/*
 * PROJECT:     KibaOS Intent-Based Window Management Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Intent-Based Window Management Engine Implementation
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#include "precomp.h"
#include "intent_wm.h"
#include <reactos/universal_settings.h>

static KIBA_INTENT_MODE g_CurrentIntentMode = INTENT_DEV_TRIPANE;
static BOOL g_IntentInitialized = FALSE;

static const KIBA_INTENT_INFO g_IntentCatalog[] = {
    { INTENT_DEV_TRIPANE, L"Developer Tri-Pane", L"Primary code editor left (60%), terminal top-right, build logs bottom-right", NULL },
    { INTENT_DUAL_SIDEBYSIDE, L"Dual Side-By-Side", L"Equal 50/50 vertical split for side-by-side comparison and multitasking", NULL },
    { INTENT_MEDIA_CINEMA, L"Media Cinema Focus", L"Centered floating active canvas with background apps dimmed and minimized", NULL },
    { INTENT_GAMING_FOCUS, L"Gaming High-Perf Focus", L"Full screen active application, foreground process CPU/GPU priority boosted", NULL },
    { INTENT_RESEARCH_QUAD, L"Research Quad-Grid", L"4-way equal quadrant tiling for multi-document research and browsing", NULL },
    { INTENT_CREATIVE_CANVAS, L"Creative Canvas Studio", L"Center workspace window surrounded by utility tool panels and palettes", NULL }
};

VOID IntentWM_Init(VOID)
{
    if (g_IntentInitialized) return;

    DWORD dwMode = 0;
    if (KibaSettingsGetDword(L"IntentWM", L"ActiveMode", &dwMode, (DWORD)INTENT_DEV_TRIPANE))
    {
        if (dwMode >= 1 && dwMode <= 6)
            g_CurrentIntentMode = (KIBA_INTENT_MODE)dwMode;
    }

    g_IntentInitialized = TRUE;
}

KIBA_INTENT_MODE IntentWM_GetActiveMode(VOID)
{
    IntentWM_Init();
    return g_CurrentIntentMode;
}

int IntentWM_GetTotalModes(VOID)
{
    return _countof(g_IntentCatalog);
}

BOOL IntentWM_GetInfo(KIBA_INTENT_MODE Mode, KIBA_INTENT_INFO *pInfo)
{
    IntentWM_Init();
    if (!pInfo) return FALSE;

    for (size_t i = 0; i < _countof(g_IntentCatalog); i++)
    {
        if (g_IntentCatalog[i].Mode == Mode)
        {
            *pInfo = g_IntentCatalog[i];
            return TRUE;
        }
    }
    return FALSE;
}

BOOL IntentWM_SetActiveMode(KIBA_INTENT_MODE Mode)
{
    IntentWM_Init();
    if (Mode < 1 || Mode > 6) return FALSE;

    KIBA_INTENT_MODE oldMode = g_CurrentIntentMode;
    g_CurrentIntentMode = Mode;

    KibaSettingsSetDword(L"IntentWM", L"ActiveMode", (DWORD)Mode);

    KIBA_INTENT_INFO oldInfo, newInfo;
    IntentWM_GetInfo(oldMode, &oldInfo);
    IntentWM_GetInfo(Mode, &newInfo);

    KibaSettingsRecordEvent(KIBA_HISTORY_CAT_CONFIG, L"Intent Window Manager Engine", L"Kiba Shell", L"Intent Mode Changed", oldInfo.Name, newInfo.Name);

    IntentWM_ApplyCurrentLayout();
    return TRUE;
}

struct ENUM_WINDOWS_DATA
{
    HWND hWnds[16];
    int Count;
};

static BOOL CALLBACK EnumTopLevelWindowsProc(HWND hWnd, LPARAM lParam)
{
    ENUM_WINDOWS_DATA *pData = (ENUM_WINDOWS_DATA *)lParam;
    if (pData->Count >= 16) return FALSE;

    if (IsWindowVisible(hWnd) && !GetWindow(hWnd, GW_OWNER) && (GetWindowLongW(hWnd, GWL_EXSTYLE) & WS_EX_APPWINDOW || !(GetWindowLongW(hWnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)))
    {
        WCHAR szClass[128];
        GetClassNameW(hWnd, szClass, _countof(szClass));
        if (_wcsicmp(szClass, L"Shell_TrayWnd") != 0 && _wcsicmp(szClass, L"Progman") != 0 && _wcsicmp(szClass, L"Button") != 0)
        {
            pData->hWnds[pData->Count++] = hWnd;
        }
    }
    return TRUE;
}

VOID IntentWM_ApplyCurrentLayout(VOID)
{
    IntentWM_Init();

    RECT rcWork;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &rcWork, 0);

    LONG workW = rcWork.right - rcWork.left;
    LONG workH = rcWork.bottom - rcWork.top;

    ENUM_WINDOWS_DATA data = {0};
    EnumWindows(EnumTopLevelWindowsProc, (LPARAM)&data);

    if (data.Count == 0) return;

    switch (g_CurrentIntentMode)
    {
        case INTENT_DEV_TRIPANE:
        {
            if (data.Count >= 1)
            {
                LONG mainW = (LONG)(workW * 0.60f);
                SetWindowPos(data.hWnds[0], NULL, rcWork.left, rcWork.top, mainW, workH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            if (data.Count >= 2)
            {
                LONG subX = rcWork.left + (LONG)(workW * 0.60f);
                LONG subW = workW - (LONG)(workW * 0.60f);
                LONG subH = workH / 2;
                SetWindowPos(data.hWnds[1], NULL, subX, rcWork.top, subW, subH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            if (data.Count >= 3)
            {
                LONG subX = rcWork.left + (LONG)(workW * 0.60f);
                LONG subW = workW - (LONG)(workW * 0.60f);
                LONG subH = workH / 2;
                SetWindowPos(data.hWnds[2], NULL, subX, rcWork.top + subH, subW, workH - subH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            break;
        }

        case INTENT_DUAL_SIDEBYSIDE:
        {
            LONG halfW = workW / 2;
            for (int i = 0; i < min(data.Count, 2); i++)
            {
                SetWindowPos(data.hWnds[i], NULL, rcWork.left + i * halfW, rcWork.top, halfW, workH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            break;
        }

        case INTENT_MEDIA_CINEMA:
        {
            if (data.Count >= 1)
            {
                LONG padX = (LONG)(workW * 0.10f);
                LONG padY = (LONG)(workH * 0.10f);
                SetWindowPos(data.hWnds[0], NULL, rcWork.left + padX, rcWork.top + padY, workW - padX * 2, workH - padY * 2, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            for (int i = 1; i < data.Count; i++)
            {
                ShowWindow(data.hWnds[i], SW_MINIMIZE);
            }
            break;
        }

        case INTENT_GAMING_FOCUS:
        {
            if (data.Count >= 1)
            {
                SetWindowPos(data.hWnds[0], NULL, rcWork.left, rcWork.top, workW, workH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            break;
        }

        case INTENT_RESEARCH_QUAD:
        {
            LONG halfW = workW / 2;
            LONG halfH = workH / 2;
            for (int i = 0; i < min(data.Count, 4); i++)
            {
                LONG x = rcWork.left + (i % 2) * halfW;
                LONG y = rcWork.top + (i / 2) * halfH;
                SetWindowPos(data.hWnds[i], NULL, x, y, halfW, halfH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            break;
        }

        case INTENT_CREATIVE_CANVAS:
        {
            if (data.Count >= 1)
            {
                LONG sideW = (LONG)(workW * 0.18f);
                LONG centerW = workW - sideW * 2;
                SetWindowPos(data.hWnds[0], NULL, rcWork.left + sideW, rcWork.top, centerW, workH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            if (data.Count >= 2)
            {
                LONG sideW = (LONG)(workW * 0.18f);
                SetWindowPos(data.hWnds[1], NULL, rcWork.left, rcWork.top, sideW, workH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            if (data.Count >= 3)
            {
                LONG sideW = (LONG)(workW * 0.18f);
                SetWindowPos(data.hWnds[2], NULL, rcWork.right - sideW, rcWork.top, sideW, workH, SWP_NOZORDER | SWP_NOACTIVATE);
            }
            break;
        }
    }
}

KIBA_INTENT_MODE IntentWM_DetectIntentFromWindows(VOID)
{
    ENUM_WINDOWS_DATA data = {0};
    EnumWindows(EnumTopLevelWindowsProc, (LPARAM)&data);

    if (data.Count == 0) return INTENT_DEV_TRIPANE;

    for (int i = 0; i < data.Count; i++)
    {
        WCHAR szTitle[256];
        GetWindowTextW(data.hWnds[i], szTitle, _countof(szTitle));

        if (wcsstr(szTitle, L"Visual Studio") || wcsstr(szTitle, L"Code") || wcsstr(szTitle, L"Git") || wcsstr(szTitle, L"Terminal") || wcsstr(szTitle, L"cmd"))
            return INTENT_DEV_TRIPANE;
        if (wcsstr(szTitle, L"Player") || wcsstr(szTitle, L"Video") || wcsstr(szTitle, L"Cinema") || wcsstr(szTitle, L"Movie"))
            return INTENT_MEDIA_CINEMA;
        if (wcsstr(szTitle, L"Game") || wcsstr(szTitle, L"Steam") || wcsstr(szTitle, L"3D"))
            return INTENT_GAMING_FOCUS;
    }

    return INTENT_DUAL_SIDEBYSIDE;
}
