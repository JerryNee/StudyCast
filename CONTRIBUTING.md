# Contributing to StudyCast

Thanks for helping improve StudyCast.

## Development Setup

Start with [docs/INSTALL.md](docs/INSTALL.md). A useful first validation is:

```sh
xcodebuild -project StudyCast.xcodeproj -scheme StudyCast -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

## Pull Request Expectations

- Keep changes focused on one behavior or release task.
- Update docs when setup, release, helper paths, or user-visible behavior changes.
- Avoid committing generated build products, app bundles, DMGs, local recordings, or DerivedData.
- Preserve GPLv3 and third-party notice information when touching bundled runtime logic.

## Testing

For code changes, include at least:

- A no-signing Xcode build.
- A short manual note for any AirPlay, recording, audio-output, or packaging behavior that cannot be tested in CI.

## Style

- Follow the existing SwiftUI and Swift concurrency style.
- Prefer bundle-first helper resolution so release builds remain self-contained.
- Keep user-facing errors direct and actionable.
