/*
 * PROJECT:     KibaOS Applications
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Linux/POSIX Application Launcher Utility
 * COPYRIGHT:   Copyright 2026 KibaOS Contributors
 */

#include <windows.h>
#include <stdio.h>
#include <winioctl.h>

#define LXCORE_SYMBOLIC_NAME    L"\\\\.\\LxCore"
#define IOCTL_LXCORE_EXECUTE_ELF CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _LX_EXECUTE_ELF_PARAMS {
    WCHAR ImagePath[260];
    WCHAR CommandLine[512];
    ULONG ExecutedPid;
} LX_EXECUTE_ELF_PARAMS, *PLX_EXECUTE_ELF_PARAMS;

int wmain(int argc, wchar_t *argv[])
{
    HANDLE hDriver;
    LX_EXECUTE_ELF_PARAMS Params;
    DWORD BytesReturned = 0;
    BOOL Success;

    if (argc < 2)
    {
        wprintf(L"KibaOS Linux Subsystem Launcher\n");
        wprintf(L"Usage: %s <path-to-elf-executable> [arguments]\n", argv[0]);
        return 1;
    }

    hDriver = CreateFileW(LXCORE_SYMBOLIC_NAME,
                          GENERIC_READ | GENERIC_WRITE,
                          FILE_SHARE_READ | FILE_SHARE_WRITE,
                          NULL,
                          OPEN_EXISTING,
                          FILE_ATTRIBUTE_NORMAL,
                          NULL);

    if (hDriver == INVALID_HANDLE_VALUE)
    {
        wprintf(L"Error: Unable to connect to LxCore subsystem driver (Error %lu)\n", GetLastError());
        return 1;
    }

    ZeroMemory(&Params, sizeof(Params));
    wcsncpy(Params.ImagePath, argv[1], 259);
    Params.ImagePath[259] = L'\0';
    if (argc >= 3)
    {
        wcsncpy(Params.CommandLine, argv[2], 511);
        Params.CommandLine[511] = L'\0';
    }

    Success = DeviceIoControl(hDriver,
                              IOCTL_LXCORE_EXECUTE_ELF,
                              &Params,
                              sizeof(Params),
                              &Params,
                              sizeof(Params),
                              &BytesReturned,
                              NULL);

    CloseHandle(hDriver);

    if (Success)
    {
        wprintf(L"Successfully launched Linux binary '%s' (PID: %lu)\n", argv[1], Params.ExecutedPid);
        return 0;
    }
    else
    {
        wprintf(L"Failed to launch Linux executable '%s' (Error %lu)\n", argv[1], GetLastError());
        return 1;
    }
}
