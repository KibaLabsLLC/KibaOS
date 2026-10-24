/*
 * PROJECT:     KibaOS Post-Install User Guide & OS Tour Application
 * LICENSE:     GPL-3.0-or-later
 * PURPOSE:     Interactive OS guide educating users on KibaOS features after installation
 * COPYRIGHT:   Copyright 2026 KibaOS Team
 */

#include <windows.h>
#include <commctrl.h>
#include <strsafe.h>
#include <shellapi.h>
#include <reactos/ux_tokens.h>
#include "resource.h"

#define WND_WIDTH  720
#define WND_HEIGHT 520

struct GUIDE_SLIDE
{
    LPCWSTR szTitle;
    LPCWSTR szSubtitle;
    LPCWSTR szContent;
    LPCWSTR szActionLabel;
    LPCWSTR szActionCmd;
};

static const GUIDE_SLIDE g_Slides[] =
{
    {
        L"Welcome to KibaOS",
        L"Next-Generation Operating System Experience",
        L"KibaOS is built on a modern NT 10.0 Kernel fork, delivering high performance, spatial workspace management, intent-based window automation, and intelligent desktop companion assistance.\n\n"
        L"This guide will introduce you to key features designed to boost your daily productivity.",
        L"Get Started",
        NULL
    },
    {
        L"1. Kiba Center (Win+K)",
        L"The Central Flyout replacing traditional Start Menu",
        L"Kiba Center completely replaces the legacy start menu with a unified, high-speed flyout.\n\n"
        L"• Access instantly with Win+K or by clicking the Start button\n"
        L"• Search applications, system services, and control commands\n"
        L"• Toggle system settings, dark mode, audio, and power actions\n"
        L"• Monitor real-time memory and system performance metrics",
        L"Launch Kiba Center",
        L"kibacenter"
    },
    {
        L"2. Intent-Based Window Management",
        L"Smart Window Layout Presets for Workflows",
        L"The Intent Window Manager automatically arranges open windows to match your task:\n\n"
        L"• Developer Tri-Pane: Code editor left (60%), terminal & build logs right\n"
        L"• Dual Side-by-Side: Equal 50/50 vertical split for side-by-side work\n"
        L"• Media Cinema Focus: Centered canvas with dimmed background\n"
        L"• Gaming Focus: Fullscreen priority boost for active gaming\n"
        L"• Research Quad & Creative Canvas: Multi-document quad tiling",
        L"Switch Intent Mode",
        L"intent"
    },
    {
        L"3. Spatial 3D Workspaces",
        L"Fluid Multi-Desktop Environment",
        L"Spatial 3D Workspaces enable effortless task grouping across virtual desktops.\n\n"
        L"• Switch workspaces seamlessly using spatial shortcuts\n"
        L"• Deep window elevation and dynamic drop shadows\n"
        L"• Time Machine Restorer to recover desktop work state after reboot",
        L"Open Spatial Workspaces",
        L"spatial"
    },
    {
        L"4. Kiba Desktop Companion",
        L"Your Intelligent Hardware & System Assistant",
        L"Kiba Companion sits cleanly on your desktop as an interactive partner.\n\n"
        L"• Re-enumerates and resolves misconfigured hardware automatically\n"
        L"• Reacts to OS state changes and system events in real time\n"
        L"• Non-intrusive smooth window rendering without overlay flickering",
        L"Open Companion Settings",
        L"companion"
    },
    {
        L"5. Universal Settings & Predictive UI",
        L"Unified System Control & Contextual Gravity",
        L"Configure your entire operating system through Universal Settings.\n\n"
        L"• Centralized design tokens and theme personalization\n"
        L"• Complete Installation & Config History Timeline auditing\n"
        L"• Predictive UI Engine with adaptive pointer hit areas and gesture grammar",
        L"Open System Settings",
        L"systemsettings.exe"
    }
};

static const INT g_SlideCount = sizeof(g_Slides) / sizeof(g_Slides[0]);
static INT g_CurrentSlide = 0;

static HFONT g_hFontTitle = NULL;
static HFONT g_hFontSubtitle = NULL;
static HFONT g_hFontBody = NULL;

static COLORREF MixColor(COLORREF c1, COLORREF c2, INT t)
{
    BYTE r = (BYTE)(GetRValue(c1) + MulDiv(GetRValue(c2) - GetRValue(c1), t, 255));
    BYTE g = (BYTE)(GetGValue(c1) + MulDiv(GetGValue(c2) - GetGValue(c1), t, 255));
    BYTE b = (BYTE)(GetBValue(c1) + MulDiv(GetBValue(c2) - GetBValue(c1), t, 255));
    return RGB(r, g, b);
}

static VOID ExecuteSlideAction(INT index, HWND hwnd)
{
    if (index < 0 || index >= g_SlideCount) return;
    LPCWSTR cmd = g_Slides[index].szActionCmd;
    if (!cmd) return;

    if (wcscmp(cmd, L"kibacenter") == 0)
    {
        HWND hwndTray = FindWindowW(L"Shell_TrayWnd", NULL);
        if (hwndTray) ::PostMessageW(hwndTray, WM_USER + 274, 0, 0); // TWM_SHOWKIBACENTER
    }
    else if (wcscmp(cmd, L"systemsettings.exe") == 0)
    {
        ShellExecuteW(hwnd, L"open", L"systemsettings.exe", NULL, NULL, SW_SHOWNORMAL);
    }
    else
    {
        ShellExecuteW(hwnd, L"open", cmd, NULL, NULL, SW_SHOWNORMAL);
    }
}

static VOID DrawSlide(HDC hdc, const RECT& rcClient)
{
    HDC hdcMem = CreateCompatibleDC(hdc);
    HBITMAP hbm = CreateCompatibleBitmap(hdc, rcClient.right, rcClient.bottom);
    HGDIOBJ hbmOld = SelectObject(hdcMem, hbm);

    // Background gradient
    HBRUSH hbrBg = CreateSolidBrush(UX_TOKEN_COLOR_BACKGROUND_LIGHT);
    FillRect(hdcMem, &rcClient, hbrBg);
    DeleteObject(hbrBg);

    // Header hero banner
    RECT rcHeader = { 0, 0, rcClient.right, 90 };
    HBRUSH hbrHeader = CreateSolidBrush(UX_TOKEN_COLOR_SURFACE_LIGHT);
    FillRect(hdcMem, &rcHeader, hbrHeader);
    DeleteObject(hbrHeader);

    HBRUSH hbrBorder = CreateSolidBrush(UX_TOKEN_COLOR_BORDER_LIGHT);
    RECT rcBorderLine = { 0, 89, rcClient.right, 90 };
    FillRect(hdcMem, &rcBorderLine, hbrBorder);
    DeleteObject(hbrBorder);

    SetBkMode(hdcMem, TRANSPARENT);

    // Header title
    HGDIOBJ hFontOld = SelectObject(hdcMem, g_hFontTitle);
    SetTextColor(hdcMem, UX_TOKEN_COLOR_TEXT_PRIMARY_LIGHT);
    RECT rcTitle = { 30, 18, rcClient.right - 30, 48 };
    DrawTextW(hdcMem, g_Slides[g_CurrentSlide].szTitle, -1, &rcTitle, DT_SINGLELINE | DT_LEFT | DT_VCENTER);

    // Header subtitle
    SelectObject(hdcMem, g_hFontSubtitle);
    SetTextColor(hdcMem, UX_TOKEN_COLOR_ACCENT_PRIMARY);
    RECT rcSubtitle = { 30, 50, rcClient.right - 30, 75 };
    DrawTextW(hdcMem, g_Slides[g_CurrentSlide].szSubtitle, -1, &rcSubtitle, DT_SINGLELINE | DT_LEFT | DT_VCENTER);

    // Body content card
    RECT rcCard = { 30, 110, rcClient.right - 30, rcClient.bottom - 70 };
    HBRUSH hbrCard = CreateSolidBrush(UX_TOKEN_COLOR_SURFACE_LIGHT);
    FillRect(hdcMem, &rcCard, hbrCard);
    DeleteObject(hbrCard);

    HBRUSH hbrCardBrd = CreateSolidBrush(MixColor(UX_TOKEN_COLOR_BORDER_LIGHT, UX_TOKEN_COLOR_SURFACE_LIGHT, 128));
    FrameRect(hdcMem, &rcCard, hbrCardBrd);
    DeleteObject(hbrCardBrd);

    SelectObject(hdcMem, g_hFontBody);
    SetTextColor(hdcMem, UX_TOKEN_COLOR_TEXT_PRIMARY_LIGHT);
    RECT rcText = { rcCard.left + 24, rcCard.top + 24, rcCard.right - 24, rcCard.bottom - 24 };
    DrawTextW(hdcMem, g_Slides[g_CurrentSlide].szContent, -1, &rcText, DT_LEFT | DT_WORDBREAK);

    // Footer page dots
    int dotCount = g_SlideCount;
    int dotW = 10;
    int gap = 8;
    int totalDotW = dotCount * dotW + (dotCount - 1) * gap;
    int startX = (rcClient.right - totalDotW) / 2;
    int dotY = rcClient.bottom - 42;

    for (int i = 0; i < dotCount; i++)
    {
        COLORREF dotColor = (i == g_CurrentSlide) ? UX_TOKEN_COLOR_ACCENT_PRIMARY : UX_TOKEN_COLOR_BORDER_LIGHT;
        HBRUSH hbrDot = CreateSolidBrush(dotColor);
        RECT rcDot = { startX + i * (dotW + gap), dotY, startX + i * (dotW + gap) + dotW, dotY + dotW };
        FillRect(hdcMem, &rcDot, hbrDot);
        DeleteObject(hbrDot);
    }

    SelectObject(hdcMem, hFontOld);

    BitBlt(hdc, 0, 0, rcClient.right, rcClient.bottom, hdcMem, 0, 0, SRCCOPY);
    SelectObject(hdcMem, hbmOld);
    DeleteObject(hbm);
    DeleteDC(hdcMem);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    static HWND hBtnPrev = NULL;
    static HWND hBtnNext = NULL;
    static HWND hBtnAction = NULL;

    switch (msg)
    {
        case WM_CREATE:
        {
            LOGFONTW lf = { 0 };
            lf.lfHeight = -22;
            lf.lfWeight = FW_BOLD;
            StringCchCopyW(lf.lfFaceName, LF_FACESIZE, L"Segoe UI");
            g_hFontTitle = CreateFontIndirectW(&lf);

            lf.lfHeight = -14;
            lf.lfWeight = FW_SEMIBOLD;
            g_hFontSubtitle = CreateFontIndirectW(&lf);

            lf.lfHeight = -14;
            lf.lfWeight = FW_NORMAL;
            g_hFontBody = CreateFontIndirectW(&lf);

            hBtnPrev = CreateWindowW(L"BUTTON", L"◄ Previous", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                     30, WND_HEIGHT - 95, 110, 32, hwnd, (HMENU)IDC_BTN_PREV, NULL, NULL);
            hBtnNext = CreateWindowW(L"BUTTON", L"Next ►", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
                                     WND_WIDTH - 150, WND_HEIGHT - 95, 110, 32, hwnd, (HMENU)IDC_BTN_NEXT, NULL, NULL);
            hBtnAction = CreateWindowW(L"BUTTON", L"Action", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                       (WND_WIDTH - 160) / 2, WND_HEIGHT - 95, 160, 32, hwnd, (HMENU)IDC_BTN_ACTION, NULL, NULL);

            EnableWindow(hBtnPrev, FALSE);
            SetWindowTextW(hBtnAction, g_Slides[0].szActionLabel);
            return 0;
        }

        case WM_COMMAND:
        {
            WORD id = LOWORD(wParam);
            if (id == IDC_BTN_PREV)
            {
                if (g_CurrentSlide > 0)
                {
                    g_CurrentSlide--;
                    EnableWindow(hBtnPrev, g_CurrentSlide > 0);
                    SetWindowTextW(hBtnNext, (g_CurrentSlide == g_SlideCount - 1) ? L"Finish" : L"Next ►");
                    SetWindowTextW(hBtnAction, g_Slides[g_CurrentSlide].szActionLabel);
                    ShowWindow(hBtnAction, g_Slides[g_CurrentSlide].szActionCmd ? SW_SHOW : SW_HIDE);
                    InvalidateRect(hwnd, NULL, FALSE);
                }
            }
            else if (id == IDC_BTN_NEXT)
            {
                if (g_CurrentSlide < g_SlideCount - 1)
                {
                    g_CurrentSlide++;
                    EnableWindow(hBtnPrev, TRUE);
                    SetWindowTextW(hBtnNext, (g_CurrentSlide == g_SlideCount - 1) ? L"Finish" : L"Next ►");
                    SetWindowTextW(hBtnAction, g_Slides[g_CurrentSlide].szActionLabel);
                    ShowWindow(hBtnAction, g_Slides[g_CurrentSlide].szActionCmd ? SW_SHOW : SW_HIDE);
                    InvalidateRect(hwnd, NULL, FALSE);
                }
                else
                {
                    PostQuitMessage(0);
                }
            }
            else if (id == IDC_BTN_ACTION)
            {
                ExecuteSlideAction(g_CurrentSlide, hwnd);
            }
            return 0;
        }

        case WM_ERASEBKGND:
            return 1;

        case WM_PAINT:
        {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            RECT rc;
            GetClientRect(hwnd, &rc);
            DrawSlide(hdc, rc);
            EndPaint(hwnd, &ps);
            return 0;
        }

        case WM_DESTROY:
            if (g_hFontTitle) DeleteObject(g_hFontTitle);
            if (g_hFontSubtitle) DeleteObject(g_hFontSubtitle);
            if (g_hFontBody) DeleteObject(g_hFontBody);
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPWSTR lpCmdLine, int nCmdShow)
{
    INITCOMMONCONTROLSEX icex = { sizeof(icex), ICC_WIN95_CLASSES };
    InitCommonControlsEx(&icex);

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInstance;
    wc.hIcon = LoadIconW(hInstance, MAKEINTRESOURCEW(IDI_KIBAGUIDE));
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"KibaGuideWindowClass";

    RegisterClassExW(&wc);

    RECT rc = { 0, 0, WND_WIDTH, WND_HEIGHT };
    AdjustWindowRect(&rc, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, FALSE);

    INT screenW = GetSystemMetrics(SM_CXSCREEN);
    INT screenH = GetSystemMetrics(SM_CYSCREEN);
    INT x = (screenW - (rc.right - rc.left)) / 2;
    INT y = (screenH - (rc.bottom - rc.top)) / 2;

    HWND hwnd = CreateWindowExW(
        0, L"KibaGuideWindowClass", L"KibaOS User Guide & Tour",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE,
        x, y, rc.right - rc.left, rc.bottom - rc.top,
        NULL, NULL, hInstance, NULL);

    if (!hwnd) return 0;

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0))
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return (int)msg.wParam;
}
