/*
 * PROJECT:     KibaOS NT Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Linux Core Subsystem Driver Entry Point
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#include "lxcore.h"

PS_PICO_ROUTINES g_PicoRoutines;

static NTSTATUS
NTAPI
LxCreateClose(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static NTSTATUS
NTAPI
LxDeviceControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _In_ PIRP Irp)
{
    PIO_STACK_LOCATION IrpSp = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS Status = STATUS_INVALID_DEVICE_REQUEST;
    ULONG_PTR Information = 0;

    UNREFERENCED_PARAMETER(DeviceObject);

    if (IrpSp->Parameters.DeviceIoControl.IoControlCode == IOCTL_LXCORE_EXECUTE_ELF)
    {
        PLX_EXECUTE_ELF_PARAMS Params;

        if (IrpSp->Parameters.DeviceIoControl.InputBufferLength >= sizeof(LX_EXECUTE_ELF_PARAMS) &&
            Irp->AssociatedIrp.SystemBuffer != NULL)
        {
            Params = (PLX_EXECUTE_ELF_PARAMS)Irp->AssociatedIrp.SystemBuffer;
            Status = LxLoadElfImage(Params->ImagePath, Params->CommandLine, &Params->ExecutedPid);
            if (NT_SUCCESS(Status))
            {
                Information = sizeof(LX_EXECUTE_ELF_PARAMS);
            }
        }
        else
        {
            Status = STATUS_BUFFER_TOO_SMALL;
        }
    }

    Irp->IoStatus.Status = Status;
    Irp->IoStatus.Information = Information;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return Status;
}

NTSTATUS
NTAPI
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath)
{
    PDEVICE_OBJECT DeviceObject = NULL;
    UNICODE_STRING DeviceName, SymbolicLinkName;
    PS_PICO_PROVIDER_ROUTINES ProviderRoutines;
    NTSTATUS Status;

    UNREFERENCED_PARAMETER(RegistryPath);

    RtlInitUnicodeString(&DeviceName, LXCORE_DEVICE_NAME);
    RtlInitUnicodeString(&SymbolicLinkName, LXCORE_SYMBOLIC_NAME);

    Status = IoCreateDevice(
                 DriverObject,
                 0,
                 &DeviceName,
                 FILE_DEVICE_UNKNOWN,
                 FILE_DEVICE_SECURE_OPEN,
                 FALSE,
                 &DeviceObject);

    if (!NT_SUCCESS(Status))
        return Status;

    Status = IoCreateSymbolicLink(&SymbolicLinkName, &DeviceName);
    if (!NT_SUCCESS(Status))
    {
        IoDeleteDevice(DeviceObject);
        return Status;
    }

    DriverObject->MajorFunction[IRP_MJ_CREATE] = LxCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = LxCreateClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = LxDeviceControl;

    RtlZeroMemory(&ProviderRoutines, sizeof(ProviderRoutines));
    ProviderRoutines.Size = sizeof(ProviderRoutines);
    ProviderRoutines.DispatchSystemCall = LxDispatchSystemCall;
    ProviderRoutines.DispatchException = LxDispatchException;
    ProviderRoutines.ExitProcess = LxExitProcess;
    ProviderRoutines.ExitThread = LxExitThread;
    ProviderRoutines.GetCpuContext = LxGetCpuContext;
    ProviderRoutines.SetCpuContext = LxSetCpuContext;

    RtlZeroMemory(&g_PicoRoutines, sizeof(g_PicoRoutines));
    g_PicoRoutines.Size = sizeof(g_PicoRoutines);

    Status = PsRegisterPicoProvider(&ProviderRoutines, &g_PicoRoutines);
    if (!NT_SUCCESS(Status))
    {
        IoDeleteSymbolicLink(&SymbolicLinkName);
        IoDeleteDevice(DeviceObject);
        return Status;
    }

    return STATUS_SUCCESS;
}
