/*
 * PROJECT:     KibaOS Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Kernel-side QR code generator for crash screens
 */

#ifndef _QRCODE_H_
#define _QRCODE_H_

#define QR_MAX_SIZE 33

/*
 * Generates a QR code matrix (up to 33x33) for the given null-terminated string.
 * Output matrix: 1 = dark module, 0 = light module.
 * Returns the size of the QR matrix (e.g. 21, 25, 29) or 0 on error.
 */
ULONG
NTAPI
KiGenerateQrCode(
    _In_ z_ PCSTR Text,
    _Out_ UCHAR Matrix[QR_MAX_SIZE][QR_MAX_SIZE]);

#endif /* _QRCODE_H_ */
