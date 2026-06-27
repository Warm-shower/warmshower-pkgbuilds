# WarmShower OS — SUSPECT URL Investigation

> **Task:** WS-004
> **Status:** ✅ COMPLETE — investigated 2026-06-28
> **Date:** 2026-06-28

---

## Summary

All nine SUSPECT URLs (`github.com/CachyOS/warmshower-*`) were investigated.
**All nine return HTTP 404.** These repositories do not exist at the CachyOS org.

The correct upstream repositories exist under the standard CachyOS naming convention
(`cachyos-*`, not `warmshower-*`). Several forks already exist in the `Warm-shower` org.

---

## Investigation Results

| SUSPECT URL (broken) | Used By Package | Result | Correct Upstream | Action |
|---|---|---|---|---|
| `github.com/CachyOS/warmshower-update` | warmshower-update | ❌ 404 | No `cachyos-update` either — fork of `Antiz96/arch-update` | WS-040: fork arch-update |
| `github.com/CachyOS/warmshower-calamares` | warmshower-calamares | ❌ 404 | `Warm-shower/warmshower-calamares` already forked | WS-041: verify fork and tag |
| `github.com/CachyOS/warmshower-chroot` | warmshower-chroot | ❌ 404 | `Warm-shower/warmshower-chroot` already forked | WS-042: verify fork builds |
| `github.com/CachyOS/warmshower-hooks` | warmshower-hooks | ❌ 404 | `CachyOS/cachyos-hooks` EXISTS; `Warm-shower/warmshower-hooks` already forked | WS-043: verify fork and update PKGBUILD |
| `github.com/CachyOS/warmshower-zsh-config` | warmshower-zsh-config | ❌ 404 | `CachyOS/cachyos-zsh-config` EXISTS; no Warm-shower fork yet | WS-044: fork and update PKGBUILD |
| `github.com/CachyOS/warmshower-plymouth-theme` | warmshower-plymouth-theme | ❌ 404 | `CachyOS/cachyos-plymouth-theme` EXISTS; no Warm-shower fork yet | WS-045: fork and update PKGBUILD |
| `github.com/cachyos/warmshower-kde-settings` | warmshower-kde-settings | ❌ 404 | `CachyOS/cachyos-kde-settings` EXISTS; no Warm-shower fork yet | WS-046: fork and update PKGBUILD |
| `github.com/cachyos/warmshower-gnome-settings` | warmshower-gnome-settings | ❌ 404 | `CachyOS/cachyos-gnome-settings` EXISTS; `Warm-shower/warmshower-gnome-settings` forked | WS-047: verify fork and update PKGBUILD |
| `github.com/cachyos/warmshower-hyprland-settings` | warmshower-hyprland-settings | ❌ 404 | `CachyOS/cachyos-hyprland-settings` EXISTS; `Warm-shower/warmshower-hyprland-settings` forked | WS-048: verify fork and update PKGBUILD |

---

## Build Impact

Every package in the table above is **currently unbuildable** because its `source=` URL returns 404.
Any `makepkg` attempt will fail at source fetch.

**Affected packages (unbuildable):**
- warmshower-update
- warmshower-calamares
- warmshower-chroot
- warmshower-hooks
- warmshower-zsh-config
- warmshower-plymouth-theme (pkg variant)
- warmshower-kde-settings
- warmshower-gnome-settings
- warmshower-hyprland-settings

---

## Constraint: Do Not Change Source URLs Yet

Per MIGRATION_MASTER.md §14: PKGBUILD `source=` URLs must **not** be changed until the
replacement repository is forked, built, and tagged. A known-404 failure is safer than
pointing to an unverified fork.

**Order of operations for each package:**
1. Verify/create `Warm-shower/warmshower-<name>` fork
2. Verify the fork builds (`cargo build` / `cmake` / etc.)
3. Create a release tag matching `pkgver=`
4. Update `source=` in PKGBUILD to the new Warm-shower URL
5. Regenerate checksums (`makepkg -g`)
6. Update `validpgpkeys` if signing key changes
7. Commit with message: `pkgbuild: <pkg> — point source= to Warm-shower fork`

---

## Tracking Tasks (Phase 4)

| Task ID | Package | Action | Priority |
|---|---|---|---|
| WS-040 | warmshower-update | Fork Antiz96/arch-update → Warm-shower | HIGH |
| WS-041 | warmshower-calamares | Verify Warm-shower/warmshower-calamares; tag | HIGH |
| WS-042 | warmshower-chroot | Verify Warm-shower/warmshower-chroot; tag | HIGH |
| WS-043 | warmshower-hooks | Verify Warm-shower/warmshower-hooks; update PKGBUILD | HIGH |
| WS-044 | warmshower-zsh-config | Fork CachyOS/cachyos-zsh-config → Warm-shower | MEDIUM |
| WS-045 | warmshower-plymouth-theme | Fork CachyOS/cachyos-plymouth-theme → Warm-shower | HIGH |
| WS-046 | warmshower-kde-settings | Fork CachyOS/cachyos-kde-settings → Warm-shower | MEDIUM |
| WS-047 | warmshower-gnome-settings | Verify Warm-shower/warmshower-gnome-settings; update PKGBUILD | MEDIUM |
| WS-048 | warmshower-hyprland-settings | Verify Warm-shower/warmshower-hyprland-settings; update PKGBUILD | MEDIUM |
