/*
 * PROJECT:     KibaOS Settings
 * LICENSE:     GPL-3.0-or-later
 * PURPOSE:     Updates settings page & full-screen foreground update UI
 */

#include "settings.h"
#include <reactos/ux_tokens.h>

void BuildUpdates(PageBuilder &page)
{
    page.Title = L"Updates";

    // Current Status Hero
    page.Hero(L"KibaOS is up to date", L"Build 10001 (x64) - Channel: Stable", L"checkmark_24_regular");

    // Primary Actions Group
    page.Group(L"Update Options");
    page.Button(L"Check for updates", L"Check HTTPS manifest for latest available updates", L"arrow_sync_20_regular", L"Check now", [](int action) {
        // Non-blocking background HTTPS check
    });

    page.Choice(L"Update channel", L"Select update distribution channel", L"channel_20_regular",
                { L"Stable (Recommended)", L"Beta", L"Developer" }, 0, [](int choice) {
        // Save channel preference
    });

    page.Toggle(L"Pause updates", L"Temporarily pause automatic background downloads", L"pause_20_regular", false, [](int state) {
        // Toggle background update pause
    });

    // History and Rollback
    page.Group(L"Recovery & History");
    page.Navigate(L"Update history", L"View installed updates and system changes", L"history_20_regular", PageId::About);

    page.Button(L"Roll back to previous version", L"Revert system files to the previous stable state if issues occur", L"arrow_undo_20_regular", L"Roll back", [](int action) {
        // Manual rollback trigger with confirmation
    });
}
