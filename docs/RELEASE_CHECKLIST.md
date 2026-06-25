# StudyCast v0.1 Release Checklist

- [ ] Pick the exact UxPlay commit and build the helper.
- [ ] Run `scripts/bootstrap_release_deps.sh`.
- [ ] Run the no-signing Xcode build.
- [ ] Run `scripts/package_unsigned_preview.sh` for the current unsigned preview DMG.
- [ ] If Developer ID credentials are available, run `SIGNING_MODE=developer-id scripts/package_release.sh` for the notarized DMG.
- [ ] Validate the DMG on a clean Apple Silicon Mac.
- [ ] For the unsigned preview DMG, confirm the README explains manual approval in System Settings > Privacy & Security.
- [ ] Confirm the app works without Homebrew `uxplay`, `ffmpeg`, or `ffprobe` on `PATH`.
- [ ] Smoke test 1, 2, and 3 simultaneous AirPlay devices.
- [ ] Confirm generated MP4 master and clip files play in QuickTime.
- [ ] Update `CHANGELOG.md` with the release date.
- [ ] Upload the DMG, source tarballs, third-party notices, and source-offer notes to GitHub Releases.
- [ ] Add repository topics and social preview.
