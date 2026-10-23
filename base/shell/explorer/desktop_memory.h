/*
 * PROJECT:     KibaOS Desktop Work Memory & Time Machine Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Desktop Memory & Point-in-Time Work Restorer Header
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#pragma once

#include <windows.h>
#include "spatial_workspace.h"
#include "intent_wm.h"

struct KIBA_WORK_ITEM
{
    WCHAR Title[128];
    WCHAR ExecutablePath[MAX_PATH];
    WCHAR DocumentPath[MAX_PATH];
    RECT WindowBounds;
    int SpatialWorkspaceId;
};

struct KIBA_DESKTOP_SNAPSHOT
{
    DWORD SnapshotId;
    WCHAR Timestamp[32];
    WCHAR Description[128];
    KIBA_INTENT_MODE IntentMode;
    int ActiveWorkspaceId;
    DWORD ItemCount;
    KIBA_WORK_ITEM Items[16];
    WCHAR LastClipboardText[256];
};

VOID DesktopMemory_Init(VOID);
DWORD DesktopMemory_CaptureSnapshot(LPCWSTR Description);
BOOL DesktopMemory_GetSnapshot(DWORD SnapshotId, KIBA_DESKTOP_SNAPSHOT *pSnapshot);
DWORD DesktopMemory_QuerySnapshots(KIBA_DESKTOP_SNAPSHOT *Buffer, DWORD MaxSnapshots);
BOOL DesktopMemory_RestoreSnapshot(DWORD SnapshotId);
VOID DesktopMemory_AutoSave(VOID);
