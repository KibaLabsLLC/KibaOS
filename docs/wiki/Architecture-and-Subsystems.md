# Architecture and Subsystems

This document provides a technical overview of the primary subsystems and architectural design decisions in KibaOS.

## Kernel Architecture

KibaOS follows the NT architecture model, separating code into executive services, kernel core, hardware abstraction layer (HAL), and device drivers.

### Memory Management (NVS)
The NT Virtual Memory Subsystem (NVS) located in `ntoskrnl/nvs` is a cleanroom NT10 memory manager. It replaces legacy memory managers with a modular structure driven by architecture descriptors (`MI_ARCH_DESCRIPTOR`). Key capabilities include:
- Independent kernel memory pools.
- Support for Unified Memory Architecture (UMA) zero-copy mapping.
- Fine-grained page table manipulation and physical memory page lists.

### Cache Manager
Located in `ntoskrnl/cc`, the KibaOS cache manager interacts directly with file system drivers and NVS to provide efficient page caching, read-ahead, and write-behind operations.

### Storage I/O Ring
Defined in `sdk/include/reactos/ioring.h` and implemented in `ntoskrnl/io/iomgr/ioring.c`, the storage I/O ring provides lock-free ring buffers for high-throughput, low-latency asynchronous I/O operations.

## Graphics and Desktop Compositing

### WDDM Graphics Infrastructure
KibaOS implements the Windows Display Driver Model kernel interface (`drivers/directx/dxgkrnl`), providing system call dispatch thunks (`win32ss/gdi/ntgdi/d3dkmt.c`) for user-mode display drivers.

### Desktop Window Manager (DWM)
Located in `base/system/dwm`, DWM manages hardware-accelerated desktop compositing. Frame borders, client areas, and non-client caption controls are rendered using centralized UX tokens (`sdk/include/reactos/ux_tokens.h`) and DWM corner radius constants (`sdk/include/reactos/dwmframe.h`).

## Architecture Portability and WoW64

### Architecture Layering
Common kernel and executive code remains strictly architecture neutral. Platform-specific execution is handled through architecture hooks in `ntoskrnl/ke/<arch>` and `hal/hal<arch>`.

### WoW64 and FEX
- 32-bit compatibility on 64-bit systems is provided by `dll/win32/wow64`, `dll/win32/wow64cpu`, and `dll/win32/wow64win`.
- On ARM64 targets, FEX translates x86 execution blocks, while ARM64EC/CHPE allows mixed-architecture code execution.

### Pico Subsystem (LXCore)
The Pico process subsystem (`ntoskrnl/ps/pico.c` and `sdk/include/reactos/pico.h`) registers external subsystem providers. The Linux kernel compatibility driver (`drivers/posix/lxcore/`) utilizes Pico processes to execute Linux binaries natively.
