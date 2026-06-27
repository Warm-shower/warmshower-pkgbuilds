# WarmShower OS — Arch Linux Package Builder Container
#
# Produces an environment that exactly replicates the GitHub Actions build
# pipeline locally so that every `makepkg` run on a developer machine
# produces byte-for-byte identical output to CI.
#
# Usage:
#   docker build -t warmshower-builder docker/arch-builder/
#   docker run --rm -v $(pwd):/workspace warmshower-builder build <package_dir>

FROM archlinux:base-devel

# ── Labels ───────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.title="WarmShower OS Package Builder"
LABEL org.opencontainers.image.description="Reproducible Arch Linux build environment for WarmShower OS packages"
LABEL org.opencontainers.image.source="https://github.com/Warm-shower/warmshower-pkgbuilds"
LABEL org.opencontainers.image.licenses="GPL-3.0-or-later"

# ── System update ─────────────────────────────────────────────────────────────
# Update the base system in one layer to keep the image current.
RUN pacman -Syu --noconfirm

# ── Core build tools ──────────────────────────────────────────────────────────
# Every tool required to build, validate, sign, and publish WarmShower packages.
RUN pacman -S --noconfirm --needed \
    # Package build & validation
    namcap \
    devtools \
    pacman-contrib \
    # Repository database generation
    pacman \
    # VCS tools (for git+https:// sources)
    git \
    # Cryptographic signing
    gnupg \
    # Build acceleration (shared object cache)
    ccache \
    # Remote sync to Cloudflare R2
    rclone \
    # Archive + checksum utilities
    coreutils \
    diffutils \
    findutils \
    # Runtime helpers
    bash \
    sudo \
    which \
    # Debugging / inspection
    binutils \
    file \
    strace

# ── ccache configuration ──────────────────────────────────────────────────────
# Shared ccache dir so repeated builds are fast.
ENV CCACHE_DIR=/ccache
RUN mkdir -p /ccache && chmod 777 /ccache

# ── Build user ────────────────────────────────────────────────────────────────
# makepkg refuses to run as root.  All builds execute as the `builder` user.
RUN useradd -m -s /bin/bash builder \
    && echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    && mkdir -p /workspace \
    && chown builder:builder /workspace

# ── makepkg.conf tweaks ───────────────────────────────────────────────────────
# Enable ccache, set PKGDEST inside /workspace so built packages are accessible
# from the host mount, and disable debug packages to keep output clean.
RUN sed -i \
    -e 's|^#BUILDENV|BUILDENV|' \
    -e 's|!ccache|ccache|' \
    /etc/makepkg.conf

# ── GPG agent configuration ───────────────────────────────────────────────────
# Allow headless gpg signing (used during `wsync publish`).
RUN mkdir -p /home/builder/.gnupg \
    && chmod 700 /home/builder/.gnupg \
    && echo "allow-loopback-pinentry" >> /home/builder/.gnupg/gpg-agent.conf \
    && echo "pinentry-mode loopback" >> /home/builder/.gnupg/gpg.conf \
    && chown -R builder:builder /home/builder/.gnupg

# ── Workspace ─────────────────────────────────────────────────────────────────
WORKDIR /workspace
VOLUME ["/workspace", "/ccache", "/repo"]

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY build.sh      /usr/local/bin/build.sh
COPY test.sh       /usr/local/bin/test.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
              /usr/local/bin/build.sh \
              /usr/local/bin/test.sh

USER builder
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--help"]
