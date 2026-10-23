<p align="center">
<img width="600" alt="Kiba Labs banner" src="https://github.com/KibaLabsLLC/KibaOS/blob/5dae868ed1caac1629ebd14959d92f3b0216e5e6/GH_MEDIA/F37FC284-F214-4989-B85C-1256AE8F9BD8.png?raw=true" />
</p>

# Graphics, Desktop Window Manager, and UI Design System

This document outlines the architecture of KibaOS display driver infrastructure, window compositing engine, centralized design tokens, and user shell experience extensions.

## Display Driver Model (WDDM & Win32k)

KibaOS implements the Windows Display Driver Model (WDDM) kernel subsystem (`drivers/directx/dxgkrnl`):

- Win32k Thunk Interface: System call thunks located in `win32ss/gdi/ntgdi/d3dkmt.c` expose the `_REACTOS_WIN32K_DXGKRNL_INTERFACE` structure (`sdk/include/reactos/rddm/rxgkinterface.h`) to user-mode display drivers (UMDs).
- System Call Dispatch: Hardware allocations, resource creation, context submission, and vertical synchronization interrupts are routed through `d3dkmt` kernel thunks.

## Non-Client Window Frame Rendering (`dll/win32/uxtheme/nonclient.c`)

Window decoration and frame visuals are handled through UxTheme non-client drawing routines:

- Modern Corner Radius: Supports rounded window corners using radius constants (`DWM_CORNER_RADIUS_96` and `DWM_CORNER_RADIUS_SMALL_96` in `sdk/include/reactos/dwmframe.h`).
- Caption Controls: Renders fluent minimize, maximize, restore, and close buttons integrated with system visual style INI definitions (`media/themes/Win8/win8.msstyles/textfiles/`).

## Centralized UX Design System (`sdk/include/reactos/ux_tokens.h`)

KibaOS enforces visual consistency across the operating system using centralized design tokens validated via `scripts/check_ux_tokens.py`:

- Color Palette: Defines standard light and dark mode system visual colors (accent fills, surface brushes, border strokes, and backdrop acrylic colors).
- Metrics & Spacing: Standardized padding, margin, radius, and elevation depth metrics used across Explorer, flyouts, and control applets.

## Centralized UX Error Catalog (`sdk/include/reactos/ux_errors.h`)

User-facing error messages follow a structured 3-part diagnostic specification:

1. What Happened: Plain language summary of the failure condition.
2. Why: Technical cause or trigger context.
3. What to Do Next: Clear, actionable troubleshooting steps or options.

## Predictive UI Shell Engine (`base/shell/explorer/predictive_ui.cpp`)

The Predictive UI engine (`sdk/include/reactos/predictive_ui.h`) analyzes application launch patterns and desktop interactions to optimize responsiveness:

- Pre-rendering and Caching: Warm-starts frequently accessed shell components and flyouts in the background.
- Taskbar Integration: Interacts directly with `base/shell/explorer/traywnd.cpp` to dynamically highlight or preload active workflows.

## Kiba Desktop Companion (`base/shell/explorer/kiba_companion.cpp`)

The Kiba Desktop Companion provides interactive desktop mascot assistance and shell status updates:

- Visual Assets: Consumes sprite graphics from `media/graphics/kiba/`.
- Configuration: Controlled via registry key `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\KibaCompanion` (`Enabled` DWORD) and toggled via the Personalization page in System Settings (`base/applications/systemsettings/page_personal.cpp`).
- Unit Testing: Standalone test suite executed via `g++ -o test_kiba base/shell/explorer/test_kiba_companion.cpp && ./test_kiba`.
