<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# System Maintenance, Diagnostics, and OTA Engine

This document details the over-the-air update pipeline, automated update verification scripts, boot success rollback safeguards, and diagnostic bugcheck tools.

## OTA Update Engine Pipeline

The OTA update state machine is integrated into System Settings (`base/applications/systemsettings/page_updates.cpp`):

1. Manifest Fetching: Retrieves release manifests over HTTPS transport.
2. Integrity Verification: Validates cryptographic SHA-256 signatures and payload checksums.
3. Anti-Downgrade Check: Ensures release manifest build numbers exceed current system build versions.
4. Payload Staging: Extracts payload files to system update staging directories.

## OTA Engine Verification Script (`scripts/test_ota_engine.py`)

A standalone validation script that verifies update distribution pipelines:

- Validates manifest JSON schema definitions.
- Enforces HTTPS transfer requirements.
- Tests SHA-256 payload integrity check logic.
- Verifies anti-downgrade enforcement policies against simulated payloads in `ota_dist/`.

## Boot Success Rollback Marker (`bootloader/boot_rollback.h`)

KibaOS implements automated update rollback protection:

- Boot Success Marker: Successful desktop startup writes a verification marker file to `\SystemRoot\boot_success.mark`.
- Failed Boot Rollback: Bootloader checks for the marker during boot. If consecutive boot attempts fail without a success marker, the bootloader automatically rolls back system files to the pre-update snapshot.

## Diagnostic BugCheck Testing Tool (`base/applications/cmdutils/forcebugcheck/`)

A command-line utility used for testing kernel bugcheck crash dump routines and system diagnostic handlers:

- Manual BugCheck Trigger: Issues `KeBugCheckEx` with user-specified bugcheck codes and parameters to verify kernel dump collection and blue screen rendering.
