/*
 * COPYRIGHT:       See COPYING in the top level directory
 * PROJECT:         KibaOS Version Program
 * FILE:            base/applications/winver/winver.c
 */

#include "winver_p.h"

HINSTANCE Winver_hInstance;

INT_PTR CALLBACK WinverDlgProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    switch (uMsg)
    {
        case WM_INITDIALOG:
        {
            PWINVER_OS_INFO pOSInfo = (PWINVER_OS_INFO)lParam;
            if (pOSInfo)
            {
                if (pOSInfo->szName[0])
                {
                    wchar_t title[128];
                    StringCchPrintfW(title, _countof(title), L"%s Operating System", pOSInfo->szName);
                    SetDlgItemTextW(hwnd, IDC_WINVER_TITLE, title);
                }
                if (pOSInfo->szCompatInfo[0])
                {
                    SetDlgItemTextW(hwnd, IDC_WINVER_BUILD, pOSInfo->szCompatInfo);
                }
            }

            // Display installed system RAM
            MEMORYSTATUSEX statex;
            statex.dwLength = sizeof(statex);
            if (GlobalMemoryStatusEx(&statex))
            {
                wchar_t memStr[128];
                DWORD mb = (DWORD)(statex.ullTotalPhys / (1024 * 1024));
                StringCchPrintfW(memStr, _countof(memStr), L"Installed Physical Memory (RAM): %u MB", mb);
                SetDlgItemTextW(hwnd, IDC_WINVER_MEM, memStr);
            }

            // Registered owner / username
            wchar_t username[UNLEN + 1];
            DWORD size = UNLEN + 1;
            if (GetUserNameW(username, &size))
            {
                wchar_t userStr[128];
                StringCchPrintfW(userStr, _countof(userStr), L"User: %s", username);
                SetDlgItemTextW(hwnd, IDC_WINVER_USER, userStr);
            }
            return TRUE;
        }

        case WM_COMMAND:
            if (LOWORD(wParam) == IDOK || LOWORD(wParam) == IDCANCEL)
            {
                EndDialog(hwnd, LOWORD(wParam));
                return TRUE;
            }
            break;
    }
    return FALSE;
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPWSTR lpCmdLine, int nCmdShow)
{
    INITCOMMONCONTROLSEX iccx;
    WINVER_OS_INFO OSInfo;

    UNREFERENCED_PARAMETER(hPrevInstance);
    UNREFERENCED_PARAMETER(lpCmdLine);
    UNREFERENCED_PARAMETER(nCmdShow);

    Winver_hInstance = hInstance;

    /* Initialize common controls */
    iccx.dwSize = sizeof(iccx);
    iccx.dwICC = ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES;
    InitCommonControlsEx(&iccx);

    if (!Winver_GetOSInfo(&OSInfo))
    {
        /* OS info is not available, display default contents */
        StringCchCopyW(OSInfo.szName, _countof(OSInfo.szName), L"KibaOS");
        StringCchCopyW(OSInfo.szCompatInfo, _countof(OSInfo.szCompatInfo), L"Version 11.0 (Build 10001 x64)");
    }

    if (lstrcmpiW(OSInfo.szName, L"ReactOS") == 0 || lstrcmpiW(OSInfo.szName, L"LiberNT") == 0)
        StringCchCopyW(OSInfo.szName, _countof(OSInfo.szName), L"KibaOS");

    DialogBoxParamW(hInstance, MAKEINTRESOURCEW(IDD_WINVER), NULL, WinverDlgProc, (LPARAM)&OSInfo);
    return 0;
}
