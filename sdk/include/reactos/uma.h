/*
 * PROJECT:         KibaOS Kernel
 * LICENSE:         GPL - See COPYING in the top level directory
 * FILE:            sdk/include/reactos/uma.h
 * PURPOSE:         Unified Memory Architecture (UMA) Optimization Declarations
 */

#ifndef _REACTOS_UMA_H_
#define _REACTOS_UMA_H_

#include <ntdef.h>

#define KIBA_UMA_FLAG_CONTIGUOUS       0x00000001
#define KIBA_UMA_FLAG_CACHE_COHERENT   0x00000002
#define KIBA_UMA_FLAG_GPU_READWRITE    0x00000004
#define KIBA_UMA_FLAG_ZERO_COPY        0x00000008

typedef struct _KIBA_UMA_DOMAIN {
    ULONG DomainId;
    ULONG TotalPages;
    ULONG FreePages;
    BOOLEAN IsUnifiedGpuCpu;
    BOOLEAN CacheCoherent;
    PHYSICAL_ADDRESS PhysicalBase;
} KIBA_UMA_DOMAIN, *PKIBA_UMA_DOMAIN;

typedef struct _KIBA_UMA_DESCRIPTOR {
    PVOID KernelVirtualAddress;
    PVOID UserVirtualAddress;
    PHYSICAL_ADDRESS PhysicalAddress;
    SIZE_T Size;
    ULONG Flags;
    ULONG DomainId;
} KIBA_UMA_DESCRIPTOR, *PKIBA_UMA_DESCRIPTOR;

NTSTATUS
NTAPI
MiAllocateUmaMemory(
    _In_ SIZE_T NumberOfBytes,
    _In_ ULONG Flags,
    _In_ ULONG DomainId,
    _Out_ PKIBA_UMA_DESCRIPTOR UmaDescriptor);

NTSTATUS
NTAPI
MiMapUmaZeroCopy(
    _In_ PKIBA_UMA_DESCRIPTOR UmaDescriptor,
    _In_ PEPROCESS Process,
    _Out_ PVOID *UserBaseAddress);

NTSTATUS
NTAPI
MiFreeUmaMemory(
    _In_ PKIBA_UMA_DESCRIPTOR UmaDescriptor);

#endif /* _REACTOS_UMA_H_ */
