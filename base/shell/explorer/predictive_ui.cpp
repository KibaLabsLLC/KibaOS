/*
 * KibaOS Predictive UI Engine Implementation
 */

#include "precomp.h"
#include "predictive_ui.h"
#include <math.h>

CPredictiveUIEngine g_PredictiveEngine;

static const WCHAR g_szPredictiveRegKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\PredictiveUI";
static const WCHAR g_szProfileRegKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\PredictiveUI\\Profile";

CPredictiveUIEngine::CPredictiveUIEngine()
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

    ZeroMemory(m_PointerSamples, sizeof(m_PointerSamples));
    ZeroMemory(m_Candidates, sizeof(m_Candidates));
}

CPredictiveUIEngine::~CPredictiveUIEngine()
{
}

VOID CPredictiveUIEngine::Initialize()
{
    LoadSettingsFromRegistry();
}

VOID CPredictiveUIEngine::LoadSettingsFromRegistry()
{
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, g_szPredictiveRegKey, 0, KEY_READ, &hKey) == ERROR_SUCCESS)
    {
        DWORD dwFlags = 0;
        DWORD cbData = sizeof(dwFlags);
        if (RegQueryValueExW(hKey, L"Flags", NULL, NULL, (LPBYTE)&dwFlags, &cbData) == ERROR_SUCCESS)
        {
            m_Settings.dwFlags = dwFlags;
        }
        RegCloseKey(hKey);
    }

    // Read stored targets profile
    if (RegOpenKeyExW(HKEY_CURRENT_USER, g_szProfileRegKey, 0, KEY_READ, &hKey) == ERROR_SUCCESS)
    {
        for (INT i = 0; i < m_CandidateCount; ++i)
        {
            WCHAR szValName[64];
            StringCchPrintfW(szValName, ARRAYSIZE(szValName), L"Target_%Iu_Count", m_Candidates[i].TargetId);
            DWORD dwCount = 0;
            DWORD cbData = sizeof(dwCount);
            if (RegQueryValueExW(hKey, szValName, NULL, NULL, (LPBYTE)&dwCount, &cbData) == ERROR_SUCCESS)
            {
                m_Candidates[i].SelectionCount = dwCount;
            }
        }
        RegCloseKey(hKey);
    }
}

VOID CPredictiveUIEngine::SaveSettingsToRegistry()
{
    HKEY hKey;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, g_szPredictiveRegKey, 0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL) == ERROR_SUCCESS)
    {
        RegSetValueExW(hKey, L"Flags", 0, REG_DWORD, (const BYTE*)&m_Settings.dwFlags, sizeof(m_Settings.dwFlags));
        RegCloseKey(hKey);
    }

    if (RegCreateKeyExW(HKEY_CURRENT_USER, g_szProfileRegKey, 0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL) == ERROR_SUCCESS)
    {
        for (INT i = 0; i < m_CandidateCount; ++i)
        {
            WCHAR szValName[64];
            StringCchPrintfW(szValName, ARRAYSIZE(szValName), L"Target_%Iu_Count", m_Candidates[i].TargetId);
            DWORD dwCount = (DWORD)m_Candidates[i].SelectionCount;
            RegSetValueExW(hKey, szValName, 0, REG_DWORD, (const BYTE*)&dwCount, sizeof(dwCount));
        }
        RegCloseKey(hKey);
    }
}

VOID CPredictiveUIEngine::ResetProfileData()
{
    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        m_Candidates[i].SelectionCount = 0;
        m_Candidates[i].LastSelectedTick = 0;
        m_Candidates[i].PredictionScore = 0.0f;
        m_Candidates[i].Confidence = PREDICTIVE_CONFIDENCE_NONE;
        m_Candidates[i].AdaptiveHitArea = m_Candidates[i].OriginalBounds;
        m_Candidates[i].AdaptiveOffset.x = 0;
        m_Candidates[i].AdaptiveOffset.y = 0;
    }

    RegDeleteKeyW(HKEY_CURRENT_USER, g_szProfileRegKey);
}

VOID CPredictiveUIEngine::SetEnabled(BOOL bEnable)
{
    if (bEnable)
        m_Settings.dwFlags |= PREDICTIVE_UI_FLAG_ENABLED;
    else
        m_Settings.dwFlags &= ~PREDICTIVE_UI_FLAG_ENABLED;

    SaveSettingsToRegistry();
}

VOID CPredictiveUIEngine::SetAdaptiveHitAreasEnabled(BOOL bEnable)
{
    if (bEnable)
        m_Settings.dwFlags |= PREDICTIVE_UI_FLAG_ADAPTIVE_HIT_AREAS;
    else
        m_Settings.dwFlags &= ~PREDICTIVE_UI_FLAG_ADAPTIVE_HIT_AREAS;

    SaveSettingsToRegistry();
}

VOID CPredictiveUIEngine::SetAdaptivePositionEnabled(BOOL bEnable)
{
    if (bEnable)
        m_Settings.dwFlags |= PREDICTIVE_UI_FLAG_ADAPTIVE_POSITION;
    else
        m_Settings.dwFlags &= ~PREDICTIVE_UI_FLAG_ADAPTIVE_POSITION;

    SaveSettingsToRegistry();
}

VOID CPredictiveUIEngine::UpdateSettings(const PREDICTIVE_UI_SETTINGS& settings)
{
    m_Settings = settings;
    SaveSettingsToRegistry();
}

BOOL CPredictiveUIEngine::RegisterTarget(UINT_PTR TargetId, PREDICTIVE_TARGET_TYPE Type, HWND hWnd, const RECT& Bounds)
{
    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        if (m_Candidates[i].TargetId == TargetId)
        {
            m_Candidates[i].TargetType = Type;
            m_Candidates[i].hWnd = hWnd;
            m_Candidates[i].OriginalBounds = Bounds;
            m_Candidates[i].AdaptiveHitArea = Bounds;
            return TRUE;
        }
    }

    if (m_CandidateCount >= MAX_TARGET_CANDIDATES)
        return FALSE;

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

    // Load persisted selection count for this newly registered target
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, g_szProfileRegKey, 0, KEY_READ, &hKey) == ERROR_SUCCESS)
    {
        WCHAR szValName[64];
        StringCchPrintfW(szValName, ARRAYSIZE(szValName), L"Target_%Iu_Count", cand.TargetId);
        DWORD dwCount = 0;
        DWORD cbData = sizeof(dwCount);
        if (RegQueryValueExW(hKey, szValName, NULL, NULL, (LPBYTE)&dwCount, &cbData) == ERROR_SUCCESS)
        {
            cand.SelectionCount = dwCount;
        }
        RegCloseKey(hKey);
    }

    return TRUE;
}

BOOL CPredictiveUIEngine::UnregisterTarget(UINT_PTR TargetId)
{
    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        if (m_Candidates[i].TargetId == TargetId)
        {
            for (INT j = i; j < m_CandidateCount - 1; ++j)
            {
                m_Candidates[j] = m_Candidates[j + 1];
            }
            m_CandidateCount--;
            return TRUE;
        }
    }
    return FALSE;
}

BOOL CPredictiveUIEngine::UpdateTargetBounds(UINT_PTR TargetId, const RECT& NewBounds)
{
    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        if (m_Candidates[i].TargetId == TargetId)
        {
            m_Candidates[i].OriginalBounds = NewBounds;
            m_Candidates[i].AdaptiveHitArea = NewBounds;
            return TRUE;
        }
    }
    return FALSE;
}

VOID CPredictiveUIEngine::ClearCandidates()
{
    m_CandidateCount = 0;
}

VOID CPredictiveUIEngine::OnPointerMove(POINT Pt, DWORD TimeMs)
{
    m_LastPointerPt = Pt;
    m_PointerSamples[m_SampleHead].Pt = Pt;
    m_PointerSamples[m_SampleHead].TimeMs = TimeMs;
    m_SampleHead = (m_SampleHead + 1) % MAX_POINTER_SAMPLES;
    if (m_SampleCount < MAX_POINTER_SAMPLES)
        m_SampleCount++;

    if (IsEnabled())
    {
        EvaluatePredictions();
    }
}

VOID CPredictiveUIEngine::OnPointerDown(POINT Pt, UINT_PTR TargetId)
{
    m_bPointerDown = TRUE;
    m_ActiveInteractionTarget = TargetId;
    m_LastPointerPt = Pt;
}

VOID CPredictiveUIEngine::OnPointerUp(POINT Pt, UINT_PTR TargetId)
{
    m_bPointerDown = FALSE;
    m_ActiveInteractionTarget = 0;
    m_LastPointerPt = Pt;
}

VOID CPredictiveUIEngine::OnTargetSelected(UINT_PTR TargetId)
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
    SaveSettingsToRegistry();
}

PREDICTIVE_TRAJECTORY CPredictiveUIEngine::CalculateTrajectory(const RECT& TargetBounds) const
{
    PREDICTIVE_TRAJECTORY traj = { 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
    if (m_SampleCount < 2)
        return traj;

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

    // Calculate directness towards target center
    LONG targetCenterX = (TargetBounds.left + TargetBounds.right) / 2;
    LONG targetCenterY = (TargetBounds.top + TargetBounds.bottom) / 2;

    FLOAT toTargetX = (FLOAT)(targetCenterX - p2.Pt.x);
    FLOAT toTargetY = (FLOAT)(targetCenterY - p2.Pt.y);
    FLOAT distToTarget = sqrtf(toTargetX * toTargetX + toTargetY * toTargetY);

    if (distToTarget > 0.001f && traj.Speed > 0.001f)
    {
        FLOAT dot = (dx * toTargetX + dy * toTargetY) / (sqrtf(dx*dx + dy*dy) * distToTarget);
        traj.Directness = max(0.0f, min(1.0f, dot));
    }

    return traj;
}

BOOL CPredictiveUIEngine::IsSafeToRepositionTarget(UINT_PTR TargetId) const
{
    // Stability Rule: Never move a target during active pointer click/drag interaction
    if (m_bPointerDown)
        return FALSE;

    // Stability Rule: Never move target underneath pointer if cursor is currently hovering inside target bounds
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

VOID CPredictiveUIEngine::EvaluatePredictions()
{
    DWORD currentTick = GetTickCount();

    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        PREDICTIVE_TARGET_CANDIDATE& cand = m_Candidates[i];
        PREDICTIVE_TRAJECTORY traj = CalculateTrajectory(cand.OriginalBounds);

        // Distance factor
        LONG centerX = (cand.OriginalBounds.left + cand.OriginalBounds.right) / 2;
        LONG centerY = (cand.OriginalBounds.top + cand.OriginalBounds.bottom) / 2;
        FLOAT dist = sqrtf((FLOAT)((m_LastPointerPt.x - centerX) * (m_LastPointerPt.x - centerX) +
                                   (m_LastPointerPt.y - centerY) * (m_LastPointerPt.y - centerY)));

        FLOAT distanceFactor = max(0.0f, 1.0f - (dist / 600.0f));

        // Frequency factor
        FLOAT freqFactor = min(1.0f, (FLOAT)cand.SelectionCount / 20.0f);

        // Recency factor
        DWORD elapsedMs = (currentTick >= cand.LastSelectedTick) ? (currentTick - cand.LastSelectedTick) : 0;
        FLOAT recencyFactor = max(0.0f, 1.0f - ((FLOAT)elapsedMs / (1000.0f * 3600.0f))); // 1 hr decay

        // Contextual Gravity calculation
        POINT gravVector = CalculateContextualGravityVector(m_LastPointerPt, 1.0f);
        FLOAT gravMag = sqrtf((FLOAT)(gravVector.x * gravVector.x + gravVector.y * gravVector.y));
        FLOAT gravBonus = min(0.15f, gravMag / 100.0f);

        // Score formulation
        FLOAT score = (traj.Directness * 0.35f) + (distanceFactor * 0.25f) + (freqFactor * 0.20f) + (recencyFactor * 0.10f) + gravBonus;
        cand.PredictionScore = max(0.0f, min(1.0f, score));

        // Assign Confidence Level
        if (cand.PredictionScore >= m_Settings.HighConfidenceThreshold)
        {
            cand.Confidence = PREDICTIVE_CONFIDENCE_HIGH;
        }
        else if (cand.PredictionScore >= m_Settings.ModerateConfidenceThreshold)
        {
            cand.Confidence = PREDICTIVE_CONFIDENCE_MODERATE;
        }
        else if (cand.PredictionScore > 0.15f)
        {
            cand.Confidence = PREDICTIVE_CONFIDENCE_LOW;
        }
        else
        {
            cand.Confidence = PREDICTIVE_CONFIDENCE_NONE;
        }

        // Adaptive Hit Area calculation
        cand.AdaptiveHitArea = cand.OriginalBounds;
        if (IsAdaptiveHitAreasEnabled() && cand.Confidence >= PREDICTIVE_CONFIDENCE_MODERATE)
        {
            INT pad = (INT)(m_Settings.MaxHitAreaPadding * cand.PredictionScore);
            InflateRect(&cand.AdaptiveHitArea, pad, pad);
        }

        // Adaptive Position Offset calculation
        if (IsAdaptivePositionEnabled() && cand.Confidence == PREDICTIVE_CONFIDENCE_HIGH && IsSafeToRepositionTarget(cand.TargetId))
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

POINT CPredictiveUIEngine::CalculateContextualGravityVector(POINT Pt, FLOAT GravityStrength) const
{
    POINT gravity = { 0, 0 };
    if (m_CandidateCount == 0 || GravityStrength <= 0.0f)
        return gravity;

    FLOAT sumX = 0.0f;
    FLOAT sumY = 0.0f;

    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        const PREDICTIVE_TARGET_CANDIDATE& cand = m_Candidates[i];
        LONG targetCenterX = (cand.OriginalBounds.left + cand.OriginalBounds.right) / 2;
        LONG targetCenterY = (cand.OriginalBounds.top + cand.OriginalBounds.bottom) / 2;

        FLOAT dx = (FLOAT)(targetCenterX - Pt.x);
        FLOAT dy = (FLOAT)(targetCenterY - Pt.y);
        FLOAT dist = sqrtf(dx * dx + dy * dy);

        if (dist > 0.1f && dist < 400.0f)
        {
            FLOAT pull = (cand.PredictionScore + 0.1f) * GravityStrength / (dist * 0.05f + 1.0f);
            sumX += (dx / dist) * pull * 10.0f;
            sumY += (dy / dist) * pull * 10.0f;
        }
    }

    gravity.x = (LONG)sumX;
    gravity.y = (LONG)sumY;
    return gravity;
}

INT CPredictiveUIEngine::RecognizePointerGesture() const
{
    if (m_SampleCount < 4)
        return 0; // Gesture Grammar: None

    INT oldestIdx = (m_SampleHead - m_SampleCount + MAX_POINTER_SAMPLES) % MAX_POINTER_SAMPLES;
    INT newestIdx = (m_SampleHead - 1 + MAX_POINTER_SAMPLES) % MAX_POINTER_SAMPLES;

    const PREDICTIVE_POINTER_SAMPLE& startSample = m_PointerSamples[oldestIdx];
    const PREDICTIVE_POINTER_SAMPLE& endSample = m_PointerSamples[newestIdx];

    LONG totalDx = endSample.Pt.x - startSample.Pt.x;
    LONG totalDy = endSample.Pt.y - startSample.Pt.y;
    FLOAT totalDist = sqrtf((FLOAT)(totalDx * totalDx + totalDy * totalDy));

    if (totalDist < 30.0f)
        return 0; // Insufficient stroke distance

    DWORD dt = (endSample.TimeMs >= startSample.TimeMs) ? (endSample.TimeMs - startSample.TimeMs) : 1;
    FLOAT speed = totalDist / (FLOAT)(dt ? dt : 1);

    if (speed < 0.2f)
        return 0; // Stroke too slow

    FLOAT angleRad = atan2f((FLOAT)totalDy, (FLOAT)totalDx);
    FLOAT angleDeg = angleRad * (180.0f / 3.14159265f);

    if (angleDeg < 0.0f)
        angleDeg += 360.0f;

    // Gesture Grammar classification:
    // 1: Flick Right (315° - 45°)
    // 2: Flick Down  (45° - 135°)
    // 3: Flick Left  (135° - 225°)
    // 4: Flick Up    (225° - 315°)
    if (angleDeg >= 315.0f || angleDeg < 45.0f)
        return 1; // Swipe/Flick Right
    else if (angleDeg >= 45.0f && angleDeg < 135.0f)
        return 2; // Swipe/Flick Down
    else if (angleDeg >= 135.0f && angleDeg < 225.0f)
        return 3; // Swipe/Flick Left
    else
        return 4; // Swipe/Flick Up
}

BOOL CPredictiveUIEngine::HitTestTarget(UINT_PTR TargetId, POINT Pt, OUT RECT* pOutHitArea)
{
    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        if (m_Candidates[i].TargetId == TargetId)
        {
            const RECT& hitArea = IsAdaptiveHitAreasEnabled() ? m_Candidates[i].AdaptiveHitArea : m_Candidates[i].OriginalBounds;
            if (pOutHitArea)
                *pOutHitArea = hitArea;

            return PtInRect(&hitArea, Pt);
        }
    }
    return FALSE;
}

POINT CPredictiveUIEngine::GetAdaptiveOffset(UINT_PTR TargetId)
{
    POINT ptOffset = { 0, 0 };
    if (!IsAdaptivePositionEnabled())
        return ptOffset;

    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        if (m_Candidates[i].TargetId == TargetId)
        {
            return m_Candidates[i].AdaptiveOffset;
        }
    }
    return ptOffset;
}

PREDICTIVE_CONFIDENCE_LEVEL CPredictiveUIEngine::GetTargetConfidence(UINT_PTR TargetId) const
{
    for (INT i = 0; i < m_CandidateCount; ++i)
    {
        if (m_Candidates[i].TargetId == TargetId)
        {
            return m_Candidates[i].Confidence;
        }
    }
    return PREDICTIVE_CONFIDENCE_NONE;
}

// C Interface Bridges
extern "C" {

void PredictiveUI_Initialize(void)
{
    g_PredictiveEngine.Initialize();
}

void PredictiveUI_OnPointerMove(POINT Pt)
{
    g_PredictiveEngine.OnPointerMove(Pt, GetTickCount());
}

void PredictiveUI_OnPointerDown(POINT Pt, UINT_PTR TargetId)
{
    g_PredictiveEngine.OnPointerDown(Pt, TargetId);
}

void PredictiveUI_OnPointerUp(POINT Pt, UINT_PTR TargetId)
{
    g_PredictiveEngine.OnPointerUp(Pt, TargetId);
}

void PredictiveUI_OnTargetSelected(UINT_PTR TargetId)
{
    g_PredictiveEngine.OnTargetSelected(TargetId);
}

BOOL PredictiveUI_HitTest(UINT_PTR TargetId, POINT Pt, RECT* pOutHitArea)
{
    return g_PredictiveEngine.HitTestTarget(TargetId, Pt, pOutHitArea);
}

POINT PredictiveUI_GetAdaptiveOffset(UINT_PTR TargetId)
{
    return g_PredictiveEngine.GetAdaptiveOffset(TargetId);
}

BOOL PredictiveUI_IsEnabled(void)
{
    return g_PredictiveEngine.IsEnabled();
}

void PredictiveUI_ResetProfile(void)
{
    g_PredictiveEngine.ResetProfileData();
}

POINT PredictiveUI_GetContextualGravityVector(POINT Pt, FLOAT GravityStrength)
{
    return g_PredictiveEngine.CalculateContextualGravityVector(Pt, GravityStrength);
}

INT PredictiveUI_RecognizeGesture(void)
{
    return g_PredictiveEngine.RecognizePointerGesture();
}

}
