# Source Offer

StudyCast release builds bundle UxPlay as `Contents/Helpers/uxplay`.

Each binary release must publish:

- The exact UxPlay source archive used for `Contents/Helpers/uxplay`.
- The UxPlay commit hash in the release notes.
- Any local UxPlay patches applied before building the helper.
- The GPLv3 license text.

The local release scripts require `UXPLAY_SOURCE_DIR` and `UXPLAY_COMMIT` so the
matching source archive can be attached to GitHub Releases.

StudyCast release builds also bundle GStreamer dynamic libraries/plugins and
ffmpeg/ffprobe from the local Homebrew installation. Include the matching
license files and provide the corresponding source availability required by
their licenses for release builds.
