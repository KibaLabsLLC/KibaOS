/*
 * PROJECT:     KibaOS NT Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Pico Process Subsystem Provider Kernel Header
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#pragma once

#include <ntdef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Subsystem callback function types */
typedef NTSTATUS (NTAPI *PS_PICO_DISPATCH_SYSTEM_CALL)(
    _In_ PVOID PicoThreadContext,
    _Inout_ PVOID TrapFrame);

typedef VOID (NTAPI *PS_PICO_DISPATCH_EXCEPTION)(
    _In_ PVOID PicoThreadContext,
    _Inout_ PVOID TrapFrame,
    _In_ NTSTATUS ExceptionCode);

typedef VOID (NTAPI *PS_PICO_EXIT_PROCESS)(
    _In_ PVOID PicoProcessContext,
    _In_ PEPROCESS Process);

typedef VOID (NTAPI *PS_PICO_EXIT_THREAD)(
    _In_ PVOID PicoThreadContext,
    _In_ PETHREAD Thread);

typedef NTSTATUS (NTAPI *PS_PICO_GET_CPU_CONTEXT)(
    _In_ PVOID PicoThreadContext,
    _Out_ PCONTEXT CpuContext);

typedef NTSTATUS (NTAPI *PS_PICO_SET_CPU_CONTEXT)(
    _In_ PVOID PicoThreadContext,
    _In_ PCONTEXT CpuContext);

typedef struct _PS_PICO_PROVIDER_ROUTINES {
    ULONG Size;
    PS_PICO_DISPATCH_SYSTEM_CALL DispatchSystemCall;
    PS_PICO_DISPATCH_EXCEPTION DispatchException;
    PS_PICO_EXIT_PROCESS ExitProcess;
    PS_PICO_EXIT_THREAD ExitThread;
    PS_PICO_GET_CPU_CONTEXT GetCpuContext;
    PS_PICO_SET_CPU_CONTEXT SetCpuContext;
} PS_PICO_PROVIDER_ROUTINES, *PPS_PICO_PROVIDER_ROUTINES;

/* Kernel routines provided to Pico subsystem driver */
typedef NTSTATUS (NTAPI *PS_PICO_CREATE_PROCESS)(
    _In_ HANDLE ParentProcessHandle,
    _In_ POBJECT_ATTRIBUTES ObjectAttributes,
    _In_ PVOID PicoContext,
    _Out_ PHANDLE ProcessHandle);

typedef NTSTATUS (NTAPI *PS_PICO_CREATE_THREAD)(
    _In_ HANDLE ProcessHandle,
    _In_ PVOID PicoContext,
    _Out_ PHANDLE ThreadHandle);

typedef PVOID (NTAPI *PS_PICO_GET_PROCESS_CONTEXT)(
    _In_ PEPROCESS Process);

typedef PVOID (NTAPI *PS_PICO_GET_THREAD_CONTEXT)(
    _In_ PETHREAD Thread);

typedef VOID (NTAPI *PS_PICO_SET_THREAD_CONTEXT)(
    _In_ PETHREAD Thread,
    _In_ PVOID PicoContext);

typedef NTSTATUS (NTAPI *PS_PICO_TERMINATE_THREAD)(
    _In_ PETHREAD Thread,
    _In_ NTSTATUS ExitStatus);

typedef NTSTATUS (NTAPI *PS_PICO_RESUME_THREAD)(
    _In_ PETHREAD Thread);

typedef struct _PS_PICO_ROUTINES {
    ULONG Size;
    PS_PICO_CREATE_PROCESS CreateProcess;
    PS_PICO_CREATE_THREAD CreateThread;
    PS_PICO_GET_PROCESS_CONTEXT GetProcessContext;
    PS_PICO_GET_THREAD_CONTEXT GetThreadContext;
    PS_PICO_SET_THREAD_CONTEXT SetThreadContext;
    PS_PICO_TERMINATE_THREAD TerminateThread;
    PS_PICO_RESUME_THREAD ResumeThread;
} PS_PICO_ROUTINES, *PPS_PICO_ROUTINES;

/* Public Kernel Exports */
NTSTATUS
NTAPI
PsRegisterPicoProvider(
    _In_ PPS_PICO_PROVIDER_ROUTINES ProviderRoutines,
    _Out_ PPS_PICO_ROUTINES PicoRoutines);

NTSTATUS
NTAPI
PsCreatePicoProcess(
    _In_ HANDLE ParentProcessHandle,
    _In_ POBJECT_ATTRIBUTES ObjectAttributes,
    _In_ PVOID PicoContext,
    _Out_ PHANDLE ProcessHandle);

NTSTATUS
NTAPI
PsCreatePicoThread(
    _In_ HANDLE ProcessHandle,
    _In_ PVOID PicoContext,
    _Out_ PHANDLE ThreadHandle);

PVOID
NTAPI
PsGetPicoProcessContext(
    _In_ PEPROCESS Process);

PVOID
NTAPI
PsGetPicoThreadContext(
    _In_ PETHREAD Thread);

VOID
NTAPI
PsSetPicoThreadContext(
    _In_ PETHREAD Thread,
    _In_ PVOID PicoContext);

BOOLEAN
NTAPI
PsIsPicoProcess(
    _In_ PEPROCESS Process);

#ifdef __cplusplus
}
#endif
