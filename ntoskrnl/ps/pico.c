/*
 * PROJECT:     KibaOS NT Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Pico process and thread provider infrastructure
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#include <ntoskrnl.h>
#include <reactos/pico.h>

#define NDBG
#include <debug.h>

static PS_PICO_PROVIDER_ROUTINES PspPicoProviderRoutines;
static BOOLEAN PspPicoProviderRegistered = FALSE;

NTSTATUS
NTAPI
PsRegisterPicoProvider(
    _In_ PPS_PICO_PROVIDER_ROUTINES ProviderRoutines,
    _Out_ PPS_PICO_ROUTINES PicoRoutines)
{
    if (ProviderRoutines == NULL || PicoRoutines == NULL)
        return STATUS_INVALID_PARAMETER;

    if (ProviderRoutines->Size < sizeof(PS_PICO_PROVIDER_ROUTINES) ||
        PicoRoutines->Size < sizeof(PS_PICO_ROUTINES))
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (PspPicoProviderRegistered)
        return STATUS_ALREADY_REGISTERED;

    RtlCopyMemory(&PspPicoProviderRoutines, ProviderRoutines, sizeof(PS_PICO_PROVIDER_ROUTINES));
    PspPicoProviderRegistered = TRUE;

    PicoRoutines->CreateProcess = PsCreatePicoProcess;
    PicoRoutines->CreateThread = PsCreatePicoThread;
    PicoRoutines->GetProcessContext = PsGetPicoProcessContext;
    PicoRoutines->GetThreadContext = PsGetPicoThreadContext;
    PicoRoutines->SetThreadContext = PsSetPicoThreadContext;
    PicoRoutines->TerminateThread = (PS_PICO_TERMINATE_THREAD)PsTerminateSystemThread;
    PicoRoutines->ResumeThread = (PS_PICO_RESUME_THREAD)KeResumeThread;

    DPRINT1("PsRegisterPicoProvider: Subsystem provider registered successfully.\n");
    return STATUS_SUCCESS;
}

NTSTATUS
NTAPI
PsCreatePicoProcess(
    _In_ HANDLE ParentProcessHandle,
    _In_ POBJECT_ATTRIBUTES ObjectAttributes,
    _In_ PVOID PicoContext,
    _Out_ PHANDLE ProcessHandle)
{
    PEPROCESS Process;
    HANDLE ParentHandle;
    NTSTATUS Status;

    if (ProcessHandle == NULL)
        return STATUS_INVALID_PARAMETER;

    *ProcessHandle = NULL;
    ParentHandle = (ParentProcessHandle != NULL) ? ParentProcessHandle : NtCurrentProcess();

    Status = PspCreateProcess(
                 ProcessHandle,
                 PROCESS_ALL_ACCESS,
                 ObjectAttributes,
                 ParentHandle,
                 0,
                 NULL,
                 NULL,
                 NULL,
                 FALSE,
                 NULL,
                 0);

    if (!NT_SUCCESS(Status))
        return Status;

    Status = ObReferenceObjectByHandle(
                 *ProcessHandle,
                 PROCESS_ALL_ACCESS,
                 *PsProcessType,
                 KernelMode,
                 (PVOID*)&Process,
                 NULL);

    if (NT_SUCCESS(Status))
    {
        Process->PicoContext = PicoContext;
        Process->PicoCreated = 1;
        ObDereferenceObject(Process);
    }

    return Status;
}

NTSTATUS
NTAPI
PsCreatePicoThread(
    _In_ HANDLE ProcessHandle,
    _In_ PVOID PicoContext,
    _Out_ PHANDLE ThreadHandle)
{
    PEPROCESS Process;
    PETHREAD Thread;
    NTSTATUS Status;

    if (ThreadHandle == NULL)
        return STATUS_INVALID_PARAMETER;

    *ThreadHandle = NULL;

    Status = ObReferenceObjectByHandle(
                 ProcessHandle,
                 PROCESS_ALL_ACCESS,
                 *PsProcessType,
                 KernelMode,
                 (PVOID*)&Process,
                 NULL);

    if (!NT_SUCCESS(Status))
        return Status;

    Status = PspCreateThread(
                 ThreadHandle,
                 THREAD_ALL_ACCESS,
                 NULL,
                 ProcessHandle,
                 Process,
                 NULL,
                 NULL,
                 NULL,
                 NULL,
                 0,
                 NULL,
                 NULL,
                 NULL);

    if (NT_SUCCESS(Status))
    {
        NTSTATUS RefStatus = ObReferenceObjectByHandle(
                                 *ThreadHandle,
                                 THREAD_ALL_ACCESS,
                                 *PsThreadType,
                                 KernelMode,
                                 (PVOID*)&Thread,
                                 NULL);
        if (NT_SUCCESS(RefStatus))
        {
            Thread->PicoContext = PicoContext;
            ObDereferenceObject(Thread);
        }
    }

    ObDereferenceObject(Process);
    return Status;
}

PVOID
NTAPI
PsGetPicoProcessContext(
    _In_ PEPROCESS Process)
{
    return (Process != NULL) ? Process->PicoContext : NULL;
}

PVOID
NTAPI
PsGetPicoThreadContext(
    _In_ PETHREAD Thread)
{
    return (Thread != NULL) ? Thread->PicoContext : NULL;
}

VOID
NTAPI
PsSetPicoThreadContext(
    _In_ PETHREAD Thread,
    _In_ PVOID PicoContext)
{
    if (Thread != NULL)
    {
        Thread->PicoContext = PicoContext;
    }
}

BOOLEAN
NTAPI
PsIsPicoProcess(
    _In_ PEPROCESS Process)
{
    return (Process != NULL && (Process->PicoContext != NULL || Process->PicoCreated != 0));
}

VOID
NTAPI
PspPicoExitProcess(
    _In_ PEPROCESS Process)
{
    if (Process != NULL && Process->PicoContext != NULL && PspPicoProviderRegistered)
    {
        if (PspPicoProviderRoutines.ExitProcess != NULL)
        {
            PspPicoProviderRoutines.ExitProcess(Process->PicoContext, Process);
        }
    }
}

VOID
NTAPI
PspPicoExitThread(
    _In_ PETHREAD Thread)
{
    if (Thread != NULL && Thread->PicoContext != NULL && PspPicoProviderRegistered)
    {
        if (PspPicoProviderRoutines.ExitThread != NULL)
        {
            PspPicoProviderRoutines.ExitThread(Thread->PicoContext, Thread);
        }
    }
}

NTSTATUS
NTAPI
PspPicoDispatchSystemCall(
    _Inout_ PVOID TrapFrame)
{
    PETHREAD Thread = PsGetCurrentThread();
    if (Thread != NULL && Thread->PicoContext != NULL && PspPicoProviderRegistered)
    {
        if (PspPicoProviderRoutines.DispatchSystemCall != NULL)
        {
            return PspPicoProviderRoutines.DispatchSystemCall(Thread->PicoContext, TrapFrame);
        }
    }
    return STATUS_NOT_IMPLEMENTED;
}
