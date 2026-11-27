# AGENTS.md

Guidance for AI agents working in this repository.

KibaOS is a desktop operating system built on Arch Linux with a Chromium-derived
desktop. Maintained by Kiba Labs, LLC. Human-facing contribution rules live in
[CONTRIBUTING.md](CONTRIBUTING.md); this file and `agent-context/` are the
agent-facing versions.

## Start Here

Read the `agent-context/` folder before making changes:

1. [agent-context/overview.md](agent-context/overview.md) — what KibaOS is and
   what every top-level directory does.
2. [agent-context/lumen-and-kibade.md](agent-context/lumen-and-kibade.md) —
   **the core architecture**: Lumen is the Chromium fork that deletes
   `chrome/` and replaces it with shell delegation glue (`LumenShellDelegate`
   plus `lumen/kibaos_*` libraries) so the Ash shell runs as the KibaDE
   desktop instead of a browser.
3. [agent-context/build-and-patches.md](agent-context/build-and-patches.md) —
   build flow, the patch series, pins, and CI gates.

## Non-Negotiables

- **No chrome comes back.** The `chrome/` browser tree does not exist in Lumen
  and must not be reintroduced. Shell behavior is implemented via delegates
  and KibaOS glue, never by pulling browser components in.
- **Graceful degradation.** Any new Ash delegate gets a minimal implementation
  that returns empty/no-op instead of crashing when its backing service is
  absent.
- **No plumbing leaks to users.** Match the project's calm, coherent, simple
  design principle (see CONTRIBUTING.md).
- **Conventional Commits** for all commit messages.
- **Never commit secrets** or local configuration values; `patches/generated/`
  is not hand-edited; pins move only with a re-verified patch series.

## Sibling Repositories

- [Lumen](https://github.com/KibaLabsLLC/Lumen) — the compositor (Ash without chrome).
