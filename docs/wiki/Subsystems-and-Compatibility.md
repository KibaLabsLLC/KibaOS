<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# Subsystems and Compatibility Layers

This document details application execution compatibility layers in KibaOS, including WoW64, POSIX/Linux Subsystem, binary translation engines, and NT system call ABI definitions.

## WoW64 Subsystem (`dll/win32/wow64`)

The Windows 32-bit on Windows 64-bit (WoW64) subsystem allows execution of 32-bit Win32 applications on 64-bit KibaOS kernel builds (`amd64`, `arm64`):

- Module Separation: Composed of `wow64.dll` (emulation environment), `wow64cpu.dll` (CPU context switching and instruction thunking), and `wow64win.dll` (GUI system call translation).
- System Call Translation: Thunks 32-bit user-mode system call requests into 64-bit kernel system call invocations.

## POSIX and Linux Subsystem (`drivers/posix/lxcore/`)

KibaOS provides native Linux application execution using a Pico process provider interface:

- Kernel Driver (`lxcore.sys`): Implements Linux system call translation tables and maps VFS calls to native KibaOS storage stacks.
- User-Space Launcher (`base/applications/posix/lxrun.c`): Shell command-line utility for launching and managing Linux binary execution environments.

## ARM64 Binary Translation and Emulation

- FEX Translation: Integrates with FEX binary translation for x86/x64 instruction translation on ARM64 platforms.
- CHPE & ARM64EC Support: Supports Compiled Hybrid Portable Executable (CHPE) and ARM64 Emulation Compatible (ARM64EC) execution ABI headers (`sdk/include/reactos/chpe.h`).

## NT Native API & System Call Specifications

- Native Development Kit (NDK): Header definitions in `sdk/include/ndk/` provide complete NT API types and structures.
- Header Fallbacks: `sdk/include/ndk/ifssupp.h` provides safe fallback definitions when `ntifs.h` or DDK headers are included out of order.
