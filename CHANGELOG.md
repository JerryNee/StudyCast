# Changelog

All notable changes to StudyCast will be documented here.

## Unreleased

- Publish every station over Apple peer-to-peer (AWDL), so senders can reach
  StudyCast without joining the same network and without the network operator
  registering the Mac.
- Show a per-station four-digit pairing code, now required to connect.
- Return a station tile to its waiting state when its sender disconnects or
  switches to another station, instead of freezing on the last frame.
- Keep every recording segment from a projection run. Previously only the
  newest survived, so anything recorded before a sender reconnected was lost.

## 0.1.0-beta.2 - 2026-06-25

- Prepare StudyCast for public GPLv3 beta release.
- Add station maximization controls in the preview grid and layout menu.
- Add bundle-first runtime helper resolution for UxPlay, ffmpeg, and ffprobe.
- Add release packaging scripts for signed and notarized Apple Silicon DMGs.
- Add an unsigned preview DMG path for early users before Developer ID funding is available.
- Add open-source project documentation, CI, app icon, and repository promotion assets.
