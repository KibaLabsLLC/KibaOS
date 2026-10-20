# KibaOS Shell UX Map

This document lists every user-facing surface in KibaOS and the codebase directories that own it.

| User-Facing Surface | Functionality / Component | Owning Directory |
| :--- | :--- | :--- |
| **Explorer & Taskbar** | Taskbar, Start Menu, Tray Flyouts, Task Switching, Desktop | `base/shell/explorer/` |
| **File Browser & Shell Frame** | File Manager UI, Common Dialogs, Folder Views, Shell Windows | `base/shell/filebrowser/`, `base/shell/shellframe/`, `base/shell/rshell/` |
| **System Settings** | Modern Settings UI (System, Devices, Network, Personalization, Apps, Accounts, Time, Sound) | `base/applications/systemsettings/` |
| **Control Panel Applets** | Legacy configuration control panel and individual applets (.cpl) | `base/applications/control/`, `dll/cpl/` (`access`, `appwiz`, `desk`, `hdwwiz`, `input`, `intl`, `main`, `mmsys`, `powercfg`, `sysdm`, `timedate`, `usrmgr`, etc.) |
| **Setup & First-Run** | Welcome wizard, OS installer, first-run setup experience | `base/setup/welcome/`, `base/setup/setup/`, `base/setup/libernt/` |
| **System Utilities** | Task Manager 11, WinVer, Cleanmgr, Disk Management | `base/applications/taskmgr11/`, `base/applications/winver/`, `base/applications/cleanmgr/`, `base/applications/mscutils/` |
| **Update Engine & Service** | Update service, payload verification, staged apply | `base/services/wuauserv/` |
| **Bootloader & Boot UI** | Graphical boot screen, progress indicator, winload rollback hooks | `bootloader/gui/`, `bootloader/winload/`, `boot/freeldr/bootsect/` |
