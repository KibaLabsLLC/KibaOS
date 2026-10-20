# KibaOS Shell UX Audit

This document lists concrete UX design rule violations in KibaOS with exact file paths, ranked by user impact frequency, as well as duplicate entry points and build pipeline details.

---

## 1. Ranked Rule Violations

### Ranking 1: Multiple Settings Surfaces (Violates Design Rule 3: One settings surface & Hard Boundary Rule 1)
- **File Paths:**
  - `dll/cpl/timedate/timedate.c` vs `base/applications/systemsettings/page_time.cpp`
  - `dll/cpl/desk/desk.c` vs `base/applications/systemsettings/page_personal.cpp`
  - `dll/cpl/main/mouse.c` / `main.c` vs `base/applications/systemsettings/page_devices.cpp`
  - `dll/cpl/mmsys/volume.c` vs `base/applications/systemsettings/page_sound.cpp`
  - `dll/cpl/appwiz/appwiz.c` vs `base/applications/systemsettings/page_apps.cpp`
  - `dll/cpl/usrmgr/usrmgr.c` vs `base/applications/systemsettings/page_accounts.cpp`
- **Violation:** Having separate legacy Control Panel applets and modern System Settings pages creates split configuration paths and user confusion.

### Ranking 2: Inline Error Strings and Raw Dialog Popups (Violates Design Rule 8: Errors state what/why/next)
- **File Paths:**
  - `base/shell/explorer/taskswnd.cpp` (Lines 3428, 3809)
  - `base/shell/explorer/startmnu2.cpp` (Lines 648, 2408)
  - `base/shell/explorer/explorer.cpp` (Line 184)
  - `dll/cpl/timedate/timedate.c` (Lines 49, 52)
  - `dll/cpl/mmsys/volume.c` (Lines 332, 339, 382)
- **Violation:** Raw `MessageBoxW` calls display inline error strings without structured explanation of what happened, why it happened, or actionable next steps.

### Ranking 3: Decentralized Visual Literals and Hardcoded Theme Colors (Violates Design Rule 2: One source of truth)
- **File Paths:**
  - `base/shell/explorer/trayflyouts.cpp`
  - `base/shell/explorer/taskswnd.cpp`
  - `base/applications/systemsettings/main.cpp`
- **Violation:** Hardcoded RGB color values, margins, and font size constants are duplicated directly in C++ UI drawing code rather than referencing a centralized token header.

### Ranking 4: Unannounced Interruptions and Blocking Modals (Violates Design Rule 6: Never interrupt)
- **File Paths:**
  - `base/services/wuauserv/`
  - `base/shell/explorer/`
- **Violation:** Update triggers and error popups theft of focus or display unannounced blocking modals during active user interaction.

### Ranking 5: Lack of Global Undo Capabilities (Violates Design Rule 5: Everything undoable)
- **File Paths:**
  - `base/shell/explorer/`
  - `base/applications/systemsettings/`
- **Violation:** File management operations and setting toggles in shell views lack unified Ctrl+Z / Ctrl+Y transaction stacks.

---

## 2. Duplicate Entry Points Identified

- **Time & Date Settings:** `timedate.cpl` vs `systemsettings.exe page_time`
- **Display & Personalization:** `desk.cpl` vs `systemsettings.exe page_personal`
- **Audio & Volume:** `mmsys.cpl` vs `systemsettings.exe page_sound`
- **Mouse & Keyboard:** `main.cpl` vs `systemsettings.exe page_devices`
- **Installed Applications:** `appwiz.cpl` vs `systemsettings.exe page_apps`
- **User Accounts:** `usrmgr.cpl` vs `systemsettings.exe page_accounts`

---

## 3. GitHub Workflows Build Pipeline & Artifacts Audit

- **Workflow Path:** `.github/workflows/build.yml`
- **Current Artifacts Generated:**
  1. `bootcd.iso` -> Staged as `dist/kibaos-v<RUN_NUMBER>-<ARCH>.iso`
  2. `KibaOS.img` -> Compressed as `dist/kibaos-v<RUN_NUMBER>-<ARCH>.img.xz`
  3. `KibaOS.vhd` -> Compressed as `dist/kibaos-v<RUN_NUMBER>-<ARCH>.vhd.xz`
- **Existing SourceForge Upload Setup:**
  - Environment variables: `SF_USER: ${{ secrets.SF_USER }}`, `SSHPASS: ${{ secrets.SF_PASS }}`
  - Target host: `frs.sourceforge.net`
  - SF directory structure: `/home/frs/project/kibaos/<ARCH>`
  - Marker file tracking: `last-build-number-<ARCH>.txt`
  - Upload protocol: `sshpass -e rsync -avP` and `sshpass -e sftp`
