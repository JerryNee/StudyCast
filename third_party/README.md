# Vendored dependencies

## UxPlay

`UxPlay/` is the AirPlay receiver StudyCast runs as a helper process, vendored
with StudyCast's modifications applied.

It lives here rather than in a separate checkout for two reasons. StudyCast
ships the compiled `uxplay` binary inside `StudyCast.app/Contents/Helpers`, and
that binary is modified, so GPLv3 obliges us to distribute the corresponding
source alongside it. And a clone of this repository can now build a working
StudyCast without hunting down a patched UxPlay elsewhere.

Both projects are GPLv3, so the combination is fine. UxPlay's own `LICENSE` and
`README.md` travel with the vendored tree and are copied into the app bundle's
notices directory at package time.

### Provenance

| | |
|---|---|
| Upstream | https://github.com/FDH2/UxPlay |
| Upstream base commit | `9c24ed264f91948e4a32a51c5f8ade3ece30e58c` |
| Base commit subject | "README updates for ARM windows (from @christian-fuego)" |

`uxplay-patches/` holds StudyCast's changes as a patch series against that
commit, so they can be read on their own and replayed onto a newer upstream:

| Patch | What it does |
|---|---|
| 0001 | Continuous MP4 audio capture, which StudyCast's recording depends on. |
| 0002 | `-p2p`: advertise and accept AirPlay over Apple peer-to-peer. This is what lets a sender reach StudyCast with no network configuration; see [../docs/AWDL_DISCOVERY.md](../docs/AWDL_DISCOVERY.md). |
| 0003 | Decrypt mirror payloads out of place rather than over the input buffer. |
| 0004 | AirPlay 2 mirroring research path, off by default. Not used by the shipping configuration; see [../docs/AP2_MIRRORING_KEY_SEARCH.md](../docs/AP2_MIRRORING_KEY_SEARCH.md). |

Patch 0002 is deliberately shaped to be offerable upstream: it adds an
ordinary option, leaves default behaviour untouched, and carries none of
StudyCast's own concerns.

### Updating to a newer upstream

```sh
git clone https://github.com/FDH2/UxPlay /tmp/uxplay-new
cd /tmp/uxplay-new
git checkout <new-upstream-ref>
git am /path/to/StudyCast/third_party/uxplay-patches/*.patch
```

Resolve any conflicts there, re-export the series with `git format-patch`, then
copy the resulting tree over `third_party/UxPlay/` and update the base commit
above. Only files tracked by upstream git belong in the vendored tree -- build
output must not be committed.

### Building

```sh
cd third_party/UxPlay
cmake .
make -j"$(sysctl -n hw.ncpu)"
```

`scripts/bundle_runtime.sh` picks this tree up automatically. Set
`UXPLAY_SOURCE_DIR` to override it with a checkout elsewhere.
