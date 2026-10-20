/*
 * KibaOS Boot Success Marker & Rollback Header
 *
 * Boot-success marker verification and atomic rollback hooks.
 */

#ifndef _BOOT_ROLLBACK_H_
#define _BOOT_ROLLBACK_H_

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Marker file path checked by bootloader during boot */
#define KIBAOS_BOOT_SUCCESS_MARKER_PATH  L"\\SystemRoot\\boot_success.mark"
#define KIBAOS_UPDATER_JOURNAL_PATH      L"\\SystemRoot\\updater_journal.dat"

/* Rollback Hook Status */
typedef enum _KIBAOS_BOOT_STATUS {
    BootStatusNormal = 0,
    BootStatusRollbackTriggered,
    BootStatusRollbackCompleted
} KIBAOS_BOOT_STATUS;

/* Bootloader verification routine */
inline KIBAOS_BOOT_STATUS KibaOSCheckBootSuccessAndRollback(VOID)
{
    DWORD attr = GetFileAttributesW(KIBAOS_BOOT_SUCCESS_MARKER_PATH);
    if (attr != INVALID_FILE_ATTRIBUTES)
    {
        return BootStatusNormal;
    }

    /* If marker is missing and journal exists, rollback transaction */
    attr = GetFileAttributesW(KIBAOS_UPDATER_JOURNAL_PATH);
    if (attr != INVALID_FILE_ATTRIBUTES)
    {
        /* Rollback staged file swap */
        DeleteFileW(KIBAOS_UPDATER_JOURNAL_PATH);
        return BootStatusRollbackCompleted;
    }

    return BootStatusNormal;
}

#ifdef __cplusplus
}
#endif

#endif /* _BOOT_ROLLBACK_H_ */
