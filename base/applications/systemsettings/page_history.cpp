/*
 * PROJECT:     KibaOS Settings
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Installation & Driver Config History Timeline Page
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#include "settings.h"
#include <reactos/universal_settings.h>

void BuildHistory(PageBuilder &page)
{
    page.Title = L"Installation & Config History Timeline";

    page.Hero(L"Installation & Configuration Audit Timeline",
              L"Track every application install, hardware driver event, and system config modification in real time",
              L"clock_20_regular");

    KIBA_HISTORY_ENTRY entries[64];
    DWORD count = KibaSettingsQueryHistory((KIBA_HISTORY_CATEGORY)0, entries, _countof(entries));

    SettingGroup &grpSummary = page.Group(L"Audit Summary");
    grpSummary.Rows.push_back({
        RowKind::Info,
        L"Total Audit Events Tracked",
        L"Real-time Universal Settings Audit Stream",
        Printf(L"%u Events Logged", count),
        L"info_20_regular"
    });

    SettingGroup &grpApps = page.Group(L"Installed Applications & Subsystems");
    int appCount = 0;
    for (DWORD i = 0; i < count; i++)
    {
        if (entries[i].Category == KIBA_HISTORY_CAT_APP || entries[i].Category == KIBA_HISTORY_CAT_SYSTEM)
        {
            appCount++;
            std::wstring detail = Printf(L"Vendor: %s | Saved: %s", entries[i].PublisherOrVendor, entries[i].Timestamp);
            std::wstring val = Printf(L"%s (%s -> %s)", entries[i].ActionOrChange, entries[i].PreviousValue, entries[i].NewValue);

            grpApps.Rows.push_back({
                RowKind::Info,
                entries[i].EntityName,
                detail,
                val,
                L"apps_20_regular"
            });
        }
    }
    if (appCount == 0)
    {
        grpApps.Rows.push_back({ RowKind::Text, L"No application installation events logged yet." });
    }

    SettingGroup &grpDrivers = page.Group(L"Hardware & Driver Installations");
    int drvCount = 0;
    for (DWORD i = 0; i < count; i++)
    {
        if (entries[i].Category == KIBA_HISTORY_CAT_DRIVER)
        {
            drvCount++;
            std::wstring detail = Printf(L"Vendor: %s | Date: %s", entries[i].PublisherOrVendor, entries[i].Timestamp);
            std::wstring val = Printf(L"%s (%s -> %s)", entries[i].ActionOrChange, entries[i].PreviousValue, entries[i].NewValue);

            grpDrivers.Rows.push_back({
                RowKind::Info,
                entries[i].EntityName,
                detail,
                val,
                L"plug_connected_20_regular"
            });
        }
    }
    if (drvCount == 0)
    {
        grpDrivers.Rows.push_back({ RowKind::Text, L"No driver installation events logged yet." });
    }

    SettingGroup &grpConfigs = page.Group(L"Configuration Change Log");
    int cfgCount = 0;
    for (DWORD i = 0; i < count; i++)
    {
        if (entries[i].Category == KIBA_HISTORY_CAT_CONFIG)
        {
            cfgCount++;
            std::wstring detail = Printf(L"Component: %s | Date: %s | %s -> %s", entries[i].PublisherOrVendor, entries[i].Timestamp, entries[i].PreviousValue, entries[i].NewValue);

            std::wstring entityName = entries[i].EntityName;
            std::wstring prevVal = entries[i].PreviousValue;
            std::wstring newVal = entries[i].NewValue;

            SettingRow row;
            row.Kind = RowKind::Button;
            row.Title = entityName;
            row.Detail = detail;
            row.Action = L"Revert Config";
            row.Icon = L"arrow_sync_20_regular";
            row.Invoke = [page, entityName, prevVal, newVal](int) {
                KibaSettingsRecordEvent(KIBA_HISTORY_CAT_CONFIG, entityName.c_str(), L"System Settings", L"Reverted Configuration Value", newVal.c_str(), prevVal.c_str());
                if (page.Host) page.Host->Refresh();
            };
            grpConfigs.Rows.push_back(row);
        }
    }
    if (cfgCount == 0)
    {
        grpConfigs.Rows.push_back({ RowKind::Text, L"No configuration change events logged yet." });
    }
}
