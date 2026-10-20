/*
 * PROJECT:     ReactOS System Control Panel
 * LICENSE:     GPL-2.0+ (https://spdx.org/licenses/GPL-2.0+)
 * PURPOSE:     ReactOS System Control Panel
 * COPYRIGHT:   Copyright 2004 Gero Kuehn (reactos.filter@gkware.com)
 *              Copyright 2008 Colin Finck (colin@reactos.org)
 *              Copyright 2014 Hermès Bélusca-Maïto (hermes.belusca-maito@reactos.org)
 */

#include <stdio.h>

#define WIN32_NO_STATUS
#define COBJMACROS


#include <windef.h>
#include <winbase.h>
#include <winuser.h>
#include <winreg.h>
#include <shellapi.h>
#include <strsafe.h>
#include <objbase.h>
#include <shobjidl.h>
#include <shlguid.h>
#include <shlwapi.h>

#include "resource.h"

#define MAX_VALUE_NAME 16383

/*
 * Macro for calling "rundll32.exe"
 * According to MSDN, ShellExecute returns a value greater than 32
 * if the operation was successful.
 */
#define RUNDLL(param)   \
    ((INT_PTR)ShellExecuteW(NULL, L"open", L"rundll32.exe", (param), NULL, SW_SHOWDEFAULT) > 32)
#define ShellExec(file, params) \
    ((INT_PTR)ShellExecuteW(NULL, NULL, (file), (params), NULL, SW_SHOWDEFAULT) > 32)

VOID
WINAPI
Control_RunDLLW(HWND hWnd, HINSTANCE hInst, LPCWSTR cmd, DWORD nCmdShow);

static BOOL
IsSwitch(LPCWSTR Switch, LPCWSTR Arg)
{
    if (*Arg == '/' || *Arg == '-')
    {
        return !lstrcmpiW(Arg+1, Switch);
    }
    return FALSE;
}

static HRESULT
OpenControlPanelItem(LPCWSTR Name, LPCWSTR Page)
{
    HRESULT hr = CoInitialize(0);
    if (SUCCEEDED(hr))
    {
        IOpenControlPanel *pOCP;
        hr = CoCreateInstance(&CLSID_OpenControlPanel, NULL, CLSCTX_INPROC_SERVER,
                              &IID_IOpenControlPanel, (void**)&pOCP);
        if (SUCCEEDED(hr))
        {
            hr = IOpenControlPanel_Open(pOCP, Name, Page, NULL);
            IOpenControlPanel_Release(pOCP);
        }
        CoUninitialize();
    }
    return hr;
}

static INT
RunControlPanel(LPCWSTR lpCmd)
{
    WCHAR szParameters[MAX_PATH];
    StringCchCopyW(szParameters, ARRAYSIZE(szParameters), L"shell32.dll,Control_RunDLL ");
    if (FAILED(StringCchCatW(szParameters, ARRAYSIZE(szParameters), lpCmd)))
        return 0;

    return RUNDLL(szParameters);
}

INT
WINAPI
wWinMain(HINSTANCE hInstance,
         HINSTANCE hPrevInstance,
         LPWSTR lpCmdLine,
         INT nCmdShow)
{
    HKEY hKey;
    LPWSTR *argv;
    int argc;

    /* Redirect control panel calls to systemsettings.exe (One Settings Surface) */
    if (*lpCmdLine == 0 || !_wcsicmp(lpCmdLine, L"panel"))
        return ShellExec(L"systemsettings.exe", NULL);
    if (StrStrIW(lpCmdLine, L"timedate.cpl") || !_wcsicmp(lpCmdLine, L"date/time"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:dateandtime");
    if (StrStrIW(lpCmdLine, L"desk.cpl") || !_wcsicmp(lpCmdLine, L"desktop") || !_wcsicmp(lpCmdLine, L"color"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:personalization");
    if (StrStrIW(lpCmdLine, L"main.cpl") || !_wcsicmp(lpCmdLine, L"mouse") || !_wcsicmp(lpCmdLine, L"keyboard"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:devices");
    if (StrStrIW(lpCmdLine, L"mmsys.cpl"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:sound");
    if (StrStrIW(lpCmdLine, L"appwiz.cpl"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:appsfeatures");
    if (StrStrIW(lpCmdLine, L"usrmgr.cpl") || StrStrIW(lpCmdLine, L"nusrmgr.cpl") || !_wcsicmp(lpCmdLine, L"userpasswords"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:yourinfo");
    if (StrStrIW(lpCmdLine, L"sysdm.cpl"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:about");
    if (StrStrIW(lpCmdLine, L"powercfg.cpl"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:powersleep");
    if (StrStrIW(lpCmdLine, L"intl.cpl") || !_wcsicmp(lpCmdLine, L"international"))
        return ShellExec(L"systemsettings.exe", L"ms-settings:regionlanguage");

    /* Show default unified settings surface */
    return ShellExec(L"systemsettings.exe", NULL);

    /* https://learn.microsoft.com/en-us/windows/win32/shell/executing-control-panel-items#windows-vista-canonical-names */
    argv = CommandLineToArgvW(lpCmdLine, &argc);
    if (argv)
    {
        UINT argi = 0;
        HRESULT hr = -1;
        if (argc >= 2 && IsSwitch(L"name", argv[argi + 0]))
        {
            LPCWSTR pszPage = NULL;
            if (argc >= 4 && IsSwitch(L"page", argv[argi + 2]))
            {
                pszPage = argv[argi + 3];
            }
            hr = OpenControlPanelItem(argv[argi + 1], pszPage);
        }
        LocalFree(argv);
        if (hr != -1)
        {
            return SUCCEEDED(hr);
        }
    }

    /* It is none of them, so look for a handler in the registry */
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Control Panel\\Cpls",
                      0,
                      KEY_QUERY_VALUE,
                      &hKey) == ERROR_SUCCESS)
    {
        DWORD dwIndex;

        for (dwIndex = 0; ; ++dwIndex)
        {
            DWORD dwDataSize;
            DWORD dwValueSize = MAX_VALUE_NAME;
            WCHAR szValueName[MAX_VALUE_NAME];

            /* Get the value name and data size */
            if (RegEnumValueW(hKey,
                              dwIndex,
                              szValueName,
                              &dwValueSize,
                              0,
                              NULL,
                              NULL,
                              &dwDataSize) != ERROR_SUCCESS)
            {
                break;
            }

            /* Check if the parameter is the value name */
            if (!_wcsicmp(lpCmdLine, szValueName))
            {
                /*
                 * Allocate memory for the data plus two more characters,
                 * so we can quote the file name if required.
                 */
                LPWSTR pszData;
                pszData = HeapAlloc(GetProcessHeap(),
                                    0,
                                    dwDataSize + 2 * sizeof(WCHAR));
                ++pszData;

                /*
                 * This value is the one we are looking for, so get the data.
                 * It is the path to a .cpl file.
                 */
                if (RegQueryValueExW(hKey,
                                     szValueName,
                                     0,
                                     NULL,
                                     (LPBYTE)pszData,
                                     &dwDataSize) == ERROR_SUCCESS)
                {
                    INT nReturnValue;

                    /* Quote the file name if required */
                    if (*pszData != L'\"')
                    {
                        *(--pszData) = L'\"';
                        pszData[dwDataSize / sizeof(WCHAR)] = L'\"';
                        pszData[(dwDataSize / sizeof(WCHAR)) + 1] = 0;
                    }

                    nReturnValue = RunControlPanel(pszData);
                    HeapFree(GetProcessHeap(), 0, pszData);
                    RegCloseKey(hKey);

                    return nReturnValue;
                }

                HeapFree(GetProcessHeap(), 0, pszData);
            }
        }

        RegCloseKey(hKey);
    }

    /*
     * It's none of the known parameters, so interpret the parameter
     * as the file name of a control panel applet.
     */
    return RunControlPanel(lpCmdLine);
}
