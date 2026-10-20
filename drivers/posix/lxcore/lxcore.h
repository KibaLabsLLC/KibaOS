/*
 * PROJECT:     KibaOS NT Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Linux Core Subsystem Driver Internal Header
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#pragma once

#include <ntddk.h>
#include <ndk/ketypes.h>
#include <ndk/kefuncs.h>
#include <ndk/mmfuncs.h>
#include <reactos/pico.h>

#define LXCORE_DEVICE_NAME      L"\\Device\\LxCore"
#define LXCORE_SYMBOLIC_NAME    L"\\DosDevices\\LxCore"

#define IOCTL_LXCORE_EXECUTE_ELF CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _LX_EXECUTE_ELF_PARAMS {
    WCHAR ImagePath[260];
    WCHAR CommandLine[512];
    ULONG ExecutedPid;
} LX_EXECUTE_ELF_PARAMS, *PLX_EXECUTE_ELF_PARAMS;

/* Global Pico Kernel Services Table */
extern PS_PICO_ROUTINES g_PicoRoutines;

/* ELF Loader Interface */
NTSTATUS
NTAPI
LxLoadElfImage(
    _In_ PCWSTR ImagePath,
    _In_ PCWSTR CommandLine,
    _Out_ PULONG ProcessId);

/* System Call Dispatcher Interface */
NTSTATUS
NTAPI
LxDispatchSystemCall(
    _In_ PVOID PicoThreadContext,
    _Inout_ PVOID TrapFrame);

VOID
NTAPI
LxDispatchException(
    _In_ PVOID PicoThreadContext,
    _Inout_ PVOID TrapFrame,
    _In_ NTSTATUS ExceptionCode);

VOID
NTAPI
LxExitProcess(
    _In_ PVOID PicoProcessContext,
    _In_ PEPROCESS Process);

VOID
NTAPI
LxExitThread(
    _In_ PVOID PicoThreadContext,
    _In_ PETHREAD Thread);

NTSTATUS
NTAPI
LxGetCpuContext(
    _In_ PVOID PicoThreadContext,
    _Out_ PCONTEXT CpuContext);

NTSTATUS
NTAPI
LxSetCpuContext(
    _In_ PVOID PicoThreadContext,
    _In_ PCONTEXT CpuContext);

/* VFS / File Descriptor Interface */
NTSTATUS
NTAPI
LxInitializeProcessVfs(
    _In_ PEPROCESS Process,
    _Out_ PVOID *VfsContext);

VOID
NTAPI
LxSetProcessEntryPoint(
    _In_ PVOID VfsContext,
    _In_ ULONG_PTR EntryPoint);

ULONG_PTR
NTAPI
LxGetProcessEntryPoint(
    _In_ PVOID VfsContext);

VOID
NTAPI
LxCleanupProcessVfs(
    _In_ PVOID VfsContext);
