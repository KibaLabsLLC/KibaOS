<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# KibaOS Features

KibaOS delivers a modern operating system experience based on the NT architecture. The following feature overview highlights key functionality built into the kernel, driver stacks, user subsystem, and desktop environment.

## 64-Bit Architecture Support

- Native 64-Bit Kernels: Full support for 64-bit platforms including amd64 (x86_64), arm64 (AArch64), and riscv64 (RISC-V 64-bit).
- Hardware Abstraction Layer (HAL): Clean, architecture-neutral HAL implementation with specialized platform hooks for ARM64 and RISC-V board bring-up.
- FreeLoader Bootloader: Modern bootloader capable of UEFI and BIOS boot, supporting GOP framebuffer displays and early kernel handover.

## Kernel and Storage Subsystems

- NVS Memory Manager: The NT Virtual Memory Subsystem provides cleanroom NT10 memory management with dedicated pool allocation and architecture descriptors.
- Cleanroom Cache Manager: Modern file system cache management optimized for low latency and kernel-bypassed storage I/O ring interfaces.
- Advanced File System Stack: High-performance NTFS driver and library (`drivers/filesystems/ntfs_new`), along with FastFAT and CDFS support.
- Kernel Storage I/O Ring: DirectStorage and `io_uring` equivalent ring interfaces for direct-to-GPU and low-overhead storage transfers.

## Graphics and Display Subsystems

- WDDM Graphics Kernel: Windows Display Driver Model driver stack (`dxgkrnl`) delivering modern GPU pipeline support.
- Desktop Window Manager (DWM): Hardware-accelerated window compositing with Fluent UI visual tokens and rounded corner rendering.
- UEFI GOP Rendering: Seamless early graphical boot progress animations and UEFI GOP display integration.

## Subsystem and Compatibility Layer

- WoW64 Subsystem: 32-bit application execution on 64-bit targets.
- ARM64 Emulation Support: Integration with FEX binary translation and ARM64EC / CHPE binary support for ARM64 systems.
- Pico Process Subsystem: Kernel-level Pico process provider support (`PsRegisterPicoProvider`) enabling lightweight container and Linux subsystem execution (LXCore / LXRun).

## Hardware and Peripheral Drivers

- USB & Bus Drivers: Native USB xHCI controllers and SD/eMMC bus driver stacks.
- Board Support Packages: Dedicated support for Raspberry Pi boards (RP1 Ethernet, CYW43455 Wi-Fi, VideoCore graphics acceleration).
- Audio and Networking: High Definition Audio (HDAudio) driver framework and modern network adapter drivers.

## Desktop Shell and User Experience

- Explorer Shell: Windows 11 aligned desktop experience with taskbar, system flyouts, and command palette integration.
- 3D Spatial Canvas Workspaces: Multiverse workspace engine providing 6 infinite 3D spatial planes with 3D camera coordinates, window depth layering, and switching transitions.
- Crystal Clear Transparent Glass: Unblurred 100% transparent glass backdrop compositor with specular edge light reflection rendering across all windows and shell flyouts.
- Intent-Based Window Management: Dynamic task-driven multi-window auto-tiling and snapping presets (Developer Tri-Pane, Dual Side-by-Side, Media Cinema, Gaming Focus, Research Quad, Creative Studio).
- Universal Settings C/C++ API: Standardized system-wide configuration store and real-time change listener subsystem (`sdk/include/reactos/universal_settings.h`).
- Installation & Driver Config History Timeline: Interactive audit timeline in System Settings tracking all installed applications, hardware drivers, and timestamped configuration changes with 1-click rollback.
- Persistent Desktop Work Memory & Time Machine: Automatic snapshot capture and point-in-time desktop restoration preserving open applications, file contexts, window coordinates, spatial workspace assignments, and clipboard states.
- Deeply Integrated Kiba Center Hub: Multi-tab OS command suite (`Win+K`) combining Neural Search, 3D Spatial Workspaces, Intent Tiling, Time Machine Restorer, Telemetry HUD, and Privacy Matrix.
- Zero-Latency Audio & GPU Dynamic Tuner: Kernel priority and ring-buffer latency optimizer for ultra-low latency audio and gaming workloads.
- Live Kernel Telemetry HUD: Real-time DPC latency, UMA memory mapping, and power profile telemetry meters in Kiba Center.
- Universal Clipboard Matrix Sync: Multi-item rich clipboard history with instant cross-node synchronization and search.
- Context-Aware Dynamic Shell Flyouts: Adaptive tray flyouts that adjust layout and controls dynamically based on the active application profile.
- Hardware Isolation Privacy Kill-Switches: Instant one-click hardware kill-switches for microphone, camera, and network telemetry in Kiba Center.
- Unified UX Tokens & Micro-Animations: Centralized design system constants (`sdk/include/reactos/ux_tokens.h`) and spring transitions for consistent visual aesthetics.
- Structured Error Reporting: Comprehensive 3-part UX error dialogs providing actionable diagnostic information.
- OTA Update Pipeline: Cryptographically verified over-the-air update system with automatic rollback hooks (`\SystemRoot\boot_success.mark`).
