/*
 * PROJECT:     KibaOS NT Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Linux System Call Dispatcher and Handlers
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#include "lxcore.h"

#define SYS_read            0
#define SYS_write           1
#define SYS_open            2
#define SYS_close           3
#define SYS_stat            4
#define SYS_fstat           5
#define SYS_lseek           8
#define SYS_mmap            9
#define SYS_mprotect        10
#define SYS_munmap          11
#define SYS_brk             12
#define SYS_ioctl           16
#define SYS_access          21
#define SYS_pipe            22
#define SYS_dup             32
#define SYS_dup2            33
#define SYS_getpid          39
#define SYS_clone           56
#define SYS_fork            57
#define SYS_vfork           58
#define SYS_execve          59
#define SYS_exit            60
#define SYS_wait4           61
#define SYS_uname           63
#define SYS_fcntl           72
#define SYS_getcwd          79
#define SYS_mkdir           83
#define SYS_rmdir           84
#define SYS_unlink          87
#define SYS_getuid          102
#define SYS_getgid          104
#define SYS_geteuid         107
#define SYS_getegid         108
#define SYS_arch_prctl      158
#define SYS_gettid          186
#define SYS_set_tid_address 218
#define SYS_exit_group      231
#define SYS_openat          257
#define SYS_mkdirat         258
#define SYS_newfstatat      262
#define SYS_unlinkat        263
#define SYS_faccessat       269
#define SYS_dup3            292
#define SYS_pipe2           293

#define ARCH_SET_GS         0x1001
#define ARCH_SET_FS         0x1002
#define ARCH_GET_FS         0x1003
#define ARCH_GET_GS         0x1004

typedef struct _LX_UTSNAME {
    char sysname[65];
    char nodename[65];
    char release[65];
    char version[65];
    char machine[65];
    char domainname[65];
} LX_UTSNAME, *PLX_UTSNAME;

NTSTATUS
NTAPI
LxDispatchSystemCall(
    _In_ PVOID PicoThreadContext,
    _Inout_ PVOID TrapFrame)
{
    ULONG_PTR SyscallNum = 0;
    ULONG_PTR Arg1 = 0;
    ULONG_PTR Arg2 = 0;
    ULONG_PTR Arg3 = 0;
    ULONG_PTR Arg4 = 0;
    LONG_PTR Result = 0;

    UNREFERENCED_PARAMETER(PicoThreadContext);

    if (TrapFrame == NULL)
        return STATUS_INVALID_PARAMETER;

#if defined(_AMD64_) || defined(_M_AMD64)
    {
        PKTRAP_FRAME Frame = (PKTRAP_FRAME)TrapFrame;
        SyscallNum = Frame->Rax;
        Arg1 = Frame->Rdi;
        Arg2 = Frame->Rsi;
        Arg3 = Frame->Rdx;
        Arg4 = Frame->R10;
    }
#else
    {
        PKTRAP_FRAME Frame = (PKTRAP_FRAME)TrapFrame;
        SyscallNum = Frame->Eax;
        Arg1 = Frame->Ebx;
        Arg2 = Frame->Ecx;
        Arg3 = Frame->Edx;
        Arg4 = Frame->Esi;
    }
#endif

    switch (SyscallNum)
    {
        case SYS_read:
            Result = 0;
            break;

        case SYS_write:
            Result = (LONG_PTR)Arg3;
            break;

        case SYS_open:
        case SYS_openat:
            Result = 3;
            break;

        case SYS_close:
            Result = 0;
            break;

        case SYS_stat:
        case SYS_fstat:
        case SYS_newfstatat:
            Result = 0;
            break;

        case SYS_lseek:
            Result = (LONG_PTR)Arg2;
            break;

        case SYS_mmap:
            Result = Arg1 ? Arg1 : 0x7ffff7ff0000;
            break;

        case SYS_mprotect:
        case SYS_munmap:
            Result = 0;
            break;

        case SYS_brk:
            Result = Arg1 ? Arg1 : 0x08048000;
            break;

        case SYS_ioctl:
            Result = 0;
            break;

        case SYS_access:
        case SYS_faccessat:
            Result = 0;
            break;

        case SYS_pipe:
        case SYS_pipe2:
            Result = 0;
            break;

        case SYS_dup:
        case SYS_dup2:
        case SYS_dup3:
            Result = (LONG_PTR)Arg1;
            break;

        case SYS_getpid:
        case SYS_gettid:
            Result = HandleToUlong(PsGetCurrentProcessId());
            break;

        case SYS_getuid:
        case SYS_geteuid:
        case SYS_getgid:
        case SYS_getegid:
            Result = 1000;
            break;

        case SYS_uname:
        {
            PLX_UTSNAME Uts = (PLX_UTSNAME)Arg1;
            if (Uts != NULL)
            {
                RtlZeroMemory(Uts, sizeof(LX_UTSNAME));
                RtlCopyMemory(Uts->sysname, "Linux", 5);
                RtlCopyMemory(Uts->nodename, "kibaos", 6);
                RtlCopyMemory(Uts->release, "6.6.0-kibaos", 12);
                RtlCopyMemory(Uts->version, "#1 KibaOS Linux Subsystem 2026", 30);
#if defined(_AMD64_) || defined(_M_AMD64)
                RtlCopyMemory(Uts->machine, "x86_64", 6);
#else
                RtlCopyMemory(Uts->machine, "i686", 4);
#endif
                RtlCopyMemory(Uts->domainname, "localdomain", 11);
                Result = 0;
            }
            else
            {
                Result = -14;
            }
            break;
        }

        case SYS_fcntl:
            Result = 0;
            break;

        case SYS_getcwd:
            if (Arg1 != 0 && Arg2 >= 2)
            {
                RtlCopyMemory((PVOID)Arg1, "/", 2);
                Result = 2;
            }
            else
            {
                Result = -34;
            }
            break;

        case SYS_mkdir:
        case SYS_mkdirat:
        case SYS_rmdir:
        case SYS_unlink:
        case SYS_unlinkat:
            Result = 0;
            break;

        case SYS_arch_prctl:
        {
            ULONG Code = (ULONG)Arg1;
            if (Code == ARCH_SET_FS || Code == ARCH_SET_GS)
            {
                Result = 0;
            }
            else
            {
                Result = -22;
            }
            break;
        }

        case SYS_set_tid_address:
            Result = HandleToUlong(PsGetCurrentThreadId());
            break;

        case SYS_exit:
        case SYS_exit_group:
            PsTerminateSystemThread((NTSTATUS)Arg1);
            Result = 0;
            break;

        default:
            Result = 0;
            break;
    }

#if defined(_AMD64_) || defined(_M_AMD64)
    ((PKTRAP_FRAME)TrapFrame)->Rax = (ULONG_PTR)Result;
#else
    ((PKTRAP_FRAME)TrapFrame)->Eax = (ULONG_PTR)Result;
#endif

    return STATUS_SUCCESS;
}

VOID
NTAPI
LxDispatchException(
    _In_ PVOID PicoThreadContext,
    _Inout_ PVOID TrapFrame,
    _In_ NTSTATUS ExceptionCode)
{
    UNREFERENCED_PARAMETER(PicoThreadContext);
    UNREFERENCED_PARAMETER(TrapFrame);
    UNREFERENCED_PARAMETER(ExceptionCode);
}

VOID
NTAPI
LxExitProcess(
    _In_ PVOID PicoProcessContext,
    _In_ PEPROCESS Process)
{
    UNREFERENCED_PARAMETER(Process);
    if (PicoProcessContext != NULL)
    {
        LxCleanupProcessVfs(PicoProcessContext);
    }
}

VOID
NTAPI
LxExitThread(
    _In_ PVOID PicoThreadContext,
    _In_ PETHREAD Thread)
{
    UNREFERENCED_PARAMETER(PicoThreadContext);
    UNREFERENCED_PARAMETER(Thread);
}

NTSTATUS
NTAPI
LxGetCpuContext(
    _In_ PVOID PicoThreadContext,
    _Out_ PCONTEXT CpuContext)
{
    UNREFERENCED_PARAMETER(PicoThreadContext);
    if (CpuContext == NULL)
        return STATUS_INVALID_PARAMETER;
    RtlZeroMemory(CpuContext, sizeof(CONTEXT));
    return STATUS_SUCCESS;
}

NTSTATUS
NTAPI
LxSetCpuContext(
    _In_ PVOID PicoThreadContext,
    _In_ PCONTEXT CpuContext)
{
    UNREFERENCED_PARAMETER(PicoThreadContext);
    UNREFERENCED_PARAMETER(CpuContext);
    return STATUS_SUCCESS;
}
