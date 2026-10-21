/*
 * PROJECT:         KibaOS Kernel
 * LICENSE:         GPL - See COPYING in the top level directory
 * FILE:            ntoskrnl/nvs/sys/uma.c
 * PURPOSE:         Unified Memory Architecture (UMA) Optimization Implementation
 */

#include <ntoskrnl.h>
#include <reactos/uma.h>

static KIBA_UMA_DOMAIN KiPrimaryUmaDomain = {
    .DomainId = 0,
    .TotalPages = 0,
    .FreePages = 0,
    .IsUnifiedGpuCpu = TRUE,
    .CacheCoherent = TRUE,
    .PhysicalBase = {{0}}
};

NTSTATUS
NTAPI
MiAllocateUmaMemory(
    _In_ SIZE_T NumberOfBytes,
    _In_ ULONG Flags,
    _In_ ULONG DomainId,
    _Out_ PKIBA_UMA_DESCRIPTOR UmaDescriptor)
{
    PHYSICAL_ADDRESS LowAddress, HighAddress, SkipBytes;
    PVOID KernelAddress;
    SIZE_T PageAlignedSize;

    if (!UmaDescriptor || NumberOfBytes == 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    RtlZeroMemory(UmaDescriptor, sizeof(*UmaDescriptor));

    PageAlignedSize = ROUND_TO_PAGES(NumberOfBytes);
    LowAddress.QuadPart = 0;
    HighAddress.QuadPart = 0xFFFFFFFFFFFFFFFFULL;
    SkipBytes.QuadPart = 0;

    KernelAddress = MmAllocateContiguousMemorySpecifyCache(
        PageAlignedSize,
        LowAddress,
        HighAddress,
        SkipBytes,
        (Flags & KIBA_UMA_FLAG_CACHE_COHERENT) ? MmCached : MmNonCached);

    if (!KernelAddress)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    UmaDescriptor->KernelVirtualAddress = KernelAddress;
    UmaDescriptor->PhysicalAddress = MmGetPhysicalAddress(KernelAddress);
    UmaDescriptor->Size = PageAlignedSize;
    UmaDescriptor->Flags = Flags | KIBA_UMA_FLAG_ZERO_COPY;
    UmaDescriptor->DomainId = DomainId;

    return STATUS_SUCCESS;
}

NTSTATUS
NTAPI
MiMapUmaZeroCopy(
    _In_ PKIBA_UMA_DESCRIPTOR UmaDescriptor,
    _In_ PEPROCESS Process,
    _Out_ PVOID *UserBaseAddress)
{
    PMDL Mdl;
    PVOID UserMapping;

    if (!UmaDescriptor || !UserBaseAddress || !UmaDescriptor->KernelVirtualAddress)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *UserBaseAddress = NULL;

    Mdl = IoAllocateMdl(
        UmaDescriptor->KernelVirtualAddress,
        (ULONG)UmaDescriptor->Size,
        FALSE,
        FALSE,
        NULL);

    if (!Mdl)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    MmBuildMdlForNonPagedPool(Mdl);

    _SEH2_TRY
    {
        UserMapping = MmMapLockedPagesSpecifyCache(
            Mdl,
            UserMode,
            (UmaDescriptor->Flags & KIBA_UMA_FLAG_CACHE_COHERENT) ? MmCached : MmNonCached,
            NULL,
            FALSE,
            NormalPagePriority);
    }
    _SEH2_EXCEPT(EXCEPTION_EXECUTE_HANDLER)
    {
        UserMapping = NULL;
    }
    _SEH2_END;

    IoFreeMdl(Mdl);

    if (!UserMapping)
    {
        return STATUS_NONE_MAPPED;
    }

    UmaDescriptor->UserVirtualAddress = UserMapping;
    *UserBaseAddress = UserMapping;

    return STATUS_SUCCESS;
}

NTSTATUS
NTAPI
MiFreeUmaMemory(
    _In_ PKIBA_UMA_DESCRIPTOR UmaDescriptor)
{
    if (!UmaDescriptor)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (UmaDescriptor->KernelVirtualAddress)
    {
        MmFreeContiguousMemory(UmaDescriptor->KernelVirtualAddress);
        UmaDescriptor->KernelVirtualAddress = NULL;
    }

    UmaDescriptor->UserVirtualAddress = NULL;
    UmaDescriptor->Size = 0;

    return STATUS_SUCCESS;
}
