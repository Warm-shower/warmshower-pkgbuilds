# WarmShower OS — Cloudflare R2 Setup Guide

> **Task:** WS-036
> **Status:** READY FOR IMPLEMENTATION — prerequisites: WS-001 (GPG key)
> **Date:** 2026-06-28

This document contains step-by-step instructions for setting up the WarmShower OS
package repository on Cloudflare R2.

---

## Repository URL Configuration

The repository URL is controlled by a **single variable** — never hardcoded:

```
WS_PACKAGE_REPOSITORY
```

Set this as a GitHub Actions **variable** (not a secret) at the org level.

| Phase | Value |
|---|---|
| Temporary (now) | `https://YOUR_R2_ACCOUNT_ID.r2.cloudflarestorage.com/warmshower` |
| Production (after DNS) | `https://repo.warmshower.ai` |

To switch from temporary to production: update `WS_PACKAGE_REPOSITORY` only.
No other files need to change.

---

## Prerequisites

- [ ] WS-001 complete (GPG signing key generated)
- [ ] WS-002 complete (warmshower-keyring updated with real key)
- [ ] Cloudflare account with `warmshower.ai` domain
- [ ] GitHub org-level secrets access

---

## Step 1: Create Cloudflare R2 Bucket

1. Log in to the [Cloudflare dashboard](https://dash.cloudflare.com)
2. Navigate to **R2 Object Storage**
3. Click **Create bucket**
4. Bucket name: `warmshower-repo`
5. Location: **Automatic**
6. Click **Create bucket**

---

## Step 2: Create R2 API Token

1. Go to **R2 → Manage R2 API Tokens**
2. Click **Create API Token**
3. Permissions: **Object Read & Write** (scoped to `warmshower-repo` bucket only)
4. Copy:
   - **Access Key ID** → `R2_ACCESS_KEY_ID`
   - **Secret Access Key** → `R2_SECRET_ACCESS_KEY`
5. Copy the **Account ID** from the R2 overview page → `R2_ACCOUNT_ID`

---

## Step 3: Configure Custom Domain (repo.warmshower.ai)

1. In Cloudflare dashboard: **R2 → warmshower-repo → Settings → Custom Domains**
2. Click **Connect Domain**
3. Enter: `repo.warmshower.ai`
4. Cloudflare creates the DNS record automatically
5. Verify: `https://repo.warmshower.ai/` should resolve once files are uploaded

---

## Step 4: Set GitHub Secrets and Variables

Navigate to: **GitHub → Warm-shower org → Settings → Secrets and variables → Actions**

### Secrets (sensitive — encrypted)

| Secret Name | Value |
|---|---|
| `R2_ACCESS_KEY_ID` | From Step 2 |
| `R2_SECRET_ACCESS_KEY` | From Step 2 |
| `R2_ACCOUNT_ID` | From Step 2 |
| `R2_BUCKET` | `warmshower-repo` |
| `WS_SIGNING_KEY` | GPG CI subkey armored export (see `docs/signing-architecture.md`) |
| `WS_SIGNING_KEY_PASSPHRASE` | GPG key passphrase |

### Variables (non-sensitive — visible in logs)

| Variable Name | Value |
|---|---|
| `WS_PACKAGE_REPOSITORY` | `https://YOUR_R2_ACCOUNT_ID.r2.cloudflarestorage.com/warmshower` (update to `https://repo.warmshower.ai` after DNS confirms) |

---

## Step 5: Test with First Package

```bash
# Trigger the publish workflow manually for a simple package
gh workflow run r2-publish.yml \
  -f package_dir=warmshower-mirrorlist-pkg \
  -f arch=x86_64
```

Expected: package uploaded to R2, `warmshower.db` created/updated.

---

## Step 6: Verify pacman Integration

On an Arch Linux machine:

```bash
# Add repo to pacman.conf
echo '[warmshower]
Server = https://repo.warmshower.ai/x86_64' | sudo tee -a /etc/pacman.conf

# Install keyring (unsigned bootstrap)
sudo pacman -U --noconfirm 'https://repo.warmshower.ai/x86_64/warmshower-keyring-*.pkg.tar.zst'

# Install mirrorlist
sudo pacman -U --noconfirm 'https://repo.warmshower.ai/x86_64/warmshower-mirrorlist-*.pkg.tar.zst'

# Sync
sudo pacman -Syu
pacman -Si warmshower-keyring
```

---

## Step 7: Update linux-warmshower CI (WS-009)

Once `repo.warmshower.ai` is serving packages, update `linux-warmshower/.github/workflows/build.yml`:

```yaml
# Replace:
Server = https://mirror.cachyos.org/repo/x86_64/cachyos

# With:
Server = ${{ vars.WS_PACKAGE_REPOSITORY }}/x86_64
```

---

## R2 Bucket Structure

```
warmshower-repo/          ← R2 bucket root (= WS_PACKAGE_REPOSITORY)
  x86_64/
    warmshower.db         ← pacman repository index
    warmshower.db.tar.gz
    warmshower.files
    warmshower.files.tar.gz
    *.pkg.tar.zst         ← signed packages
    *.pkg.tar.zst.sig     ← detached GPG signatures
  x86_64_v3/ …
  x86_64_v4/ …
  znver4/ …
```

---

## Cost Estimate

~50 packages × 15MB average:
- Storage: ~$0.01/month
- Egress: **$0** (R2 has zero egress fees)
- Requests: within free tier

---

## Rollback

To temporarily disable the repository:
1. Update `WS_PACKAGE_REPOSITORY` to an empty value or maintenance page
2. Revert linux-warmshower CI to CachyOS mirror (WS-009 revert)

R2 bucket contents are unaffected.
