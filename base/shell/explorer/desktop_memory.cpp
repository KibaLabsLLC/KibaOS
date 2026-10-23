/*
 * PROJECT:     KibaOS Desktop Work Memory & Time Machine Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Desktop Memory & Point-in-Time Work Restorer Implementation
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#include "precomp.h"
#include "desktop_memory.h"
#include <reactos/universal_settings.h>

#define KIBA_MEMORY_BASE_KEY L"Software\\KibaOS\\DesktopMemory\\Snapshots"

static BOOL g_MemoryInitialized = FALSE;
static DWORD g_NextSnapshotId = 1001;

VOID DesktopMemory_Init(VOID)
{
    if (g_MemoryInitialized) return;
    g_MemoryInitialized = TRUE;
}

struct ENUM_SNAPSHOT_DATA
{
    KIBA_DESKTOP_SNAPSHOT *pSnapshot;
};

static BOOL CALLBACK EnumSnapshotWindowsProc(HWND hWnd, LPARAM lParam)
{
    ENUM_SNAPSHOT_DATA *pData = (ENUM_SNAPSHOT_DATA *)lParam;
    if (pData->pSnapshot->ItemCount >= 16) return FALSE;

    if (IsWindowVisible(hWnd) && !GetWindow(hWnd, GW_OWNER) && (GetWindowLongW(hWnd, GWL_EXSTYLE) & WS_EX_APPWINDOW || !(GetWindowLongW(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)))
    {
        WCHAR szClass[128];
        GetClassNameW(hWnd, szClass, _countof(szClass));
        if (_wcsicmp(szClass, L"Shell_TrayWnd") != 0 && _wcsicmp(szClass, L"Progman") != 0 && _wcsicmp(szClass, L"Button") != 0)
        {
            KIBA_WORK_ITEM *pItem = &pData->pSnapshot->Items[pData->pSnapshot->ItemCount];
            ZeroMemory(pItem, sizeof(KIBA_WORK_ITEM));

            GetWindowTextW(hWnd, pItem->Title, _countof(pItem->Title));
            GetWindowRect(hWnd, &pItem->WindowBounds);

            DWORD dwProcId = 0;
            GetWindowThreadProcessId(hWnd, &dwProcId);
            HANDLE hProc = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, dwProcId);
            if (hProc)
            {
                GetModuleFileNameExW(hProc, NULL, pItem->ExecutablePath, _countof(pItem->ExecutablePath));
                CloseHandle(hProc);
            }

            pItem->SpatialWorkspaceId = SpatialWorkspace_GetActive();
            pData->pSnapshot->ItemCount++;
        }
    }
    return TRUE;
}

DWORD DesktopMemory_CaptureSnapshot(LPCWSTR Description)
{
    DesktopMemory_Init();

    KIBA_DESKTOP_SNAPSHOT snap;
    ZeroMemory(&snap, sizeof(snap));

    snap.SnapshotId = g_NextSnapshotId++;

    SYSTEMTIME st;
    GetLocalTime(&st);
    StringCchPrintfW(snap.Timestamp, _countof(snap.Timestamp), L"%04u-%02u-%02u %02u:%02u:%02u", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    StringCchCopyW(snap.Description, _countof(snap.Description), (Description && Description[0]) ? Description : L"Desktop Work Snapshot");

    snap.IntentMode = IntentWM_GetActiveMode();
    snap.ActiveWorkspaceId = SpatialWorkspace_GetActive();

    ENUM_SNAPSHOT_DATA data = { &snap };
    EnumWindows(EnumSnapshotWindowsProc, (LPARAM)&data);

    if (OpenClipboard(NULL))
    {
        HANDLE hData = GetClipboardData(CF_UNICODETEXT);
        if (hData)
        {
            LPCWSTR pszClip = (LPCWSTR)GlobalLock(hData);
            if (pszClip)
            {
                StringCchCopyW(snap.LastClipboardText, _countof(snap.LastClipboardText), pszClip);
                GlobalUnlock(hData);
            }
        }
        CloseClipboard();
    }

    HKEY hBaseKey;
    DWORD dwDisp;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, KIBA_MEMORY_BASE_KEY, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL, &hBaseKey, &dwDisp) == ERROR_SUCCESS)
    {
        WCHAR szSubKey[64];
        StringCchPrintfW(szSubKey, _countof(szSubKey), L"Snap_%08u", snap.SnapshotId);

        HKEY hSnapKey;
        if (RegCreateKeyExW(hBaseKey, szSubKey, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_WRITE, NULL, &hSnapKey, &dwDisp) == ERROR_SUCCESS)
        {
            RegSetValueExW(hSnapKey, L"Timestamp", 0, REG_SZ, (const BYTE *)snap.Timestamp, (DWORD)(wcslen(snap.Timestamp) + 1) * sizeof(WCHAR));
            RegSetValueExW(hSnapKey, L"Description", 0, REG_SZ, (const BYTE *)snap.Description, (DWORD)(wcslen(snap.Description) + 1) * sizeof(WCHAR));
            RegSetValueExW(hSnapKey, L"ClipboardText", 0, REG_SZ, (const BYTE *)snap.LastClipboardText, (DWORD)(wcslen(snap.LastClipboardText) + 1) * sizeof(WCHAR));

            DWORD dwIntent = (DWORD)snap.IntentMode;
            RegSetValueExW(hSnapKey, L"IntentMode", 0, REG_DWORD, (const BYTE *)&dwIntent, sizeof(DWORD));

            DWORD dwWs = (DWORD)snap.ActiveWorkspaceId;
            RegSetValueExW(hSnapKey, L"ActiveWorkspaceId", 0, REG_DWORD, (const BYTE *)&dwWs, sizeof(DWORD));

            RegSetValueExW(hSnapKey, L"ItemCount", 0, REG_DWORD, (const BYTE *)&snap.ItemCount, sizeof(DWORD));

            for (DWORD i = 0; i < snap.ItemCount; i++)
            {
                WCHAR szItemVal[64];
                StringCchPrintfW(szItemVal, _countof(szItemVal), L"ItemExec_%u", i);
                RegSetValueExW(hSnapKey, szItemVal, 0, REG_SZ, (const BYTE *)snap.Items[i].ExecutablePath, (DWORD)(wcslen(snap.Items[i].ExecutablePath) + 1) * sizeof(WCHAR));

                StringCchPrintfW(szItemVal, _countof(szItemVal), L"ItemTitle_%u", i);
                RegSetValueExW(hSnapKey, szItemVal, 0, REG_SZ, (const BYTE *)snap.Items[i].Title, (DWORD)(wcslen(snap.Items[i].Title) + 1) * sizeof(WCHAR));
            }

            RegCloseKey(hSnapKey);
        }
        RegCloseKey(hBaseKey);
    }

    KibaSettingsRecordEvent(KIBA_HISTORY_CAT_SYSTEM, L"Desktop Memory Subsystem", L"Kiba Shell", L"Work Snapshot Saved", L"-", snap.Description);
    return snap.SnapshotId;
}

DWORD DesktopMemory_QuerySnapshots(KIBA_DESKTOP_SNAPSHOT *Buffer, DWORD MaxSnapshots)
{
    DesktopMemory_Init();
    if (!Buffer || MaxSnapshots == 0) return 0;

    HKEY hBaseKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, KIBA_MEMORY_BASE_KEY, 0, KEY_READ, &hBaseKey) != ERROR_SUCCESS)
    {
        DesktopMemory_CaptureSnapshot(L"System Boot Initial State");
        if (RegOpenKeyExW(HKEY_CURRENT_USER, KIBA_MEMORY_BASE_KEY, 0, KEY_READ, &hBaseKey) != ERROR_SUCCESS)
            return 0;
    }

    DWORD count = 0;
    WCHAR szSubKey[128];
    DWORD dwIndex = 0;

    while (count < MaxSnapshots)
    {
        DWORD dwNameLen = _countof(szSubKey);
        if (RegEnumKeyExW(hBaseKey, dwIndex++, szSubKey, &dwNameLen, NULL, NULL, NULL, NULL) != ERROR_SUCCESS)
            break;

        HKEY hSnapKey;
        if (RegOpenKeyExW(hBaseKey, szSubKey, 0, KEY_READ, &hSnapKey) == ERROR_SUCCESS)
        {
            KIBA_DESKTOP_SNAPSHOT *pSnap = &Buffer[count];
            ZeroMemory(pSnap, sizeof(KIBA_DESKTOP_SNAPSHOT));

            swscanf(szSubKey, L"Snap_%08u", &pSnap->SnapshotId);

            DWORD dwBytes = sizeof(pSnap->Timestamp);
            RegQueryValueExW(hSnapKey, L"Timestamp", NULL, NULL, (LPBYTE)pSnap->Timestamp, &dwBytes);

            dwBytes = sizeof(pSnap->Description);
            RegQueryValueExW(hSnapKey, L"Description", NULL, NULL, (LPBYTE)pSnap->Description, &dwBytes);

            dwBytes = sizeof(pSnap->LastClipboardText);
            RegQueryValueExW(hSnapKey, L"ClipboardText", NULL, NULL, (LPBYTE)pSnap->LastClipboardText, &dwBytes);

            DWORD dwIntent = 0, dwWs = 0, dwItems = 0;
            dwBytes = sizeof(DWORD);
            RegQueryValueExW(hSnapKey, L"IntentMode", NULL, NULL, (LPBYTE)&dwIntent, &dwBytes);
            pSnap->IntentMode = (KIBA_INTENT_MODE)dwIntent;

            dwBytes = sizeof(DWORD);
            RegQueryValueExW(hSnapKey, L"ActiveWorkspaceId", NULL, NULL, (LPBYTE)&dwWs, &dwBytes);
            pSnap->ActiveWorkspaceId = (int)dwWs;

            dwBytes = sizeof(DWORD);
            RegQueryValueExW(hSnapKey, L"ItemCount", NULL, NULL, (LPBYTE)&dwItems, &dwBytes);
            pSnap->ItemCount = min(dwItems, 16u);

            for (DWORD i = 0; i < pSnap->ItemCount; i++)
            {
                WCHAR szItemVal[64];
                StringCchPrintfW(szItemVal, _countof(szItemVal), L"ItemExec_%u", i);
                dwBytes = sizeof(pSnap->Items[i].ExecutablePath);
                RegQueryValueExW(hSnapKey, szItemVal, NULL, NULL, (LPBYTE)pSnap->Items[i].ExecutablePath, &dwBytes);

                StringCchPrintfW(szItemVal, _countof(szItemVal), L"ItemTitle_%u", i);
                dwBytes = sizeof(pSnap->Items[i].Title);
                RegQueryValueExW(hSnapKey, szItemVal, NULL, NULL, (LPBYTE)pSnap->Items[i].Title, &dwBytes);
            }

            count++;
            RegCloseKey(hSnapKey);
        }
    }

    RegCloseKey(hBaseKey);
    return count;
}

BOOL DesktopMemory_GetSnapshot(DWORD SnapshotId, KIBA_DESKTOP_SNAPSHOT *pSnapshot)
{
    DesktopMemory_Init();
    if (!pSnapshot) return FALSE;

    KIBA_DESKTOP_SNAPSHOT list[16];
    DWORD num = DesktopMemory_QuerySnapshots(list, _countof(list));

    for (DWORD i = 0; i < num; i++)
    {
        if (list[i].SnapshotId == SnapshotId)
        {
            *pSnapshot = list[i];
            return TRUE;
        }
    }
    return FALSE;
}

BOOL DesktopMemory_RestoreSnapshot(DWORD SnapshotId)
{
    DesktopMemory_Init();

    KIBA_DESKTOP_SNAPSHOT snap;
    if (!DesktopMemory_GetSnapshot(SnapshotId, &snap))
        return FALSE;

    SpatialWorkspace_Switch(snap.ActiveWorkspaceId);
    IntentWM_SetActiveMode(snap.IntentMode);

    for (DWORD i = 0; i < snap.ItemCount; i++)
    {
        if (snap.Items[i].ExecutablePath[0] != UNICODE_NULL)
        {
            ShellExecuteW(NULL, L"open", snap.Items[i].ExecutablePath, NULL, NULL, SW_SHOWNORMAL);
        }
    }

    KibaSettingsRecordEvent(KIBA_HISTORY_CAT_SYSTEM, L"Desktop Memory Subsystem", L"Kiba Shell", L"Time Machine Snapshot Restored", L"-", snap.Description);
    return TRUE;
}

VOID DesktopMemory_AutoSave(VOID)
{
    DesktopMemory_CaptureSnapshot(L"Periodic Auto-Save Work Snapshot");
}
