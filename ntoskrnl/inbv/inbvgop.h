/*
 * PROJECT:     KibaOS Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     UEFI GOP-specific boot UI helpers
 * COPYRIGHT:   Copyright 2026 Ahmed ARIF (arif.ing@outlook.com)
 */

#pragma once

#include <ntddk.h>
#include <reactos/arc/arc.h>

#ifdef __cplusplus
extern "C" {
#endif

CODE_SEG("INIT")
BOOLEAN
NTAPI
InbvGopHandleBootBitmap(VOID);

CODE_SEG("INIT")
BOOLEAN
NTAPI
InbvQueryBgrtInfo(
    _Out_opt_ PLOADER_PARAMETER_BGRT BgrtInfo);

VOID
NTAPI
InbvGopLogoComplete(VOID);

VOID
NTAPI
InbvGopLogoStop(VOID);

VOID
NTAPI
InbvRenderCrashOverlay(VOID);

VOID
NTAPI
InbvRenderCrashAnimation(VOID);

VOID
NTAPI
InbvRenderCrashQrCode(
    _In_ z_ PCSTR Url,
    _In_ ULONG X,
    _In_ ULONG Y,
    _In_ ULONG ModulePixelSize);

VOID
NTAPI
InbvRenderBsodMascotScreen(
    _In_ ULONG BugCheckCode,
    _In_opt_ PCSTR BugCheckName);

#ifdef __cplusplus
}
#endif
