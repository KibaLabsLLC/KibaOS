/*
 * PROJECT:     KibaOS force bugcheck CLI tool
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Trigger a system BugCheck / BSOD for diagnostic and testing purposes
 * COPYRIGHT:   Copyright 2026 KibaOS Developers
 */

#define WIN32_NO_STATUS
#include <windows.h>
#undef WIN32_NO_STATUS
#include <ndk/iotypes.h>
#include <ndk/kdfuncs.h>
#include <ndk/kdtypes.h>
#include <ndk/rtlfuncs.h>
#include <ndk/exfuncs.h>
#include <ndk/setypes.h>
#include <stdio.h>
#include <stdlib.h>

#define MANUALLY_INITIATED_CRASH 0x000000E2

int wmain(int argc, WCHAR *argv[])
{
    NTSTATUS Status;
    BOOLEAN OldPrivilege;
    ULONG BugCheckCode = MANUALLY_INITIATED_CRASH;
    ULONG Response;

    if (argc > 1 && (wcscmp(argv[1], L"/?") == 0 || wcscmp(argv[1], L"-h") == 0 || wcscmp(argv[1], L"--help") == 0))
    {
        wprintf(L"ForceBugCheck - KibaOS BugCheck testing utility\n");
        wprintf(L"Usage: forcebugcheck [bugcheck_code_hex]\n");
        wprintf(L"Default bugcheck code: 0x000000E2 (MANUALLY_INITIATED_CRASH)\n");
        return 0;
    }

    if (argc > 1)
    {
        BugCheckCode = (ULONG)wcstoul(argv[1], NULL, 16);
        if (BugCheckCode == 0)
        {
            BugCheckCode = MANUALLY_INITIATED_CRASH;
        }
    }

    wprintf(L"Initiating forced system BugCheck (Code: 0x%08X)...\n", BugCheckCode);

    /* Enable SeShutdownPrivilege / SeDebugPrivilege */
    Status = RtlAdjustPrivilege(SE_SHUTDOWN_PRIVILEGE, TRUE, FALSE, &OldPrivilege);
    if (!NT_SUCCESS(Status))
    {
        Status = RtlAdjustPrivilege(SE_DEBUG_PRIVILEGE, TRUE, FALSE, &OldPrivilege);
    }

    if (!NT_SUCCESS(Status))
    {
        fwprintf(stderr, L"Failed to acquire required privilege (Status: 0x%08X).\n", Status);
        return 1;
    }

    /* Raise hard error or system exception to trigger KeBugCheck */
    Status = NtRaiseHardError(STATUS_ASSERTION_FAILURE, 0, 0, NULL, OptionOk, &Response);

    if (!NT_SUCCESS(Status))
    {
        fwprintf(stderr, L"Failed to raise hard error (Status: 0x%08X).\n", Status);
        return 1;
    }

    return 0;
}
