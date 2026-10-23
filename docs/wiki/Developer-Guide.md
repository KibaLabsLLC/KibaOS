<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# Developer Guide

This document outlines engineering guidelines, cleanroom rules, coding standards, and testing procedures for KibaOS contributors.

## Cleanroom Engineering Rules

KibaOS adheres strictly to cleanroom reverse-engineering principles:

1. Prohibition of Proprietary Code: Never inspect, reference, or copy leaked proprietary source code (e.g., Windows NT 3.5/4.0/2000 leaks or WRK). Any contribution derived from non-public source code will be rejected immediately.
2. Sources of Truth: Definitions, structures, and API contracts must originate from official public headers (Windows SDK/WDK), Windows 11 public PDB symbols, black-box runtime behavior observation, or Wine documentation for user-mode behavior.
3. GPL Code Isolation: Do not copy GPL-licensed code directly from Linux into kernel drivers. Study the technical design and implement a cleanroom solution.

## Architecture Guidelines

- Architecture Neutrality: Keep common kernel, executive, and driver code free of architecture `#ifdef` directives. Route platform-specific actions through architecture descriptor structures or HAL hooks.
- Structure Offsets: Mirror Windows 11 structure layouts exactly using public PDB symbols. Use compile-time assertions (`C_ASSERT(FIELD_OFFSET(...))`) to guarantee offset parity.
- 64-Bit Pointer Width: Use `sizeof(ULONG_PTR)` rather than conditional preprocessor flags when checking pointer size.

## Coding Style and License Headers

- Header Format: Every new C/C++ source file must begin with the standard header block:

```c
/*
 * PROJECT:     KibaOS Kernel / Subsystem Name
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Brief description of file purpose
 * COPYRIGHT:   Copyright (c) 2026 Kiba Labs and the KibaOS contributors
 */
```

- Code Diffs: Do not add inline comments inside code diffs. Keep diffs concise and focused on functional changes.

## Testing Against Windows 11 Baseline

- API Verification: Test API implementations against a running Windows 11 baseline. When an API test fails on both KibaOS and Windows 11, update the test expectation rather than forcing non-standard behavior.
- VM Testing: Use the `vm_monitor.py` script for automated headless virtual machine testing:

```bash
python3 scripts/vm_monitor.py --timeout 30 --stall 6
```

## Submitting Changes

- Title Prefix: Use component tags in commit titles, such as `[NTOSKRNL]`, `[DRIVERS/USB]`, or `[EXPLORER]`.
- Commit Body: Include concise `Problem:`, `Why:`, and `How:` sections describing the bug or feature, or use `feat:` for short additions.
