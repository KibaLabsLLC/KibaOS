# KibaOS NT ABI Specification and Architecture Design Requirements

## 1. Overview

The KibaOS Native Application Binary Interface (NT ABI) defines the binary interface between user-mode applications, subsystems, native libraries (such as `ntdll.dll`), and the KibaOS Executive kernel (`ntoskrnl.sys`). This document specifies the calling conventions, status codes, register layouts across modern 64-bit platforms (`amd64`, `arm64`, `riscv64`), as well as the architectural design specifications for next-generation kernel subsystems.

---

## 2. System Call ABI & Calling Conventions

### 2.1 Register Usage and Transition Mechanics

| Architecture | System Call Instruction | Service Index Register | Return Value Register | First 4 Arguments |
| :--- | :--- | :--- | :--- | :--- |
| **AMD64 (x86_64)** | `syscall` | `RAX` | `RAX` | `RCX`, `RDX`, `R8`, `R9` |
| **ARM64 (aarch64)** | `svc #0` | `X8` | `X0` | `X0`, `X1`, `X2`, `X3` |
| **RISC-V 64 (riscv64)** | `ecall` | `A7` | `A0` | `A0`, `A1`, `A2`, `A3` |

- Additional parameters beyond the register limits are passed on the user stack according to standard 64-bit calling conventions (e.g., Microsoft x64 ABI or AAPCS64).
- System service dispatch tables (`KiServiceTable`) route service numbers directly to Executive service functions (`Nt*`).

### 2.2 System Call Return Codes (`NTSTATUS`)

System calls return 32-bit `NTSTATUS` values formatted as:
- `0x00000000` (`STATUS_SUCCESS`): Operation completed successfully.
- `0x00000100`–`0x3FFFFFFF`: Informational or warning status codes.
- `0x80000000`–`0xBFFFFFFF`: Error status codes (e.g., `STATUS_ACCESS_DENIED`, `STATUS_INVALID_HANDLE`).
- `0xC0000000`–`0xFFFFFFFF`: Severe kernel or hardware error status codes.

---

## 3. Advanced Kernel Subsystems & Innovations

### 3.1 User-Mode Scheduling (UMS) & IoRing Integration

KibaOS implements User-Mode Scheduling (UMS) seamlessly integrated with the Kernel Storage Ring (`IoRing`) completion mechanics.
- **Concept**: User-space threads can yield, switch execution contexts, and schedule lightweight execution units without incurring full kernel context switch overhead.
- **IoRing Binding**: When an `IoRing` completion entry (`IORING_CQE`) is posted, the kernel wakes up the associated UMS completion list without transitioning through traditional kernel DPCs, allowing microsecond-level async response times.

### 3.2 Truly Async Metadata Operations

In traditional NT systems, file open, close, directory queries, and renames are synchronous or involve blocking I/O stack traversals. KibaOS elevates metadata operations to first-class async primitives:
- `NtOpenFileEx` & `NtCloseFileEx`: Queued to asynchronous Object Manager / VFS worker queues with non-blocking completion tokens.
- `NtQueryDirectoryFileEx`: Directly writes directory records into caller-provided DMA ring buffers without thread blocking.
- `NtRenameFileEx`: Performs non-blocking VFS inode namespace updates with transactional rollbacks on failure.

### 3.3 Write-Back Throttling & Per-Process Dirty Budgets

To prevent heavy background disk writes from stalling interactive desktop applications, KibaOS features a proactive Cache Manager & Memory Manager dirty page throttling system:
- **Per-Process Dirty Budgets**: Each process is assigned a maximum dirty page threshold (default: 5% of physical RAM for background applications, unthrottled for interactive UI foreground threads).
- **Fairness I/O Scheduler**: Disk I/O requests are scheduled using weighted round-robin queues where thread interactive priority dynamically prevents write-back bursts from freezing UI message loops.

### 3.4 Native Multi-Queue NVMe Path

KibaOS skips legacy SCSI translation layers for modern NVMe hardware:
- Exposes native NVMe submission and completion queues directly to the Storage Class Driver (`stornvme.sys`).
- Supports up to 64,000 queues with per-CPU core queue affinity, eliminating lock contention in storage dispatch routines.

### 3.5 Core Userspace Filesystem Framework (`KibaFuse` / `KibaUserFs`)

KibaOS provides a built-in, first-class userspace filesystem driver framework integrated into the VFS layer:
- **Fast-Path Kernel Protocol**: Uses direct zero-copy shared memory queues between kernel filesystem dispatch and user-mode daemon implementations.
- Supports cloud storage sync drives, archive virtual mounts, and overlay filesystems with minimal context switch penalty.

### 3.6 Atomic Multi-File Transactions & Immutable A/B Image OS

- **Atomic Transactions**: Applications and installers can bundle multi-file and registry modifications into a single lightweight transaction handle (`NtCreateTransaction`, `NtCommitTransaction`), guaranteeing all-or-nothing execution without legacy TxF overhead.
- **Immutable A/B Rollback**: System partitions use image-based read-only updates. System updates stage to an inactive slot (Slot B) and switch atomically on boot via `boot_rollback.h` hooks. In case of boot failure, system state rolls back instantly to Slot A.

### 3.7 Modern Service Supervisor (`kiba-supervisord`)

Replaces the traditional Service Control Manager (SCM) architecture with a modern init system:
- **Dependency Graphs**: Parallel service startup based on explicit DAG dependency trees.
- **Socket Activation**: System services listen on pre-allocated sockets and launch on-demand.
- **Resource Limits & Auto-Restart**: Automatic crash recovery with per-service cgroup-style memory, CPU, and handle limits.

### 3.8 Per-Process Namespace Overlays

- Mount-namespace-style sandboxing for Object Manager (`\ObjectTypes`), Filesystem, and Registry.
- Allows applications, containers, and legacy software to run with private environment views without full virtual machine overhead.
