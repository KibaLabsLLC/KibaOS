# Build, Patches, and Pins

## Build Flow

`build-kibaos.sh` is the single orchestrator. Its stages, roughly in order:

1. **Arch build root** — `ci/bootstrap-arch-root.sh` creates a pacman-native
   build environment from `pins/arch.snapshot`.
2. **depot_tools + Lumen bootstrap** — `ci/bootstrap-chromium-src.sh` clones
   `KibaLabsLLC/Lumen` (`KIBAOS_LUMEN_REPOSITORY`, default branch `main`) into
   the build tree, resolves its `DEPS` with `ci/resolve-deps.py`, and verifies
      the patch series will apply. `ci/system-tools.sh` links the build root's
   own `gn` and `ninja` packages into the checkout and has the resolver skip
   Chromium's prebuilt copies of those two, so only tools pacman does not
   provide are downloaded; Chromium's prebuilt Clang/LLVM toolchain is always
   kept, because the tree's build config pins and asserts that exact clang, and
   anything an earlier bootstrap put in its path is cleared first. A package
   that cannot do the job keeps Chromium's copy instead (an older `gn` cannot
   read the tree's list-form `script_executable`), the package build stops at
   once on such a `gn` link instead of running the recovery loop, and
   `KIBAOS_SYSTEM_TOOLS=0` keeps the downloads.
   `ci/restore-truncated-sources.py --restore-dir third_party/abseil-cpp`
   puts the pinned `third_party/abseil-cpp` back when a checkout has lost or
   emptied part of it (which reads as undefined `ABSL_*` macros), deletions
   included, and re-applies the series' abseil hunks;
   `KIBAOS_RESTORE_ABSEIL=0` leaves it alone. Files that survived the import
   are not self-contained either: it dropped every `#include "absl/..."` line
   from that directory, so `ci/restore-abseil-includes.py` puts the 4,488
   lines in `ci/abseil-includes.json` back where the Chromium copy has them,
   inside the `#if` that needs them and with their blank lines, which leaves
   the directory byte for byte as Chromium ships it. The manifest names each
   block with the two lines it sat between and the occurrence of that pair,
   and is rebuilt by `--generate` from Chromium's copy and Lumen's rather
   than edited; the repair itself is a fixed order of rules (already there,
   then the recorded pair, then its last occurrence, then the top of the
   file, then the line above), so the same tree always produces the same
   result and a second run writes nothing. A block with nowhere to go stops
   the build and names itself instead of being guessed at, and a file Lumen
   has already restored is left exactly as it is. Both tools run before
   ninja, in the package build too, and a header whose includes are still
   missing fails its first user on `ABSL_NAMESPACE_BEGIN` (see the
   `abseil-cpp` section below).
3. **Patch series** — the patches in `patches/SERIES` are applied to the
   Lumen tree. `ci/verify-patch-series.sh` and `ci/refresh-bootstrap-series.sh`
   manage this; the series is the integration contract between the two repos.
4. **Source packages** — `kibaosfs` and `chromiumos-ash`
   (`ci/build-kibaosfs-package.sh`, `ci/build-current-chromiumos-ash-package.sh`).
   The Ash package compiles the Lumen tree via `build-chromeos-ash.sh` /
   GN into the desktop binary and resources.
5. **Candidate repo + ISO** — built packages go into a pacman repo
   (`ci/build-private-repo.sh`, release variants), then ISO assembly,
   verification (`ci/verify-iso-*.sh`), SBOM, and checksums.

Docker-based local build (from `CONTRIBUTING.md`):

```bash
docker run --rm --privileged -v "$PWD:/w" -e RUN_NUM=local \
  archlinux:latest /w/build.sh
```

Note: CONTRIBUTING refers to `build.sh`; in the current tree the entry point
is `build-kibaos.sh` (plus `build-chromeos-ash.sh` for the Ash compile step).
Full builds need Docker, ~15 GB free space, and Linux.

## The Patch Series

- `patches/SERIES` is the authoritative ordered list. Every patch must be
  listed; CI verifies the series applies cleanly against the pinned Lumen
  revision.
- Naming is sentence-style and describes the behavior the patch produces
  (e.g. `0071-files-a-cut-file-stays-dimmed.patch`). Match the tone and
  numbering when adding patches.
- The `00xx-files-*` range builds the KibaOS Files app port inside Ash;
  `0162`–`0180` reconcile the build after the `chrome/` cut (GN parse fixes,
  dropped chrome dependency edges, restored protos/buildflags); `0900` is the
  GN evaluation convergence step that runs last.
- `patches/generated/` holds machine-produced content. Do not hand-edit it;
  regenerate via CI tooling instead.

## Pins

`pins/` pins the exact upstream inputs for reproducible builds:

- `chromium.sha` / `chromium.version` / `chromium.provenance` — the Lumen
  upstream snapshot the series is verified against.
- `arch.snapshot` — the Arch package set for the build root and ISO.
- `kibaos-release.gpg` — release signing key.

Changing a pin changes what every patch must apply to. Update pins only with a
matching re-verification of the patch series (`ci/refresh-bootstrap-series.sh`,
`ci/verify-patch-series.sh`) and call it out explicitly in the PR.

## CI and Gates

GitHub Actions builds official ISOs on merges. Key gates to keep green:

- `ci/verify-patch-series.sh` — series applies and stays ordered.
- `ci/source-integrity-gate.sh` / `ci/public-release-leak-gate.sh` — no
  secrets, private paths, or non-public references leak into artifacts.
- `ci/chromium-candidate-gate.sh` — Lumen snapshot promotion.
- `ci/iso-install-smoke.sh`, `ci/iso-upgrade-smoke.sh`, `ci/vm-smoke.sh` —
  boot/install/upgrade verification.
- `ci/public-docs-gate.sh` — public documentation checks.

When touching build scripts, run the narrowest relevant script locally first;
most accept `KIBAOS_*` environment variables documented in their headers.
