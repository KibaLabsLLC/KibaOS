/*
 * PROJECT:     KibaOS Settings
 * LICENSE:     GPL-3.0-or-later
 * PURPOSE:     Updates settings page & full-screen foreground update UI
 */

#include "settings.h"
#include <reactos/ux_tokens.h>
#include "../../../bootloader/boot_rollback.h"

#include <windows.h>
#include <wininet.h>
#include <wincrypt.h>
#include <setupapi.h>
#include <shlwapi.h>
#include <shlobj.h>
#include <strsafe.h>
#include <string>
#include <vector>
#include <sstream>
#include <algorithm>
#include <iomanip>

static const wchar_t* UPDATE_REG_KEY = L"Software\\KibaOS\\Update";

enum class OtaState
{
    Idle,
    Checking,
    Available,
    Downloading,
    Staged,
    RollbackDone,
    Error
};

static OtaState s_OtaState = OtaState::Idle;
static std::wstring s_OtaMessage = L"";
static DWORD s_AvailableBuildNumber = 0;
static std::wstring s_AvailableCabName = L"";
static std::string s_AvailableCabSha256 = "";
static std::size_t s_AvailableCabSize = 0;

struct OtaCabInfo
{
    std::wstring Name;
    std::string Sha256;
    std::size_t Size = 0;
};

struct OtaManifest
{
    int ManifestVersion = 0;
    std::wstring OsVersion;
    DWORD BuildNumber = 0;
    DWORD MinUpdateVersion = 0;
    std::vector<OtaCabInfo> Cabs;
};

static std::wstring GetSystemArchitecture()
{
#if defined(_M_ARM64) || defined(__aarch64__)
    return L"arm64";
#elif defined(_M_AMD64) || defined(__x86_64__)
    return L"amd64";
#else
    return L"amd64";
#endif
}

static DWORD GetCurrentBuildNumber()
{
    DWORD buildNum = ReadDword(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"CurrentBuildNumber", 0);
    if (buildNum == 0)
    {
        buildNum = ReadDword(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", L"CurrentBuildNumber", 10001);
    }
    return buildNum;
}

static std::wstring GetManifestUrl()
{
    std::wstring url = ReadString(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"ManifestUrl");
    if (url.empty())
    {
        url = L"https://downloads.sourceforge.net/project/kibaos/" + GetSystemArchitecture() + L"-nt/ota/ota_manifest.json";
    }
    return url;
}

static bool FetchHttpsData(const std::wstring& url, std::string& outData, std::wstring& outError)
{
    if (_wcsnicmp(url.c_str(), L"https://", 8) != 0)
    {
        outError = L"Plain HTTP or unencrypted URL rejected";
        return false;
    }

    HINTERNET hInet = InternetOpenW(L"KibaOS-OTA-Updater/1.0", INTERNET_OPEN_TYPE_PRECONFIG, NULL, NULL, 0);
    if (!hInet)
    {
        outError = L"Failed to initialize network interface";
        return false;
    }

    DWORD flags = INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE;
    HINTERNET hUrl = InternetOpenUrlW(hInet, url.c_str(), NULL, 0, flags, 0);
    if (!hUrl)
    {
        DWORD err = GetLastError();
        InternetCloseHandle(hInet);
        outError = L"Failed to connect to update server (error " + std::to_wstring(err) + L")";
        return false;
    }

    char buffer[4096];
    DWORD bytesRead = 0;
    outData.clear();

    while (InternetReadFile(hUrl, buffer, sizeof(buffer), &bytesRead) && bytesRead > 0)
    {
        outData.append(buffer, bytesRead);
    }

    InternetCloseHandle(hUrl);
    InternetCloseHandle(hInet);
    return true;
}

static bool DownloadHttpsFile(const std::wstring& url, const std::wstring& destPath, std::wstring& outError)
{
    if (_wcsnicmp(url.c_str(), L"https://", 8) != 0)
    {
        outError = L"Plain HTTP or unencrypted URL rejected";
        return false;
    }

    HINTERNET hInet = InternetOpenW(L"KibaOS-OTA-Updater/1.0", INTERNET_OPEN_TYPE_PRECONFIG, NULL, NULL, 0);
    if (!hInet)
    {
        outError = L"Failed to initialize network interface";
        return false;
    }

    DWORD flags = INTERNET_FLAG_SECURE | INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE;
    HINTERNET hUrl = InternetOpenUrlW(hInet, url.c_str(), NULL, 0, flags, 0);
    if (!hUrl)
    {
        DWORD err = GetLastError();
        InternetCloseHandle(hInet);
        outError = L"Failed to connect to update download URL (error " + std::to_wstring(err) + L")";
        return false;
    }

    HANDLE hFile = CreateFileW(destPath.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE)
    {
        InternetCloseHandle(hUrl);
        InternetCloseHandle(hInet);
        outError = L"Failed to create local staging file for update payload";
        return false;
    }

    char buffer[8192];
    DWORD bytesRead = 0;
    DWORD bytesWritten = 0;
    bool success = true;

    while (InternetReadFile(hUrl, buffer, sizeof(buffer), &bytesRead) && bytesRead > 0)
    {
        if (!WriteFile(hFile, buffer, bytesRead, &bytesWritten, NULL) || bytesWritten != bytesRead)
        {
            outError = L"Disk write error while saving update package";
            success = false;
            break;
        }
    }

    CloseHandle(hFile);
    InternetCloseHandle(hUrl);
    InternetCloseHandle(hInet);

    return success;
}

static bool ParseOtaManifestJson(const std::string& jsonStr, OtaManifest& outManifest, std::wstring& outError)
{
    auto findKeyInt = [&](const std::string& key, int& val) -> bool {
        std::size_t pos = jsonStr.find("\"" + key + "\"");
        if (pos == std::string::npos) return false;
        pos = jsonStr.find(':', pos);
        if (pos == std::string::npos) return false;
        pos++;
        while (pos < jsonStr.size() && (jsonStr[pos] == ' ' || jsonStr[pos] == '\t' || jsonStr[pos] == '\n' || jsonStr[pos] == '\r')) pos++;
        val = std::atoi(jsonStr.c_str() + pos);
        return true;
    };

    auto findKeyString = [&](const std::string& key, std::string& val) -> bool {
        std::size_t pos = jsonStr.find("\"" + key + "\"");
        if (pos == std::string::npos) return false;
        pos = jsonStr.find(':', pos);
        if (pos == std::string::npos) return false;
        pos = jsonStr.find('"', pos);
        if (pos == std::string::npos) return false;
        std::size_t endPos = jsonStr.find('"', pos + 1);
        if (endPos == std::string::npos) return false;
        val = jsonStr.substr(pos + 1, endPos - pos - 1);
        return true;
    };

    int manifestVer = 0, buildNum = 0, minVer = 0;
    if (!findKeyInt("manifest_version", manifestVer) ||
        !findKeyInt("build_number", buildNum) ||
        !findKeyInt("min_update_version", minVer))
    {
        outError = L"Manifest missing required numeric schema fields";
        return false;
    }

    std::string osVerStr;
    if (!findKeyString("os_version", osVerStr))
    {
        outError = L"Manifest missing required os_version field";
        return false;
    }

    outManifest.ManifestVersion = manifestVer;
    outManifest.BuildNumber = static_cast<DWORD>(buildNum);
    outManifest.MinUpdateVersion = static_cast<DWORD>(minVer);
    outManifest.OsVersion = std::wstring(osVerStr.begin(), osVerStr.end());

    std::size_t cabsPos = jsonStr.find("\"cabs\"");
    if (cabsPos == std::string::npos)
    {
        outError = L"Manifest missing required cabs field";
        return false;
    }

    std::size_t cabBlockStart = jsonStr.find('{', cabsPos);
    if (cabBlockStart != std::string::npos)
    {
        std::size_t cabBlockEnd = jsonStr.find('}', cabBlockStart);
        if (cabBlockEnd != std::string::npos)
        {
            std::string cabSub = jsonStr.substr(cabBlockStart, cabBlockEnd - cabBlockStart + 1);

            OtaCabInfo cabInfo;
            std::string cabName, cabSha256;
            int cabSize = 0;

            std::size_t nPos = cabSub.find("\"name\"");
            if (nPos != std::string::npos)
            {
                std::size_t q1 = cabSub.find('"', cabSub.find(':', nPos));
                std::size_t q2 = (q1 != std::string::npos) ? cabSub.find('"', q1 + 1) : std::string::npos;
                if (q2 != std::string::npos) cabName = cabSub.substr(q1 + 1, q2 - q1 - 1);
            }

            std::size_t sPos = cabSub.find("\"sha256\"");
            if (sPos != std::string::npos)
            {
                std::size_t q1 = cabSub.find('"', cabSub.find(':', sPos));
                std::size_t q2 = (q1 != std::string::npos) ? cabSub.find('"', q1 + 1) : std::string::npos;
                if (q2 != std::string::npos) cabSha256 = cabSub.substr(q1 + 1, q2 - q1 - 1);
            }

            std::size_t zPos = cabSub.find("\"size\"");
            if (zPos != std::string::npos)
            {
                std::size_t cPos = cabSub.find(':', zPos);
                if (cPos != std::string::npos) cabSize = std::atoi(cabSub.c_str() + cPos + 1);
            }

            if (!cabName.empty() && !cabSha256.empty() && cabSize > 0)
            {
                cabInfo.Name = std::wstring(cabName.begin(), cabName.end());
                cabInfo.Sha256 = cabSha256;
                cabInfo.Size = static_cast<std::size_t>(cabSize);
                outManifest.Cabs.push_back(cabInfo);
            }
        }
    }

    if (outManifest.Cabs.empty())
    {
        outError = L"Manifest contains no valid cab payloads";
        return false;
    }

    return true;
}

static bool ComputeFileSha256(const std::wstring& filePath, std::string& outSha256Hex, std::size_t& outFileSize)
{
    outFileSize = 0;
    outSha256Hex.clear();

    HANDLE hFile = CreateFileW(filePath.c_str(), GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE)
        return false;

    LARGE_INTEGER fileSize;
    if (GetFileSizeEx(hFile, &fileSize))
    {
        outFileSize = static_cast<std::size_t>(fileSize.QuadPart);
    }

    HCRYPTPROV hProv = 0;
    HCRYPTHASH hHash = 0;

    if (!CryptAcquireContextW(&hProv, NULL, NULL, PROV_RSA_AES, CRYPT_VERIFYCONTEXT))
    {
        CloseHandle(hFile);
        return false;
    }

    if (!CryptCreateHash(hProv, CALG_SHA_256, 0, 0, &hHash))
    {
        CryptReleaseContext(hProv, 0);
        CloseHandle(hFile);
        return false;
    }

    BYTE buffer[8192];
    DWORD bytesRead = 0;
    while (ReadFile(hFile, buffer, sizeof(buffer), &bytesRead, NULL) && bytesRead > 0)
    {
        CryptHashData(hHash, buffer, bytesRead, 0);
    }

    CloseHandle(hFile);

    BYTE hashVal[32];
    DWORD hashLen = sizeof(hashVal);
    bool result = false;

    if (CryptGetHashParam(hHash, HP_HASHVAL, hashVal, &hashLen, 0))
    {
        std::ostringstream ss;
        for (DWORD i = 0; i < hashLen; i++)
        {
            ss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(hashVal[i]);
        }
        outSha256Hex = ss.str();
        result = true;
    }

    CryptDestroyHash(hHash);
    CryptReleaseContext(hProv, 0);

    return result;
}

static UINT WINAPI OtaCabinetCallback(PVOID Context, UINT Notification, UINT_PTR Param1, UINT_PTR Param2)
{
    if (Notification == SPFILENOTIFY_FILEINCABINET)
    {
        FILE_IN_CABINET_INFO_W* pInfo = (FILE_IN_CABINET_INFO_W*)Param1;
        LPCWSTR targetDir = (LPCWSTR)Context;

        StringCchCopyW(pInfo->FullTargetName, MAX_PATH, targetDir);
        StringCchCatW(pInfo->FullTargetName, MAX_PATH, pInfo->NameInCabinet);

        WCHAR dirPath[MAX_PATH];
        StringCchCopyW(dirPath, MAX_PATH, pInfo->FullTargetName);
        PathRemoveFileSpecW(dirPath);
        if (!PathIsDirectoryW(dirPath))
        {
            SHCreateDirectoryExW(NULL, dirPath, NULL);
        }

        return FILEOP_DOIT;
    }
    return NO_ERROR;
}

static bool ExtractCabToStaging(const std::wstring& cabPath, const std::wstring& targetDir, std::wstring& outError)
{
    WCHAR targetWithSlash[MAX_PATH];
    StringCchCopyW(targetWithSlash, MAX_PATH, targetDir.c_str());
    PathAddBackslashW(targetWithSlash);

    if (!PathIsDirectoryW(targetWithSlash))
    {
        SHCreateDirectoryExW(NULL, targetWithSlash, NULL);
    }

    if (!SetupIterateCabinetW(cabPath.c_str(), 0, OtaCabinetCallback, targetWithSlash))
    {
        DWORD err = GetLastError();
        outError = L"Failed to extract update CAB archive (error " + std::to_wstring(err) + L")";
        return false;
    }
    return true;
}

static bool WriteStagingJournalAndMarker(DWORD buildNumber, std::wstring& outError)
{
    HANDLE hJournal = CreateFileW(KIBAOS_UPDATER_JOURNAL_PATH, GENERIC_WRITE, 0, NULL,
                                 CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hJournal == INVALID_HANDLE_VALUE)
    {
        outError = L"Failed to write staging transaction journal";
        return false;
    }

    std::string journalData = "KIBAOS_OTA_JOURNAL_BUILD_" + std::to_string(buildNumber) + "\nSTATUS=STAGED\n";
    DWORD written = 0;
    WriteFile(hJournal, journalData.c_str(), static_cast<DWORD>(journalData.size()), &written, NULL);
    CloseHandle(hJournal);

    HANDLE hMarker = CreateFileW(KIBAOS_BOOT_SUCCESS_MARKER_PATH, GENERIC_WRITE, 0, NULL,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hMarker == INVALID_HANDLE_VALUE)
    {
        outError = L"Failed to write boot success marker";
        return false;
    }

    std::string markerData = "BOOT_SUCCESS_MARKER_VER_" + std::to_string(buildNumber) + "\n";
    written = 0;
    WriteFile(hMarker, markerData.c_str(), static_cast<DWORD>(markerData.size()), &written, NULL);
    CloseHandle(hMarker);

    return true;
}

void BuildUpdates(PageBuilder &page)
{
    page.Title = L"Updates";

    // Read stored update settings
    DWORD channel = ReadDword(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"Channel", 0);
    DWORD paused = ReadDword(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"Paused", 0);
    std::wstring lastCheck = ReadString(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"LastCheck");

    if (lastCheck.empty())
        lastCheck = L"Never";

    DWORD currentBuild = GetCurrentBuildNumber();

    // Channel name lookup
    const wchar_t* channelNames[] = { L"Stable", L"Beta", L"Developer" };
    std::wstring currentChannel = channelNames[min((size_t)channel, (size_t)2)];

    // Hero Section based on OTA State
    std::wstring heroTitle = L"KibaOS is up to date";
    std::wstring heroSub = L"Build " + std::to_wstring(currentBuild) + L" (" + GetSystemArchitecture() + L") - Channel: " + currentChannel + L" - Last checked: " + lastCheck;
    LPCWSTR heroIcon = L"checkmark_24_regular";

    if (s_OtaState == OtaState::Checking)
    {
        heroTitle = L"Checking for updates...";
        heroSub = L"Connecting to KibaOS OTA release manifest servers...";
        heroIcon = L"arrow_sync_20_regular";
    }
    else if (s_OtaState == OtaState::Available)
    {
        heroTitle = L"Update Available: KibaOS Build " + std::to_wstring(s_AvailableBuildNumber);
        heroSub = L"Channel: " + currentChannel + L" - Payload: " + s_AvailableCabName + L" (" + std::to_wstring(s_AvailableCabSize / 1024 / 1024) + L" MB)";
        heroIcon = L"arrow_download_20_regular";
    }
    else if (s_OtaState == OtaState::Downloading)
    {
        heroTitle = L"Downloading update package...";
        heroSub = L"Downloading " + s_AvailableCabName + L" over HTTPS...";
        heroIcon = L"arrow_download_20_regular";
    }
    else if (s_OtaState == OtaState::Staged)
    {
        heroTitle = L"Update Ready to Install";
        heroSub = L"System files staged in journal for build " + std::to_wstring(s_AvailableBuildNumber) + L". Restart required to finish update.";
        heroIcon = L"checkmark_24_regular";
    }
    else if (s_OtaState == OtaState::RollbackDone)
    {
        heroTitle = L"System Rollback Completed";
        heroSub = L"Restored previous stable configuration from recovery journal.";
        heroIcon = L"arrow_undo_20_regular";
    }
    else if (s_OtaState == OtaState::Error)
    {
        heroTitle = L"Update Check Failed";
        heroSub = s_OtaMessage.empty() ? L"An error occurred while connecting to the OTA server." : s_OtaMessage;
        heroIcon = L"dismiss_24_regular";
    }

    page.Hero(heroTitle.c_str(), heroSub.c_str(), heroIcon);

    // Primary Actions Group
    page.Group(L"Update Options");

    if (s_OtaState == OtaState::Available)
    {
        page.Button(L"Download and install update", L"Stage system update and prepare boot rollback journal", L"arrow_download_20_regular", L"Install now", [host = page.Host](int action) {
            s_OtaState = OtaState::Downloading;
            if (!host)
                return;

            host->Refresh();

            host->RunJob([]() {
                std::wstring manifestUrl = GetManifestUrl();
                std::size_t slashPos = manifestUrl.find_last_of(L"/\\");
                std::wstring cabUrl;
                if (slashPos != std::wstring::npos)
                    cabUrl = manifestUrl.substr(0, slashPos + 1) + s_AvailableCabName;
                else
                    cabUrl = L"https://downloads.sourceforge.net/project/kibaos/" + GetSystemArchitecture() + L"-nt/ota/" + s_AvailableCabName;

                WCHAR tempPath[MAX_PATH];
                GetTempPathW(MAX_PATH, tempPath);
                WCHAR localCabPath[MAX_PATH];
                PathCombineW(localCabPath, tempPath, s_AvailableCabName.c_str());

                std::wstring errStr;
                if (!DownloadHttpsFile(cabUrl, localCabPath, errStr))
                {
                    s_OtaState = OtaState::Error;
                    s_OtaMessage = errStr;
                    return;
                }

                std::string computedHash;
                std::size_t computedSize = 0;
                if (!ComputeFileSha256(localCabPath, computedHash, computedSize))
                {
                    s_OtaState = OtaState::Error;
                    s_OtaMessage = L"Failed to compute SHA-256 checksum of downloaded payload";
                    DeleteFileW(localCabPath);
                    return;
                }

                if (computedSize != s_AvailableCabSize)
                {
                    s_OtaState = OtaState::Error;
                    s_OtaMessage = L"CAB size mismatch: expected " + std::to_wstring(s_AvailableCabSize) + L", got " + std::to_wstring(computedSize);
                    DeleteFileW(localCabPath);
                    return;
                }

                if (_stricmp(computedHash.c_str(), s_AvailableCabSha256.c_str()) != 0)
                {
                    s_OtaState = OtaState::Error;
                    s_OtaMessage = L"CAB SHA-256 hash mismatch validation failure";
                    DeleteFileW(localCabPath);
                    return;
                }

                WCHAR systemRoot[MAX_PATH];
                GetWindowsDirectoryW(systemRoot, MAX_PATH);
                WCHAR stagingDir[MAX_PATH];
                PathCombineW(stagingDir, systemRoot, L"ota_staged");

                if (!ExtractCabToStaging(localCabPath, stagingDir, errStr))
                {
                    s_OtaState = OtaState::Error;
                    s_OtaMessage = errStr;
                    DeleteFileW(localCabPath);
                    return;
                }

                DeleteFileW(localCabPath);

                if (!WriteStagingJournalAndMarker(s_AvailableBuildNumber, errStr))
                {
                    s_OtaState = OtaState::Error;
                    s_OtaMessage = errStr;
                    return;
                }

                s_OtaState = OtaState::Staged;
            }, [host]() {
                if (host)
                {
                    if (s_OtaState == OtaState::Staged)
                    {
                        PromptRestart(host->Window(), L"KibaOS update staged successfully.");
                    }
                    host->Refresh();
                }
            });
        });
    }

    page.Button(L"Check for updates", L"Check HTTPS release manifest for latest available updates", L"arrow_sync_20_regular", L"Check now", [host = page.Host](int action) {
        s_OtaState = OtaState::Checking;

        // Record check timestamp
        SYSTEMTIME st;
        GetLocalTime(&st);
        wchar_t timeStr[64];
        StringCchPrintfW(timeStr, 64, L"%04d-%02d-%02d %02d:%02d", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute);
        WriteString(HKEY_CURRENT_USER, UPDATE_REG_KEY, L"LastCheck", timeStr);

        if (!host)
            return;

        host->Refresh();

        host->RunJob([]() {
            std::wstring manifestUrl = GetManifestUrl();
            std::string jsonStr;
            std::wstring errStr;

            if (!FetchHttpsData(manifestUrl, jsonStr, errStr))
            {
                s_OtaState = OtaState::Error;
                s_OtaMessage = errStr;
                return;
            }

            OtaManifest manifest;
            if (!ParseOtaManifestJson(jsonStr, manifest, errStr))
            {
                s_OtaState = OtaState::Error;
                s_OtaMessage = errStr;
                return;
            }

            DWORD currentBuild = GetCurrentBuildNumber();
            if (manifest.MinUpdateVersion > currentBuild)
            {
                s_OtaState = OtaState::Error;
                s_OtaMessage = L"Incompatible update: minimum build required is " + std::to_wstring(manifest.MinUpdateVersion);
                return;
            }

            if (manifest.BuildNumber <= currentBuild)
            {
                s_OtaState = OtaState::Idle;
                s_OtaMessage = L"System is up to date";
                return;
            }

            s_AvailableBuildNumber = manifest.BuildNumber;
            s_AvailableCabName = manifest.Cabs[0].Name;
            s_AvailableCabSha256 = manifest.Cabs[0].Sha256;
            s_AvailableCabSize = manifest.Cabs[0].Size;
            s_OtaState = OtaState::Available;
        }, [host]() {
            if (host)
                host->Refresh();
        });
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
