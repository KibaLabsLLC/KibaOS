/*
 * KibaOS Predictive UI Engine Public SDK Header
 *
 * Provides native structures, constants, and interface definitions for
 * adaptive pointer interaction, hit area calculation, target layout bounds,
 * and profile management.
 */

#ifndef _PREDICTIVE_UI_H_
#define _PREDICTIVE_UI_H_

#ifdef _WIN32
#include <windows.h>
#else
typedef int INT;
typedef void VOID;
typedef int LONG;
typedef unsigned int DWORD;
typedef int BOOL;
typedef unsigned long UINT_PTR;
typedef void* HWND;
typedef float FLOAT;
typedef unsigned int UINT;

typedef struct _RECT {
    LONG left;
    LONG top;
    LONG right;
    LONG bottom;
} RECT;

typedef struct _POINT {
    LONG x;
    LONG y;
} POINT;
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Prediction Confidence Levels */
typedef enum _PREDICTIVE_CONFIDENCE_LEVEL
{
    PREDICTIVE_CONFIDENCE_NONE = 0,
    PREDICTIVE_CONFIDENCE_LOW = 1,      /* No visible change */
    PREDICTIVE_CONFIDENCE_MODERATE = 2, /* Reversible low-impact adaptive hit area */
    PREDICTIVE_CONFIDENCE_HIGH = 3      /* Bounded adaptive layout positioning */
} PREDICTIVE_CONFIDENCE_LEVEL;

/* Adaptive Feature Flags */
#define PREDICTIVE_UI_FLAG_ENABLED             0x00000001
#define PREDICTIVE_UI_FLAG_ADAPTIVE_HIT_AREAS  0x00000002
#define PREDICTIVE_UI_FLAG_ADAPTIVE_POSITION   0x00000004
#define PREDICTIVE_UI_FLAG_REDUCED_MOTION      0x00000008

/* Candidate Control Types */
typedef enum _PREDICTIVE_TARGET_TYPE
{
    PREDICTIVE_TARGET_UNKNOWN = 0,
    PREDICTIVE_TARGET_START_BUTTON,
    PREDICTIVE_TARGET_TASK_BUTTON,
    PREDICTIVE_TARGET_TRAY_ICON,
    PREDICTIVE_TARGET_QUICK_SETTING,
    PREDICTIVE_TARGET_DESKTOP_ICON,
    PREDICTIVE_TARGET_FLYOUT_BUTTON
} PREDICTIVE_TARGET_TYPE;

/* Target Candidate Record */
typedef struct _PREDICTIVE_TARGET_CANDIDATE
{
    UINT_PTR TargetId;
    PREDICTIVE_TARGET_TYPE TargetType;
    HWND hWnd;
    RECT OriginalBounds;
    RECT AdaptiveHitArea;
    POINT AdaptiveOffset;
    FLOAT PredictionScore; /* 0.0f to 1.0f */
    PREDICTIVE_CONFIDENCE_LEVEL Confidence;
    UINT SelectionCount;
    DWORD LastSelectedTick;
} PREDICTIVE_TARGET_CANDIDATE, *PPREDICTIVE_TARGET_CANDIDATE;

/* Pointer Movement Point Sample */
typedef struct _PREDICTIVE_POINTER_SAMPLE
{
    POINT Pt;
    DWORD TimeMs;
} PREDICTIVE_POINTER_SAMPLE, *PPREDICTIVE_POINTER_SAMPLE;

/* Interaction Trajectory Vector */
typedef struct _PREDICTIVE_TRAJECTORY
{
    FLOAT VelocityX; /* Pixels per millisecond */
    FLOAT VelocityY;
    FLOAT Speed;     /* Total velocity magnitude */
    FLOAT AngleRad;  /* Trajectory angle in radians */
    FLOAT Directness;/* Vector alignment towards target (0.0f - 1.0f) */
} PREDICTIVE_TRAJECTORY, *PPREDICTIVE_TRAJECTORY;

/* Configuration & Profile Settings */
typedef struct _PREDICTIVE_UI_SETTINGS
{
    DWORD dwFlags;
    FLOAT ModerateConfidenceThreshold; /* Default: 0.45f */
    FLOAT HighConfidenceThreshold;     /* Default: 0.75f */
    INT MaxHitAreaPadding;             /* Max extra hit px (e.g., 12px) */
    INT MaxLayoutOffset;               /* Max position shift px (e.g., 6px) */
} PREDICTIVE_UI_SETTINGS, *PPREDICTIVE_UI_SETTINGS;

#ifdef __cplusplus
}
#endif

#endif /* _PREDICTIVE_UI_H_ */
