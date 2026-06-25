# Troubleshooting

## AirPlay Target Does Not Appear

- Confirm StudyCast has Local Network permission in System Settings.
- Keep the Mac and device on the same network and VLAN.
- Stop other AirPlay receiver apps before starting projection.
- Restart projection so StudyCast can publish fresh receiver names.

## Projection Starts But No Preview Appears

- Wait a few seconds after selecting the AirPlay target.
- Confirm GStreamer was bundled in the release app or installed through Homebrew for a source build.
- Check the station `.uxplay.log` in the output session directory.

## Recording Does Not Produce a Clip

- StudyCast records a continuous master while projection is running, then trims marked intervals when projection stops.
- Click **Stop Projection** to finalize outputs.
- Confirm bundled `ffmpeg` and `ffprobe` are present in `StudyCast.app/Contents/Helpers` for release builds.

## Audio Output Is Missing

- Click the refresh audio button in the toolbar.
- Re-select the monitoring output from the station menu.
- If the selected device was unplugged, choose System Default or another available device.

## Gatekeeper or "Damaged App" Warning

- The current preview DMG is ad-hoc signed but not Apple Developer ID signed or notarized.
- Try launching StudyCast once. When macOS blocks it, open **System Settings > Privacy & Security**.
- In the Security section, choose **Open Anyway** for StudyCast, then confirm **Open**.
- If the button does not appear, make sure you attempted to open the app from Applications first.
- A future Developer ID release should avoid this manual approval step.

## Release Signing Fails

- Confirm `DEVELOPER_ID_APPLICATION` matches a valid Developer ID Application certificate.
- Confirm `NOTARYTOOL_PROFILE` exists:

```sh
xcrun notarytool history --keychain-profile "$NOTARYTOOL_PROFILE"
```

- Run `scripts/bootstrap_release_deps.sh` before packaging.
