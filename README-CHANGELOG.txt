WG MANAGER — RELEASE NOTES / CHANGELOG
Release: v2.14.2
Date: 2026-11-12
Baseline: v2.14.1

v2.14.2 — SHA-256 verifier compatibility fix
  * Fixed updater failure on ASUSWRT-Merlin models without a standalone
    sha256sum executable: "sha256sum is required to verify downloaded updates".
  * Verifier now tries sha256sum, the BusyBox sha256sum applet, and native
    OpenSSL dgst -sha256, in that order.
  * Keeps SHA-256 integrity verification mandatory. If no verifier works, or
    the downloaded file does not match the release manifest, update is aborted.
  * This release must be installed once via SCP on routers whose existing
    updater cannot locate sha256sum. Subsequent releases can update normally.
  * No WireGuard peer configuration, connection history, GUI, or router-hook
    functionality was changed.
