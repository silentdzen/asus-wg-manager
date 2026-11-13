# WG Manager for ASUSWRT-Merlin

Manage ASUS WireGuard server `wgs1` peers beyond the 10 ASUS GUI client slots.
The script supports client listing, add/modify/delete, LAN policies, connection
history, backups and restores, and GitHub-release-based manual updates.

Requires an enabled native ASUS WireGuard
server (`wgs1`), JFFS custom scripts and administrative shell access.

## Installation

Enable SSH access, **JFFS custom scripts**, and the native ASUS WireGuard
server `wgs1` in your router's settings. Connect to the router over SSH as
administrator (use the SSH port you configured).

Run this **single command on the router**:

```sh
curl -fsSL https://raw.githubusercontent.com/silentdzen/asus-wg-manager/main/install.sh -o /tmp/wg-manager-install.sh && /bin/sh /tmp/wg-manager-install.sh
```

The installer retrieves the latest **published GitHub Release**, verifies the
`update-info.txt` SHA-256 checksum (with standalone `sha256sum`, BusyBox or
OpenSSL), checks syntax and version, and then installs
`/jffs/scripts/wg-manager.sh`. If WG Manager is already installed, it creates
a timestamped backup in `/jffs/wg-manager/backups/updates/` before replacement.
Any download, verification or backup failure stops installation without
replacing the current executable. It does not restart the WireGuard server or
modify client keys, policies, or connection history.

To start WG Manager after installation:

```sh
/jffs/scripts/wg-manager.sh
```

Future updates can be installed from **7) Update WG Manager** in the menu.
The one-line command downloads and runs `install.sh` from this public repository
with administrator privileges.

## Security and update behaviour

- Version checks are cached for 12 hours, with a 30-minute failure backoff;
  option 7 can force a fresh check at any time.
- Installing is always manual. The updater shows the changelog and asks for
  confirmation, verifies the release hash and syntax, backs up the current
  executable under `/jffs/wg-manager/backups/updates/`, then replaces it.
- Rollback restores only the executable; client keys, LAN policies and
  connection-history data are never modified by updates/rollbacks.
- Keep full, offline router configuration backups as a separate precaution.
