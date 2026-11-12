WG MANAGER — RELEASE NOTES / CHANGELOG
Release: v2.14.1
Date: 2026-11-12
Baseline: v2.14.0

v2.14.1 — Self-update test release (no functional changes)
  * Test-only release to verify GitHub Actions publication, automatic
    version discovery, user-confirmed installation and backup/rollback.
  * No changes to WireGuard management, connection monitoring, router hooks,
    menus, user interface, configuration format, or update logic.
  * Only WG Manager version identifiers and release notes are changed.
  * The installed banner will display "WG Manager v2.14.1".

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

PRIOR RELEASES
v2.13.1 — Added dynamic Server VPN IPv4 in the main menu.
v2.13.0 — Redesigned menu colours, client tables, and connection snapshots;
           preserved all router-side WireGuard operations and status history.
v2.12.1 — Fixed the connection-history clear display behaviour.

UNCHANGED
  * GUI and script-managed clients remain separate and numerically sorted.
  * Peer creation/modification/deletion, LAN access policies, WireGuard startup
    hooks, server lifecycle, and history persistence are unchanged.
  * The existing backup/restore archive format remains .tar.gz.

INSTALL / FIRST-TIME UPGRADE
  The currently installed v2.13.1 does not have self-update capability.
  Install v2.14.0 once via SCP (port 99), after saving a backup of the old
  script. Subsequently, use menu item 7 for release updates and rollbacks.

  Staging example (replace USERNAME and ROUTER_HOST):
    scp -O -P 99 wg-manager.sh USERNAME@ROUTER_HOST:/jffs/wg-manager.sh

  Installation example:
    ssh -p 99 USERNAME@ROUTER_HOST 'sh -n /jffs/wg-manager.sh && cp -p /jffs/scripts/wg-manager.sh /jffs/scripts/wg-manager.sh.bak && chmod 700 /jffs/wg-manager.sh && mv /jffs/wg-manager.sh /jffs/scripts/wg-manager.sh'

SECURITY / LIMITATIONS
  * Updates use verified HTTPS and a release SHA-256 integrity manifest.
  * A checksum published alongside its script does NOT provide independent
    authenticity if the publisher's account/repository is compromised.
  * Enable release immutability and protect your GitHub account with 2FA.
  * Release assets contain only source and documentation, never router keys.
  * The updater requires a working curl and sha256sum on the router.
  * Update and rollback syntax checks cannot fully verify runtime behaviour;
    retain independent backups and test one router before updating the others.
  * Reverting from v2.14.0 to v2.13.1 (or earlier) requires the manually saved
    pre-upgrade backup; the built-in rollback accepts v2.14.0+ versioned copies.
