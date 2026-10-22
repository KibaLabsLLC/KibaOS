/*
 * KibaOS Predictive UI Engine Unit Test Suite
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>

// Mock Windows definitions for standalone Linux unit testing
#include "sdk/include/reactos/predictive_ui.h"

#ifndef _WIN32
#define TRUE 1
#define FALSE 0
#define ERROR_SUCCESS 0

static inline BOOL PtInRect(const RECT *lprc, POINT pt) {
    return (pt.x >= lprc->left && pt.x < lprc->right && pt.y >= lprc->top && pt.y < lprc->bottom);
}

static inline void InflateRect(RECT *lprc, int dx, int dy) {
    lprc->left -= dx;
    lprc->top -= dy;
    lprc->right += dx;
    lprc->bottom += dy;
}

static DWORD g_mockTick = 1000;
static DWORD GetTickCount(void) {
    return g_mockTick;
}
#endif

#define MAX_POINTER_SAMPLES 16
#define MAX_TARGET_CANDIDATES 64

class CPredictiveEngineTest
{
public:
    PREDICTIVE_UI_SETTINGS m_Settings;
    PREDICTIVE_POINTER_SAMPLE m_PointerSamples[MAX_POINTER_SAMPLES];
    INT m_SampleHead;
    INT m_SampleCount;

    PREDICTIVE_TARGET_CANDIDATE m_Candidates[MAX_TARGET_CANDIDATES];
    INT m_CandidateCount;

    UINT_PTR m_ActiveInteractionTarget;
    BOOL m_bPointerDown;
    POINT m_LastPointerPt;

    CPredictiveEngineTest()
        : m_SampleHead(0)
        , m_SampleCount(0)
        , m_CandidateCount(0)
        , m_ActiveInteractionTarget(0)
        , m_bPointerDown(FALSE)
    {
        m_LastPointerPt.x = 0;
        m_LastPointerPt.y = 0;

        m_Settings.dwFlags = PREDICTIVE_UI_FLAG_ENABLED |
                             PREDICTIVE_UI_FLAG_ADAPTIVE_HIT_AREAS |
                             PREDICTIVE_UI_FLAG_ADAPTIVE_POSITION;
        m_Settings.ModerateConfidenceThreshold = 0.45f;
        m_Settings.HighConfidenceThreshold = 0.75f;
        m_Settings.MaxHitAreaPadding = 12;
        m_Settings.MaxLayoutOffset = 6;

        memset(m_PointerSamples, 0, sizeof(m_PointerSamples));
        memset(m_Candidates, 0, sizeof(m_Candidates));
    }

    BOOL RegisterTarget(UINT_PTR TargetId, PREDICTIVE_TARGET_TYPE Type, HWND hWnd, const RECT& Bounds)
    {
        if (m_CandidateCount >= MAX_TARGET_CANDIDATES) return FALSE;
        PREDICTIVE_TARGET_CANDIDATE& cand = m_Candidates[m_CandidateCount++];
        cand.TargetId = TargetId;
        cand.TargetType = Type;
        cand.hWnd = hWnd;
        cand.OriginalBounds = Bounds;
        cand.AdaptiveHitArea = Bounds;
        cand.AdaptiveOffset.x = 0;
        cand.AdaptiveOffset.y = 0;
        cand.PredictionScore = 0.0f;
        cand.Confidence = PREDICTIVE_CONFIDENCE_NONE;
        cand.SelectionCount = 0;
        cand.LastSelectedTick = 0;
        return TRUE;
    }

    VOID OnPointerMove(POINT Pt, DWORD TimeMs)
    {
        m_LastPointerPt = Pt;
        m_PointerSamples[m_SampleHead].Pt = Pt;
        m_PointerSamples[m_SampleHead].TimeMs = TimeMs;
        m_SampleHead = (m_SampleHead + 1) % MAX_POINTER_SAMPLES;
        if (m_SampleCount < MAX_POINTER_SAMPLES) m_SampleCount++;
        EvaluatePredictions();
    }

    VOID OnPointerDown(POINT Pt, UINT_PTR TargetId)
    {
        m_bPointerDown = TRUE;
        m_ActiveInteractionTarget = TargetId;
        m_LastPointerPt = Pt;
    }

    VOID OnPointerUp(POINT Pt, UINT_PTR TargetId)
    {
        m_bPointerDown = FALSE;
        m_ActiveInteractionTarget = 0;
        m_LastPointerPt = Pt;
    }

    VOID OnTargetSelected(UINT_PTR TargetId)
    {
        for (INT i = 0; i < m_CandidateCount; ++i)
        {
            if (m_Candidates[i].TargetId == TargetId)
            {
                m_Candidates[i].SelectionCount++;
                m_Candidates[i].LastSelectedTick = GetTickCount();
                break;
            }
        }
    }

    PREDICTIVE_TRAJECTORY CalculateTrajectory(const RECT& TargetBounds) const
    {
        PREDICTIVE_TRAJECTORY traj = { 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
        if (m_SampleCount < 2) return traj;

        INT oldestIdx = (m_SampleHead - m_SampleCount + MAX_POINTER_SAMPLES) % MAX_POINTER_SAMPLES;
        INT newestIdx = (m_SampleHead - 1 + MAX_POINTER_SAMPLES) % MAX_POINTER_SAMPLES;

        const PREDICTIVE_POINTER_SAMPLE& p1 = m_PointerSamples[oldestIdx];
        const PREDICTIVE_POINTER_SAMPLE& p2 = m_PointerSamples[newestIdx];

        DWORD dt = (p2.TimeMs >= p1.TimeMs) ? (p2.TimeMs - p1.TimeMs) : 1;
        if (dt == 0) dt = 1;

        FLOAT dx = (FLOAT)(p2.Pt.x - p1.Pt.x);
        FLOAT dy = (FLOAT)(p2.Pt.y - p1.Pt.y);

        traj.VelocityX = dx / (FLOAT)dt;
        traj.VelocityY = dy / (FLOAT)dt;
        traj.Speed = sqrtf(traj.VelocityX * traj.VelocityX + traj.VelocityY * traj.VelocityY);
        traj.AngleRad = atan2f(dy, dx);

        LONG targetCenterX = (TargetBounds.left + TargetBounds.right) / 2;
        LONG targetCenterY = (TargetBounds.top + TargetBounds.bottom) / 2;

        FLOAT toTargetX = (FLOAT)(targetCenterX - p2.Pt.x);
        FLOAT toTargetY = (FLOAT)(targetCenterY - p2.Pt.y);
        FLOAT distToTarget = sqrtf(toTargetX * toTargetX + toTargetY * toTargetY);

        if (distToTarget > 0.001f && traj.Speed > 0.001f)
        {
            FLOAT dot = (dx * toTargetX + dy * toTargetY) / (sqrtf(dx*dx + dy*dy) * distToTarget);
            traj.Directness = (dot > 0.0f) ? ((dot < 1.0f) ? dot : 1.0f) : 0.0f;
        }

        return traj;
    }

    BOOL IsSafeToRepositionTarget(UINT_PTR TargetId) const
    {
        if (m_bPointerDown) return FALSE;
        for (INT i = 0; i < m_CandidateCount; ++i)
        {
            if (m_Candidates[i].TargetId == TargetId)
            {
                if (PtInRect(&m_Candidates[i].OriginalBounds, m_LastPointerPt) ||
                    PtInRect(&m_Candidates[i].AdaptiveHitArea, m_LastPointerPt))
                {
                    return FALSE;
                }
                break;
            }
        }
        return TRUE;
    }

    VOID EvaluatePredictions()
    {
        DWORD currentTick = GetTickCount();

        for (INT i = 0; i < m_CandidateCount; ++i)
        {
            PREDICTIVE_TARGET_CANDIDATE& cand = m_Candidates[i];
            PREDICTIVE_TRAJECTORY traj = CalculateTrajectory(cand.OriginalBounds);

            LONG centerX = (cand.OriginalBounds.left + cand.OriginalBounds.right) / 2;
            LONG centerY = (cand.OriginalBounds.top + cand.OriginalBounds.bottom) / 2;
            FLOAT dist = sqrtf((FLOAT)((m_LastPointerPt.x - centerX) * (m_LastPointerPt.x - centerX) +
                                       (m_LastPointerPt.y - centerY) * (m_LastPointerPt.y - centerY)));

            FLOAT distanceFactor = (1.0f - (dist / 600.0f) > 0.0f) ? (1.0f - (dist / 600.0f)) : 0.0f;
            FLOAT freqFactor = ((FLOAT)cand.SelectionCount / 20.0f < 1.0f) ? ((FLOAT)cand.SelectionCount / 20.0f) : 1.0f;

            DWORD elapsedMs = (currentTick >= cand.LastSelectedTick) ? (currentTick - cand.LastSelectedTick) : 0;
            FLOAT recencyFactor = (1.0f - ((FLOAT)elapsedMs / (1000.0f * 3600.0f)) > 0.0f) ? (1.0f - ((FLOAT)elapsedMs / (1000.0f * 3600.0f))) : 0.0f;

            FLOAT score = (traj.Directness * 0.40f) + (distanceFactor * 0.30f) + (freqFactor * 0.20f) + (recencyFactor * 0.10f);
            cand.PredictionScore = (score > 0.0f) ? ((score < 1.0f) ? score : 1.0f) : 0.0f;

            if (cand.PredictionScore >= m_Settings.HighConfidenceThreshold)
                cand.Confidence = PREDICTIVE_CONFIDENCE_HIGH;
            else if (cand.PredictionScore >= m_Settings.ModerateConfidenceThreshold)
                cand.Confidence = PREDICTIVE_CONFIDENCE_MODERATE;
            else if (cand.PredictionScore > 0.15f)
                cand.Confidence = PREDICTIVE_CONFIDENCE_LOW;
            else
                cand.Confidence = PREDICTIVE_CONFIDENCE_NONE;

            cand.AdaptiveHitArea = cand.OriginalBounds;
            if ((m_Settings.dwFlags & PREDICTIVE_UI_FLAG_ADAPTIVE_HIT_AREAS) && cand.Confidence >= PREDICTIVE_CONFIDENCE_MODERATE)
            {
                INT pad = (INT)(m_Settings.MaxHitAreaPadding * cand.PredictionScore);
                InflateRect(&cand.AdaptiveHitArea, pad, pad);
            }

            if ((m_Settings.dwFlags & PREDICTIVE_UI_FLAG_ADAPTIVE_POSITION) && cand.Confidence == PREDICTIVE_CONFIDENCE_HIGH && IsSafeToRepositionTarget(cand.TargetId))
            {
                FLOAT dirX = (FLOAT)(m_LastPointerPt.x - centerX);
                FLOAT dirY = (FLOAT)(m_LastPointerPt.y - centerY);
                FLOAT len = sqrtf(dirX * dirX + dirY * dirY);
                if (len > 0.001f)
                {
                    INT offsetPx = (INT)(m_Settings.MaxLayoutOffset * (cand.PredictionScore - m_Settings.HighConfidenceThreshold) / (1.0f - m_Settings.HighConfidenceThreshold));
                    cand.AdaptiveOffset.x = (LONG)((dirX / len) * offsetPx);
                    cand.AdaptiveOffset.y = (LONG)((dirY / len) * offsetPx);
                }
            }
            else
            {
                cand.AdaptiveOffset.x = 0;
                cand.AdaptiveOffset.y = 0;
            }
        }
    }

    BOOL HitTestTarget(UINT_PTR TargetId, POINT Pt, RECT* pOutHitArea)
    {
        for (INT i = 0; i < m_CandidateCount; ++i)
        {
            if (m_Candidates[i].TargetId == TargetId)
            {
                const RECT& hitArea = (m_Settings.dwFlags & PREDICTIVE_UI_FLAG_ADAPTIVE_HIT_AREAS) ? m_Candidates[i].AdaptiveHitArea : m_Candidates[i].OriginalBounds;
                if (pOutHitArea) *pOutHitArea = hitArea;
                return PtInRect(&hitArea, Pt);
            }
        }
        return FALSE;
    }
};

int main(void)
{
    printf("[Test 1] Initializing Predictive UI Engine...\n");
    CPredictiveEngineTest engine;

    RECT startBtnBounds = { 0, 1040, 48, 1080 }; // bottom-left start button
    assert(engine.RegisterTarget(101, PREDICTIVE_TARGET_START_BUTTON, NULL, startBtnBounds) == TRUE);

    printf("[Test 2] Simulating pointer motion trajectory towards Start Button...\n");
    POINT p1 = { 200, 800 };
    POINT p2 = { 100, 920 };
    POINT p3 = { 20, 1020 };

    engine.OnPointerMove(p1, 1000);
    engine.OnPointerMove(p2, 1020);
    engine.OnPointerMove(p3, 1040);

    PREDICTIVE_TARGET_CANDIDATE& target = engine.m_Candidates[0];
    printf("  Prediction Score: %.3f, Confidence Level: %d\n", target.PredictionScore, target.Confidence);
    assert(target.PredictionScore > 0.3f);
    assert(target.Confidence >= PREDICTIVE_CONFIDENCE_LOW);

    printf("[Test 3] Simulating high selection frequency and recency...\n");
    for (int i = 0; i < 15; ++i)
    {
        engine.OnTargetSelected(101);
    }
    engine.OnPointerMove(p3, 1050);

    printf("  High Frequency Prediction Score: %.3f, Confidence Level: %d\n", target.PredictionScore, target.Confidence);
    assert(target.Confidence >= PREDICTIVE_CONFIDENCE_MODERATE);
    assert(target.AdaptiveHitArea.left < startBtnBounds.left); // Expanded hit area

    printf("[Test 4] Testing Adaptive Hit Area expansion hit testing...\n");
    POINT nearPt = { -4, 1050 }; // Outside original bounds, but inside expanded hit area
    RECT hitRect;
    BOOL bHit = engine.HitTestTarget(101, nearPt, &hitRect);
    printf("  Hit Test near target: %s (HitArea: [%d, %d, %d, %d])\n",
           bHit ? "PASSED" : "FAILED", hitRect.left, hitRect.top, hitRect.right, hitRect.bottom);
    assert(bHit == TRUE);

    printf("[Test 5] Verifying Stability Safety Rules (Pointer down & hover protection)...\n");
    engine.OnPointerDown(p3, 101);
    assert(engine.IsSafeToRepositionTarget(101) == FALSE);

    engine.OnPointerUp(p3, 101);
    POINT hoverInside = { 10, 1050 };
    engine.OnPointerMove(hoverInside, 1060);
    assert(engine.IsSafeToRepositionTarget(101) == FALSE); // Hovering inside: target positioning locked for stability

    printf("\nAll Predictive UI Unit Tests PASSED Successfully!\n");
    return 0;
}
