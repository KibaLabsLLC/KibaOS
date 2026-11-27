# Lumen, KibaDE, and the Chrome Cut

This is the most important architecture document in this folder. If an agent
understands one thing about KibaOS, it should be this.

## What Lumen Is

[Lumen](https://github.com/KibaLabsLLC/Lumen) is the KibaOS windowing
compositor. It is an experimental fork of Chromium that keeps:

- `ash/` — the Ash window manager (the Chrome OS shell)
- `aura/` — the Aura windowing library
- `chromeos/` — ChromeOS platform components, rebranded for KibaOS
- the build system and dependency trees those need

…and **deletes the entire `chrome/` directory**. The browser is not built,
not shipped, and not referenced. What remains is compiled into an executable
target that is still *named* `chrome` (for GN/build compatibility with the
upstream tree), but it is not a browser — it is the KibaDE desktop process.

## Why Chrome Is Cut

In upstream Chromium, `chrome/browser/` is the layer that implements Ash's
feature surface: it owns every `ShellDelegate` sub-delegate, backs them with
browser services, and pulls the entire UI/omnibox/tab/download stack with it.
For KibaOS that layer is the wrong product: users get the desktop (KibaDE),
not a web browser with a desktop attached.

Removing `chrome/` buys:

- a dramatically smaller build and attack surface,
- no browser UI, omnibox, or settings surfaces to hide or rebrand,
- a hard boundary: anything Ash needs must be re-implemented deliberately.

The cost is that Ash no longer has a natural implementation of its delegate
interfaces. Lumen fills that hole with **shell delegation glue**.

## The Replacement: Shell Delegation Glue

Ash never talks to Chrome directly. Every Ash feature that needs platform
behavior asks an abstract delegate interface (`ash::ShellDelegate` and its
sub-delegates). Lumen satisfies those interfaces with its own implementations,
wired to the KibaOS platform layer instead of a browser.

All of this lives in `lumen/` in the Lumen repository:

| File | Role |
| --- | --- |
| `lumen/main.cc` | Entry point. Boots base, logging, the glue layer, and the Ash shell. |
| `lumen/lumen_shell_delegate.{h,cc}` | `LumenShellDelegate`, the `ash::ShellDelegate` implementation, plus one minimal sub-delegate class per Ash feature. |
| `lumen/kibaos_shell_glue.{h,cc}` | `kibaos::ShellGlue` — owns the delegate, initialises KibaOS path/environment utilities, hands the delegate to Ash. |
| `lumen/kibaos_paths.{h,cc}` | KibaOS filesystem path resolution. |
| `lumen/kibaos_environment.{h,cc}` | KibaOS environment/session state helpers. |
| `lumen/ash_shell_init.{h,cc}` | `AshShellInit` — creates `ShellInitParams`, starts Ash, runs the UI loop, tears down. |

### Startup Order (lumen/main.cc)

1. `base::AtExitManager` and `base::CommandLine::Init`.
2. Logging to stderr.
3. `kibaos::ShellGlue glue; glue.Init()` — must complete **before** Ash shell
   creation; it instantiates `LumenShellDelegate` and initialises the KibaOS
   path/environment utilities.
4. `base::SingleThreadTaskExecutor` with `MessagePumpType::UI`.
5. `kibaos::AshShellInit` creates the shell, calls `TakeShellDelegate()` to
   hand `LumenShellDelegate` over to `ash::Shell`, and runs the message loop.

`ShellGlue` must be constructed before `ash::Shell::CreateInstance` and
destroyed after `ash::Shell::DeleteInstance`.

### The Sub-Delegates

`LumenShellDelegate` implements one `Create*()` factory per Ash feature:
capture mode, clipboard history, clipboard image model, coral, game dashboard,
accelerator prefs, accessibility, back-gesture nudge, media notifications,
nearby share, saved desks, system sounds, tasks, tab strip, focus mode, user
education, and scanner.

The design rule for every one of them: **degrade gracefully, never crash.**
Each factory returns a minimal implementation — empty lists, null child
delegates, no-op actions — so the shell boots and works without a browser.
Browser-backed behavior (tasks sync, nearby share transfer, capture mode
upload, and so on) is intentionally inert until something replaces it. When a
new `Create*Delegate()` appears in `ash/shell_delegate.h`, the Lumen build
breaks until `LumenShellDelegate` grows a matching minimal implementation.
That is by design: the delegate file is the compatibility seam between Ash and
KibaOS.

### GN Targets (lumen/BUILD.gn)

- `lumen_shell_delegate` — source_set for the delegate alone, kept separate so
  `kibaos_glue` can depend on it without a circular dep through the executable.
- `kibaos_glue` — the path/environment/shell-glue source_set.
- `ash_shell_init` — shell bootstrap (currently `testonly`).
- `chrome` — the executable from `main.cc` (currently `testonly`).

`ash_shell_init` and the executable are `testonly` because Lumen reuses Ash's
test compositor and fake display delegates for its in-process graphics
transport. Wiring a production KibaOS graphics/display transport is the known
TODO that unlocks shipping this outside test builds.

## Where KibaDE Fits

KibaDE is the desktop environment users see: the KibaOS shell, its apps, and
its look. Lumen is its foundation — the Ash window manager, driven by
`LumenShellDelegate`, is what draws the desktop, shelf, launcher, and system
UI. Everything KibaDE-specific that Ash needs is delivered through the glue
layer (`kibaos_shell_glue`, `kibaos_paths`, `kibaos_environment`) and through
KibaOS patches, never through a browser. Release packaging for the desktop is
handled from this repository (see `kibaos-full/` and `ci/release.sh`, which
publishes to `KibaLabsLLC/KibaDE`).

## How KibaOS Builds It

- `build-kibaos.sh` bootstraps the Lumen source via
  `ci/bootstrap-chromium-src.sh` (`KIBAOS_LUMEN_REPOSITORY`, `KIBAOS_LUMEN_BRANCH`),
  resolves its `DEPS` with `ci/resolve-deps.py`, then builds the
  `chromiumos-ash` Arch package from the result.
- `patches/SERIES` is applied on top of the Lumen tree. The `0162`–`0180`
  range is the chrome-cut reconciliation: it keeps GN parsing and targets
  working without `chrome/` (dropping chrome dependency edges, restoring
  pruned protos/buildflags/visibility lists). Patch content must therefore
  never assume `chrome/` exists.
- `chromiumos-ash/PKGBUILD` builds the desktop package, and the session
  scripts in that directory launch it under Weston at login.

## Rules of Thumb for Agents

- To change shell behavior in KibaOS, change a **delegate** (in Lumen or a
  KibaOS patch). Never propose re-adding `chrome/` or pulling browser
  components in to "fix" a missing feature — implement it in the glue layer.
- New Ash delegate interfaces need a new minimal `Lumen*Delegate` in
  `lumen/lumen_shell_delegate.cc`, degrading gracefully per the rule above.
- The executable is named `chrome` but is not Chrome; do not "restore" browser
  behavior because of the name.
- KibaOS-side feature work (Files app, greeter, session scripts, helpers) does
  not belong in Lumen; keep the seam clean.
