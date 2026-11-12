WG MANAGER — RELEASE NOTES / CHANGELOG
Release: v2.14.0
Date: 2026-11-12
Baseline: v2.13.1

v2.14.0 — GitHub Releases updates and clearer connection status
  * Public release licensing: PolyForm Noncommercial License 1.0.0.
    See LICENSE and NOTICE. Commercial use is not permitted except for
    uses expressly allowed by the governing terms or law.
    Earlier valid GPL grants, if any, remain in effect for their copies.
  * Changed the main title to "WG Manager" with one visible installed version.
  * Added the latest available stable version below the server details:
    "Latest version: X.Y.Z [Update available]".
  * Retained one uninterrupted menu for options 1 through 5, with a blank
    line before options 6–7, and another before 0) Exit.
  * Renumbered Exit from 7 to 0; the menu now prompts "Select [0-7]:".
  * Added menu option 7, "Update WG Manager".
  * Added the Update submenu:
      1) Check installed and latest versions
      2) Update WG Manager
      3) Roll back to a previous version
      4) Back to main menu
  * Version checks occur during interactive menu use only and cache successful
    results for 12 hours. Failed automatic checks back off for 30 minutes.
    Installation is never automatic.
  * New update flow downloads the stable GitHub release manifest, displays
    release notes, and asks for confirmation before installing.
  * Downloads the exact tagged script, verifies SHA-256 and "sh -n", then
    creates a versioned backup and atomically replaces the installed script.
  * Added script-only rollback from saved update backups. No WireGuard peers,
    keys, firewall policy, status history or service settings are restored.
  * Client names on Connection status now show green for "recent", or yellow
    for "idle" when the last handshake is less than 24 hours old. Clients
    with older handshakes keep the default name colour.
  * Colours remain optional in noninteractive/dumb/NO_COLOR terminals.
  * The public release repository is configured as:
      https://github.com/silentdzen/asus-wg-manager
    If your actual repository owner differs, edit UPDATE_REPO before upload.
