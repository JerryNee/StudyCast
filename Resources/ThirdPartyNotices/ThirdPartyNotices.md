# Third-Party Notices

StudyCast release builds bundle UxPlay, ffmpeg, ffprobe, and GStreamer runtime
components.

UxPlay is distributed under the GNU General Public License version 3. StudyCast
bundles a modified UxPlay, and its complete source lives in `third_party/UxPlay`
with the modifications also kept as a patch series in `third_party/uxplay-patches`.
Publishing the StudyCast source archive therefore satisfies the source
requirement; see SourceOffer.md.

ffmpeg and ffprobe are distributed by the FFmpeg project under license terms that
depend on the enabled build configuration. StudyCast release builds use the
Homebrew-provided ffmpeg package and include the package license notice when
available.

GStreamer is distributed under LGPL-family licenses. The bundled runtime is kept
as separate dynamic libraries and plugins.

This notice is not legal advice. Review the license files and source-offer notes
before distributing StudyCast outside this development environment.
