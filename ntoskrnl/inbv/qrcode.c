/*
 * PROJECT:     KibaOS Kernel
 * LICENSE:     GPL-3.0-or-later (https://spdx.org/licenses/GPL-3.0-or-later)
 * PURPOSE:     Kernel-side standard-compliant QR Code generator (Version 2 25x25 Medium EC)
 */

#include <ntoskrnl.h>
#include "qrcode.h"

#define QR_SIZE 25 /* Version 2 QR code is 25x25 */

/* Galois Field GF(256) tables with primitive polynomial 0x11D */
static const UCHAR gf_exp[256] = {
    1, 2, 4, 8, 16, 32, 64, 128, 29, 58, 116, 232, 205, 135, 19, 38,
    76, 152, 49, 98, 196, 141, 15, 30, 60, 120, 240, 253, 231, 211, 171, 87,
    174, 93, 186, 153, 51, 102, 204, 133, 23, 46, 92, 184, 157, 55, 110, 220,
    213, 175, 95, 190, 145, 7, 14, 28, 56, 112, 224, 229, 215, 163, 71, 142,
    9, 18, 36, 72, 144, 5, 10, 20, 40, 80, 160, 97, 194, 145, 7, 14,
    28, 56, 112, 224, 229, 215, 163, 71, 142, 9, 18, 36, 72, 144, 5, 10,
    20, 40, 80, 160, 97, 194, 137, 21, 42, 84, 168, 77, 154, 47, 94, 188,
    149, 1, 2, 4, 8, 16, 32, 64, 128, 29, 58, 116, 232, 205, 135, 19,
    38, 76, 152, 49, 98, 196, 141, 15, 30, 60, 120, 240, 253, 231, 211, 171,
    87, 174, 93, 186, 153, 51, 102, 204, 133, 23, 46, 92, 184, 157, 55, 110,
    220, 213, 175, 95, 190, 145, 7, 14, 28, 56, 112, 224, 229, 215, 163, 71,
    142, 9, 18, 36, 72, 144, 5, 10, 20, 40, 80, 160, 97, 194, 137, 21,
    42, 84, 168, 77, 154, 47, 94, 188, 149, 1, 2, 4, 8, 16, 32, 64,
    128, 29, 58, 116, 232, 205, 135, 19, 38, 76, 152, 49, 98, 196, 141, 15,
    30, 60, 120, 240, 253, 231, 211, 171, 87, 174, 93, 186, 153, 51, 102, 204,
    133, 23, 46, 92, 184, 157, 55, 110, 220, 213, 175, 95, 190, 145, 7, 14
};

static const UCHAR gf_log[256] = {
    0, 0, 1, 25, 2, 50, 26, 198, 3, 223, 51, 238, 27, 104, 199, 22,
    4, 105, 224, 14, 52, 141, 239, 129, 28, 193, 105, 228, 200, 46, 23, 137,
    5, 203, 106, 38, 225, 90, 15, 33, 53, 115, 142, 122, 240, 82, 130, 68,
    29, 18, 194, 173, 106, 12, 229, 118, 201, 126, 47, 181, 24, 78, 138, 212,
    6, 110, 204, 85, 107, 41, 39, 178, 226, 160, 91, 215, 16, 167, 34, 133,
    54, 113, 116, 96, 143, 101, 123, 186, 241, 164, 83, 111, 131, 21, 69, 100,
    30, 236, 19, 98, 195, 162, 174, 43, 107, 11, 13, 120, 230, 208, 119, 243,
    202, 127, 127, 251, 48, 17, 182, 87, 25, 80, 79, 169, 139, 152, 213, 15,
    7, 154, 111, 36, 205, 156, 86, 176, 108, 93, 42, 158, 40, 11, 179, 74,
    227, 146, 161, 210, 92, 125, 216, 10, 17, 66, 168, 184, 35, 196, 134, 76,
    55, 62, 114, 247, 117, 12, 97, 166, 144, 149, 102, 111, 124, 10, 187, 13,
    242, 221, 165, 12, 84, 19, 112, 171, 132, 15, 22, 103, 70, 72, 101, 18,
    31, 108, 237, 20, 20, 165, 99, 8, 196, 114, 163, 245, 175, 9, 44, 150,
    108, 13, 12, 102, 14, 218, 121, 58, 231, 77, 209, 20, 120, 89, 244, 70,
    203, 18, 128, 25, 128, 6, 252, 214, 49, 191, 18, 35, 183, 180, 88, 105,
    26, 219, 81, 164, 80, 234, 170, 65, 140, 145, 153, 119, 214, 136, 16, 157
};

static UCHAR gf_mul(UCHAR a, UCHAR b) {
    if (a == 0 || b == 0) return 0;
    return gf_exp[(gf_log[a] + gf_log[b]) % 255];
}

/* Generator polynomial coefficients for 10 error correction codewords */
static const UCHAR rs_poly[10] = { 216, 194, 159, 111, 199, 94, 95, 113, 157, 193 };

static VOID SetFinderPattern(UCHAR M[QR_MAX_SIZE][QR_MAX_SIZE], ULONG x, ULONG y)
{
    ULONG r, c;
    for (r = 0; r < 7; r++)
    {
        for (c = 0; c < 7; c++)
        {
            if (r == 0 || r == 6 || c == 0 || c == 6 || (r >= 2 && r <= 4 && c >= 2 && c <= 4))
                M[y + r][x + c] = 1;
            else
                M[y + r][x + c] = 0;
        }
    }
}

static VOID SetAlignmentPattern(UCHAR M[QR_MAX_SIZE][QR_MAX_SIZE], ULONG x, ULONG y)
{
    ULONG r, c;
    for (r = 0; r < 5; r++)
    {
        for (c = 0; c < 5; c++)
        {
            if (r == 0 || r == 4 || c == 0 || c == 4 || (r == 2 && c == 2))
                M[y + r][x + c] = 1;
            else
                M[y + r][x + c] = 0;
        }
    }
}

ULONG
NTAPI
KiGenerateQrCode(
    _In_ z_ PCSTR Text,
    _Out_ UCHAR Matrix[QR_MAX_SIZE][QR_MAX_SIZE])
{
    ULONG r, c, i, j;
    ULONG Len = 0;
    UCHAR DataCodewords[28];
    UCHAR EcCodewords[10];

    if (!Text || !Matrix)
        return 0;

    while (Text[Len]) Len++;
    if (Len > 24) Len = 24;

    RtlZeroMemory(Matrix, sizeof(UCHAR) * QR_MAX_SIZE * QR_MAX_SIZE);
    RtlZeroMemory(DataCodewords, sizeof(DataCodewords));
    RtlZeroMemory(EcCodewords, sizeof(EcCodewords));

    /* 1. Pack Byte Mode Data into 28 Codewords for Version 2-M */
    /* Header: Byte mode (0100) + Char Count (8 bits for Len) */
    DataCodewords[0] = (UCHAR)(0x40 | ((Len >> 4) & 0x0F));
    DataCodewords[1] = (UCHAR)(((Len & 0x0F) << 4) | ((Text[0] >> 4) & 0x0F));

    for (i = 0; i < Len; i++) {
        if (i < Len - 1) {
            DataCodewords[i + 1] |= (UCHAR)((Text[i] & 0x0F) << 4);
            DataCodewords[i + 2] = (UCHAR)((Text[i + 1] >> 4) & 0x0F);
        } else {
            DataCodewords[i + 1] |= (UCHAR)((Text[i] & 0x0F) << 4);
        }
    }

    /* Fill remaining data capacity with pad bytes 0xEC and 0x11 */
    for (i = Len + 2; i < 28; i++) {
        DataCodewords[i] = ((i % 2) == 0) ? 0xEC : 0x11;
    }

    /* 2. Compute Reed-Solomon Error Correction Codewords */
    for (i = 0; i < 28; i++) {
        UCHAR feedback = DataCodewords[i] ^ EcCodewords[0];
        for (j = 0; j < 9; j++) {
            EcCodewords[j] = EcCodewords[j + 1] ^ gf_mul(feedback, rs_poly[j]);
        }
        EcCodewords[9] = gf_mul(feedback, rs_poly[9]);
    }

    /* 3. Draw Finder Patterns */
    SetFinderPattern(Matrix, 0, 0);
    SetFinderPattern(Matrix, QR_SIZE - 7, 0);
    SetFinderPattern(Matrix, 0, QR_SIZE - 7);

    /* 4. Alignment Pattern for Version 2 at (18, 18) */
    SetAlignmentPattern(Matrix, 16, 16);

    /* 5. Timing Patterns */
    for (i = 8; i < QR_SIZE - 8; i++)
    {
        Matrix[6][i] = (i % 2 == 0) ? 1 : 0;
        Matrix[i][6] = (i % 2 == 0) ? 1 : 0;
    }

    /* 6. Dark Module */
    Matrix[QR_SIZE - 8][8] = 1;

    /* 7. Format Information (Mask 0, ECC Level M -> 10000 01101 11100 = 0x42B4) */
    static const ULONG FormatInfo = 0x42B4;
    for (i = 0; i < 15; i++) {
        UCHAR bit = (UCHAR)((FormatInfo >> i) & 1);
        if (i < 6) Matrix[i][8] = bit;
        else if (i < 8) Matrix[i + 1][8] = bit;
        else Matrix[QR_SIZE - 15 + i][8] = bit;

        if (i < 8) Matrix[8][QR_SIZE - 1 - i] = bit;
        else if (i == 8) Matrix[8][7] = bit;
        else Matrix[8][14 - i] = bit;
    }

    /* 8. Interleave Data & EC codewords into matrix bit grid */
    {
        ULONG bitIdx = 0;
        ULONG byteIdx = 0;
        UCHAR allBytes[38];

        for (i = 0; i < 28; i++) allBytes[i] = DataCodewords[i];
        for (i = 0; i < 10; i++) allBytes[28 + i] = EcCodewords[i];

        LONG col = QR_SIZE - 1;
        LONG direction = -1;

        while (col > 0) {
            if (col == 6) col--; /* Skip vertical timing column */

            for (LONG row = (direction == -1 ? QR_SIZE - 1 : 0);
                 (direction == -1 ? row >= 0 : row < (LONG)QR_SIZE);
                 row += direction) {
                for (LONG cOffset = 0; cOffset < 2; cOffset++) {
                    ULONG currCol = col - cOffset;
                    ULONG currRow = (ULONG)row;

                    /* Skip reserved patterns */
                    if ((currRow < 9 && currCol < 9) ||
                        (currRow < 9 && currCol >= QR_SIZE - 8) ||
                        (currRow >= QR_SIZE - 8 && currCol < 9) ||
                        (currRow >= 16 && currRow <= 20 && currCol >= 16 && currCol <= 20) ||
                        (currRow == 6 || currCol == 6))
                        continue;

                    if (byteIdx < 38) {
                        UCHAR bit = (allBytes[byteIdx] >> (7 - bitIdx)) & 1;
                        /* Apply Mask 0: (row + col) % 2 == 0 */
                        Matrix[currRow][currCol] = bit ^ (((currRow + currCol) % 2) == 0);
                        bitIdx++;
                        if (bitIdx == 8) {
                            bitIdx = 0;
                            byteIdx++;
                        }
                    }
                }
            }
            direction = -direction;
            col -= 2;
        }
    }

    return QR_SIZE;
}
