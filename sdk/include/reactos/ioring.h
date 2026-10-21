/*
 * PROJECT:         KibaOS Kernel
 * LICENSE:         GPL - See COPYING in the top level directory
 * FILE:            sdk/include/reactos/ioring.h
 * PURPOSE:         Kernel-Bypassed I/O Ring Interface (io_uring / DirectStorage)
 */

#ifndef _REACTOS_IORING_H_
#define _REACTOS_IORING_H_

#include <ntdef.h>

#define KIBA_IORING_OP_NOP       0
#define KIBA_IORING_OP_READ      1
#define KIBA_IORING_OP_WRITE     2
#define KIBA_IORING_OP_FLUSH     3

#define KIBA_IORING_FLAG_DIRECT_NVME    0x00000001
#define KIBA_IORING_FLAG_FIXED_BUFFER   0x00000002
#define KIBA_IORING_FLAG_SQPOLL         0x00000004

typedef struct _KIBA_IO_RING_SQE {
    UCHAR Opcode;
    UCHAR Flags;
    USHORT Reserved;
    HANDLE FileHandle;
    ULONG64 Offset;
    PVOID Buffer;
    ULONG Length;
    ULONG64 UserData;
} KIBA_IO_RING_SQE, *PKIBA_IO_RING_SQE;

typedef struct _KIBA_IO_RING_CQE {
    ULONG64 UserData;
    LONG Result;
    ULONG Flags;
} KIBA_IO_RING_CQE, *PKIBA_IO_RING_CQE;

typedef struct _KIBA_IO_RING {
    ULONG QueueDepth;
    ULONG Flags;
    volatile ULONG SqHead;
    volatile ULONG SqTail;
    volatile ULONG CqHead;
    volatile ULONG CqTail;
    PKIBA_IO_RING_SQE Sqes;
    PKIBA_IO_RING_CQE Cqes;
    PVOID RegisteredBufferBase;
    SIZE_T RegisteredBufferSize;
    HANDLE EventHandle;
} KIBA_IO_RING, *PKIBA_IO_RING;

NTSTATUS
NTAPI
KibaCreateIoRing(
    _In_ ULONG QueueDepth,
    _In_ ULONG Flags,
    _Out_ PKIBA_IO_RING *IoRing);

NTSTATUS
NTAPI
KibaRegisterIoRingBuffer(
    _In_ PKIBA_IO_RING IoRing,
    _In_ PVOID BufferBase,
    _In_ SIZE_T BufferSize);

NTSTATUS
NTAPI
KibaSubmitIoRing(
    _In_ PKIBA_IO_RING IoRing,
    _In_ ULONG ToSubmit,
    _Out_ PULONG Submitted);

NTSTATUS
NTAPI
KibaCloseIoRing(
    _In_ PKIBA_IO_RING IoRing);

#endif /* _REACTOS_IORING_H_ */
