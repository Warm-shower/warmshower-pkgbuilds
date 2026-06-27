<div align="center">
  <h1 align="center">WarmShower OS PKGBUILDs</h1>
  <p align="center">Package build scripts for WarmShower OS — an AI-first Linux distribution based on Arch Linux.</p>
</div>

## Overview

This repository contains all [PKGBUILD](https://wiki.archlinux.org/index.php/PKGBUILD) scripts for packages maintained by the WarmShower OS project.

WarmShower OS packages are served from `https://repo.warmshower.ai/` once the repository infrastructure (WS-036) is live.

## Repository Layout

```
warmshower-pkgbuilds/
  warmshower-*/       — WarmShower OS identity packages
  docs/               — Engineering documentation
  .github/
    workflows/        — CI: validation, version checking, build & publish
    scripts/          — Helper scripts for CI and maintenance
    ISSUE_TEMPLATE/   — Standardized issue templates
  CODEOWNERS          — Code review requirements
```

## Using These Packages

**Install from the WarmShower repository (recommended):**

```bash
# Add WarmShower keyring and mirrorlist
sudo pacman -U https://repo.warmshower.ai/x86_64/warmshower-keyring-<ver>-any.pkg.tar.zst
sudo pacman -U https://repo.warmshower.ai/x86_64/warmshower-mirrorlist-<ver>-any.pkg.tar.zst

# Add [warmshower] to /etc/pacman.conf:
# [warmshower]
# Include = /etc/pacman.d/warmshower-mirrorlist

sudo pacman -Syu
```

**Build from source:**

```bash
git clone https://github.com/Warm-shower/warmshower-pkgbuilds.git
cd warmshower-pkgbuilds/<package>
makepkg -si
```

## Prerequisites

- [Git](https://git-scm.com/)
- [base-devel](https://archlinux.org/groups/x86_64/base-devel/) (includes gcc, make, binutils, fakeroot)

## Contributing

Please read [docs/repository-standards.md](docs/repository-standards.md) before contributing.

All PKGBUILD contributions must:
- Pass `namcap PKGBUILD` with no errors
- Pass `makepkg --verifysource` (no SKIP checksums on static sources)
- Follow the commit message format in repository-standards.md
- Be submitted via pull request (no direct pushes to master)

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODEOWNERS](CODEOWNERS) for review requirements.

## Infrastructure Status

| Component | Status |
|---|---|
| Package repository (`repo.warmshower.ai`) | Pending WS-036 |
| GPG signing key | Pending WS-001 |
| Cloudflare R2 bucket | Pending WS-036 |
| CI validation | ✅ Active |
| Version monitoring | ✅ Active |

## Links

- **Website:** [warmshower.ai](https://warmshower.ai)
- **Issues:** [github.com/Warm-shower/warmshower-pkgbuilds/issues](https://github.com/Warm-shower/warmshower-pkgbuilds/issues)
- **Engineering Spec:** MIGRATION_MASTER.md
