<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# Kernel and Executive Services

This document provides a detailed technical breakdown of the KibaOS kernel executive (`ntoskrnl`), memory subsystem, concurrency models, and asynchronous kernel interfaces.

## Executive Subsystems Overview

The KibaOS executive consists of modular kernel services implementing the NT kernel architecture model:

- Process Manager (`ntoskrnl/ps`): Handles thread creation, process scheduling, job objects, and Pico process subsystem registrations.
- Object Manager (`ntoskrnl/ob`): Provides uniform object creation, reference counting, security tracking, and namespace resolution.
- Memory Manager (`ntoskrnl/nvs`): Cleanroom NT10 Virtual Memory Subsystem managing page translation, working sets, and kernel pool allocations.
- Cache Manager (`ntoskrnl/cc`): High-speed file system caching interface with read-ahead, write-behind, and direct ring integration.
- I/O Manager (`ntoskrnl/io`): Asynchronous I/O request packet (IRP) routing, device stack traversal, and kernel I/O ring interfaces.
- Security Subsystem (`ntoskrnl/se`): Access token management, access control list (ACL) evaluation, and security descriptors.

## NVS Memory Manager (`ntoskrnl/nvs`)

The NT Virtual Memory Subsystem (NVS) is a cleanroom NT10 memory manager designed for modularity and high performance across 64-bit platforms (`amd64`, `arm64`, `riscv64`).

### Key Capabilities
- Architecture Descriptors (`MI_ARCH_DESCRIPTOR`): Platform-independent structures defining page directory layouts, translation table levels, and physical memory limits.
- Independent Kernel Pools: Non-paged pool and paged pool allocators optimized for lock-free block allocation and zero-fragmentation page tracking.
- Unified Memory Architecture (UMA): Declarations and zero-copy mapping definitions (`sdk/include/reactos/uma.h` and `ntoskrnl/nvs/sys/uma.c`) providing shared memory region access between host CPU and integrated GPU/DMA peripherals.

## Lock-Free Multi-Priority DPC Ring Buffer (`ntoskrnl/ke/dpc.c`)

Deferred Procedure Calls (DPCs) in KibaOS are managed through a lock-free multi-priority ring buffer implementation (`KIBA_DPC_RING_BUFFER`):

- High-Concurrency Queuing: Functions `KibaEnqueueDpcRing` and `KibaDequeueDpcRing` handle lock-free enqueue and dequeue operations under high IRQL conditions.
- Priority Rings: Supports distinct DPC priority levels (Low, Medium, High, High-Priority Realtime) to prevent interrupt latency degradation during intensive driver I/O.

## Storage I/O Ring Interface (`ntoskrnl/io/iomgr/ioring.c`)

Defined in `sdk/include/reactos/ioring.h`, the Kernel Storage I/O Ring interface provides low-overhead, kernel-bypassed asynchronous I/O capabilities comparable to `io_uring` and DirectStorage:

- Lock-Free Circular Buffers: Submission and completion queue rings populated in user or kernel space and processed directly by storage drivers (`drivers/storage/port/stornvme/`).
- Direct-to-Storage Transfers: Minimizes context switches and buffer copying for high-IOPS storage workloads.

## Pico Process Subsystem (`ntoskrnl/ps/pico.c`)

The Pico process framework (`sdk/include/reactos/pico.h`) provides interface routines (`PsRegisterPicoProvider`, `PsCreatePicoProcess`) allowing external subsystem kernel drivers to host lightweight isolated processes:

- System Call Redirection: Pico processes dispatch system calls directly to registered provider callbacks rather than standard NT system call tables.
- Driver Integration: Used directly by `drivers/posix/lxcore/` for running Linux processes natively within the KibaOS executive environment.
