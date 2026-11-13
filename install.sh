#!/bin/sh
# WG Manager bootstrap installer for ASUSWRT-Merlin.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Required Notice: Copyright (c) 2026 silentdzen
# Licence: https://polyformproject.org/licenses/noncommercial/1.0.0/
# Downloads and validates a published GitHub Release before installation.

set -eu
umask 077
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/opt/sbin${PATH:+:$PATH}
export PATH

REPO='silentdzen/asus-wg-manager'
DEST='/jffs/scripts/wg-manager.sh'
STAGE="/jffs/scripts/.wg-manager-install.$$"
BACKUP_DIR='/jffs/wg-manager/backups/updates'

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

# Some ASUS firmware builds omit `command -v` and place utilities in /usr/sbin.
has_bin() {
  hb_name=$1
  hb_path=$PATH:
  while [ -n "$hb_path" ]; do
    hb_dir=${hb_path%%:*}
    hb_path=${hb_path#*:}
    [ -n "$hb_dir" ] || hb_dir=.
    if [ -f "$hb_dir/$hb_name" ] && [ -x "$hb_dir/$hb_name" ]; then
      return 0
    fi
  done
  return 1
}

# Do not rely on `id` or `command -v`: some router firmware omits them.
if ! awk '$1=="Uid:" {found=1; root=($3==0)} END {exit !(found && root)}' /proc/self/status 2>/dev/null; then
  fail 'Run as the router administrator (root).'
fi
[ -d /jffs ] || fail '/jffs is not available.'
[ "$(nvram get jffs2_scripts)" = 1 ] || fail 'Enable JFFS custom scripts in the ASUS router settings.'

mkdir -p /jffs/scripts || fail 'Could not create /jffs/scripts.'
(umask 077; mkdir "$STAGE") || fail 'Could not create a private staging directory.'
trap 'rm -rf "$STAGE"' 0
trap 'exit 1' 1 2 3 15

fetch() {
  curl --proto '=https' --proto-redir '=https' -fLsS \
    --connect-timeout 10 --max-time 90 --retry 2 \
    -o "$2" "$1"
}
valid_version() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+[.][0-9]+[.][0-9]+$'
}
valid_hash() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0123456789abcdefABCDEF]*) return 1 ;; esac
  return 0
}
lower_hash() { printf '%s\n' "$1" | tr 'ABCDEF' 'abcdef'; }
parse_manifest() {
  [ "$(grep -c '^VERSION=' "$1")" -eq 1 ] || return 1
  [ "$(grep -c '^SHA256=' "$1")" -eq 1 ] || return 1
  MANIFEST_VERSION=$(sed -n 's/^VERSION=//p' "$1")
  MANIFEST_HASH=$(sed -n 's/^SHA256=//p' "$1")
  valid_version "$MANIFEST_VERSION" || return 1
  valid_hash "$MANIFEST_HASH" || return 1
  MANIFEST_HASH=$(lower_hash "$MANIFEST_HASH")
  return 0
}
normalize_hash() {
  valid_hash "$1" || return 1
  lower_hash "$1"
}
file_sha256() {
  hash_file=$1
  if has_bin sha256sum; then
    hash_output=$(sha256sum "$hash_file" 2>/dev/null) && {
      hash_value=${hash_output%% *}
      normalize_hash "$hash_value" && return 0
    }
  fi
  if has_bin busybox; then
    hash_output=$(busybox sha256sum "$hash_file" 2>/dev/null) && {
      hash_value=${hash_output%% *}
      normalize_hash "$hash_value" && return 0
    }
  fi
  if has_bin openssl; then
    hash_output=$(openssl dgst -sha256 "$hash_file" 2>/dev/null) && {
      hash_value=${hash_output##* }
      normalize_hash "$hash_value" && return 0
    }
  fi
  return 1
}

info 'WG Manager — installing latest stable GitHub Release...'
latest="https://github.com/$REPO/releases/latest/download"
fetch "$latest/update-info.txt" "$STAGE/latest-info.txt" || fail 'Could not download the release manifest.'
parse_manifest "$STAGE/latest-info.txt" || fail 'Invalid release manifest.'
VERSION=$MANIFEST_VERSION
SHA=$MANIFEST_HASH

# Pin both files to the exact release tag to avoid a latest-release race.
base="https://github.com/$REPO/releases/download/v$VERSION"
fetch "$base/update-info.txt" "$STAGE/tagged-info.txt" || fail 'Could not download the tagged release manifest.'
parse_manifest "$STAGE/tagged-info.txt" || fail 'Invalid tagged release manifest.'
[ "$MANIFEST_VERSION" = "$VERSION" ] && [ "$MANIFEST_HASH" = "$SHA" ] || fail 'Release manifest changed unexpectedly.'
fetch "$base/wg-manager.sh" "$STAGE/wg-manager.sh" || fail 'Could not download wg-manager.sh.'

actual=$(file_sha256 "$STAGE/wg-manager.sh") || fail 'No working SHA-256 verifier (sha256sum, BusyBox or OpenSSL).'
[ "$actual" = "$SHA" ] || fail 'SHA-256 mismatch; existing installation is unchanged.'
[ "$(grep -c '^WG_MANAGER_VERSION=' "$STAGE/wg-manager.sh")" -eq 1 ] || fail 'Unexpected script version declaration.'
script_version=$(sed -n 's/^WG_MANAGER_VERSION=//p' "$STAGE/wg-manager.sh")
[ "$script_version" = "$VERSION" ] || fail 'Script version does not match the release manifest.'
sh -n "$STAGE/wg-manager.sh" || fail 'Script has shell syntax errors.'
chmod 700 "$STAGE/wg-manager.sh" || fail 'Could not set script permissions.'

[ ! -L "$DEST" ] || fail 'Installation target is a symbolic link; refusing to replace it.'
if [ -e "$DEST" ]; then
  [ -f "$DEST" ] || fail 'Existing installation is not a regular file.'
  mkdir -p "$BACKUP_DIR" || fail 'Could not create backup directory.'
  chmod 700 "$BACKUP_DIR" || fail 'Could not protect backup directory.'
  old_version=$(sed -n 's/^WG_MANAGER_VERSION=//p' "$DEST" | sed -n '1p')
  valid_version "$old_version" || old_version=legacy
  stamp=$(date +%Y%m%d-%H%M%S)
  backup="$BACKUP_DIR/$stamp-v$old_version-$$.sh"
  cp -p "$DEST" "$backup" || fail 'Could not back up existing installation; no changes made.'
  chmod 700 "$backup" || fail 'Could not protect backup; no changes made.'
  info "Previous version backed up to: $backup"
fi

mv "$STAGE/wg-manager.sh" "$DEST" || fail 'Could not install the verified script.'
info "WG Manager v$VERSION installed successfully."
info "Run: $DEST"
info 'Enable native ASUS WireGuard server wgs1 before launching the manager.'
