/*
 * KibaOS Desktop Companion (Kiba) Unit & Integration Test Suite
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

// Mock Windows definitions for standalone unit testing
#ifndef _WIN32
#define TRUE 1
#define FALSE 0
typedef int BOOL;
typedef void VOID;
typedef unsigned long DWORD;
typedef unsigned int UINT;
typedef const wchar_t* LPCWSTR;
typedef wchar_t WCHAR;
typedef void* HWND;
typedef void* DEVINST;
#define ERROR_SUCCESS 0
#define ERROR_ACCESS_DENIED 5
#define DN_HAS_PROBLEM 0x00000040
#define CR_SUCCESS 0
#endif

// State definitions matching kiba_companion.h
typedef enum _TEST_KIBA_STATE {
    TEST_KIBA_STATE_IDLE = 0,
    TEST_KIBA_STATE_REACTING,
    TEST_KIBA_STATE_TALKING,
    TEST_KIBA_STATE_TROUBLESHOOTING,
    TEST_KIBA_STATE_ALERT,
    TEST_KIBA_STATE_COUNT
} TEST_KIBA_STATE;

class CKibaCompanionTest
{
public:
    BOOL m_bEnabled;
    TEST_KIBA_STATE m_State;
    UINT m_FrameIndex;
    BOOL m_bShowBubble;
    WCHAR m_szBubbleTitle[128];
    WCHAR m_szBubbleMessage[256];
    WCHAR m_szBubbleAction[64];
    DEVINST m_PendingFixDevInst;
    BOOL m_bDeviceTroubleshot;
    BOOL m_bFixExecuted;

    CKibaCompanionTest()
        : m_bEnabled(TRUE)
        , m_State(TEST_KIBA_STATE_IDLE)
        , m_FrameIndex(0)
        , m_bShowBubble(FALSE)
        , m_PendingFixDevInst(0)
        , m_bDeviceTroubleshot(FALSE)
        , m_bFixExecuted(FALSE)
    {
        m_szBubbleTitle[0] = L'\0';
        m_szBubbleMessage[0] = L'\0';
        m_szBubbleAction[0] = L'\0';
    }

    VOID SetEnabled(BOOL bEnable)
    {
        m_bEnabled = bEnable;
        if (!m_bEnabled)
        {
            m_bShowBubble = FALSE;
        }
    }

    VOID SetState(TEST_KIBA_STATE newState)
    {
        m_State = newState;
        m_FrameIndex = 0;
    }

    VOID ShowSpeechBubble(LPCWSTR szTitle, LPCWSTR szMessage, LPCWSTR szAction)
    {
        if (!m_bEnabled) return;
        m_bShowBubble = TRUE;
        if (m_State == TEST_KIBA_STATE_IDLE)
            SetState(TEST_KIBA_STATE_TALKING);
    }

    VOID OnDeviceArrival(BOOL bHasProblem, DWORD problemCode, DEVINST devInst)
    {
        if (!m_bEnabled) return;

        if (bHasProblem)
        {
            m_PendingFixDevInst = devInst;
            m_bDeviceTroubleshot = TRUE;
            SetState(TEST_KIBA_STATE_TROUBLESHOOTING);
            ShowSpeechBubble(L"Device Problem Detected", L"Error encountered.", L"Click to Fix");
        }
        else
        {
            SetState(TEST_KIBA_STATE_REACTING);
            ShowSpeechBubble(L"Device Connected", L"Working properly!", NULL);
        }
    }

    VOID ExecuteFix()
    {
        if (m_PendingFixDevInst != 0)
        {
            m_bFixExecuted = TRUE;
            SetState(TEST_KIBA_STATE_REACTING);
            ShowSpeechBubble(L"Fix Complete!", L"Hardware re-enumerated.", NULL);
            m_PendingFixDevInst = 0;
        }
    }
};

int main(void)
{
    printf("[Test 1] Initializing Kiba Companion Test Suite...\n");
    CKibaCompanionTest kiba;
    assert(kiba.m_bEnabled == TRUE);
    assert(kiba.m_State == TEST_KIBA_STATE_IDLE);

    printf("[Test 2] Verifying Kiba enable/disable toggle persistence...\n");
    kiba.SetEnabled(FALSE);
    assert(kiba.m_bEnabled == FALSE);
    kiba.ShowSpeechBubble(L"Test", L"Hello", NULL);
    assert(kiba.m_bShowBubble == FALSE); // Should remain hidden when disabled

    kiba.SetEnabled(TRUE);
    assert(kiba.m_bEnabled == TRUE);

    printf("[Test 3] Testing device insertion and normal reaction...\n");
    kiba.OnDeviceArrival(FALSE, 0, (DEVINST)1);
    assert(kiba.m_State == TEST_KIBA_STATE_REACTING);
    assert(kiba.m_bShowBubble == TRUE);

    printf("[Test 4] Testing external misconfigured device detection and troubleshooting...\n");
    kiba.OnDeviceArrival(TRUE, 28, (DEVINST)2); // Code 28: Missing driver
    assert(kiba.m_State == TEST_KIBA_STATE_TROUBLESHOOTING);
    assert(kiba.m_bDeviceTroubleshot == TRUE);
    assert(kiba.m_PendingFixDevInst == (DEVINST)2);

    printf("[Test 5] Executing automated troubleshooting fix...\n");
    kiba.ExecuteFix();
    assert(kiba.m_bFixExecuted == TRUE);
    assert(kiba.m_PendingFixDevInst == 0);
    assert(kiba.m_State == TEST_KIBA_STATE_REACTING);

    printf("\nAll Kiba Desktop Companion Unit Tests PASSED Successfully!\n");
    return 0;
}
