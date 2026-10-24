/*
 * KibaOS Predictive UI Engine Internal Shell Declarations
 */

#ifndef _EXPLORER_PREDICTIVE_UI_H_
#define _EXPLORER_PREDICTIVE_UI_H_

#include <reactos/predictive_ui.h>

#ifdef __cplusplus

#define MAX_POINTER_SAMPLES 16
#define MAX_TARGET_CANDIDATES 64

class CPredictiveUIEngine
{
private:
    PREDICTIVE_UI_SETTINGS m_Settings;
    PREDICTIVE_POINTER_SAMPLE m_PointerSamples[MAX_POINTER_SAMPLES];
    INT m_SampleHead;
    INT m_SampleCount;

    PREDICTIVE_TARGET_CANDIDATE m_Candidates[MAX_TARGET_CANDIDATES];
    INT m_CandidateCount;

    UINT_PTR m_ActiveInteractionTarget;
    BOOL m_bPointerDown;
    POINT m_LastPointerPt;

    VOID LoadSettingsFromRegistry();
    VOID SaveSettingsToRegistry();

public:
    CPredictiveUIEngine();
    ~CPredictiveUIEngine();

    VOID Initialize();
    VOID ResetProfileData();

    // Settings access
    BOOL IsEnabled() const { return (m_Settings.dwFlags & PREDICTIVE_UI_FLAG_ENABLED) != 0; }
    BOOL IsAdaptiveHitAreasEnabled() const { return (m_Settings.dwFlags & PREDICTIVE_UI_FLAG_ADAPTIVE_HIT_AREAS) != 0; }
    BOOL IsAdaptivePositionEnabled() const { return (m_Settings.dwFlags & PREDICTIVE_UI_FLAG_ADAPTIVE_POSITION) != 0; }

    VOID SetEnabled(BOOL bEnable);
    VOID SetAdaptiveHitAreasEnabled(BOOL bEnable);
    VOID SetAdaptivePositionEnabled(BOOL bEnable);

    PREDICTIVE_UI_SETTINGS GetSettings() const { return m_Settings; }
    VOID UpdateSettings(const PREDICTIVE_UI_SETTINGS& settings);

    // Candidate Target Management
    BOOL RegisterTarget(UINT_PTR TargetId, PREDICTIVE_TARGET_TYPE Type, HWND hWnd, const RECT& Bounds);
    BOOL UnregisterTarget(UINT_PTR TargetId);
    BOOL UpdateTargetBounds(UINT_PTR TargetId, const RECT& NewBounds);
    VOID ClearCandidates();

    // Signal Collection Pipeline
    VOID OnPointerMove(POINT Pt, DWORD TimeMs);
    VOID OnPointerDown(POINT Pt, UINT_PTR TargetId);
    VOID OnPointerUp(POINT Pt, UINT_PTR TargetId);
    VOID OnTargetSelected(UINT_PTR TargetId);

    // Feature Extraction & Prediction Calculation
    PREDICTIVE_TRAJECTORY CalculateTrajectory(const RECT& TargetBounds) const;
    VOID EvaluatePredictions();

    // Contextual Gravity & Gesture Grammar Calculations
    POINT CalculateContextualGravityVector(POINT Pt, FLOAT GravityStrength) const;
    INT RecognizePointerGesture() const;

    // Query Hit Testing & Adaptive Offsets
    BOOL HitTestTarget(UINT_PTR TargetId, POINT Pt, OUT RECT* pOutHitArea);
    POINT GetAdaptiveOffset(UINT_PTR TargetId);
    PREDICTIVE_CONFIDENCE_LEVEL GetTargetConfidence(UINT_PTR TargetId) const;

    // Safety & Stability Validation
    BOOL IsSafeToRepositionTarget(UINT_PTR TargetId) const;
};

extern CPredictiveUIEngine g_PredictiveEngine;

#endif // __cplusplus

// C Bridge Interface for C shell wrappers
#ifdef __cplusplus
extern "C" {
#endif

void PredictiveUI_Initialize(void);
void PredictiveUI_OnPointerMove(POINT Pt);
void PredictiveUI_OnPointerDown(POINT Pt, UINT_PTR TargetId);
void PredictiveUI_OnPointerUp(POINT Pt, UINT_PTR TargetId);
void PredictiveUI_OnTargetSelected(UINT_PTR TargetId);
BOOL PredictiveUI_HitTest(UINT_PTR TargetId, POINT Pt, RECT* pOutHitArea);
POINT PredictiveUI_GetAdaptiveOffset(UINT_PTR TargetId);
BOOL PredictiveUI_IsEnabled(void);
void PredictiveUI_ResetProfile(void);
POINT PredictiveUI_GetContextualGravityVector(POINT Pt, FLOAT GravityStrength);
INT PredictiveUI_RecognizeGesture(void);

#ifdef __cplusplus
}
#endif

#endif // _EXPLORER_PREDICTIVE_UI_H_
