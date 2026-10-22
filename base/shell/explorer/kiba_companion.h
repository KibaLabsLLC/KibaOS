/*
 * PROJECT:     KibaOS Desktop Companion (Kiba)
 * LICENSE:     GPL-3.0-or-later
 * PURPOSE:     Kiba Companion header definition
 */

#ifndef _KIBA_COMPANION_H_
#define _KIBA_COMPANION_H_

#include <windows.h>
#include <wincodec.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <reactos/ux_errors.h>

#ifdef __cplusplus
extern "C" {
#endif

// Registry key and value names
#define KIBA_REG_KEY    L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\KibaCompanion"
#define KIBA_REG_VAL_ENABLED L"Enabled"

// Kiba Companion Animation States
typedef enum _KIBA_STATE {
    KIBA_STATE_IDLE = 0,
    KIBA_STATE_REACTING,
    KIBA_STATE_TALKING,
    KIBA_STATE_TROUBLESHOOTING,
    KIBA_STATE_ALERT,
    KIBA_STATE_COUNT
} KIBA_STATE;

// Core functions exported to Explorer shell
BOOL KibaCompanion_Init(HWND hParentTray);
VOID KibaCompanion_Shutdown(VOID);
VOID KibaCompanion_UpdateSettings(VOID);
BOOL KibaCompanion_IsEnabled(VOID);
VOID KibaCompanion_SetEnabled(BOOL bEnable);

// Reactions & Troubleshooting API
VOID KibaCompanion_OnDeviceChange(WPARAM wParam, LPARAM lParam);
VOID KibaCompanion_OnForegroundWindowChanged(HWND hwndForeground);
VOID KibaCompanion_OnSettingChanged(LPCWSTR lpszSection);
VOID KibaCompanion_ShowSpeechBubble(LPCWSTR szTitle, LPCWSTR szMessage, LPCWSTR szActionText, DWORD dwDurationMs);
BOOL KibaCompanion_TroubleshootDevice(DEVINST devInst);

#ifdef __cplusplus
}
#endif

#endif /* _KIBA_COMPANION_H_ */
