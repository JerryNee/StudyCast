# Source Offer

StudyCast release builds bundle UxPlay as `Contents/Helpers/uxplay`. That helper
is a modified UxPlay, so GPLv3 requires the corresponding source to be
distributed with it.

The source ships inside the StudyCast source archive:

```
StudyCast-<version>-source.tar.gz
  └── third_party/
      ├── UxPlay/          complete helper source, modifications applied
      ├── uxplay-patches/  the modifications as a patch series
      └── README.md        upstream URL, base commit, how to rebuild
```

No separate UxPlay archive is published. The vendored tree is the exact source
the bundled helper is built from, and the patch series shows what was changed
relative to upstream.

Each binary release must publish:

- The StudyCast source archive, which carries `third_party/UxPlay`.
- The commit identifying the vendored helper, in the release notes.
- The GPLv3 license text.

If a release ever bundles a helper built from a tree outside this repository,
`scripts/package_release.sh` emits a matching `UxPlay-<commit>-source.tar.gz`,
and that archive must be published alongside the DMG.

StudyCast release builds also bundle GStreamer dynamic libraries/plugins and
ffmpeg/ffprobe from the local Homebrew installation. Include the matching
license files and provide the corresponding source availability required by
their licenses for release builds.
