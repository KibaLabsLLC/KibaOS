/*
 * PROJECT:     KibaOS Executive & Universal Settings Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Public Universal Settings API C/C++ Interface Header
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#pragma once

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum _KIBA_SETTING_TYPE
{
    KIBA_SETTING_TYPE_NONE = 0,
    KIBA_SETTING_TYPE_DWORD = 1,
    KIBA_SETTING_TYPE_STRING = 2,
    KIBA_SETTING_TYPE_BINARY = 3
} KIBA_SETTING_TYPE;

typedef enum _KIBA_HISTORY_CATEGORY
{
    KIBA_HISTORY_CAT_APP = 1,
    KIBA_HISTORY_CAT_DRIVER = 2,
    KIBA_HISTORY_CAT_CONFIG = 3,
    KIBA_HISTORY_CAT_SYSTEM = 4
} KIBA_HISTORY_CATEGORY;

typedef struct _KIBA_HISTORY_ENTRY
{
    WCHAR Timestamp[32];
    WCHAR EntityName[128];
    WCHAR PublisherOrVendor[128];
    WCHAR ActionOrChange[256];
    WCHAR PreviousValue[128];
    WCHAR NewValue[128];
    KIBA_HISTORY_CATEGORY Category;
} KIBA_HISTORY_ENTRY, *PKIBA_HISTORY_ENTRY;

BOOL WINAPI KibaSettingsGetDword(LPCWSTR KeyPath, LPCWSTR ValueName, DWORD *OutValue, DWORD DefaultValue);
BOOL WINAPI KibaSettingsSetDword(LPCWSTR KeyPath, LPCWSTR ValueName, DWORD NewValue);

BOOL WINAPI KibaSettingsGetString(LPCWSTR KeyPath, LPCWSTR ValueName, LPWSTR OutBuffer, DWORD BufferSizeChars, LPCWSTR DefaultValue);
BOOL WINAPI KibaSettingsSetString(LPCWSTR KeyPath, LPCWSTR ValueName, LPCWSTR NewValue);

BOOL WINAPI KibaSettingsRecordEvent(KIBA_HISTORY_CATEGORY Category, LPCWSTR EntityName, LPCWSTR Vendor, LPCWSTR Action, LPCWSTR PrevVal, LPCWSTR NewVal);
DWORD WINAPI KibaSettingsQueryHistory(KIBA_HISTORY_CATEGORY FilterCategory, PKIBA_HISTORY_ENTRY Buffer, DWORD MaxEntries);

typedef void (CALLBACK *PFN_KIBA_SETTING_CHANGE_CALLBACK)(LPCWSTR KeyPath, LPCWSTR ValueName, DWORD SettingType, LPARAM lParam);
HANDLE WINAPI KibaSettingsRegisterChangeListener(LPCWSTR KeyPath, PFN_KIBA_SETTING_CHANGE_CALLBACK Callback, LPARAM lParam);
BOOL WINAPI KibaSettingsUnregisterChangeListener(HANDLE ListenerHandle);

#ifdef __cplusplus
}
#endif
