<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# KibaOS Wiki

Welcome to the official KibaOS documentation wiki. KibaOS is a free, open-source NT operating system from Kiba Labs targeting Windows 11 application and driver compatibility across modern 64-bit platforms.

## Documentation Index

- [Features](Features.md): Overview of capabilities across kernel, storage, graphics, and shell subsystems.
- [Architecture and Subsystems](Architecture-and-Subsystems.md): High-level technical overview on NVS, WDDM/DWM, Pico provider, WoW64, and hardware drivers.
- [Kernel and Executive Services](Kernel-Executive.md): Detailed breakdown of NVS Memory Manager, Cache Manager, lock-free DPC ring buffers, UMA, and Storage I/O Ring.
- [Graphics, Desktop Window Manager, and UI Design System](Graphics-and-UI.md): WDDM driver model, Win32k thunks, non-client window rendering, UX tokens, error catalog, Predictive UI, and Kiba Companion.
- [Device Drivers and Hardware Support](Device-Drivers-and-Hardware.md): Storage/NVMe, USB stack, Realtek Ethernet, WFP/IPSec, HDAudio, and Raspberry Pi BSP.
- [Subsystems and Compatibility Layers](Subsystems-and-Compatibility.md): WoW64, POSIX/Linux subsystem (LXCore), ARM64 FEX/CHPE translation, and NT Native API specifications.
- [User Experience, Shell, and Desktop Environment](User-Experience-and-Shell.md): Explorer shell engine, taskbar flyouts, System Settings, and first-boot onboarding setup wizard.
- [System Maintenance, Diagnostics, and OTA Engine](System-Maintenance-and-OTA.md): Over-the-air update state machine, verification framework, boot success rollback marker, and ForceBugCheck utility.
- [Building and Installation](Building-and-Installation.md): Step-by-step guides for compiling KibaOS with RosBE and running prebuilt disk images.
- [Developer Guide](Developer-Guide.md): Guidelines for code contributions, cleanroom compliance, testing against Windows 11 baselines, and coding standards.
- [Frequently Asked Questions (FAQ)](FAQ.md): Common queries about system compatibility, project origin, licensing, and hardware support.

## Project Vision

KibaOS provides a modern, fast, and familiar NT-based operating system designed for contemporary 64-bit hardware architectures (amd64, arm64, riscv64). By combining robust kernel subsystems with cleanroom engineering, KibaOS delivers an open alternative for running Windows applications and drivers seamlessly.

## Important Notices

### Legal and Trademark Notice
KibaOS is an independent open-source project developed by Kiba Labs and contributors. It is not affiliated with, endorsed by, or sponsored by Microsoft Corporation. Windows is a registered trademark of Microsoft Corporation in the United States and other countries.

### Copyright and Licensing
KibaOS is licensed under the GNU General Public License v3.0 (GPL-3.0-or-later). The changes made in KibaOS are Copyright (c) 2026 Kiba Labs and the KibaOS contributors. Code inherited from LiberNT, ReactOS, and third parties retains the copyright notices of its original authors as specified in individual file headers and LICENSES documentation.

### Cleanroom Source Code Policy
KibaOS strictly enforces cleanroom engineering standards. Contributions or references based on proprietary or leaked source code (including leaked Windows NT source code or WRK) are forbidden and will be rejected.
