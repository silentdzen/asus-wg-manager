WG Manager v2.14.4 — Changes

- Fixed shell syntax checks on ASUS routers where `sh` resolves to a non-shell utility.
- Use `/bin/sh -n` in installation, self-update, rollback, and backup restore validation.
- Updated the README installation command to invoke `/bin/sh` explicitly.
