# Building and Installation Guide

This guide describes how to set up the RosBE build toolchain, compile KibaOS source code, and run or install KibaOS.

## Prerequisites and Toolchain Setup

Building KibaOS requires Git, CMake, Ninja, and the RosBE (ReactOS Build Environment) toolchain cross-compiler package.

### Linux and macOS
Run the automated bootstrap script to install RosBE:

```bash
curl -fsSL https://raw.githubusercontent.com/ahmedarif193/libernt-build-toolchain/main/rosbe-unix-bootstrap.sh | sh
```

### Windows (WSL2)
1. Install WSL2 by running `wsl --install` in PowerShell.
2. Open the installed Linux terminal.
3. Run the Linux bootstrap script shown above inside the Linux filesystem for optimal build performance.

## Cloning the Repository

```bash
git clone https://github.com/KibaLabsLLC/KibaOS.git
cd KibaOS
```

## Configuring the Build

Run `configure.sh` to initialize CMake and Ninja build files:

```bash
./configure.sh
```

By default, this creates a build directory named `output-Clang-amd64-debug`.

### Configuration Options

| Option | Description |
| --- | --- |
| `-a, --arch <arch>` | Selects target architecture: `amd64` (default), `i386`, `arm64`, or `riscv64`. |
| `--clang` | Uses Clang/LLVM compiler (default). |
| `--gcc` | Uses GCC compiler. |
| `-r, --release` | Configures an optimized Release build. |
| `menuconfig` | Launches an interactive configuration menu. |
| `--no-feeds-update` | Skips updating external feed dependencies. |

### Configuration Examples

```bash
./configure.sh -a arm64              # ARM64 Debug build with Clang
./configure.sh -a amd64 --release    # AMD64 Release build
./configure.sh menuconfig            # Interactive menu configuration
```

## Compiling KibaOS

Navigate to the generated output directory and run Ninja:

```bash
cd output-Clang-amd64-debug
ninja kibaosimg
```

### Build Targets

| Command | Output File | Usage |
| --- | --- | --- |
| `ninja bootcd` | `bootcd.iso` | Bootable ISO image for clean setup installations in VMs or on bare metal. |
| `ninja kibaosimg` | `KibaOS.img` | Disk image with preinstalled KibaOS booting on UEFI or BIOS systems. |
| `ninja kibaosvhd` | `KibaOS.vhd` | Virtual Hard Disk image for Hyper-V, VirtualBox, or QEMU. |

## Running KibaOS in QEMU

To boot `KibaOS.img` directly in QEMU:

```bash
qemu-system-x86_64 -m 2048 -hda KibaOS.img -bios /path/to/OVMF.fd
```

## Installing via Setup CD

1. Boot a virtual machine or PC using `bootcd.iso`.
2. Follow the KibaOS Setup wizard instructions to select destination partitions and formatting options (NTFS).
3. Complete installation and restart the system into KibaOS.
