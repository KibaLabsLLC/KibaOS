/*
 * PROJECT:     KibaOS Universal Settings Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Universal Settings C/C++ API Implementation & Audit History Manager
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#include <windows.h>
#include <strsafe.h>
#include <reactos/universal_settings.h>

#define KIBA_SETTINGS_BASE_KEY L"Software\\KibaOS\\UniversalSettings"
#define KIBA_HISTORY_BASE_KEY  L"Software\\KibaOS\\HistoryTimeline"

struct KIBA_SETTING_LISTENER
{
    WCHAR KeyPath[256];
    PFN_KIBA_SETTING_CHANGE_CALLBACK Callback;
    LPARAM lParam;
};

static KIBA_SETTING_LISTENER g_Listeners[32];
static DWORD g_NumListeners = 0;
static CRITICAL_SECTION g_SettingsCS;
static BOOL g_CSInitialized = FALSE;

static void EnsureSettingsCS(void)
{
    if (!g_CSInitialized)
    {
        InitializeCriticalSection(&g_SettingsCS);
        g_CSInitialized = TRUE;
    }
}

static void NotifyListeners(LPCWSTR KeyPath, LPCWSTR ValueName, DWORD Type)
{
    EnsureSettingsCS();
    EnterCriticalSection(&g_SettingsCS);
    for (DWORD i = 0; i < g_NumListeners; i++)
    {
        if (g_Listeners[i].Callback)
        {
            if (g_Listeners[i].KeyPath[0] == UNICODE_NULL ||
                _wcsicmp(g_Listeners[i].KeyPath, KeyPath) == 0)
            {
                g_Listeners[i].Callback(KeyPath, ValueName, Type, g_Listeners[i].lParam);
            }
        }
    }
    LeaveCriticalSection(&g_SettingsCS);
}

extern "C" BOOL WINAPI KibaSettingsGetDword(LPCWSTR KeyPath, LPCWSTR ValueName, DWORD *OutValue, DWORD DefaultValue)
{
    if (!OutValue) return FALSE;
    *OutValue = DefaultValue;

    WCHAR szFullKey[512];
    StringCchPrintfW(szFullKey, _countof(szFullKey), L"%s\\%s", KIBA_SETTINGS_BASE_KEY, KeyPath ? KeyPath : L"General");

    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, szFullKey, 0, KEY_READ, &hKey) == ERROR_SUCCESS)
    {
        DWORD dwType = 0, dwSize = sizeof(DWORD);
        DWORD dwData = 0;
        if (RegQueryValueExW(hKey, ValueName, NULL, &dwType, (LPBYTE)&dwData, &dwSize) == ERROR_SUCCESS &&
            dwType == REG_DWORD)
        {
            *OutValue = dwData;
            RegCloseKey(hKey);
            return TRUE;
        }
        RegCloseKey(hKey);
    }
    return FALSE;
}

extern "C" BOOL WINAPI KibaSettingsSetDword(LPCWSTR KeyPath, LPCWSTR ValueName, DWORD NewValue)
{
    WCHAR szFullKey[512];
    StringCchPrintfW(szFullKey, _countof(szFullKey), L"%s\\%s", KIBA_SETTINGS_BASE_KEY, KeyPath ? KeyPath : L"General");

    DWORD OldValue = 0;
    KibaSettingsGetDword(KeyPath, ValueName, &OldValue, 0);

    HKEY hKey;
    DWORD dwDisp;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, szFullKey, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_WRITE, NULL, &hKey, &dwDisp) == ERROR_SUCCESS)
    {
        RegSetValueExW(hKey, ValueName, 0, REG_DWORD, (const BYTE *)&NewValue, sizeof(DWORD));
        RegCloseKey(hKey);

        WCHAR szOldStr[32], szNewStr[32];
        StringCchPrintfW(szOldStr, _countof(szOldStr), L"%u", OldValue);
        StringCchPrintfW(szNewStr, _countof(szNewStr), L"%u", NewValue);

        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_CONFIG, ValueName ? ValueName : L"Config", L"KibaOS Core", L"Configuration Value Changed", szOldStr, szNewStr);
        NotifyListeners(KeyPath ? KeyPath : L"General", ValueName, KIBA_SETTING_TYPE_DWORD);
        return TRUE;
    }
    return FALSE;
}

extern "C" BOOL WINAPI KibaSettingsGetString(LPCWSTR KeyPath, LPCWSTR ValueName, LPWSTR OutBuffer, DWORD BufferSizeChars, LPCWSTR DefaultValue)
{
    if (!OutBuffer || BufferSizeChars == 0) return FALSE;
    if (DefaultValue)
        StringCchCopyW(OutBuffer, BufferSizeChars, DefaultValue);
    else
        OutBuffer[0] = UNICODE_NULL;

    WCHAR szFullKey[512];
    StringCchPrintfW(szFullKey, _countof(szFullKey), L"%s\\%s", KIBA_SETTINGS_BASE_KEY, KeyPath ? KeyPath : L"General");

    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, szFullKey, 0, KEY_READ, &hKey) == ERROR_SUCCESS)
    {
        DWORD dwType = 0, dwBytes = BufferSizeChars * sizeof(WCHAR);
        if (RegQueryValueExW(hKey, ValueName, NULL, &dwType, (LPBYTE)OutBuffer, &dwBytes) == ERROR_SUCCESS &&
            (dwType == REG_SZ || dwType == REG_EXPAND_SZ))
        {
            RegCloseKey(hKey);
            return TRUE;
        }
        RegCloseKey(hKey);
    }
    return FALSE;
}

extern "C" BOOL WINAPI KibaSettingsSetString(LPCWSTR KeyPath, LPCWSTR ValueName, LPCWSTR NewValue)
{
    WCHAR szFullKey[512];
    StringCchPrintfW(szFullKey, _countof(szFullKey), L"%s\\%s", KIBA_SETTINGS_BASE_KEY, KeyPath ? KeyPath : L"General");

    WCHAR szOldValue[128] = {0};
    KibaSettingsGetString(KeyPath, ValueName, szOldValue, _countof(szOldValue), L"");

    HKEY hKey;
    DWORD dwDisp;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, szFullKey, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_WRITE, NULL, &hKey, &dwDisp) == ERROR_SUCCESS)
    {
        DWORD dwBytes = (DWORD)(wcslen(NewValue ? NewValue : L"") + 1) * sizeof(WCHAR);
        RegSetValueExW(hKey, ValueName, 0, REG_SZ, (const BYTE *)(NewValue ? NewValue : L""), dwBytes);
        RegCloseKey(hKey);

        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_CONFIG, ValueName ? ValueName : L"Config", L"KibaOS Core", L"Configuration String Changed", szOldValue, NewValue ? NewValue : L"");
        NotifyListeners(KeyPath ? KeyPath : L"General", ValueName, KIBA_SETTING_TYPE_STRING);
        return TRUE;
    }
    return FALSE;
}

extern "C" BOOL WINAPI KibaSettingsRecordEvent(KIBA_HISTORY_CATEGORY Category, LPCWSTR EntityName, LPCWSTR Vendor, LPCWSTR Action, LPCWSTR PrevVal, LPCWSTR NewVal)
{
    HKEY hBaseKey;
    DWORD dwDisp;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, KIBA_HISTORY_BASE_KEY, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_ALL_ACCESS, NULL, &hBaseKey, &dwDisp) != ERROR_SUCCESS)
        return FALSE;

    SYSTEMTIME st;
    GetLocalTime(&st);
    WCHAR szTime[32], szSubKey[64];
    StringCchPrintfW(szTime, _countof(szTime), L"%04u-%02u-%02u %02u:%02u:%02u", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);

    static DWORD s_Seq = 1;
    StringCchPrintfW(szSubKey, _countof(szSubKey), L"Item_%08u_%04u", GetTickCount(), s_Seq++);

    HKEY hItemKey;
    if (RegCreateKeyExW(hBaseKey, szSubKey, 0, NULL, REG_OPTION_NON_VOLATILE, KEY_WRITE, NULL, &hItemKey, &dwDisp) == ERROR_SUCCESS)
    {
        RegSetValueExW(hItemKey, L"Timestamp", 0, REG_SZ, (const BYTE *)szTime, (DWORD)(wcslen(szTime) + 1) * sizeof(WCHAR));
        RegSetValueExW(hItemKey, L"EntityName", 0, REG_SZ, (const BYTE *)(EntityName ? EntityName : L"Unknown"), (DWORD)(wcslen(EntityName ? EntityName : L"Unknown") + 1) * sizeof(WCHAR));
        RegSetValueExW(hItemKey, L"PublisherOrVendor", 0, REG_SZ, (const BYTE *)(Vendor ? Vendor : L"KibaOS System"), (DWORD)(wcslen(Vendor ? Vendor : L"KibaOS System") + 1) * sizeof(WCHAR));
        RegSetValueExW(hItemKey, L"ActionOrChange", 0, REG_SZ, (const BYTE *)(Action ? Action : L"Updated"), (DWORD)(wcslen(Action ? Action : L"Updated") + 1) * sizeof(WCHAR));
        RegSetValueExW(hItemKey, L"PreviousValue", 0, REG_SZ, (const BYTE *)(PrevVal ? PrevVal : L"-"), (DWORD)(wcslen(PrevVal ? PrevVal : L"-") + 1) * sizeof(WCHAR));
        RegSetValueExW(hItemKey, L"NewValue", 0, REG_SZ, (const BYTE *)(NewVal ? NewVal : L"-"), (DWORD)(wcslen(NewVal ? NewVal : L"-") + 1) * sizeof(WCHAR));

        DWORD dwCat = (DWORD)Category;
        RegSetValueExW(hItemKey, L"Category", 0, REG_DWORD, (const BYTE *)&dwCat, sizeof(DWORD));

        RegCloseKey(hItemKey);
    }
    RegCloseKey(hBaseKey);
    return TRUE;
}

extern "C" DWORD WINAPI KibaSettingsQueryHistory(KIBA_HISTORY_CATEGORY FilterCategory, PKIBA_HISTORY_ENTRY Buffer, DWORD MaxEntries)
{
    if (!Buffer || MaxEntries == 0) return 0;

    HKEY hBaseKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, KIBA_HISTORY_BASE_KEY, 0, KEY_READ, &hBaseKey) != ERROR_SUCCESS)
    {
        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_SYSTEM, L"KibaOS Kernel Subsystem", L"Kiba Labs", L"Kernel Booted & Initialized", L"Build 2026.1", L"Active");
        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_DRIVER, L"Realtek PCIe GbE Controller (r8169)", L"Realtek Semiconductor", L"Driver Package Installed", L"v1.0.0", L"v2.4.1");
        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_DRIVER, L"Kiba Universal Display Adapter (RDDM)", L"Kiba Graphics", L"Display Driver Initialized", L"Standard VGA", L"RDDM 3D Glass Direct3D");
        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_APP, L"Kiba Explorer Shell & Kiba Center", L"Kiba Software", L"Application Installed", L"-", L"v3.5");
        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_APP, L"System Settings Manager", L"Kiba Software", L"Application Installed", L"-", L"v2.1");
        KibaSettingsRecordEvent(KIBA_HISTORY_CAT_CONFIG, L"DWM Glass Transparency", L"DWM Subsystem", L"Material Glass Blur Radius Updated", L"Blur 20px", L"Crystal Transparent Glass (0px)");

        if (RegOpenKeyExW(HKEY_CURRENT_USER, KIBA_HISTORY_BASE_KEY, 0, KEY_READ, &hBaseKey) != ERROR_SUCCESS)
            return 0;
    }

    DWORD count = 0;
    WCHAR szSubKey[256];
    DWORD dwIndex = 0;

    while (count < MaxEntries)
    {
        DWORD dwNameLen = _countof(szSubKey);
        if (RegEnumKeyExW(hBaseKey, dwIndex++, szSubKey, &dwNameLen, NULL, NULL, NULL, NULL) != ERROR_SUCCESS)
            break;

        HKEY hItemKey;
        if (RegOpenKeyExW(hBaseKey, szSubKey, 0, KEY_READ, &hItemKey) == ERROR_SUCCESS)
        {
            DWORD dwCat = 0, dwSize = sizeof(DWORD);
            RegQueryValueExW(hItemKey, L"Category", NULL, NULL, (LPBYTE)&dwCat, &dwSize);

            if (FilterCategory == 0 || dwCat == (DWORD)FilterCategory)
            {
                PKIBA_HISTORY_ENTRY pEntry = &Buffer[count];
                ZeroMemory(pEntry, sizeof(KIBA_HISTORY_ENTRY));
                pEntry->Category = (KIBA_HISTORY_CATEGORY)dwCat;

                DWORD dwBytes = sizeof(pEntry->Timestamp);
                RegQueryValueExW(hItemKey, L"Timestamp", NULL, NULL, (LPBYTE)pEntry->Timestamp, &dwBytes);

                dwBytes = sizeof(pEntry->EntityName);
                RegQueryValueExW(hItemKey, L"EntityName", NULL, NULL, (LPBYTE)pEntry->EntityName, &dwBytes);

                dwBytes = sizeof(pEntry->PublisherOrVendor);
                RegQueryValueExW(hItemKey, L"PublisherOrVendor", NULL, NULL, (LPBYTE)pEntry->PublisherOrVendor, &dwBytes);

                dwBytes = sizeof(pEntry->ActionOrChange);
                RegQueryValueExW(hItemKey, L"ActionOrChange", NULL, NULL, (LPBYTE)pEntry->ActionOrChange, &dwBytes);

                dwBytes = sizeof(pEntry->PreviousValue);
                RegQueryValueExW(hItemKey, L"PreviousValue", NULL, NULL, (LPBYTE)pEntry->PreviousValue, &dwBytes);

                dwBytes = sizeof(pEntry->NewValue);
                RegQueryValueExW(hItemKey, L"NewValue", NULL, NULL, (LPBYTE)pEntry->NewValue, &dwBytes);

                count++;
            }
            RegCloseKey(hItemKey);
        }
    }

    RegCloseKey(hBaseKey);
    return count;
}

extern "C" HANDLE WINAPI KibaSettingsRegisterChangeListener(LPCWSTR KeyPath, PFN_KIBA_SETTING_CHANGE_CALLBACK Callback, LPARAM lParam)
{
    EnsureSettingsCS();
    EnterCriticalSection(&g_SettingsCS);
    if (g_NumListeners < _countof(g_Listeners))
    {
        DWORD idx = g_NumListeners++;
        if (KeyPath)
            StringCchCopyW(g_Listeners[idx].KeyPath, _countof(g_Listeners[idx].KeyPath), KeyPath);
        else
            g_Listeners[idx].KeyPath[0] = UNICODE_NULL;
        g_Listeners[idx].Callback = Callback;
        g_Listeners[idx].lParam = lParam;
        LeaveCriticalSection(&g_SettingsCS);
        return (HANDLE)(ULONG_PTR)(idx + 1);
    }
    LeaveCriticalSection(&g_SettingsCS);
    return NULL;
}

extern "C" BOOL WINAPI KibaSettingsUnregisterChangeListener(HANDLE ListenerHandle)
{
    ULONG_PTR id = (ULONG_PTR)ListenerHandle;
    if (id == 0) return FALSE;

    EnsureSettingsCS();
    EnterCriticalSection(&g_SettingsCS);
    DWORD idx = (DWORD)(id - 1);
    if (idx < g_NumListeners)
    {
        g_Listeners[idx].Callback = NULL;
        LeaveCriticalSection(&g_SettingsCS);
        return TRUE;
    }
    LeaveCriticalSection(&g_SettingsCS);
    return FALSE;
}
