/*
 * PROJECT:     KibaOS Intent-Based Window Management Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Intent-Based Window Management Header
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#pragma once

#include <windows.h>

typedef enum _KIBA_INTENT_MODE
{
    INTENT_MODE_NONE = 0,
    INTENT_DEV_TRIPANE = 1,
    INTENT_DUAL_SIDEBYSIDE = 2,
    INTENT_MEDIA_CINEMA = 3,
    INTENT_GAMING_FOCUS = 4,
    INTENT_RESEARCH_QUAD = 5,
    INTENT_CREATIVE_CANVAS = 6
} KIBA_INTENT_MODE;

struct KIBA_INTENT_INFO
{
    KIBA_INTENT_MODE Mode;
    WCHAR Name[64];
    WCHAR Description[128];
    LPCWSTR Icon;
};

VOID IntentWM_Init(VOID);
KIBA_INTENT_MODE IntentWM_GetActiveMode(VOID);
BOOL IntentWM_SetActiveMode(KIBA_INTENT_MODE Mode);
BOOL IntentWM_GetInfo(KIBA_INTENT_MODE Mode, KIBA_INTENT_INFO *pInfo);
VOID IntentWM_ApplyCurrentLayout(VOID);
KIBA_INTENT_MODE IntentWM_DetectIntentFromWindows(VOID);
int IntentWM_GetTotalModes(VOID);
