//
//  ContentView.swift
//  Control bar (study / headset count / output / record) + a grid of station
//  tiles. Live video preview is added on top of these tiles in the next step
//  (ScreenCaptureKit); for now each tile shows status + the name to pick on the
//  headset.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 16)]

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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.stations) { station in
                        StationTile(station: station)
                    }
                }
                .padding(16)
            }
        }
    }

    private var controlBar: some View {
        HStack(alignment: .bottom, spacing: 14) {
            field("Study") {
                TextField("Study name", text: $model.studyName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(model.isProjecting)
            }
            field("Headsets") {
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
}

struct StationTile: View {
    @ObservedObject var station: Station

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                VStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(height: 150)

            TextField("Label", text: $station.label)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 4) {
                Text("镜像选:").font(.caption2).foregroundStyle(.secondary)
                Text(station.airplayName).font(.caption2.monospaced())
                Spacer()
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
            if let outputFile = station.outputFile {
                Text(outputFile.lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
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
