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
| Upstream release | 1.74 |
| Upstream base commit | `a73e88c77d7aaa70c1cef0cb31b6407787b9ca1d` |

`uxplay-patches/` holds StudyCast's changes as a patch series against that base
commit, so they can be read on their own and replayed onto a newer upstream:

| Patch | What it does |
|---|---|
| 0001 | Discovery and reception over Apple peer-to-peer (AWDL). This is what lets a sender reach StudyCast with no network configuration; see [../docs/AWDL_DISCOVERY.md](../docs/AWDL_DISCOVERY.md). |
| 0002 | Decrypt mirror payloads out of place rather than over the input buffer. |
| 0003 | AirPlay 2 mirroring research path, disabled by default. Not used by the shipping configuration; see [../docs/AP2_MIRRORING_KEY_SEARCH.md](../docs/AP2_MIRRORING_KEY_SEARCH.md). |

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
