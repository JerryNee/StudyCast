# Release Guide

StudyCast release builds are created locally. The current public beta can ship as an unsigned preview DMG, while a future Apple Developer ID build can be signed and notarized.

## Version Policy

- App marketing version: `0.1.0`.
- First public tag: `v0.1.0-beta.2`.
- Current preview binary asset: `StudyCast-0.1.0-beta.2-arm64-unsigned.dmg`.
- Future notarized binary asset: `StudyCast-0.1.0-beta.2-arm64.dmg`.
- Binary support target: Apple Silicon, macOS 26 or newer.

## Required Environment for Unsigned Preview

```sh
export RELEASE_VERSION=0.1.0-beta.2
```

The UxPlay helper comes from the vendored `third_party/UxPlay`, so its location
and commit no longer need to be supplied. Build it first:

```sh
cd third_party/UxPlay && cmake . && make -j"$(sysctl -n hw.ncpu)"
```

Build the current preview DMG:

```sh
scripts/package_unsigned_preview.sh
```

This creates `StudyCast-${RELEASE_VERSION}-arm64-unsigned.dmg`. It is ad-hoc signed but not Apple Developer ID signed or notarized, so users must approve it manually in **System Settings > Privacy & Security**.

## Required Environment for Developer ID Release

```sh
export RELEASE_VERSION=0.1.0-beta.2
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'
export NOTARYTOOL_PROFILE=studycast-notary
export SIGNING_MODE=developer-id
```

Create the notary profile once:

```sh
xcrun notarytool store-credentials "$NOTARYTOOL_PROFILE" \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password app-specific-password
```

## Build Release Assets

```sh
scripts/bootstrap_release_deps.sh
scripts/package_release.sh
```

The package script produces:

- `build/release/assets/StudyCast-${RELEASE_VERSION}-arm64-unsigned.dmg` for `SIGNING_MODE=adhoc`
- `build/release/assets/StudyCast-${RELEASE_VERSION}-arm64.dmg` for `SIGNING_MODE=developer-id`
- `build/release/assets/StudyCast-${RELEASE_VERSION}-source.tar.gz`, which carries the bundled helper's source in `third_party/UxPlay`
- `build/release/assets/ThirdPartyNotices.md`
- `build/release/assets/SourceOffer.md`

## Publish Checklist

- Confirm `CHANGELOG.md` has the release date.
- Confirm `README.md` download instructions match the release asset names.
- Confirm `Resources/ThirdPartyNotices` names UxPlay, GStreamer, ffmpeg, and source availability.
- Confirm the source archive contains `third_party/UxPlay`; it is the GPLv3 corresponding source for the bundled helper.
- Run the no-signing CI build locally.
- For unsigned preview releases, run `scripts/package_unsigned_preview.sh` and verify the DMG installs after manual Gatekeeper approval.
- For Developer ID releases, run `SIGNING_MODE=developer-id scripts/package_release.sh` and verify `codesign`, `spctl`, notarization, and staple checks pass.
- Smoke test with 1, 2, and 3 devices.
- Create a GitHub Release for `v${RELEASE_VERSION}` and upload all generated assets.
- Set GitHub topics and social preview as described in `docs/REPOSITORY_SETUP.md`.
