/*
 * KibaOS Design System UX Tokens
 *
 * Centralized design tokens for shell and presentation surfaces.
 * Violations of hardcoded raw visual literals in shell components are checked
 * by scripts/check_ux_tokens.py.
 */

#ifndef _UX_TOKENS_H_
#define _UX_TOKENS_H_

#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Color Tokens (COLORREF) */
#define UX_TOKEN_COLOR_ACCENT_PRIMARY       RGB(0, 120, 212)
#define UX_TOKEN_COLOR_ACCENT_HOVER         RGB(16, 110, 190)
#define UX_TOKEN_COLOR_ACCENT_PRESSED       RGB(0, 90, 158)
#define UX_TOKEN_COLOR_BACKGROUND_DARK      RGB(32, 32, 32)
#define UX_TOKEN_COLOR_BACKGROUND_LIGHT     RGB(243, 243, 243)
#define UX_TOKEN_COLOR_SURFACE_DARK         RGB(45, 45, 45)
#define UX_TOKEN_COLOR_SURFACE_LIGHT        RGB(255, 255, 255)
#define UX_TOKEN_COLOR_TEXT_PRIMARY_DARK    RGB(255, 255, 255)
#define UX_TOKEN_COLOR_TEXT_PRIMARY_LIGHT   RGB(0, 0, 0)
#define UX_TOKEN_COLOR_TEXT_SECONDARY_DARK  RGB(200, 200, 200)
#define UX_TOKEN_COLOR_TEXT_SECONDARY_LIGHT RGB(100, 100, 100)
#define UX_TOKEN_COLOR_BORDER_DARK          RGB(60, 60, 60)
#define UX_TOKEN_COLOR_BORDER_LIGHT         RGB(229, 229, 229)

/* Geometry and Corner Radii (DPI 96 base pixels) */
#define UX_TOKEN_CORNER_RADIUS_DEFAULT     8
#define UX_TOKEN_CORNER_RADIUS_SMALL       4
#define UX_TOKEN_CORNER_RADIUS_LARGE       12

/* Spacing and Padding Tokens (pixels) */
#define UX_TOKEN_MARGIN_SMALL              4
#define UX_TOKEN_MARGIN_MEDIUM             8
#define UX_TOKEN_MARGIN_LARGE              16
#define UX_TOKEN_MARGIN_XLARGE             24

#define UX_TOKEN_PADDING_SMALL             4
#define UX_TOKEN_PADDING_MEDIUM            8
#define UX_TOKEN_PADDING_LARGE             16

/* Font Size Tokens (points/pt) */
#define UX_TOKEN_FONT_SIZE_BODY            9
#define UX_TOKEN_FONT_SIZE_SUBTITLE        12
#define UX_TOKEN_FONT_SIZE_TITLE           16
#define UX_TOKEN_FONT_SIZE_HEADER          24

#ifdef __cplusplus
}
#endif

#endif /* _UX_TOKENS_H_ */
