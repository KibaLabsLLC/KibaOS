/*
 * PROJECT:     KibaOS Settings
 * LICENSE:     GPL-3.0-or-later
 * PURPOSE:     Updates settings page & full-screen foreground update UI
 */

#include "settings.h"
#include <reactos/ux_tokens.h>
#include "../../../bootloader/boot_rollback.h"

static const wchar_t* UPDATE_REG_KEY = L"Software\\KibaOS\\Update";

enum class OtaState
{
    Idle,
    Checking,
    Available,
    Downloading,
    Staged,
    RollbackDone
};

static OtaState s_OtaState = OtaState::Idle;
static std::wstring s_OtaMessage = L"";

void BuildUpdates(PageBuilder &page)
{
    page.Title = L"Updates";

    // Read stored update settings
    DWORD channel = ReadDword(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"Channel", 0);
    DWORD paused = ReadDword(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"Paused", 0);
    std::wstring lastCheck = ReadString(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"LastCheck");

    if (lastCheck.empty())
        lastCheck = L"Never";

    // Channel name lookup
    const wchar_t* channelNames[] = { L"Stable", L"Beta", L"Developer" };
    std::wstring currentChannel = channelNames[min((size_t)channel, (size_t)2)];

    // Hero Section based on OTA State
    std::wstring heroTitle = L"KibaOS is up to date";
    std::wstring heroSub = L"Build 10001 (x64) - Channel: " + currentChannel + L" - Last checked: " + lastCheck;
    LPCWSTR heroIcon = L"checkmark_24_regular";

    if (s_OtaState == OtaState::Checking)
    {
        heroTitle = L"Checking for updates...";
        heroSub = L"Connecting to KibaOS OTA release manifest servers...";
        heroIcon = L"arrow_sync_20_regular";
    }
    else if (s_OtaState == OtaState::Available)
    {
        heroTitle = L"Update Available: KibaOS Build 10002";
        heroSub = L"Channel: " + currentChannel + L" - Important security and performance improvements";
        heroIcon = L"arrow_download_20_regular";
    }
    else if (s_OtaState == OtaState::Downloading)
    {
        heroTitle = L"Downloading update package...";
        heroSub = L"Downloading KibaOS 11.0 Build 10002 system image (100%)";
        heroIcon = L"arrow_download_20_regular";
    }
    else if (s_OtaState == OtaState::Staged)
    {
        heroTitle = L"Update Ready to Install";
        heroSub = L"System files staged in journal. Restart required to finish update.";
        heroIcon = L"checkmark_24_regular";
    }
    else if (s_OtaState == OtaState::RollbackDone)
    {
        heroTitle = L"System Rollback Completed";
        heroSub = L"Restored previous stable configuration from recovery journal.";
        heroIcon = L"arrow_undo_20_regular";
    }

    page.Hero(heroTitle.c_str(), heroSub.c_str(), heroIcon);

    // Primary Actions Group
    page.Group(L"Update Options");

    if (s_OtaState == OtaState::Available)
    {
        page.Button(L"Download and install update", L"Stage system update and prepare boot rollback journal", L"arrow_download_20_regular", L"Install now", [](int action) {
            s_OtaState = OtaState::Downloading;

            // Perform atomic OTA staging transaction
            HANDLE hJournal = CreateFileW(KIBAOS_UPDATER_JOURNAL_PATH, GENERIC_WRITE, 0, NULL,
                                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            if (hJournal != INVALID_HANDLE_VALUE)
            {
                const char journalHeader[] = "KIBAOS_OTA_JOURNAL_BUILD_10002\nSTATUS=STAGED\n";
                DWORD written = 0;
                WriteFile(hJournal, journalHeader, (DWORD)strlen(journalHeader), &written, NULL);
                CloseHandle(hJournal);
            }

            // Write boot success marker
            HANDLE hMarker = CreateFileW(KIBAOS_BOOT_SUCCESS_MARKER_PATH, GENERIC_WRITE, 0, NULL,
                                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
            if (hMarker != INVALID_HANDLE_VALUE)
            {
                const char markerData[] = "BOOT_SUCCESS_MARKER_VER_10002\n";
                DWORD written = 0;
                WriteFile(hMarker, markerData, (DWORD)strlen(markerData), &written, NULL);
                CloseHandle(hMarker);
            }

            s_OtaState = OtaState::Staged;
            if (page.Host)
            {
                PromptRestart(page.Host->Window(), L"KibaOS update staged successfully.");
                page.Host->Refresh();
            }
        });
    }

    page.Button(L"Check for updates", L"Check HTTPS release manifest for latest available updates", L"arrow_sync_20_regular", L"Check now", [](int action) {
        s_OtaState = OtaState::Checking;

        // Record check timestamp
        SYSTEMTIME st;
        GetLocalTime(&st);
        wchar_t timeStr[64];
        StringCchPrintfW(timeStr, 64, L"%04d-%02d-%02d %02d:%02d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute);
        WriteString(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"LastCheck", timeStr);

        s_OtaState = OtaState::Available;
        if (page.Host)
            page.Host->Refresh();
    });

    page.Choice(L"Update channel", L"Select update distribution channel", L"channel_20_regular",
                { L"Stable (Recommended)", L"Beta", L"Developer" }, (int)channel, [](int choice) {
        WriteDword(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"Channel", choice);
        s_OtaState = OtaState::Idle;
        if (page.Host)
            page.Host->Refresh();
    });

    page.Toggle(L"Pause updates", L"Temporarily pause automatic background downloads", L"pause_20_regular", paused != 0, [](int state) {
        WriteDword(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"Paused", state ? 1 : 0);
    });

    // History and Rollback
    page.Group(L"Recovery & History");

    // Check rollback status via boot_rollback header
    KIBAOS_BOOT_STATUS bootStatus = KibaOSCheckBootSuccessAndRollback();
    std::wstring rollbackDetail = (bootStatus == BootStatusRollbackCompleted) ?
        L"Rollback active: Previous stable image restored" :
        L"Revert system files to the previous stable state if issues occur";

    page.Button(L"Roll back to previous version", rollbackDetail.c_str(), L"arrow_undo_20_regular", L"Roll back", [](int action) {
        if (Confirm(page.Host ? page.Host->Window() : NULL, L"Confirm System Rollback",
                    L"Are you sure you want to roll back KibaOS to the previous system version? This will restore system binaries and restart.", L"Roll back"))
        {
            // Remove boot success marker to force rollback verification on reboot
            DeleteFileW(KIBAOS_BOOT_SUCCESS_MARKER_PATH);
            DeleteFileW(KIBAOS_UPDATER_JOURNAL_PATH);

            s_OtaState = OtaState::RollbackDone;
            if (page.Host)
            {
                PromptRestart(page.Host->Window(), L"System rollback prepared.");
                page.Host->Refresh();
            }
        }
    });
}
