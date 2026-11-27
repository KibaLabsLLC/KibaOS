# Agent Context

Context for AI agents (and humans) working on the KibaOS repository. Start here,
then follow the reading order below. When this folder and other documentation
disagree, trust the code and raise the discrepancy.

## Reading Order

1. [overview.md](overview.md) — what KibaOS is and what every top-level directory does.
2. [lumen-and-kibade.md](lumen-and-kibade.md) — the core architecture: how Lumen cuts
   the chrome/ browser out of Chromium and replaces it with shell delegation glue for
   the KibaDE desktop.
3. [build-and-patches.md](build-and-patches.md) — how the ISO gets built: the patch
   series, pins, CI scripts, and what must stay in sync.

## Ground Rules

- Follow [CONTRIBUTING.md](../CONTRIBUTING.md): Conventional Commits, focused PRs,
  and the design principle — **does this make the system feel simpler, or does it
  expose more plumbing?**
- KibaOS is GPL-3.0, but Lumen and its patches touch BSD-licensed Chromium sources.
  Never copy GPL code into Lumen patch content or Chromium-derived files.
- Never commit secrets, credentials, tokens, or local configuration values.
- Do not edit files under `patches/generated/` by hand; they are produced by CI tooling.
- Do not bump `pins/chromium.sha` or `pins/chromium.version` casually; see
  [build-and-patches.md](build-and-patches.md) for the update procedure.
