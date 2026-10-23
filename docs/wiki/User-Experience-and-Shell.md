<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# User Experience, Shell, and Desktop Environment

This document outlines the KibaOS desktop shell architecture, taskbar flyouts, system applications, and first-boot onboarding experience.

## Explorer Shell Engine (`base/shell/explorer/`)

The KibaOS Explorer Shell provides a Windows 11 aligned desktop environment:

- Taskbar & Hotkeys (`traywnd.cpp`): Manages global taskbar state, window messaging (`TWM_*`), start button hooks, and desktop shortcuts configured in `media/inf/shortcuts.inf`.
- Shell Flyouts (`trayflyouts.cpp`): Renders modern popover flyouts for volume, network status, battery level, calendar, and quick settings.
- Start Button Artwork: Consumes custom Start button artwork and WIC pipeline graphics from `media/graphics/start-button/`.

## System Settings Application (`base/applications/systemsettings/`)

A centralized settings application written with modular pages:

- Personalization Page (`page_personal.cpp`): Controls desktop themes, visual tokens, accent colors, and toggles for Kiba Desktop Companion.
- Updates Page (`page_updates.cpp`): Controls OTA update check interval, update channel selection, and update package deployment.

## First-Boot Onboarding and Setup Wizard (`base/setup/libernt/`)

The LiberNT Setup Wizard handles system initialization and onboarding:

- Setup Frame (`frame.c` & `wizard.c`): Manages partition formatting (NTFS/FAT32), system file copy, bootloader installation, and hardware device discovery.
- OOBE Onboarding (`oobe.c`): Initial user creation, timezone selection, computer naming, and initial system settings configuration.
