/*
 * PROJECT:     KibaOS Spatial 3D Workspaces Subsystem
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Spatial 3D Canvas Workspaces Engine Header
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF <arif193@gmail.com>
 */

#pragma once

#include <windows.h>

#define KIBA_MAX_SPATIAL_WORKSPACES 6

struct KIBA_SPATIAL_PLANE
{
    int WorkspaceId;
    WCHAR Name[64];
    float CameraX;
    float CameraY;
    float CameraZ;
    float Scale;
    float TiltAngle;
    COLORREF AccentColor;
    DWORD WindowCount;
};

struct KIBA_WINDOW_SPATIAL_POS
{
    HWND hWnd;
    int WorkspaceId;
    float RelX;
    float RelY;
    float DepthZ;
    float Scale;
};

VOID SpatialWorkspace_Init(VOID);
int SpatialWorkspace_GetActive(VOID);
BOOL SpatialWorkspace_Switch(int WorkspaceId);
BOOL SpatialWorkspace_GetPlane(int WorkspaceId, KIBA_SPATIAL_PLANE *pPlane);
BOOL SpatialWorkspace_SetPlane(int WorkspaceId, const KIBA_SPATIAL_PLANE *pPlane);
VOID SpatialWorkspace_AssignWindow(HWND hWnd, int WorkspaceId, float x, float y, float z);
BOOL SpatialWorkspace_GetWindowPos(HWND hWnd, KIBA_WINDOW_SPATIAL_POS *pPos);
VOID SpatialWorkspace_ApplySpatialTransformToWindows(VOID);
int SpatialWorkspace_GetTotalCount(VOID);
