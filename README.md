<p align="center">
  <img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/main-nt10/GH_MEDIA/kiba-banner-mascot.png?raw=true" />
</p>

<h1 align="center">KibaOS</h1>
<h2 align="center">
A new dawn in how we interact with our computers, no longer is it a machine, but second nature.

Simple. Refined. Libre.
</h2>

## Quick Links

[Website](https://kibaos.com) | [Source Code](https://github.com/KibaLabsLLC/KibaOS) | [Documentation Wiki](docs/wiki/Home.md) | [Issues](https://github.com/KibaLabsLLC/KibaOS/issues) | [Build Environment](https://github.com/LiberNT/libernt-build-toolchain)

[![License](https://img.shields.io/badge/license-GNU_GPL_3.0-0161B6.svg)](COPYING)
[![Build Status](https://img.shields.io/github/actions/workflow/status/KibaLabsLLC/KibaOS/build.yml?branch=main-nt10&label=Build&style=for-the-badge&logo=githubactions&logoColor=white)](https://github.com/KibaLabsLLC/KibaOS/actions)
[![SourceForge](https://img.shields.io/sourceforge/dt/kibaos?style=for-the-badge&color=orange&logo=sourceforge&logoColor=white)](https://sourceforge.net/projects/kibaos/)

---

## Important Notices

### Legal and Trademark Notice
KibaOS is an independent open-source operating system project developed by Kiba Labs and contributors. It is not affiliated with, endorsed by, or sponsored by Microsoft Corporation. Windows is a registered trademark of Microsoft Corporation in the United States and other countries.

### Cleanroom Source Code Policy Notice
KibaOS enforces strict cleanroom engineering standards. Contributions, references, or code derived from proprietary or leaked source code (including leaked Windows NT source code or the Windows Research Kernel) are strictly forbidden and will not be accepted.

### Development Status Notice
KibaOS is currently in active early development and tracks pre-release builds. System behavior and hardware support depend on upstream integration. Windows 11 serves as the reference implementation for API and driver compatibility.

### Licensing Notice
KibaOS is licensed under the [GNU GPL 3.0](COPYING). Code inherited from LiberNT and ReactOS retains the license specified in its respective file headers, primarily GPL 2.0 or later. Full license texts for GPL 2.0, LGPL 2.1, and BSD are available in [COPYING2](COPYING2), [COPYING.LIB](COPYING.LIB), and [COPYING.ARM](COPYING.ARM).

---

## Overview

KibaOS is a free, Windows-compatible NT operating system developed by Kiba Labs targeting Windows 11 compatibility across modern 64-bit platforms.

KibaOS is based on [LiberNT](https://github.com/ahmedarif193/LiberNT), which is in turn based on ReactOS. KibaOS expands upon this foundation with dedicated support for 64-bit architectures (`amd64`, `arm64`, and `riscv64`), an updated kernel memory manager, modern graphics compositing, and performance enhancements.

---

<h1 align="center">Desktop Screenshot</h1>

<p align="center">
  <img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/main-nt10/GH_MEDIA/Screenshot_20261020_221943.png?raw=true" />
</p>

<h1 align="center">Operating System Features</h1> 

### Kernel and Storage
- **NVS Memory Manager:** Cleanroom NT10 memory manager (`ntoskrnl/nvs`) providing dedicated kernel pool allocation and architecture descriptors.
- **Cleanroom Cache Manager:** Modern file system cache manager (`ntoskrnl/cc`) designed for low latency.
- **Storage I/O Ring Interface:** Asynchronous direct-to-storage I/O ring structures for kernel-bypassed operations.
- **Modern NTFS Driver & Library:** Rewritten NTFS file system implementation (`drivers/filesystems/ntfs_new`) alongside FastFAT and CDFS support.

### Graphics and Display
- **WDDM Kernel Infrastructure:** Windows Display Driver Model driver framework (`dxgkrnl`) and Win32k thunk dispatch interfaces.
- **Desktop Window Manager (DWM):** Hardware-accelerated window compositing engine with Fluent UI visual design tokens and rounded frame corners.
- **UEFI GOP Boot Display:** Seamless early boot progress animation and GOP graphics framebuffer handoff.

### Subsystem and Emulation
- **WoW64 Subsystem:** Execution of 32-bit applications on 64-bit kernel targets.
- **ARM64 Translation:** FEX binary translation integration and ARM64EC / CHPE support for ARM64 targets.
- **Pico Process Subsystem:** Kernel Pico provider interface enabling lightweight subsystem integration (LXCore).

### Hardware and Board Support
- **USB & SD Drivers:** Native xHCI USB controller driver stack and SD bus driver.
- **Raspberry Pi BSP:** Board support packages including VideoCore graphics acceleration, RP1 Ethernet, and CYW43455 Wi-Fi.
- **Unified Audio & Networking:** High Definition Audio (HDAudio) driver framework and network device stacks.

---

## Documentation Wiki

Comprehensive guides and technical documentation are available in the repository [docs/wiki](docs/wiki/Home.md) folder:

- **[Wiki Home](docs/wiki/Home.md):** Documentation overview and key project principles.
- **[Features List](docs/wiki/Features.md):** Detailed technical capabilities across kernel, storage, and shell components.
- **[Architecture & Subsystems](docs/wiki/Architecture-and-Subsystems.md):** In-depth analysis of NVS, WDDM/DWM, WoW64, and driver stacks.
- **[Building & Installation Guide](docs/wiki/Building-and-Installation.md):** Step-by-step instructions for RosBE compilation, QEMU execution, and setup installation.
- **[Developer Guide](docs/wiki/Developer-Guide.md):** Guidelines on cleanroom compliance, coding conventions, and testing against Windows 11 baselines.
- **[Frequently Asked Questions (FAQ)](docs/wiki/FAQ.md):** Answers to common questions regarding compatibility, licensing, and architecture.

---

## Building KibaOS

KibaOS compiles using the RosBE cross-build toolchain on Linux, macOS, or Windows (WSL2).

### 1. Install Tools
On Linux or macOS:
```bash
curl -fsSL https://raw.githubusercontent.com/ahmedarif193/libernt-build-toolchain/main/rosbe-unix-bootstrap.sh | sh
```
On Windows, install WSL2 (`wsl --install`) and execute the bootstrap script inside the Linux terminal.

### 2. Get the Source
```bash
git clone https://github.com/KibaLabsLLC/KibaOS.git
cd KibaOS
```

### 3. Configure
```bash
./configure.sh
```
Common options:
- `./configure.sh -a arm64`: Target ARM64 architecture.
- `./configure.sh -a amd64 --release`: Optimized AMD64 release build.
- `./configure.sh menuconfig`: Interactive terminal configuration menu.

### 4. Build Image
```bash
cd output-Clang-amd64-debug
ninja kibaosimg
```

| Target | Output | Usage |
| --- | --- | --- |
| `ninja bootcd` | `bootcd.iso` | Bootable ISO image for installation via KibaOS Setup. |
| `ninja kibaosimg` | `KibaOS.img` | Disk image with preinstalled KibaOS booting on UEFI or BIOS. |
| `ninja kibaosvhd` | `KibaOS.vhd` | Virtual Hard Disk image for Hyper-V and VirtualBox. |

For detailed installation instructions, see [INSTALL.md](INSTALL.md) and [Building & Installation Guide](docs/wiki/Building-and-Installation.md).

---


<h1 align="center">Upstream Gratitude</h1> 

KibaOS builds upon the foundational work of the following upstream open-source projects:

- **LiberNT** (Direct Upstream): [github.com/ahmedarif193/LiberNT](https://github.com/ahmedarif193/LiberNT)
- **ReactOS**: [github.com/reactos/reactos](https://github.com/reactos/reactos)

---

<h1 align="center">Contributing</h1> 

We welcome contributions from developers and testers. Please review [CONTRIBUTING.md](CONTRIBUTING.md), [PULL_REQUEST_MANAGEMENT.md](PULL_REQUEST_MANAGEMENT.md), and the [Developer Guide](docs/wiki/Developer-Guide.md) before submitting patches.

---

## Copyright Notice

The changes made in KibaOS are Copyright © 2026 Kiba Labs and the KibaOS contributors. Code inherited from LiberNT, ReactOS and third parties keeps the copyright notices of its authors. See [CREDITS.md](CREDITS.md).
