# WG Manager for ASUSWRT-Merlin

Manage ASUS WireGuard server `wgs1` peers beyond the 10 ASUS GUI client slots.
The script supports client listing, add/modify/delete, LAN policies, connection
history, backups and restores, and GitHub-release-based manual updates.

**Current source release:** `v2.14.0`. Requires an enabled native ASUS WireGuard
server (`wgs1`), JFFS custom scripts and administrative shell access. Tested
syntactically with POSIX `sh` and BusyBox `ash` outside the router; live testing
on your router is recommended. No Entware required; the updater needs `curl`
and `sha256sum` from the firmware.

## Browser-based publishing

1. Create public repository `asus-wg-manager` on GitHub (default branch: `main`).
2. Upload `wg-manager.sh`, `README.md`, `README-CHANGELOG.txt`, `LICENSE`,
   and `NOTICE` to its root.
3. Create the workflow file at `.github/workflows/release.yml`, using the exact
   contents supplied with this package.
4. Open **Actions → Publish WG Manager release → Run workflow** (branch `main`)
   to create the initial v2.14.0 Release. Later script uploads to `main` will
   trigger a release automatically when `WG_MANAGER_VERSION` increases.
5. Confirm that `Releases` shows an asset called `update-info.txt` and a script
   asset named exactly `wg-manager.sh`. Enable release immutability under
   **Settings → General → Releases** for subsequent releases if available.

**Every new release**: Upload the new `wg-manager.sh` and matching
`README-CHANGELOG.txt` through **Add file → Upload files** on GitHub.com and
commit to `main`. The script must have a new `WG_MANAGER_VERSION=X.Y.Z`
assignment, and the changelog must mention `vX.Y.Z`. The workflow validates,
checks the version is newer than the latest release, generates `update-info.txt`
with the SHA-256 digest, produces a ZIP, and publishes the GitHub release.
Never upload WireGuard peer keys, `.conf` exports, or router backups publicly.

The updater currently points to `silentdzen/asus-wg-manager`:

```sh
UPDATE_REPO=silentdzen/asus-wg-manager
```

If your GitHub account has a different owner name, edit this line in
`wg-manager.sh` **before** uploading it or distributing it to your routers.

## Initial router installation (manual, once)

Upload the script as `wg-manager.sh` to `/jffs/wg-manager.sh`, then check its
syntax, preserve a copy of the previous executable and move the new file into
`/jffs/scripts/wg-manager.sh`. SSH port 99 is used in the following example.

```sh
scp -O -P 99 wg-manager.sh USERNAME@ROUTER_HOST:/jffs/wg-manager.sh
ssh -p 99 USERNAME@ROUTER_HOST 'sh -n /jffs/wg-manager.sh && cp -p /jffs/scripts/wg-manager.sh /jffs/scripts/wg-manager.sh.bak && chmod 700 /jffs/wg-manager.sh && mv /jffs/wg-manager.sh /jffs/scripts/wg-manager.sh'
```

## Security and update behaviour

- Version checks are cached for 12 hours, with a 30-minute failure backoff;
  option 7 can force a fresh check at any time.
- Installing is always manual. The updater shows the changelog and asks for
  confirmation, verifies the release hash and syntax, backs up the current
  executable under `/jffs/wg-manager/backups/updates/`, then replaces it.
- Rollback restores only the executable; client keys, LAN policies and
  connection-history data are never modified by updates/rollbacks.
- Enabling GitHub **immutable releases** helps protect published assets.
  A SHA-256 checksum from the same publisher is not an independent signature.
- Keep full, offline router configuration backups as a separate precaution.

## Licence and commercial permissions

WG Manager source code and the project's original documentation are
made available under the **PolyForm Noncommercial License 1.0.0**.
The governing terms are at
https://polyformproject.org/licenses/noncommercial/1.0.0/.
See `LICENSE` and `NOTICE` for the applicable URL and required notice.

**Commercial use is not licensed** except where the official terms
expressly permit the activity or applicable law provides an exception.
Separate written permission from the copyright holder is needed for
other commercial use. PolyForm expressly permits use by certain
noncommercial organisations, educational institutions and government bodies.

This is *source-available*, **not OSI-approved open-source software**.
The noncommercial licence applies only to versions published with these
terms, and does not revoke any valid rights previously granted under GPL.
Before publishing this change, confirm ownership or relicensing rights
for any third-party contributions incorporated in the script.

