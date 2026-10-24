/*
 * PROJECT:     KibaOS Desktop Companion (Kiba)
 * LICENSE:     GPL-3.0-or-later
 * PURPOSE:     Kiba Companion window, sprite animation engine, OS reactions, and automated device troubleshooter
 */

#include "precomp.h"
#include "kiba_companion.h"
#include <gdiplus.h>
#include <dbt.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <devguid.h>
#include <reactos/ux_errors.h>

using namespace Gdiplus;

// Sprite mappings
static const WCHAR* g_IdleSprites[] = {
    L"media\\graphics\\kiba\\sprite_01.png",
    L"media\\graphics\\kiba\\sprite_02.png",
    L"media\\graphics\\kiba\\sprite_03.png",
    L"media\\graphics\\kiba\\sprite_04.png",
    L"media\\graphics\\kiba\\sprite_05.png",
    L"media\\graphics\\kiba\\sprite_06.png"
};

static const WCHAR* g_ReactingSprites[] = {
    L"media\\graphics\\kiba\\sprite_07.png",
    L"media\\graphics\\kiba\\sprite_08.png",
    L"media\\graphics\\kiba\\sprite_09.png",
    L"media\\graphics\\kiba\\sprite_10.png",
    L"media\\graphics\\kiba\\sprite_11.png"
};

static const WCHAR* g_TalkingSprites[] = {
    L"media\\graphics\\kiba\\sprite_12.png",
    L"media\\graphics\\kiba\\sprite_13.png",
    L"media\\graphics\\kiba\\sprite_14.png",
    L"media\\graphics\\kiba\\sprite_15.png",
    L"media\\graphics\\kiba\\sprite_16.png"
};

static const WCHAR* g_TroubleshootingSprites[] = {
    L"media\\graphics\\kiba\\sprite_17.png",
    L"media\\graphics\\kiba\\sprite_18.png",
    L"media\\graphics\\kiba\\sprite_19.png",
    L"media\\graphics\\kiba\\sprite_20.png",
    L"media\\graphics\\kiba\\sprite_21.png"
};

static const WCHAR* g_AlertSprites[] = {
    L"media\\graphics\\kiba\\sprite_22.png",
    L"media\\graphics\\kiba\\sprite_23.png",
    L"media\\graphics\\kiba\\sprite_24.png"
};

struct SPRITE_SET {
    const WCHAR** Files;
    UINT Count;
};

static void AddRoundRectToPath(GraphicsPath &path, const RectF &bounds, float radius)
{
    float diameter = radius * 2.0f;
    path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180.0f, 90.0f);
    path.AddArc(bounds.X + bounds.Width - diameter, bounds.Y, diameter, diameter, 270.0f, 90.0f);
    path.AddArc(bounds.X + bounds.Width - diameter, bounds.Y + bounds.Height - diameter, diameter, diameter, 0.0f, 90.0f);
    path.AddArc(bounds.X, bounds.Y + bounds.Height - diameter, diameter, diameter, 90.0f, 90.0f);
    path.CloseFigure();
}

static const SPRITE_SET g_SpriteSets[KIBA_STATE_COUNT] = {
    { g_IdleSprites, _countof(g_IdleSprites) },
    { g_ReactingSprites, _countof(g_ReactingSprites) },
    { g_TalkingSprites, _countof(g_TalkingSprites) },
    { g_TroubleshootingSprites, _countof(g_TroubleshootingSprites) },
    { g_AlertSprites, _countof(g_AlertSprites) }
};

#define IDT_ANIMATION_TIMER  1001
#define IDT_BUBBLE_TIMER     1002

class CKibaCompanionWindow
{
private:
    HWND m_hWnd;
    HWND m_hParentTray;
    HWINEVENTHOOK m_hWinEventHook;
    ULONG_PTR m_gdiplusToken;
    BOOL m_bEnabled;
    KIBA_STATE m_CurrentState;
    UINT m_CurrentFrameIndex;

    // Speech bubble state
    WCHAR m_szBubbleTitle[128];
    WCHAR m_szBubbleMessage[256];
    WCHAR m_szBubbleAction[64];
    BOOL m_bShowBubble;
    DWORD m_dwBubbleExpireTick;
    DEVINST m_PendingFixDevInst;

    // Window position / dragging & screen wandering
    POINT m_ptPosition;
    POINT m_ptTargetPos;
    DWORD m_dwNextWanderTick;
    DWORD m_dwFrameTickCount;
    SIZE m_WndSize;
    BOOL m_bDragging;
    POINT m_ptDragStart;

    // Sprite memory cache
    Bitmap* m_pCachedSprites[KIBA_STATE_COUNT][8];

public:
    CKibaCompanionWindow()
        : m_hWnd(NULL)
        , m_hParentTray(NULL)
        , m_hWinEventHook(NULL)
        , m_gdiplusToken(0)
        , m_bEnabled(TRUE)
        , m_CurrentState(KIBA_STATE_IDLE)
        , m_CurrentFrameIndex(0)
        , m_dwNextWanderTick(0)
        , m_dwFrameTickCount(0)
        , m_bShowBubble(FALSE)
        , m_dwBubbleExpireTick(0)
        , m_PendingFixDevInst(0)
        , m_bDragging(FALSE)
    {
        m_szBubbleTitle[0] = L'\0';
        m_szBubbleMessage[0] = L'\0';
        m_szBubbleAction[0] = L'\0';
        m_WndSize.cx = 180;
        m_WndSize.cy = 170;
        m_ptPosition.x = 100;
        m_ptPosition.y = 100;

        for (int i = 0; i < KIBA_STATE_COUNT; i++)
        {
            for (int j = 0; j < 8; j++)
            {
                m_pCachedSprites[i][j] = NULL;
            }
        }
    }

    ~CKibaCompanionWindow()
    {
        Shutdown();
    }

    BOOL Initialize(HWND hParentTray)
    {
        m_hParentTray = hParentTray;

        // Initialize GDI+
        GdiplusStartupInput gdiplusStartupInput;
        GdiplusStartup(&m_gdiplusToken, &gdiplusStartupInput, NULL);

        // Read enable status from registry
        m_bEnabled = KibaCompanion_IsEnabled();

        // Register window class
        WNDCLASSEXW wc = { sizeof(wc) };
        wc.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
        wc.lpfnWndProc = s_WndProc;
        wc.hInstance = hExplorerInstance;
        wc.hCursor = LoadCursor(NULL, IDC_ARROW);
        wc.lpszClassName = L"KibaCompanionWindowClass";
        RegisterClassExW(&wc);

        // Position window at bottom right of primary desktop
        RECT rcWork;
        SystemParametersInfoW(SPI_GETWORKAREA, 0, &rcWork, 0);
        m_ptPosition.x = rcWork.right - m_WndSize.cx - 20;
        m_ptPosition.y = rcWork.bottom - m_WndSize.cy - 10;
        m_ptTargetPos = m_ptPosition;
        m_dwNextWanderTick = GetTickCount() + 2000;
        m_dwFrameTickCount = 0;

        // Create Normal Window (non-layered to eliminate overlay flickering)
        m_hWnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            L"KibaCompanionWindowClass",
            L"Kiba Desktop Companion",
            WS_POPUP,
            m_ptPosition.x, m_ptPosition.y,
            m_WndSize.cx, m_WndSize.cy,
            NULL, NULL, hExplorerInstance, this);

        if (!m_hWnd)
            return FALSE;

        // Apply rounded window region
        HRGN hRgn = CreateRoundRectRgn(0, 0, m_WndSize.cx + 1, m_WndSize.cy + 1, 16, 16);
        SetWindowRgn(m_hWnd, hRgn, TRUE);

        // Hook system foreground window changes for OS awareness
        m_hWinEventHook = SetWinEventHook(
            EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
            NULL, s_WinEventProc, 0, 0, WINEVENT_OUTOFCONTEXT);

        // Set animation/movement timer (150ms tick for smooth wandering)
        SetTimer(m_hWnd, IDT_ANIMATION_TIMER, 150, NULL);

        if (m_bEnabled)
        {
            ShowWindow(m_hWnd, SW_SHOWNOACTIVATE);
            ShowSpeechBubble(L"Kiba", L"Hi! I'm Kiba, your desktop companion!", NULL, 5000);
        }
        else
        {
            ShowWindow(m_hWnd, SW_HIDE);
        }

        return TRUE;
    }

    VOID ClearCachedSprites()
    {
        for (int i = 0; i < KIBA_STATE_COUNT; i++)
        {
            for (int j = 0; j < 8; j++)
            {
                if (m_pCachedSprites[i][j])
                {
                    delete m_pCachedSprites[i][j];
                    m_pCachedSprites[i][j] = NULL;
                }
            }
        }
    }

    Bitmap* GetSpriteBitmap(KIBA_STATE state, UINT frameIndex)
    {
        if (state < 0 || state >= KIBA_STATE_COUNT) return NULL;
        const SPRITE_SET& set = g_SpriteSets[state];
        if (set.Count == 0) return NULL;
        UINT idx = frameIndex % set.Count;
        if (idx >= 8) return NULL;

        if (m_pCachedSprites[state][idx])
            return m_pCachedSprites[state][idx];

        const WCHAR* szRelative = set.Files[idx];
        WCHAR szFullPath[MAX_PATH];
        GetWindowsDirectoryW(szFullPath, _countof(szFullPath));
        PathCombineW(szFullPath, szFullPath, szRelative);

        Bitmap* pBmp = new Bitmap(szFullPath, FALSE);
        if (pBmp->GetLastStatus() != Ok)
        {
            delete pBmp;
            pBmp = new Bitmap(szRelative, FALSE);
        }

        if (pBmp->GetLastStatus() == Ok)
        {
            m_pCachedSprites[state][idx] = pBmp;
            return pBmp;
        }

        delete pBmp;
        return NULL;
    }

    VOID Shutdown()
    {
        if (m_hWinEventHook)
        {
            UnhookWinEvent(m_hWinEventHook);
            m_hWinEventHook = NULL;
        }

        if (m_hWnd)
        {
            KillTimer(m_hWnd, IDT_ANIMATION_TIMER);
            KillTimer(m_hWnd, IDT_BUBBLE_TIMER);
            DestroyWindow(m_hWnd);
            m_hWnd = NULL;
        }

        ClearCachedSprites();

        if (m_gdiplusToken)
        {
            GdiplusShutdown(m_gdiplusToken);
            m_gdiplusToken = 0;
        }
    }

    VOID UpdateSettings()
    {
        BOOL bOldEnabled = m_bEnabled;
        m_bEnabled = KibaCompanion_IsEnabled();

        if (m_bEnabled != bOldEnabled)
        {
            if (m_bEnabled)
            {
                ShowWindow(m_hWnd, SW_SHOWNOACTIVATE);
                SetState(KIBA_STATE_REACTING);
                ShowSpeechBubble(L"Kiba", L"I'm back!", NULL, 3000);
            }
            else
            {
                ShowWindow(m_hWnd, SW_HIDE);
            }
        }
    }

    VOID SetState(KIBA_STATE newState)
    {
        if (m_CurrentState != newState)
        {
            m_CurrentState = newState;
            m_CurrentFrameIndex = 0;
            Render();
        }
    }

    VOID ShowSpeechBubble(LPCWSTR szTitle, LPCWSTR szMessage, LPCWSTR szAction, DWORD dwDurationMs)
    {
        if (!m_bEnabled) return;

        StringCchCopyW(m_szBubbleTitle, _countof(m_szBubbleTitle), szTitle ? szTitle : L"Kiba");
        StringCchCopyW(m_szBubbleMessage, _countof(m_szBubbleMessage), szMessage ? szMessage : L"");
        StringCchCopyW(m_szBubbleAction, _countof(m_szBubbleAction), szAction ? szAction : L"");

        m_bShowBubble = TRUE;
        m_dwBubbleExpireTick = GetTickCount() + (dwDurationMs > 0 ? dwDurationMs : 5000);

        SetTimer(m_hWnd, IDT_BUBBLE_TIMER, 500, NULL);
        if (m_CurrentState == KIBA_STATE_IDLE)
            SetState(KIBA_STATE_TALKING);

        Render();
    }

    VOID HideSpeechBubble()
    {
        m_bShowBubble = FALSE;
        m_szBubbleTitle[0] = L'\0';
        m_szBubbleMessage[0] = L'\0';
        m_szBubbleAction[0] = L'\0';
        KillTimer(m_hWnd, IDT_BUBBLE_TIMER);
        if (m_CurrentState == KIBA_STATE_TALKING)
            SetState(KIBA_STATE_IDLE);
        Render();
    }

    VOID OnDeviceChange(WPARAM wParam, LPARAM lParam)
    {
        if (!m_bEnabled) return;

        if (wParam == DBT_DEVICEARRIVAL)
        {
            SetState(KIBA_STATE_ALERT);
            DEV_BROADCAST_HDR* pHdr = (DEV_BROADCAST_HDR*)lParam;
            if (pHdr && pHdr->dbch_devicetype == DBT_DEVTYP_HANDLE)
            {
                // Inspect connected device for errors
                TroubleshootConnectedDevices();
            }
            else
            {
                TroubleshootConnectedDevices();
            }
        }
        else if (wParam == DBT_DEVICEREMOVECOMPLETE)
        {
            SetState(KIBA_STATE_REACTING);
            ShowSpeechBubble(L"Device Removed", L"An external device was disconnected.", NULL, 3000);
        }
    }

    VOID OnForegroundWindowChanged(HWND hwndForeground)
    {
        if (!m_bEnabled || !hwndForeground || hwndForeground == m_hWnd) return;

        WCHAR szTitle[128] = { 0 };
        GetWindowTextW(hwndForeground, szTitle, _countof(szTitle));

        // Periodically react when switching to interesting apps
        if (wcsstr(szTitle, L"Settings") || wcsstr(szTitle, L"System Settings"))
        {
            SetState(KIBA_STATE_REACTING);
            ShowSpeechBubble(L"Kiba Assistant", L"Need help configuring KibaOS settings?", NULL, 4000);
        }
    }

    VOID OnSettingChanged(LPCWSTR lpszSection)
    {
        UpdateSettings();
    }

    BOOL TroubleshootConnectedDevices()
    {
        HDEVINFO hDevInfo = SetupDiGetClassDevsW(NULL, NULL, NULL, DIGCF_PRESENT | DIGCF_ALLCLASSES);
        if (hDevInfo == INVALID_HANDLE_VALUE) return FALSE;

        SP_DEVINFO_DATA devInfoData = { sizeof(SP_DEVINFO_DATA) };
        BOOL bFoundProblem = FALSE;

        for (DWORD i = 0; SetupDiEnumDeviceInfo(hDevInfo, i, &devInfoData); i++)
        {
            ULONG status = 0, problemNumber = 0;
            if (CM_Get_DevNode_Status(&status, &problemNumber, devInfoData.DevInst, 0) == CR_SUCCESS)
            {
                if (status & DN_HAS_PROBLEM)
                {
                    WCHAR szName[128] = L"External Device";
                    SetupDiGetDeviceRegistryPropertyW(hDevInfo, &devInfoData, SPDRP_FRIENDLYNAME, NULL, (BYTE*)szName, sizeof(szName), NULL);

                    m_PendingFixDevInst = devInfoData.DevInst;
                    bFoundProblem = TRUE;

                    SetState(KIBA_STATE_TROUBLESHOOTING);
                    WCHAR szMsg[256];
                    StringCchPrintfW(szMsg, _countof(szMsg),
                        L"%s encountered error (Code %lu). Would you like Kiba to fix it automatically?",
                        szName, problemNumber);

                    ShowSpeechBubble(L"Device Problem Detected", szMsg, L"Click to Fix", 10000);
                    break;
                }
            }
        }

        SetupDiDestroyDeviceInfoList(hDevInfo);

        if (!bFoundProblem)
        {
            SetState(KIBA_STATE_REACTING);
            ShowSpeechBubble(L"Device Connected", L"A new device was connected and is working properly!", NULL, 3500);
        }

        return bFoundProblem;
    }

    VOID ExecuteFix()
    {
        if (m_PendingFixDevInst != 0)
        {
            SetState(KIBA_STATE_TROUBLESHOOTING);
            ShowSpeechBubble(L"Troubleshooting", L"Attempting automated fix: re-enumerating device hardware...", NULL, 3000);

            // Trigger re-enumeration & resolution
            CONFIGRET cr = CM_Reenumerate_DevNode(m_PendingFixDevInst, CM_REENUMERATE_NORMAL);
            if (cr == CR_SUCCESS)
            {
                SetState(KIBA_STATE_REACTING);
                ShowSpeechBubble(L"Fix Complete!", L"Device hardware re-enumerated successfully.", NULL, 4000);
            }
            else
            {
                SetState(KIBA_STATE_ALERT);
                const UX_ERROR_ENTRY* err = UxGetErrorEntry(ERROR_ACCESS_DENIED);
                ShowSpeechBubble(err->WhatHappened, err->WhatToDoNext, NULL, 5000);
            }
            m_PendingFixDevInst = 0;
        }
    }

private:
    VOID Render()
    {
        if (!m_hWnd || !m_bEnabled) return;
        InvalidateRect(m_hWnd, NULL, FALSE);
    }

    VOID OnPaint(HDC hdc)
    {
        if (!m_hWnd || !m_bEnabled) return;

        HDC hdcMem = CreateCompatibleDC(hdc);
        HBITMAP hBitmap = CreateCompatibleBitmap(hdc, m_WndSize.cx, m_WndSize.cy);
        HGDIOBJ hOldBitmap = SelectObject(hdcMem, hBitmap);

        Graphics graphics(hdcMem);
        graphics.SetSmoothingMode(SmoothingModeAntiAlias);
        graphics.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
        graphics.Clear(Color(255, 245, 248, 252)); // Solid surface background for normal window

        // Draw card border
        Pen framePen(Color(255, 200, 210, 225), 1.0f);
        graphics.DrawRectangle(&framePen, 0, 0, m_WndSize.cx - 1, m_WndSize.cy - 1);

        // Draw current sprite frame from cache (scaled down to 100x100)
        Bitmap* pSpriteBmp = GetSpriteBitmap(m_CurrentState, m_CurrentFrameIndex);
        if (pSpriteBmp)
        {
            graphics.DrawImage(pSpriteBmp, 40, 65, 100, 100);
        }

        // Render Speech Bubble if active
        if (m_bShowBubble)
        {
            GraphicsPath path(FillModeAlternate);
            RectF bubbleRect(10.0f, 5.0f, 160.0f, 55.0f);
            AddRoundRectToPath(path, bubbleRect, 8.0f);

            SolidBrush bgBrush(Color(240, 255, 255, 255));
            Pen borderPen(Color(200, 0, 120, 215), 1.5f);

            graphics.FillPath(&bgBrush, &path);
            graphics.DrawPath(&borderPen, &path);

            FontFamily fontFamily(L"Segoe UI", NULL);
            Font titleFont(&fontFamily, 8, FontStyleBold, UnitPoint);
            Font msgFont(&fontFamily, 7.5f, FontStyleRegular, UnitPoint);
            SolidBrush textBrush(Color(255, 30, 30, 30));
            SolidBrush actionBrush(Color(255, 0, 102, 204));

            RectF titleRect(15.0f, 8.0f, 150.0f, 14.0f);
            RectF msgRect(15.0f, 22.0f, 150.0f, 24.0f);
            RectF actionRect(15.0f, 44.0f, 150.0f, 12.0f);

            graphics.DrawString(m_szBubbleTitle, -1, &titleFont, titleRect, NULL, &textBrush);
            graphics.DrawString(m_szBubbleMessage, -1, &msgFont, msgRect, NULL, &textBrush);

            if (m_szBubbleAction[0] != L'\0')
            {
                Font actionFont(&fontFamily, 7.5f, FontStyleBold, UnitPoint);
                graphics.DrawString(m_szBubbleAction, -1, &actionFont, actionRect, NULL, &actionBrush);
            }
        }

        BitBlt(hdc, 0, 0, m_WndSize.cx, m_WndSize.cy, hdcMem, 0, 0, SRCCOPY);

        SelectObject(hdcMem, hOldBitmap);
        DeleteObject(hBitmap);
        DeleteDC(hdcMem);
    }

    VOID OnTimer(UINT_PTR nIDEvent)
    {
        if (nIDEvent == IDT_ANIMATION_TIMER)
        {
            // Handle smooth screen wandering behavior
            if (!m_bDragging && m_bEnabled)
            {
                RECT rcWork;
                SystemParametersInfoW(SPI_GETWORKAREA, 0, &rcWork, 0);

                if (abs(m_ptPosition.x - m_ptTargetPos.x) <= 4 &&
                    abs(m_ptPosition.y - m_ptTargetPos.y) <= 4 &&
                    GetTickCount() >= m_dwNextWanderTick)
                {
                    LONG maxW = max(1L, (rcWork.right - rcWork.left - m_WndSize.cx));
                    LONG maxH = max(1L, (rcWork.bottom - rcWork.top - m_WndSize.cy));
                    m_ptTargetPos.x = rcWork.left + (rand() % maxW);
                    m_ptTargetPos.y = rcWork.top + (rand() % maxH);
                    m_dwNextWanderTick = GetTickCount() + 4000 + (rand() % 5000);
                }

                if (m_ptPosition.x < m_ptTargetPos.x)
                    m_ptPosition.x += min((LONG)3, m_ptTargetPos.x - m_ptPosition.x);
                else if (m_ptPosition.x > m_ptTargetPos.x)
                    m_ptPosition.x -= min((LONG)3, m_ptPosition.x - m_ptTargetPos.x);

                if (m_ptPosition.y < m_ptTargetPos.y)
                    m_ptPosition.y += min((LONG)3, m_ptTargetPos.y - m_ptPosition.y);
                else if (m_ptPosition.y > m_ptTargetPos.y)
                    m_ptPosition.y -= min((LONG)3, m_ptPosition.y - m_ptTargetPos.y);

                SetWindowPos(m_hWnd, NULL, m_ptPosition.x, m_ptPosition.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            }

            // Slow the pace of animation frame changes significantly (frame advances every 8 ticks / ~1200ms)
            m_dwFrameTickCount++;
            if (m_dwFrameTickCount % 8 == 0)
            {
                const SPRITE_SET& set = g_SpriteSets[m_CurrentState];
                m_CurrentFrameIndex = (m_CurrentFrameIndex + 1) % (set.Count > 0 ? set.Count : 1);

                // Transition from temporary states back to idle
                if (m_CurrentFrameIndex == 0 &&
                    (m_CurrentState == KIBA_STATE_REACTING || m_CurrentState == KIBA_STATE_ALERT))
                {
                    if (!m_bShowBubble)
                        m_CurrentState = KIBA_STATE_IDLE;
                }
            }

            Render();
        }
        else if (nIDEvent == IDT_BUBBLE_TIMER)
        {
            if (GetTickCount() >= m_dwBubbleExpireTick)
            {
                HideSpeechBubble();
            }
        }
    }

    VOID OnContextMenu(POINT pt)
    {
        HMENU hMenu = CreatePopupMenu();
        AppendMenuW(hMenu, MF_STRING, 1, L"Troubleshoot External Devices");
        AppendMenuW(hMenu, MF_STRING, 2, L"Hide Kiba Companion");
        AppendMenuW(hMenu, MF_SEPARATOR, 0, NULL);
        AppendMenuW(hMenu, MF_STRING, 3, L"Open System Settings");

        UINT cmd = TrackPopupMenu(hMenu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, m_hWnd, NULL);
        DestroyMenu(hMenu);

        if (cmd == 1)
        {
            TroubleshootConnectedDevices();
        }
        else if (cmd == 2)
        {
            KibaCompanion_SetEnabled(FALSE);
            UpdateSettings();
        }
        else if (cmd == 3)
        {
            ShellExecuteW(NULL, L"open", L"systemsettings.exe", NULL, NULL, SW_SHOWNORMAL);
        }
    }

    static LRESULT CALLBACK s_WndProc(HWND hWnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
    {
        CKibaCompanionWindow* pThis = NULL;
        if (uMsg == WM_NCCREATE)
        {
            CREATESTRUCT* pCreate = (CREATESTRUCT*)lParam;
            pThis = (CKibaCompanionWindow*)pCreate->lpCreateParams;
            SetWindowLongPtrW(hWnd, GWLP_USERDATA, (LONG_PTR)pThis);
        }
        else
        {
            pThis = (CKibaCompanionWindow*)GetWindowLongPtrW(hWnd, GWLP_USERDATA);
        }

        if (pThis)
        {
            switch (uMsg)
            {
                case WM_ERASEBKGND:
                    return 1;

                case WM_PAINT:
                {
                    PAINTSTRUCT ps;
                    HDC hdc = BeginPaint(hWnd, &ps);
                    pThis->OnPaint(hdc);
                    EndPaint(hWnd, &ps);
                    return 0;
                }

                case WM_TIMER:
                    pThis->OnTimer(wParam);
                    return 0;

                case WM_LBUTTONDOWN:
                    if (pThis->m_bShowBubble && pThis->m_PendingFixDevInst != 0)
                    {
                        pThis->ExecuteFix();
                    }
                    else
                    {
                        pThis->m_bDragging = TRUE;
                        GetCursorPos(&pThis->m_ptDragStart);
                        SetCapture(hWnd);
                    }
                    return 0;

                case WM_MOUSEMOVE:
                    if (pThis->m_bDragging)
                    {
                        POINT ptCurr;
                        GetCursorPos(&ptCurr);
                        pThis->m_ptPosition.x += (ptCurr.x - pThis->m_ptDragStart.x);
                        pThis->m_ptPosition.y += (ptCurr.y - pThis->m_ptDragStart.y);
                        pThis->m_ptDragStart = ptCurr;
                        SetWindowPos(hWnd, NULL, pThis->m_ptPosition.x, pThis->m_ptPosition.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                        pThis->Render();
                    }
                    return 0;

                case WM_LBUTTONUP:
                    if (pThis->m_bDragging)
                    {
                        pThis->m_bDragging = FALSE;
                        ReleaseCapture();
                    }
                    return 0;

                case WM_RBUTTONUP:
                {
                    POINT pt;
                    GetCursorPos(&pt);
                    pThis->OnContextMenu(pt);
                    return 0;
                }

                case WM_DEVICECHANGE:
                    pThis->OnDeviceChange(wParam, lParam);
                    return 0;

                case WM_SETTINGCHANGE:
                    pThis->OnSettingChanged((LPCWSTR)lParam);
                    return 0;

                case WM_DESTROY:
                    SetWindowLongPtrW(hWnd, GWLP_USERDATA, 0);
                    return 0;
            }
        }

        return DefWindowProcW(hWnd, uMsg, wParam, lParam);
    }

    static VOID CALLBACK s_WinEventProc(
        HWINEVENTHOOK hWinEventHook, DWORD event, HWND hwnd,
        LONG idObject, LONG idChild, DWORD dwEventThread, DWORD dwmsEventTime)
    {
        if (event == EVENT_SYSTEM_FOREGROUND && g_pKibaCompanion)
        {
            g_pKibaCompanion->OnForegroundWindowChanged(hwnd);
        }
    }

public:
    static CKibaCompanionWindow* g_pKibaCompanion;
};

CKibaCompanionWindow* CKibaCompanionWindow::g_pKibaCompanion = NULL;

// C API implementation
extern "C" {

BOOL KibaCompanion_IsEnabled(VOID)
{
    HKEY hKey;
    DWORD dwEnabled = 1; // Default to ON
    DWORD dwSize = sizeof(dwEnabled);

    if (RegOpenKeyExW(HKEY_CURRENT_USER, KIBA_REG_KEY, 0, KEY_READ, &hKey) == ERROR_SUCCESS)
    {
        RegQueryValueExW(hKey, KIBA_REG_VAL_ENABLED, NULL, NULL, (BYTE*)&dwEnabled, &dwSize);
        RegCloseKey(hKey);
    }
    return (dwEnabled != 0);
}

VOID KibaCompanion_SetEnabled(BOOL bEnable)
{
    HKEY hKey;
    DWORD dwEnabled = bEnable ? 1 : 0;

    if (RegCreateKeyExW(HKEY_CURRENT_USER, KIBA_REG_KEY, 0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL) == ERROR_SUCCESS)
    {
        RegSetValueExW(hKey, KIBA_REG_VAL_ENABLED, 0, REG_DWORD, (BYTE*)&dwEnabled, sizeof(dwEnabled));
        RegCloseKey(hKey);
    }

    // Broadcast setting change
    SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, (LPARAM)L"TraySettings", SMTO_ABORTIFHUNG, 1000, NULL);
}

BOOL KibaCompanion_Init(HWND hParentTray)
{
    if (CKibaCompanionWindow::g_pKibaCompanion) return TRUE;

    CKibaCompanionWindow* pKiba = new CKibaCompanionWindow();
    if (!pKiba->Initialize(hParentTray))
    {
        delete pKiba;
        return FALSE;
    }

    CKibaCompanionWindow::g_pKibaCompanion = pKiba;
    return TRUE;
}

VOID KibaCompanion_Shutdown(VOID)
{
    if (CKibaCompanionWindow::g_pKibaCompanion)
    {
        delete CKibaCompanionWindow::g_pKibaCompanion;
        CKibaCompanionWindow::g_pKibaCompanion = NULL;
    }
}

VOID KibaCompanion_UpdateSettings(VOID)
{
    if (CKibaCompanionWindow::g_pKibaCompanion)
    {
        CKibaCompanionWindow::g_pKibaCompanion->UpdateSettings();
    }
}

VOID KibaCompanion_OnDeviceChange(WPARAM wParam, LPARAM lParam)
{
    if (CKibaCompanionWindow::g_pKibaCompanion)
    {
        CKibaCompanionWindow::g_pKibaCompanion->OnDeviceChange(wParam, lParam);
    }
}

VOID KibaCompanion_OnForegroundWindowChanged(HWND hwndForeground)
{
    if (CKibaCompanionWindow::g_pKibaCompanion)
    {
        CKibaCompanionWindow::g_pKibaCompanion->OnForegroundWindowChanged(hwndForeground);
    }
}

VOID KibaCompanion_OnSettingChanged(LPCWSTR lpszSection)
{
    if (CKibaCompanionWindow::g_pKibaCompanion)
    {
        CKibaCompanionWindow::g_pKibaCompanion->OnSettingChanged(lpszSection);
    }
}

VOID KibaCompanion_ShowSpeechBubble(LPCWSTR szTitle, LPCWSTR szMessage, LPCWSTR szActionText, DWORD dwDurationMs)
{
    if (CKibaCompanionWindow::g_pKibaCompanion)
    {
        CKibaCompanionWindow::g_pKibaCompanion->ShowSpeechBubble(szTitle, szMessage, szActionText, dwDurationMs);
    }
}

BOOL KibaCompanion_TroubleshootDevice(DEVINST devInst)
{
    if (CKibaCompanionWindow::g_pKibaCompanion)
    {
        return CKibaCompanionWindow::g_pKibaCompanion->TroubleshootConnectedDevices();
    }
    return FALSE;
}

} // extern "C"
