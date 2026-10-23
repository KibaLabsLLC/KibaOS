<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# Frequently Asked Questions (FAQ)

## General Questions

### What is KibaOS?
KibaOS is an open-source NT operating system developed by Kiba Labs. It aims for compatibility with Windows 11 applications and drivers while serving modern 64-bit hardware architectures (amd64, arm64, riscv64).

### How does KibaOS relate to ReactOS and LiberNT?
KibaOS is based on LiberNT, which in turn originated from ReactOS. KibaOS builds upon this foundation with significant architecture updates, including the NVS memory manager, cleanroom cache manager, WDDM/DWM graphics stack, and dedicated 64-bit platform support.

### Is KibaOS affiliated with Microsoft?
No. KibaOS is an independent open-source project created by Kiba Labs. It is not affiliated with, endorsed by, or sponsored by Microsoft Corporation. Windows is a registered trademark of Microsoft Corporation.

## Compatibility and Usage

### Can KibaOS run Windows 11 applications?
KibaOS targets Windows 11 (NT10) API and ABI compatibility. While development is ongoing, many Win32 applications and drivers run as subsystem implementations mature.

### What hardware architectures are supported?
KibaOS natively targets 64-bit platforms:
- amd64 (x86_64)
- arm64 (AArch64, including Raspberry Pi 4/5)
- riscv64 (RISC-V 64-bit)

32-bit x86 software runs on 64-bit targets via the built-in WoW64 subsystem and FEX emulation on ARM64.

## Licensing and Cleanroom Policies

### What license does KibaOS use?
KibaOS is licensed under the GNU General Public License v3.0 (GPL-3.0-or-later). Individual files inherited from upstream projects retain their original file header licenses (GPL-2.0-or-later, LGPL, or BSD).

### Can I contribute code reverse-engineered from Windows?
Contributions must follow cleanroom reverse-engineering rules. Code derived from leaked Windows source code or disassembly is strictly prohibited. Acceptable sources include official SDK/WDK headers, public PDB symbols, black-box execution observation, and published documentation.
