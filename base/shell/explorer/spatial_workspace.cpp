/*
 * PROJECT:     KibaOS Spatial 3D Workspaces Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Spatial 3D Canvas Workspaces Engine Implementation
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#include "precomp.h"
#include "spatial_workspace.h"
#include <reactos/universal_settings.h>

static KIBA_SPATIAL_PLANE g_SpatialPlanes[KIBA_MAX_SPATIAL_WORKSPACES];
static KIBA_WINDOW_SPATIAL_POS g_WindowSpatial[128];
static int g_NumSpatialWindows = 0;
static int g_ActiveWorkspaceId = 0;
static BOOL g_SpatialInitialized = FALSE;

static const KIBA_SPATIAL_PLANE g_DefaultPlanes[KIBA_MAX_SPATIAL_WORKSPACES] = {
    { 0, L"Workspace 1: Coding & Dev", 0.0f, 0.0f, 1.0f, 1.0f, 0.0f, UX_TOKEN_COLOR_ACCENT_PRIMARY, 0 },
    { 1, L"Workspace 2: Gaming & High Perf", 1000.0f, 0.0f, 1.2f, 1.0f, 5.0f, UX_TOKEN_COLOR_ACCENT_HOVER, 0 },
    { 2, L"Workspace 3: Design & Media", 2000.0f, 0.0f, 0.8f, 1.0f, -5.0f, UX_TOKEN_COLOR_ACCENT_PRESSED, 0 },
    { 3, L"Workspace 4: Research & Documents", 0.0f, 1000.0f, 1.0f, 1.0f, 0.0f, UX_TOKEN_COLOR_NATURE_LEAF, 0 },
    { 4, L"Workspace 5: Multi-Monitor Grid", 1000.0f, 1000.0f, 1.5f, 1.0f, 10.0f, UX_TOKEN_COLOR_NATURE_GLOW, 0 },
    { 5, L"Workspace 6: Spatial Sandbox 3D", -1000.0f, 0.0f, 2.0f, 0.9f, -10.0f, UX_TOKEN_COLOR_NATURE_MIST, 0 }
};

VOID SpatialWorkspace_Init(VOID)
{
    if (g_SpatialInitialized) return;

    for (int i = 0; i < KIBA_MAX_SPATIAL_WORKSPACES; i++)
    {
        g_SpatialPlanes[i] = g_DefaultPlanes[i];
    }

    DWORD dwActive = 0;
    if (KibaSettingsGetDword(L"SpatialWorkspaces", L"ActiveWorkspace", &dwActive, 0) && dwActive < KIBA_MAX_SPATIAL_WORKSPACES)
    {
        g_ActiveWorkspaceId = (int)dwActive;
    }

    g_SpatialInitialized = TRUE;
}

int SpatialWorkspace_GetActive(VOID)
{
    SpatialWorkspace_Init();
    return g_ActiveWorkspaceId;
}

int SpatialWorkspace_GetTotalCount(VOID)
{
    return KIBA_MAX_SPATIAL_WORKSPACES;
}

BOOL SpatialWorkspace_Switch(int WorkspaceId)
{
    SpatialWorkspace_Init();
    if (WorkspaceId < 0 || WorkspaceId >= KIBA_MAX_SPATIAL_WORKSPACES)
        return FALSE;

    int oldWorkspace = g_ActiveWorkspaceId;
    g_ActiveWorkspaceId = WorkspaceId;

    KibaSettingsSetDword(L"SpatialWorkspaces", L"ActiveWorkspace", (DWORD)WorkspaceId);

    WCHAR szPrev[32], szNew[32];
    StringCchPrintfW(szPrev, _countof(szPrev), L"Workspace %d", oldWorkspace + 1);
    StringCchPrintfW(szNew, _countof(szNew), L"Workspace %d", WorkspaceId + 1);
    KibaSettingsRecordEvent(KIBA_HISTORY_CAT_CONFIG, L"3D Spatial Workspace Engine", L"Kiba Shell", L"Workspace Switch", szPrev, szNew);

    SpatialWorkspace_ApplySpatialTransformToWindows();
    return TRUE;
}

BOOL SpatialWorkspace_GetPlane(int WorkspaceId, KIBA_SPATIAL_PLANE *pPlane)
{
    SpatialWorkspace_Init();
    if (!pPlane || WorkspaceId < 0 || WorkspaceId >= KIBA_MAX_SPATIAL_WORKSPACES)
        return FALSE;

    *pPlane = g_SpatialPlanes[WorkspaceId];
    return TRUE;
}

BOOL SpatialWorkspace_SetPlane(int WorkspaceId, const KIBA_SPATIAL_PLANE *pPlane)
{
    SpatialWorkspace_Init();
    if (!pPlane || WorkspaceId < 0 || WorkspaceId >= KIBA_MAX_SPATIAL_WORKSPACES)
        return FALSE;

    g_SpatialPlanes[WorkspaceId] = *pPlane;
    return TRUE;
}

VOID SpatialWorkspace_AssignWindow(HWND hWnd, int WorkspaceId, float x, float y, float z)
{
    SpatialWorkspace_Init();
    if (!hWnd || !IsWindow(hWnd)) return;

    for (int i = 0; i < g_NumSpatialWindows; i++)
    {
        if (g_WindowSpatial[i].hWnd == hWnd)
        {
            g_WindowSpatial[i].WorkspaceId = WorkspaceId;
            g_WindowSpatial[i].RelX = x;
            g_WindowSpatial[i].RelY = y;
            g_WindowSpatial[i].DepthZ = z;
            return;
        }
    }

    if (g_NumSpatialWindows < _countof(g_WindowSpatial))
    {
        int idx = g_NumSpatialWindows++;
        g_WindowSpatial[idx].hWnd = hWnd;
        g_WindowSpatial[idx].WorkspaceId = WorkspaceId;
        g_WindowSpatial[idx].RelX = x;
        g_WindowSpatial[idx].RelY = y;
        g_WindowSpatial[idx].DepthZ = z;
        g_WindowSpatial[idx].Scale = 1.0f;
    }
}

BOOL SpatialWorkspace_GetWindowPos(HWND hWnd, KIBA_WINDOW_SPATIAL_POS *pPos)
{
    SpatialWorkspace_Init();
    if (!hWnd || !pPos) return FALSE;

    for (int i = 0; i < g_NumSpatialWindows; i++)
    {
        if (g_WindowSpatial[i].hWnd == hWnd)
        {
            *pPos = g_WindowSpatial[i];
            return TRUE;
        }
    }
    return FALSE;
}

VOID SpatialWorkspace_ApplySpatialTransformToWindows(VOID)
{
    SpatialWorkspace_Init();
    for (int i = 0; i < g_NumSpatialWindows; i++)
    {
        HWND hWnd = g_WindowSpatial[i].hWnd;
        if (!IsWindow(hWnd)) continue;

        if (g_WindowSpatial[i].WorkspaceId == g_ActiveWorkspaceId)
        {
            ShowWindow(hWnd, SW_SHOWNA);
        }
        else
        {
            ShowWindow(hWnd, SW_HIDE);
        }
    }
}
