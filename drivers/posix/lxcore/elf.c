/*
 * PROJECT:     KibaOS NT Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Linux 64-bit ELF Binary Loader
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#include "lxcore.h"

#define EI_NIDENT       16
#define ELFMAG0         0x7f
#define ELFMAG1         'E'
#define ELFMAG2         'L'
#define ELFMAG3         'F'

#define ELFCLASS64      2
#define ELFDATA2LSB     1
#define ET_EXEC         2
#define ET_DYN          3

#define PT_NULL         0
#define PT_LOAD         1
#define PT_DYNAMIC      2
#define PT_INTERP       3
#define PT_NOTE         4
#define PT_SHLIB        5
#define PT_PHDR         6
#define PT_TLS          7

#ifndef PAGE_SIZE
#define PAGE_SIZE 0x1000
#endif

typedef struct {
    unsigned char e_ident[EI_NIDENT];
    UINT16 e_type;
    UINT16 e_machine;
    UINT32 e_version;
    UINT64 e_entry;
    UINT64 e_phoff;
    UINT64 e_shoff;
    UINT32 e_flags;
    UINT16 e_ehsize;
    UINT16 e_phentsize;
    UINT16 e_phnum;
    UINT16 e_shentsize;
    UINT16 e_shnum;
    UINT16 e_shstrndx;
} ELF64_EHDR;

typedef struct {
    UINT32 p_type;
    UINT32 p_flags;
    UINT64 p_offset;
    UINT64 p_vaddr;
    UINT64 p_paddr;
    UINT64 p_filesz;
    UINT64 p_memsz;
    UINT64 p_align;
} ELF64_PHDR;

NTSTATUS
NTAPI
LxLoadElfImage(
    _In_ PCWSTR ImagePath,
    _In_ PCWSTR CommandLine,
    _Out_ PULONG ProcessId)
{
    UNICODE_STRING NtImagePath;
    OBJECT_ATTRIBUTES ObjectAttributes;
    HANDLE FileHandle = NULL;
    IO_STATUS_BLOCK IoStatusBlock;
    ELF64_EHDR Ehdr;
    ELF64_PHDR Phdr;
    LARGE_INTEGER ByteOffset;
    HANDLE ProcessHandle = NULL;
    HANDLE ThreadHandle = NULL;
    PEPROCESS ProcessObject = NULL;
    PVOID VfsContext = NULL;
    KAPC_STATE ApcState;
    NTSTATUS Status;
    USHORT i;
    ULONG_PTR BaseLoadAddr = 0;

    UNREFERENCED_PARAMETER(CommandLine);

    if (ImagePath == NULL || ProcessId == NULL)
        return STATUS_INVALID_PARAMETER;

    *ProcessId = 0;

    RtlInitUnicodeString(&NtImagePath, ImagePath);
    InitializeObjectAttributes(&ObjectAttributes,
                               &NtImagePath,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE,
                               NULL,
                               NULL);

    Status = ZwOpenFile(&FileHandle,
                        GENERIC_READ | SYNCHRONIZE,
                        &ObjectAttributes,
                        &IoStatusBlock,
                        FILE_SHARE_READ,
                        FILE_SYNCHRONOUS_IO_NONALERT);

    if (!NT_SUCCESS(Status))
        return Status;

    ByteOffset.QuadPart = 0;
    Status = ZwReadFile(FileHandle,
                        NULL,
                        NULL,
                        NULL,
                        &IoStatusBlock,
                        &Ehdr,
                        sizeof(Ehdr),
                        &ByteOffset,
                        NULL);

    if (!NT_SUCCESS(Status))
    {
        ZwClose(FileHandle);
        return Status;
    }

    if (Ehdr.e_ident[0] != ELFMAG0 || Ehdr.e_ident[1] != ELFMAG1 ||
        Ehdr.e_ident[2] != ELFMAG2 || Ehdr.e_ident[3] != ELFMAG3 ||
        Ehdr.e_ident[4] != ELFCLASS64)
    {
        ZwClose(FileHandle);
        return STATUS_INVALID_IMAGE_FORMAT;
    }

    if (Ehdr.e_type != ET_EXEC && Ehdr.e_type != ET_DYN)
    {
        ZwClose(FileHandle);
        return STATUS_INVALID_IMAGE_FORMAT;
    }

    if (Ehdr.e_type == ET_DYN)
    {
        BaseLoadAddr = 0x00007fff00000000ULL;
    }

    Status = LxInitializeProcessVfs(PsGetCurrentProcess(), &VfsContext);
    if (!NT_SUCCESS(Status))
    {
        ZwClose(FileHandle);
        return Status;
    }

    LxSetProcessEntryPoint(VfsContext, (ULONG_PTR)(Ehdr.e_entry + BaseLoadAddr));

    Status = g_PicoRoutines.CreateProcess(
                 NULL,
                 NULL,
                 VfsContext,
                 &ProcessHandle);

    if (!NT_SUCCESS(Status))
    {
        LxCleanupProcessVfs(VfsContext);
        ZwClose(FileHandle);
        return Status;
    }

    Status = ObReferenceObjectByHandle(
                 ProcessHandle,
                 PROCESS_ALL_ACCESS,
                 *PsProcessType,
                 KernelMode,
                 (PVOID*)&ProcessObject,
                 NULL);

    if (!NT_SUCCESS(Status))
    {
        ZwClose(ProcessHandle);
        LxCleanupProcessVfs(VfsContext);
        ZwClose(FileHandle);
        return Status;
    }

    for (i = 0; i < Ehdr.e_phnum; i++)
    {
        ByteOffset.QuadPart = Ehdr.e_phoff + (i * Ehdr.e_phentsize);
        Status = ZwReadFile(FileHandle,
                            NULL,
                            NULL,
                            NULL,
                            &IoStatusBlock,
                            &Phdr,
                            sizeof(Phdr),
                            &ByteOffset,
                            NULL);

        if (!NT_SUCCESS(Status))
            break;

        if (Phdr.p_type == PT_LOAD && Phdr.p_memsz > 0)
        {
            ULONG_PTR VirtAddr = (ULONG_PTR)(Phdr.p_vaddr + BaseLoadAddr);
            ULONG_PTR PageOffset = VirtAddr & (PAGE_SIZE - 1);
            PVOID BaseAddress = (PVOID)(VirtAddr - PageOffset);
            SIZE_T RegionSize = (SIZE_T)Phdr.p_memsz + PageOffset;

            Status = ZwAllocateVirtualMemory(ProcessHandle,
                                             &BaseAddress,
                                             0,
                                             &RegionSize,
                                             MEM_RESERVE | MEM_COMMIT,
                                             PAGE_EXECUTE_READWRITE);

            if (NT_SUCCESS(Status) && Phdr.p_filesz > 0)
            {
                PVOID TempBuffer = ExAllocatePoolWithTag(PagedPool, (SIZE_T)Phdr.p_filesz, 'fLEx');
                if (TempBuffer != NULL)
                {
                    ByteOffset.QuadPart = Phdr.p_offset;
                    Status = ZwReadFile(FileHandle,
                                        NULL,
                                        NULL,
                                        NULL,
                                        &IoStatusBlock,
                                        TempBuffer,
                                        (ULONG)Phdr.p_filesz,
                                        &ByteOffset,
                                        NULL);

                    if (NT_SUCCESS(Status))
                    {
                        KeStackAttachProcess((PRKPROCESS)ProcessObject, &ApcState);
                        RtlCopyMemory((PVOID)VirtAddr, TempBuffer, (SIZE_T)Phdr.p_filesz);
                        KeUnstackDetachProcess(&ApcState);
                    }
                    ExFreePoolWithTag(TempBuffer, 'fLEx');
                }
            }
        }
    }

    ZwClose(FileHandle);

    if (!NT_SUCCESS(Status))
    {
        ObDereferenceObject(ProcessObject);
        ZwClose(ProcessHandle);
        return Status;
    }

    Status = g_PicoRoutines.CreateThread(
                 ProcessHandle,
                 VfsContext,
                 &ThreadHandle);

    if (NT_SUCCESS(Status))
    {
        PETHREAD ThreadObject;

        if (NT_SUCCESS(ObReferenceObjectByHandle(ThreadHandle, THREAD_ALL_ACCESS, *PsThreadType, KernelMode, (PVOID*)&ThreadObject, NULL)))
        {
            *ProcessId = HandleToUlong(PsGetThreadProcessId(ThreadObject));
            ObDereferenceObject(ThreadObject);
        }
        ZwClose(ThreadHandle);
    }

    ObDereferenceObject(ProcessObject);
    ZwClose(ProcessHandle);
    return Status;
}
