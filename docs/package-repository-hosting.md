# WarmShower OS — Package Repository Hosting Decision

> **Task:** WS-036a
> **Status:** APPROVED DESIGN — implement via WS-036
> **Date:** 2026-06-28

---

## Decision: Cloudflare R2 + Cloudflare CDN

The WarmShower OS package repository (`[warmshower]`) will be hosted on **Cloudflare R2** with the Cloudflare CDN serving as the global delivery layer.

---

## Rationale

| Option | Cost | Egress | CDN | Complexity | Verdict |
|---|---|---|---|---|---|
| GitHub Releases + Pages | Free | GitHub CDN (throttled at scale) | Partial | Low | ❌ 100MB file limit; can't serve `warmshower.db` reliably at scale |
| Cloudflare R2 | $0.015/GB stored, $0 egress | Zero egress fees | ✅ Global Cloudflare CDN | Low | ✅ **CHOSEN** |
| Self-hosted VPS | ~$5–20/mo | Bandwidth costs | Needs separate CDN | High | ❌ Operational burden too high for Phase 3 |
| Backblaze B2 + CF | ~$0.006/GB stored | Zero via CF | ✅ | Medium | Viable alternative but split vendor |

R2 was chosen because:
- Zero egress fees (critical for a public package repository with many downloads)
- Native Cloudflare CDN integration via `r2.dev` custom domain
- S3-compatible API — any S3 upload tool (rclone, wrangler, aws-cli) works
- `repo.warmshower.ai` can be mapped directly to the R2 bucket via Cloudflare DNS
- No operational infrastructure to maintain

---

## Repository Structure

```
r2://warmshower-repo/
  x86_64/
    warmshower.db             ← pacman repository database (updated by repo-add)
    warmshower.db.tar.gz      ← same (symlink target)
    warmshower.files          ← file index
    warmshower.files.tar.gz   ← same
    *.pkg.tar.zst             ← signed packages
    *.pkg.tar.zst.sig         ← detached GPG signatures
  x86_64_v3/
    [same structure]
  x86_64_v4/
    [same structure]
  znver4/
    [same structure]
```

URL structure: `https://repo.warmshower.ai/x86_64/`

---

## CI Publishing Workflow

After a package is built and signed:

1. Upload `.pkg.tar.zst` and `.pkg.tar.zst.sig` to R2
2. Run `repo-add warmshower.db.tar.gz <package>.pkg.tar.zst` locally
3. Upload the updated `warmshower.db` and `warmshower.files` to R2
4. Cloudflare CDN cache is invalidated automatically (R2 + CF Workers integration)

### rclone configuration for R2

```toml
[warmshower-r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://<account-id>.r2.cloudflarestorage.com
```

Upload command:
```bash
rclone copy --checksum packages/ warmshower-r2:warmshower-repo/x86_64/
```

---

## Cloudflare DNS Setup

1. Create R2 bucket: `warmshower-repo`
2. Enable R2 public access or connect via Custom Domain
3. In Cloudflare DNS for `warmshower.ai`:
   - Add CNAME: `repo` → `<bucket>.r2.dev` (or Workers route)
4. `https://repo.warmshower.ai/x86_64/warmshower.db` must resolve and return the database

---

## Configurable Repository URL

The repository URL is a **single configurable variable** — never hardcoded anywhere:

**Variable name:** `WS_PACKAGE_REPOSITORY` (GitHub Actions variable, not a secret)

| Phase | Value |
|---|---|
| Temporary | `https://YOUR_R2_ACCOUNT_ID.r2.cloudflarestorage.com/warmshower` |
| Production | `https://repo.warmshower.ai` |

To switch from the temporary endpoint to production: update `WS_PACKAGE_REPOSITORY` only.
No workflows, scripts, or PKGBUILDs need to change. This is the sole configuration point.

Set it in: **GitHub → Warm-shower org → Settings → Secrets and variables → Actions → Variables**

---

## Cost Estimate

For a repository with 100 packages at ~30MB average:
- Storage: ~3GB × $0.015 = **$0.045/month**
- Operations: ~10K requests/day × 30 = **well within free tier** (10M requests/month free)
- Egress: **$0** (Cloudflare R2 has zero egress fees)

Even at 500 packages and 10x the download volume, cost stays under $1/month.

---

## mirrorlist-proxy-experiment Review

The `warmshower-src/mirrorlist-proxy-experiment` directory contains experimental work
on a mirror proxy. After review:

- The experiment predates the R2 decision
- A CDN-backed R2 bucket eliminates the need for a custom mirror proxy at this scale
- The experiment should be **archived** (not deleted — it may be useful if WarmShower
  grows to need custom mirror routing logic)
- No backlog task is needed until the project reaches 500+ packages

---

## GitHub Releases (Secondary Use)

GitHub Releases will still be used for:
- ISO files (large binary artifacts, one per release)
- Source tarballs of WarmShower-owned tools (wsync, etc.)
- Release changelogs and announcement text

GitHub Releases are **not** used for pacman package delivery — R2 is used for that.

---

## Implementation Checklist (WS-036)

- [ ] Create Cloudflare account (if not exists)
- [ ] Create R2 bucket `warmshower-repo`
- [ ] Configure `repo.warmshower.ai` DNS CNAME
- [ ] Verify HTTPS works at `https://repo.warmshower.ai/`
- [ ] Add `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY` to GitHub org secrets
- [ ] Add `rclone` to CI workflow
- [ ] Test upload of a signed test package
- [ ] Verify `pacman -Syu` resolves from WarmShower repo
- [ ] Update `warmshower-mirrorlist` to use `https://repo.warmshower.ai/repo/$arch/$repo`
- [ ] Update linux-warmshower CI pacman.conf (WS-009)
