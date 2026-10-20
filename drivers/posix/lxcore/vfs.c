/*
 * PROJECT:     KibaOS NT Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Linux VFS and Per-Process File Descriptor Table
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#include "lxcore.h"

#define LX_MAX_FD 256

typedef struct _LX_FD_ENTRY {
    HANDLE FileHandle;
    ULONG Flags;
    ULONG Access;
} LX_FD_ENTRY, *PLX_FD_ENTRY;

typedef struct _LX_VFS_CONTEXT {
    PEPROCESS Process;
    KSPIN_LOCK Lock;
    ULONG_PTR EntryPoint;
    LX_FD_ENTRY FdTable[LX_MAX_FD];
} LX_VFS_CONTEXT, *PLX_VFS_CONTEXT;

NTSTATUS
NTAPI
LxInitializeProcessVfs(
    _In_ PEPROCESS Process,
    _Out_ PVOID *VfsContext)
{
    PLX_VFS_CONTEXT Vfs;

    if (VfsContext == NULL)
        return STATUS_INVALID_PARAMETER;

    *VfsContext = NULL;

    Vfs = ExAllocatePoolWithTag(NonPagedPool, sizeof(LX_VFS_CONTEXT), 'xLpV');
    if (Vfs == NULL)
        return STATUS_INSUFFICIENT_RESOURCES;

    RtlZeroMemory(Vfs, sizeof(LX_VFS_CONTEXT));
    Vfs->Process = Process;
    KeInitializeSpinLock(&Vfs->Lock);

    /* Reserve FDs 0, 1, 2 for standard IO streams */
    Vfs->FdTable[0].Flags = 1; /* Stdin */
    Vfs->FdTable[1].Flags = 1; /* Stdout */
    Vfs->FdTable[2].Flags = 1; /* Stderr */

    *VfsContext = Vfs;
    return STATUS_SUCCESS;
}

VOID
NTAPI
LxSetProcessEntryPoint(
    _In_ PVOID VfsContext,
    _In_ ULONG_PTR EntryPoint)
{
    PLX_VFS_CONTEXT Vfs = (PLX_VFS_CONTEXT)VfsContext;
    if (Vfs != NULL)
    {
        Vfs->EntryPoint = EntryPoint;
    }
}

ULONG_PTR
NTAPI
LxGetProcessEntryPoint(
    _In_ PVOID VfsContext)
{
    PLX_VFS_CONTEXT Vfs = (PLX_VFS_CONTEXT)VfsContext;
    return (Vfs != NULL) ? Vfs->EntryPoint : 0;
}

VOID
NTAPI
LxCleanupProcessVfs(
    _In_ PVOID VfsContext)
{
    PLX_VFS_CONTEXT Vfs = (PLX_VFS_CONTEXT)VfsContext;
    ULONG i;

    if (Vfs == NULL)
        return;

    for (i = 0; i < LX_MAX_FD; i++)
    {
        if (Vfs->FdTable[i].FileHandle != NULL)
        {
            ZwClose(Vfs->FdTable[i].FileHandle);
            Vfs->FdTable[i].FileHandle = NULL;
        }
    }

    ExFreePoolWithTag(Vfs, 'xLpV');
}
