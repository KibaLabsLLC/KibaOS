/*
 * KibaOS Centralized Error Catalog
 *
 * Defines structured error messages containing:
 * 1. What happened
 * 2. Why it happened
 * 3. What to do next
 */

#ifndef _UX_ERRORS_H_
#define _UX_ERRORS_H_

#include <windows.h>
#include <wininet.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _UX_ERROR_ENTRY {
    DWORD ErrorCode;
    LPCWSTR WhatHappened;
    LPCWSTR WhyItHappened;
    LPCWSTR WhatToDoNext;
} UX_ERROR_ENTRY;

static const UX_ERROR_ENTRY g_UxErrorCatalog[] = {
    {
        ERROR_ACCESS_DENIED,
        L"Access was denied.",
        L"You do not have sufficient permissions to modify this file or setting.",
        L"Please sign in with an Administrator account or check file ownership permissions."
    },
    {
        ERROR_FILE_NOT_FOUND,
        L"The requested file could not be found.",
        L"The file may have been moved, renamed, or deleted by another program.",
        L"Verify the path name or restore the file from backup."
    },
    {
        ERROR_CANCELLED,
        L"The operation was canceled.",
        L"A request to abort the task was issued by the user or system.",
        L"You can try running the operation again when ready."
    },
    {
        ERROR_INTERNET_CANNOT_CONNECT,
        L"Could not connect to the remote update server.",
        L"Your network adapter is disconnected or the server URL is unreachable.",
        L"Check your network settings in System Settings or verify your internet connection."
    }
};

inline const UX_ERROR_ENTRY* UxGetErrorEntry(DWORD errorCode)
{
    size_t i;
    for (i = 0; i < sizeof(g_UxErrorCatalog) / sizeof(g_UxErrorCatalog[0]); i++)
    {
        if (g_UxErrorCatalog[i].ErrorCode == errorCode)
            return &g_UxErrorCatalog[i];
    }
    return &g_UxErrorCatalog[0]; // Default fallback
}

#ifdef __cplusplus
}
#endif

#endif /* _UX_ERRORS_H_ */
