# Install and Build StudyCast

## Requirements

- Apple Silicon Mac.
- macOS 26 or newer for the downloadable beta.
- Xcode with macOS SDK 26 or newer.
- Homebrew.
- GStreamer and ffmpeg:

```sh
brew install gstreamer ffmpeg
```

## UxPlay

StudyCast uses UxPlay as the AirPlay receiver helper. For source builds, build UxPlay separately and point StudyCast at the resulting executable:

```sh
git clone https://github.com/FDH2/UxPlay.git
cd UxPlay
# Build UxPlay using the upstream instructions for macOS.
export UXPLAY_SOURCE_DIR="$PWD"
export UXPLAY_PATH="$PWD/uxplay"
```

Release builds must also set `UXPLAY_COMMIT` to the exact source commit used for the bundled helper.

## Build

```sh
xcodebuild \
  -project StudyCast.xcodeproj \
  -scheme StudyCast \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

If you want the app bundle to include runtime helpers during a local Debug build, make sure `UXPLAY_PATH`, `ffmpeg`, `ffprobe`, and `gst-inspect-1.0` are available before building.

## Runtime Helper Lookup

StudyCast resolves helpers in this order:

1. Bundled helper inside `StudyCast.app/Contents/Helpers`.
2. Environment variable: `UXPLAY_PATH`, `FFMPEG_PATH`, or `FFPROBE_PATH`.
3. Common Homebrew locations such as `/opt/homebrew/bin`.

This keeps the signed release self-contained while still allowing source builds to use local tools.
