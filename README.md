# KibaOS

[![License](https://img.shields.io/badge/license-GNU_GPL_3.0-0161B6.svg)](COPYING)

## Quick Links

[Website](https://kibaos.com) • [Source code](https://github.com/KibaLabsLLC/KibaOS) • [Issues](https://github.com/KibaLabsLLC/KibaOS/issues) • [Wiki](https://github.com/KibaLabsLLC/KibaOS/wiki) • [Build environment](https://github.com/LiberNT/winget-rosbe)

## What is KibaOS?

KibaOS is a free, Windows-compatible operating system from Kiba Labs, built on the NT architecture. It targets Windows® 11 compatibility, with room for freestyle and experimental features.

KibaOS is based on [LiberNT](https://github.com/ahmedarif193/LiberNT), a free NT operating system, which is in turn based on ReactOS, the Open Source effort to develop an operating system that is compatible with applications and drivers written for the Microsoft Windows NT family of operating systems. KibaOS inherits LiberNT's focus on 64-bit platforms: amd64, arm64 and riscv64.

KibaOS is licensed under the [GNU GPL 3.0](COPYING). Code inherited from LiberNT and ReactOS keeps the licence stated in its file headers, most of it GPL 2.0 or later. The GPL 2.0, LGPL 2.1 and BSD texts those files refer to are in [COPYING2](COPYING2), [COPYING.LIB](COPYING.LIB) and [COPYING.ARM](COPYING.ARM).

The changes made in KibaOS are Copyright © 2026 Kiba Labs and the KibaOS contributors. Code inherited from LiberNT, ReactOS and third parties keeps the copyright notices of its authors. See [CREDITS.md](CREDITS.md).

KibaOS is an independent project. It is not affiliated with, endorsed by or sponsored by Microsoft. Windows® is a registered trademark of Microsoft Corporation.

### Status

KibaOS is in early development and tracks LiberNT's pre-release builds. Expect rough edges, and expect hardware support to depend on what LiberNT supports upstream. Windows 11 is the compatibility reference.

## Support KibaOS

We want KibaOS to be a free NT operating system that anyone can try, hack on and rely on. Support the project by reporting bugs, sending patches, or joining the community. See [Contributing](#contributing) to get started.

## Upstream

KibaOS would not exist without the projects below. With respect and gratitude to their teams and contributors:

- **LiberNT**, the direct upstream: [github.com/ahmedarif193/LiberNT](https://github.com/ahmedarif193/LiberNT)
- **ReactOS**, the project LiberNT is based on: [github.com/reactos/reactos](https://github.com/reactos/reactos)

## Building

KibaOS builds with RosBE, a cross-build toolchain. The steps below work on Linux and macOS, and on Windows through WSL2.

### 1. Install the tools

You need Git, CMake, Ninja and a C/C++ compiler for your own machine. RosBE adds the compilers that build KibaOS.

On Linux or macOS:

```
curl -fsSL https://raw.githubusercontent.com/ahmedarif193/winget-rosbe/main/rosbe-unix-bootstrap.sh | sh
```

On Windows, we suggest WSL2. Install it with `wsl --install`, open the Linux terminal it adds, and follow the Linux steps there. Keep the source inside the Linux file system rather than under `/mnt/c`, where builds run slower.

### 2. Get the source

```
git clone https://github.com/KibaLabsLLC/KibaOS.git
cd KibaOS
```

The first configure run also fetches the submodule and external sources the build needs.

### 3. Configure

```
./configure.sh
```

With no options, this sets up an AMD64 Debug build with Clang in the folder `output-Clang-amd64-debug`. The folder name always follows the pattern `output-<compiler>-<architecture>-<debug|release>`.

| Option                | What it does                                                                                  |
| --------------------- | --------------------------------------------------------------------------------------------- |
| `-a`, `--arch <arch>` | Chooses the target architecture: `amd64` (default), `i386`, `arm64` or `riscv64`.             |
| `--clang`             | Builds with Clang/LLVM from RosBE. This is the default.                                       |
| `--gcc`               | Builds with GCC from RosBE instead of Clang. The macOS RosBE does not include GCC.            |
| `-r`, `--release`     | Makes an optimized Release build. Without it you get a Debug build, which is easier to debug. |
| `menuconfig`          | Opens a menu to choose optional components first. Your choices are kept in the output folder. |
| `makefiles`           | Uses `make` instead of Ninja.                                                                 |
| `--no-feeds-update`   | Skips fetching the external sources listed in `feeds.conf`, for example when offline.         |
| `-D<name>=<value>`    | Passes a setting straight to CMake.                                                           |

For example:

```
./configure.sh -a arm64              # ARM64 Debug build with Clang
./configure.sh -a i386 --gcc         # 32-bit x86 build with GCC
./configure.sh -a amd64 --release    # optimized AMD64 build
```

For a more personalized build, add `menuconfig`:

```
./configure.sh menuconfig
```

It opens a menu, much like the Linux kernel's, where you choose the target, compiler and build type, and switch features on or off. Press `?` on any option for help, `S` to save and `Q` to quit. Your choices are saved in the output folder and used every time you configure it again.

### 4. Build

Go to the output folder and run Ninja with the target you want:

```
cd output-Clang-amd64-debug
ninja kibaosimg
```

| Command           | Creates      | Use it to                                                                                                                                                 |
| ----------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ninja bootcd`    | `bootcd.iso` | Install KibaOS from a CD image, in a virtual machine or on a PC.                                                                                          |
| `ninja kibaosimg` | `KibaOS.img` | Boot a disk with KibaOS already installed. Start it in a virtual machine such as QEMU, or write it to a USB drive or SD card. It boots with UEFI or BIOS. |
| `ninja kibaosvhd` | `KibaOS.vhd` | Use the same preinstalled disk in virtual machines that take VHD disks, such as Hyper-V and VirtualBox.                                                   |

Each target builds everything it needs first, and the files are written to the output folder.

## What KibaOS Enables

KibaOS brings modern hardware and platforms to the NT architecture, building on LiberNT's work. The current focus is:

- 64-bit platform support on amd64, arm64 and riscv64: kernel, HAL and FreeLoader
- UEFI boot, GOP framebuffer, and early display support
- PCIe, PCI, PnP, USB/xHCI, SD/eMMC, and storage/bus drivers
- Board support, including the Raspberry Pi and its RP1 I/O controller
- Windows 11 (NT10) compatibility and driver-model work

See [INSTALL.md](INSTALL.md) for installation instructions.

## Contributing

Report bugs and suggest features in [Issues](https://github.com/KibaLabsLLC/KibaOS/issues), and find guides and notes in the [Wiki](https://github.com/KibaLabsLLC/KibaOS/wiki).

See [CONTRIBUTING.md](CONTRIBUTING.md) and [PULL_REQUEST_MANAGEMENT.md](PULL_REQUEST_MANAGEMENT.md).

Changes that are not specific to KibaOS, such as kernel, driver and compatibility fixes, belong upstream in [LiberNT](https://github.com/ahmedarif193/LiberNT) where possible, which keeps this fork easy to rebase.

**Legal notice:** If you have seen proprietary Microsoft Windows source code (including but not limited to the leaked Windows NT 3.5, NT 4, 2000 source code and the Windows Research Kernel), your contribution won't be accepted because of potential copyright violation.
