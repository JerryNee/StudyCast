//
//  ContentView.swift
//  Control bar (study / device count / output / record) + a grid of station
//  tiles. Each tile embeds a local RTP preview from its hidden UxPlay helper.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage("StudyCast.previewGridColumns") private var previewGridColumns = 0
    @AppStorage("StudyCast.previewImageMode") private var previewImageModeRaw = PreviewImageMode.fill.rawValue
    @AppStorage("StudyCast.tileDetailMode") private var tileDetailModeRaw = TileDetailMode.compact.rawValue
    @State private var didFitWindowThisLaunch = false
    @State private var maximizedStationID: UUID?

    private var previewImageMode: PreviewImageMode {
        PreviewImageMode(rawValue: previewImageModeRaw) ?? .fill
    }

    private var tileDetailMode: TileDetailMode {
        TileDetailMode(rawValue: tileDetailModeRaw) ?? .compact
    }

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            if let err = model.lastError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { proxy in
                if let station = maximizedStation {
                    stationTile(station, isMaximized: true)
                        .frame(width: max(1, proxy.size.width - 24), height: max(120, proxy.size.height - 24))
                        .padding(12)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                } else {
                    let metrics = PreviewGridMetrics(
                        containerSize: proxy.size,
                        stationCount: model.stations.count,
                        preferredColumns: previewGridColumns,
                        detailMode: tileDetailMode
                    )

                    LazyVGrid(columns: metrics.gridItems, spacing: metrics.spacing) {
                        ForEach(model.stations) { station in
                            stationTile(station, isMaximized: false)
                                .frame(height: metrics.tileHeight)
                        }
                    }
                    .padding(metrics.padding)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                }
            }
        }
        .onAppear {
            guard !didFitWindowThisLaunch else { return }
            didFitWindowThisLaunch = true
            fitWindowToScreen()
        }
        .onChange(of: model.stations.map(\.id)) { _, stationIDs in
            if let maximizedStationID, !stationIDs.contains(maximizedStationID) {
                self.maximizedStationID = nil
            }
        }
        .onExitCommand {
            if maximizedStationID != nil {
                maximizedStationID = nil
            }
        }
    }

    private var maximizedStation: Station? {
        guard let maximizedStationID else { return nil }
        return model.stations.first { $0.id == maximizedStationID }
    }

    private var controlBar: some View {
        HStack(alignment: .bottom, spacing: 14) {
            field("Study") {
                TextField("Study name", text: $model.studyName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(model.isProjecting)
            }
            field("Devices") {
                Stepper(value: Binding(
                    get: { model.stations.count },
                    set: { model.setStationCount($0) }
                ), in: 1...8) {
                    Text("\(model.stations.count)").frame(width: 22)
                }
                .disabled(model.isProjecting)
            }
            field("Output") {
                Button { chooseOutput() } label: {
                    Text(model.outputDirectory.path)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                .disabled(model.isProjecting)
            }
            Spacer()
            if model.currentSessionDir != nil {
                Button("Show in Finder") { model.revealOutputInFinder() }
            }
            Button {
                model.refreshAudioOutputDevices()
            } label: {
                Label("Refresh Audio Devices", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("刷新音频输出设备")
            layoutMenu
            projectionButton
            recordButton
        }
        .padding(12)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private var layoutMenu: some View {
        Menu {
            if maximizedStation != nil {
                Button {
                    maximizedStationID = nil
                } label: {
                    Label("Return to Grid", systemImage: "rectangle.grid.2x2")
                }

                Divider()
            }

            Button {
                fitWindowToScreen()
            } label: {
                Label("Fit Window to Screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Divider()

            Menu {
                ForEach(model.stations) { station in
                    Button {
                        maximizedStationID = station.id
                    } label: {
                        Label(
                            stationDisplayName(station),
                            systemImage: maximizedStationID == station.id ? "checkmark" : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                }
            } label: {
                Label("Maximize Station", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            Divider()

            Picker("Columns", selection: $previewGridColumns) {
                Text("Auto").tag(0)
                ForEach(1...8, id: \.self) { value in
                    Text("\(value)").tag(value)
                }
            }

            Picker("Image", selection: $previewImageModeRaw) {
                Text("Fill").tag(PreviewImageMode.fill.rawValue)
                Text("Fit").tag(PreviewImageMode.fit.rawValue)
            }

            Picker("Tiles", selection: $tileDetailModeRaw) {
                Text("Compact").tag(TileDetailMode.compact.rawValue)
                Text("Expanded").tag(TileDetailMode.expanded.rawValue)
            }
        } label: {
            Label("Layout", systemImage: "rectangle.grid.2x2")
        }
        .help("布局")
    }

    private func stationTile(_ station: Station, isMaximized: Bool) -> some View {
        StationTile(
            station: station,
            audioOutputManager: model.audioOutputManager,
            imageMode: previewImageMode,
            detailMode: tileDetailMode,
            isMaximized: isMaximized,
            onToggleMaximized: {
                maximizedStationID = isMaximized ? nil : station.id
            }
        )
    }

    private func stationDisplayName(_ station: Station) -> String {
        let trimmed = station.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? station.airplayName : trimmed
    }

    private var projectionButton: some View {
        Button {
            if model.isProjecting {
                Task { await model.stopProjection() }
            } else {
                model.startProjection()
            }
        } label: {
            Label(model.isProjecting ? "Stop Projection" : "Start Projection",
                  systemImage: model.isProjecting ? "airplayvideo.badge.exclamationmark" : "airplayvideo")
                .frame(width: 155)
        }
        .tint(model.isProjecting ? .orange : .accentColor)
        .controlSize(.large)
    }

    private var recordButton: some View {
        Button {
            if model.isRecording {
                model.stopRecording()
            } else {
                model.startRecording()
            }
        } label: {
            Label(model.isRecording ? "Stop Recording" : "Start Recording",
                  systemImage: model.isRecording ? "stop.fill" : "record.circle")
                .frame(width: 150)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.isProjecting)
        .tint(model.isRecording ? .red : .accentColor)
        .controlSize(.large)
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDirectory = url
        }
    }

    private func fitWindowToScreen() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "StudyCast" }),
                  let screen = window.screen ?? NSScreen.main else {
                return
            }

            let visibleFrame = screen.visibleFrame
            let horizontalInset = max(36, visibleFrame.width * 0.04)
            let verticalInset = max(36, visibleFrame.height * 0.05)
            let targetWidth = min(visibleFrame.width - horizontalInset * 2, max(1180, visibleFrame.width * 0.88))
            let targetHeight = min(visibleFrame.height - verticalInset * 2, max(760, visibleFrame.height * 0.84))
            let targetFrame = NSRect(
                x: visibleFrame.midX - targetWidth / 2,
                y: visibleFrame.midY - targetHeight / 2,
                width: targetWidth,
                height: targetHeight
            )

            window.setFrame(targetFrame, display: true, animate: false)
        }
    }
}

private enum PreviewImageMode: String {
    case fill
    case fit

    var contentMode: ContentMode {
        switch self {
        case .fill: return .fill
        case .fit: return .fit
        }
    }
}

private enum TileDetailMode: String {
    case compact
    case expanded
}

private struct PreviewGridMetrics {
    let columns: Int
    let tileHeight: CGFloat
    let spacing: CGFloat = 12
    let padding: CGFloat = 12

    var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing), count: columns)
    }

    init(containerSize: CGSize, stationCount: Int, preferredColumns: Int, detailMode: TileDetailMode) {
        let count = max(1, stationCount)
        let maxColumns = min(8, count)
        let availableWidth = max(1, containerSize.width - padding * 2)
        let availableHeight = max(1, containerSize.height - padding * 2)

        if preferredColumns > 0 {
            columns = min(max(1, preferredColumns), maxColumns)
        } else {
            columns = Self.bestColumns(
                count: count,
                maxColumns: maxColumns,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                spacing: spacing,
                detailMode: detailMode
            )
        }

        let rows = Int(ceil(Double(count) / Double(columns)))
        let rowSpacing = CGFloat(max(0, rows - 1)) * spacing
        tileHeight = max(120, floor((availableHeight - rowSpacing) / CGFloat(rows)))
    }

    private static func bestColumns(
        count: Int,
        maxColumns: Int,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        spacing: CGFloat,
        detailMode: TileDetailMode
    ) -> Int {
        let targetAspect: CGFloat = detailMode == .compact ? 16 / 9 : 1.35
        var bestColumns = 1
        var bestScore: CGFloat = -.greatestFiniteMagnitude

        for candidate in 1...maxColumns {
            let rows = Int(ceil(Double(count) / Double(candidate)))
            let cellWidth = (availableWidth - CGFloat(candidate - 1) * spacing) / CGFloat(candidate)
            let cellHeight = (availableHeight - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let fittedWidth = min(cellWidth, cellHeight * targetAspect)
            let fittedHeight = min(cellHeight, cellWidth / targetAspect)
            let filledArea = fittedWidth * fittedHeight
            let leftoverPenalty = (cellWidth * cellHeight - filledArea) * 0.08
            let emptyCellPenalty = CGFloat(candidate * rows - count) * filledArea * 0.03
            let score = filledArea - leftoverPenalty - emptyCellPenalty

            if score > bestScore {
                bestScore = score
                bestColumns = candidate
            }
        }

        return bestColumns
    }
}

private struct StationTile: View {
    @ObservedObject var station: Station
    @ObservedObject private var preview: StationMediaPreviewModel
    @ObservedObject var audioOutputManager: AudioOutputManager
    let imageMode: PreviewImageMode
    let detailMode: TileDetailMode
    let isMaximized: Bool
    let onToggleMaximized: () -> Void

    init(
        station: Station,
        audioOutputManager: AudioOutputManager,
        imageMode: PreviewImageMode,
        detailMode: TileDetailMode,
        isMaximized: Bool,
        onToggleMaximized: @escaping () -> Void
    ) {
        self.station = station
        self.preview = station.preview
        self.audioOutputManager = audioOutputManager
        self.imageMode = imageMode
        self.detailMode = detailMode
        self.isMaximized = isMaximized
        self.onToggleMaximized = onToggleMaximized
    }

    var body: some View {
        Group {
            switch detailMode {
            case .compact:
                compactBody
            case .expanded:
                expandedBody
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var compactBody: some View {
        ZStack {
            previewPane

            VStack(spacing: 0) {
                overlayBar {
                    HStack(spacing: 8) {
                        Text(station.label)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        maximizeButton(foregroundStyle: .white.opacity(0.92))
                        Circle().fill(dotColor).frame(width: 8, height: 8)
                    }
                }

                Spacer(minLength: 0)

                overlayBar {
                    HStack(spacing: 8) {
                        Text(station.airplayName)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        compactAudioControls
                    }
                }
            }
            .padding(8)
        }
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewPane
                .layoutPriority(1)

            TextField("Label", text: $station.label)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 4) {
                Text("镜像选:").font(.caption2).foregroundStyle(.secondary)
                Text(station.airplayName).font(.caption2.monospaced())
                Spacer()
                maximizeButton(foregroundStyle: isMaximized ? Color.accentColor : Color.secondary)
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
            audioControls
            if let outputFile = station.outputFile {
                Text(outputFile.lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
    }

    private func overlayBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 8))
    }

    private func maximizeButton<S: ShapeStyle>(foregroundStyle: S) -> some View {
        Button(action: onToggleMaximized) {
            Image(systemName: isMaximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(foregroundStyle)
        .accessibilityLabel(isMaximized ? "Return to grid" : "Maximize station")
        .help(isMaximized ? "返回网格" : "最大化此 Station")
    }

    private var previewPane: some View {
        GeometryReader { proxy in
            let size = CGSize(width: max(1, proxy.size.width), height: max(1, proxy.size.height))

            ZStack {
                Color.black.opacity(0.92)
                if let image = preview.image {
                    previewImage(image, in: size)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(previewStatusText)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(8)
                    .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func previewImage(_ image: CGImage, in size: CGSize) -> some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .aspectRatio(contentMode: imageMode.contentMode)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    preview.isMuted.toggle()
                } label: {
                    Image(systemName: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(preview.isMuted ? "取消静音" : "静音")

                Slider(value: $preview.volume, in: 0...1)
                    .disabled(preview.isMuted)
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("监听输出")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("Audio Output", selection: $station.selectedAudioOutputUID) {
                    ForEach(audioOutputManager.pickerDevices(including: station.selectedAudioOutputUID)) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
            }

            if let audioOutputStatusMessage {
                Label(audioOutputStatusMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .controlSize(.small)
    }

    private var compactAudioControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                audioOutputMenu
                muteButton
                Slider(value: $preview.volume, in: 0...1)
                    .disabled(preview.isMuted)
                    .frame(width: 96)
            }
            HStack(spacing: 6) {
                audioOutputMenu
                muteButton
            }
            audioOutputMenu
        }
        .controlSize(.small)
    }

    private var audioOutputMenu: some View {
        Menu {
            Picker("监听输出", selection: $station.selectedAudioOutputUID) {
                ForEach(audioOutputManager.pickerDevices(including: station.selectedAudioOutputUID)) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Divider()
            Button {
                audioOutputManager.refresh()
                station.applySelectedAudioOutput()
            } label: {
                Label("Refresh Audio Devices", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: audioOutputStatusMessage == nil ? "speaker.wave.2.fill" : "exclamationmark.triangle.fill")
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(audioOutputStatusMessage ?? "选择监听输出")
    }

    private var muteButton: some View {
        Button {
            preview.isMuted.toggle()
        } label: {
            Image(systemName: preview.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .help(preview.isMuted ? "取消静音" : "静音")
    }

    private var icon: String {
        switch station.state {
        case .recording: return "record.circle"
        case .projecting:return "airplayvideo"
        case .error:     return "exclamationmark.triangle"
        default:         return "video"
        }
    }

    private var statusText: String {
        switch station.state {
        case .idle:         return "未开始"
        case .projecting:   return "投屏接收中"
        case .recording:    return "录制中"
        case .stopped:      return "已停止"
        case .error(let m): return m
        }
    }

    private var previewStatusText: String {
        switch station.state {
        case .projecting, .recording:
            return preview.statusText
        default:
            return statusText
        }
    }

    private var audioOutputStatusMessage: String? {
        if station.isSelectedAudioOutputUnavailable(using: audioOutputManager) {
            return "输出设备不可用"
        }
        return preview.audioOutputStatusText
    }

    private var dotColor: Color {
        switch station.state {
        case .recording: return .red
        case .projecting:return .green
        case .error:     return .orange
        case .stopped:   return .gray
        case .idle:      return .secondary
        }
    }
}
