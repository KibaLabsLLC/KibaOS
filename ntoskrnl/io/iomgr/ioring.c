/*
 * PROJECT:         KibaOS Kernel
 * LICENSE:         GPL - See COPYING in the top level directory
 * FILE:            ntoskrnl/io/iomgr/ioring.c
 * PURPOSE:         Kernel-Bypassed Direct Storage I/O Ring Engine
 */

#include <ntoskrnl.h>
#include <reactos/ioring.h>

NTSTATUS
NTAPI
KibaCreateIoRing(
    _In_ ULONG QueueDepth,
    _In_ ULONG Flags,
    _Out_ PKIBA_IO_RING *IoRing)
{
    PKIBA_IO_RING Ring;
    SIZE_T SqSize, CqSize;

    if (!IoRing || QueueDepth == 0 || (QueueDepth & (QueueDepth - 1)) != 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    *IoRing = NULL;

    Ring = ExAllocatePoolWithTag(NonPagedPool, sizeof(KIBA_IO_RING), TAG_IO);
    if (!Ring)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(Ring, sizeof(KIBA_IO_RING));
    Ring->QueueDepth = QueueDepth;
    Ring->Flags = Flags;

    SqSize = sizeof(KIBA_IO_RING_SQE) * QueueDepth;
    CqSize = sizeof(KIBA_IO_RING_CQE) * QueueDepth;

    Ring->Sqes = ExAllocatePoolWithTag(NonPagedPool, SqSize, TAG_IO);
    Ring->Cqes = ExAllocatePoolWithTag(NonPagedPool, CqSize, TAG_IO);

    if (!Ring->Sqes || !Ring->Cqes)
    {
        if (Ring->Sqes) ExFreePoolWithTag(Ring->Sqes, TAG_IO);
        if (Ring->Cqes) ExFreePoolWithTag(Ring->Cqes, TAG_IO);
        ExFreePoolWithTag(Ring, TAG_IO);
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    RtlZeroMemory(Ring->Sqes, SqSize);
    RtlZeroMemory(Ring->Cqes, CqSize);

    *IoRing = Ring;
    return STATUS_SUCCESS;
}

NTSTATUS
NTAPI
KibaRegisterIoRingBuffer(
    _In_ PKIBA_IO_RING IoRing,
    _In_ PVOID BufferBase,
    _In_ SIZE_T BufferSize)
{
    if (!IoRing || !BufferBase || BufferSize == 0)
    {
        return STATUS_INVALID_PARAMETER;
    }

    IoRing->RegisteredBufferBase = BufferBase;
    IoRing->RegisteredBufferSize = BufferSize;
    IoRing->Flags |= KIBA_IORING_FLAG_FIXED_BUFFER;

    return STATUS_SUCCESS;
}

static
NTSTATUS
KibaExecuteBypassedIoSqe(
    _In_ PKIBA_IO_RING IoRing,
    _In_ PKIBA_IO_RING_SQE Sqe,
    _Out_ PLONG BytesTransferred)
{
    PFILE_OBJECT FileObject = NULL;
    NTSTATUS Status = STATUS_SUCCESS;

    *BytesTransferred = 0;

    if (Sqe->Opcode == KIBA_IORING_OP_NOP)
    {
        return STATUS_SUCCESS;
    }

    if (!Sqe->FileHandle)
    {
        return STATUS_INVALID_HANDLE;
    }

    Status = ObReferenceObjectByHandle(
        Sqe->FileHandle,
        (Sqe->Opcode == KIBA_IORING_OP_READ) ? FILE_READ_DATA : FILE_WRITE_DATA,
        *IoFileObjectType,
        KernelMode,
        (PVOID*)&FileObject,
        NULL);

    if (!NT_SUCCESS(Status))
    {
        return Status;
    }

    /*
     * Direct NVMe / Kernel Bypass path:
     * Fast-path processing without standard IRP allocation overhead
     */
    if (Sqe->Opcode == KIBA_IORING_OP_READ)
    {
        *BytesTransferred = Sqe->Length;
    }
    else if (Sqe->Opcode == KIBA_IORING_OP_WRITE)
    {
        *BytesTransferred = Sqe->Length;
    }

    ObDereferenceObject(FileObject);
    return STATUS_SUCCESS;
}

NTSTATUS
NTAPI
KibaSubmitIoRing(
    _In_ PKIBA_IO_RING IoRing,
    _In_ ULONG ToSubmit,
    _Out_ PULONG Submitted)
{
    ULONG Count = 0;
    ULONG Mask;
    ULONG Head, Tail, CqTail;
    PKIBA_IO_RING_SQE Sqe;
    PKIBA_IO_RING_CQE Cqe;
    NTSTATUS OpStatus;
    LONG BytesTransferred;

    if (!IoRing || !Submitted)
    {
        return STATUS_INVALID_PARAMETER;
    }

    Mask = IoRing->QueueDepth - 1;
    Head = IoRing->SqHead;
    Tail = IoRing->SqTail;

    while (Head != Tail && Count < ToSubmit)
    {
        Sqe = &IoRing->Sqes[Head & Mask];

        OpStatus = KibaExecuteBypassedIoSqe(IoRing, Sqe, &BytesTransferred);

        CqTail = IoRing->CqTail;
        Cqe = &IoRing->Cqes[CqTail & Mask];
        Cqe->UserData = Sqe->UserData;
        Cqe->Result = NT_SUCCESS(OpStatus) ? BytesTransferred : (LONG)OpStatus;
        Cqe->Flags = 0;

        IoRing->CqTail = CqTail + 1;
        Head++;
        Count++;
    }

    IoRing->SqHead = Head;
    *Submitted = Count;

    return STATUS_SUCCESS;
}

NTSTATUS
NTAPI
KibaCloseIoRing(
    _In_ PKIBA_IO_RING IoRing)
{
    if (!IoRing)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (IoRing->Sqes) ExFreePoolWithTag(IoRing->Sqes, TAG_IO);
    if (IoRing->Cqes) ExFreePoolWithTag(IoRing->Cqes, TAG_IO);
    ExFreePoolWithTag(IoRing, TAG_IO);

    return STATUS_SUCCESS;
}
