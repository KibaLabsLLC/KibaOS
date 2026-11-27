# KibaOS Overview

KibaOS is a desktop operating system built on Arch Linux, with its desktop
environment derived from the Chromium project. It is developed by Kiba Labs, LLC
across several repositories. The user-facing product promise is a simple, calm,
coherent desktop with **no plumbing exposed** — no developer menus, no
ChromiumOS branding, no browser chrome.

## Repository Layout

| Path | What it is |
| --- | --- |
| `build-kibaos.sh` | The build orchestrator. Stages an Arch build root, bootstraps the Lumen source, builds source packages, assembles a candidate repo, and produces the ISO. |
| `build-chromeos-ash.sh` | Helper entry point for the Chromium/Ash source compile. |
| `ci/` | Build and release tooling: Lumen bootstrap, GN dependency resolution, patch-series verification, package builds, ISO smoke tests, release gates. See `ci/README.md`. |
| `patches/` | The quilt-style patch series applied to the Lumen/Chromium tree. `SERIES` lists order; `generated/` is CI-produced output — do not hand-edit. |
| `pins/` | Pinned upstream inputs: `chromium.sha`, `chromium.version`, `chromium.provenance`, `arch.snapshot`, and the release signing key. |
| `chromiumos-ash/` | The `chromiumos-ash` Arch package: session scripts (Weston kiosk compositor wrapping the Ash session), desktop files, PAM/sysusers/tmpfiles config, branding overrides, and the package `PKGBUILD`. |
| `kibaos-greeter/` | Login greeter. |
| `kibaos-login/` | Login/session plumbing. |
| `kibaos-system-helper/` | Privileged system operations used by the desktop. |
| `kibaos-power/` | Power management glue. |
| `kibaos-hardware/` | Hardware enablement. |
| `kibaos-host-bridge/` | Bridge between the Ash session and the host Linux system. |
| `kibaosfs/` | Filesystem/data layer shipped as its own package. |
| `kibaos-android/` | Android app windowing support. |
| `kibaos-kai/` | kAI voice assistant daemon for the KibaDE shell (whisper.cpp + Piper). |
| `kibaos-account-helper/` | Local account management. |
| `kibaos-webapp-shortcuts/` | Web app shortcut integration. |
| `files-app/` | The KibaOS Files app sources. |
| `installer/` | Install media tooling. |
| `kibaos-full/` | Meta package pulling in the complete KibaDE desktop with local AI. |
| `shill-nm-adapter/` | Adapts ChromeOS shill networking concepts to NetworkManager. |
| `vm/` | Scripts for booting/testing KibaOS in a VM. |
| `branding/`, `assets/` | Logos, wallpapers, screenshots. |

## Sibling Repositories

- **[Lumen](https://github.com/KibaLabsLLC/Lumen)** — the KibaOS windowing
  compositor: the Chromium fork without `chrome/`. This is where Ash lives.
  See [lumen-and-kibade.md](lumen-and-kibade.md).
  
## How the Pieces Fit

```
KibaOS ISO
└── Arch Linux base (pinned by pins/arch.snapshot)
    ├── chromiumos-ash package      ← built from the Lumen tree in this repo's CI
    ├── kibaos-* packages           ← built from the directories in this repo
    └── kibaos-full (meta)          ← pulls the whole KibaDE desktop together
```

The desktop session (`chromiumos-ash/chromiumos-ash-session.sh`) starts a Weston
kiosk compositor and runs the Ash-based desktop as its client, falling back to
software rendering when no usable 3D render node exists. The greeter handles
login, and the session is supervised so a crash shows `kibaos-session-error`
instead of a bare prompt.
