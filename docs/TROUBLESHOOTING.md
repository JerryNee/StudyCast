# Troubleshooting

## AirPlay Target Does Not Appear

- Confirm StudyCast has Local Network permission in System Settings.
- Keep Wi-Fi on for both devices. Stations are published over Apple
  peer-to-peer (AWDL), which needs the Wi-Fi radio even when the sender is on
  another network. Joining the same network or VLAN is not required.
- Stop other AirPlay receiver apps before starting projection.
- Restart projection so StudyCast can publish fresh receiver names.

## AirPlay Target Appears But Will Not Connect

- **Check this first: macOS's own AirPlay Receiver must be on.** System
  Settings → General → AirDrop & Handoff → AirPlay Receiver. With it off,
  senders still discover the stations and list them, but every connection is
  refused and the helper never sees a byte — no `Accepted IPv6 client`, no
  `Remote:` line in the station log. Measured 8/8 success with it enabled
  against 0/3 with it disabled, same Mac and same iPad. StudyCast now warns
  when projection starts while the setting is off. Note that `awdl0` stays
  `active` either way, so `ifconfig` will not reveal this.
- The sender is asking for the station's pairing code. Each station shows its
  own four-digit code next to the receiver name: `1111`, `2222`, `3333`.
- If the sender reports a connection failure without prompting for a code,
  check `SO_RECV_ANYIF` support in the UxPlay helper — see
  [AWDL_DISCOVERY.md](AWDL_DISCOVERY.md). A receiver that is visible but never
  sees an incoming connection is the signature of that option being missing.
  Note that a disabled system AirPlay Receiver produces the *same* signature,
  so rule the setting out before suspecting the helper build.

## Projection Starts But No Preview Appears

- Wait a few seconds after selecting the AirPlay target.
- Confirm GStreamer was bundled in the release app or installed through Homebrew for a source build.
- Check the station `.uxplay.log` in the output session directory.

## Recording Does Not Produce a Clip

- StudyCast records a continuous master while projection is running, then trims marked intervals when projection stops.
- Click **Stop Projection** to finalize outputs.
- Confirm bundled `ffmpeg` and `ffprobe` are present in `StudyCast.app/Contents/Helpers` for release builds.
- If a station reports that a marked interval produced no clip, the message
  distinguishes the causes: footage lost with a crashed receiver, a segment
  that could not be trimmed, and a mark that matched no segment at all. See
  [RECORDING.md](RECORDING.md) for what each means.

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
