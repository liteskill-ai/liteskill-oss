#!/usr/bin/env bash
#
# Shared desktop build script used by both Docker and GitHub Actions CI.
# Handles everything after system dependencies + toolchains are installed:
#   ERTS packaging → PG fetch → Elixir build → Burrito → Tauri → post-process
#
# Usage:
#   MIX_ENV=prod bash scripts/build-desktop.sh <target-triple>
#
# Requires on PATH: erl, elixir, node, npm, cargo, cargo-tauri, zig
# Linux also requires: patchelf
#
# Supported triples:
#   x86_64-unknown-linux-gnu
#   aarch64-apple-darwin
#
set -euo pipefail

TRIPLE="${1:?Usage: $0 <target-triple>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "==> [build-desktop] $*"; }

# ---------------------------------------------------------------------------
# Phase 0: Validate environment & resolve target
# ---------------------------------------------------------------------------
if [ "${MIX_ENV:-}" != "prod" ]; then
  echo "ERROR: MIX_ENV must be set to 'prod'" >&2
  exit 1
fi

case "$TRIPLE" in
  x86_64-unknown-linux-gnu)
    BURRITO_TARGET="linux_x86_64"
    ;;
  aarch64-apple-darwin)
    BURRITO_TARGET="macos_aarch64"
    ;;
  x86_64-apple-darwin)
    BURRITO_TARGET="macos_x86_64"
    ;;
  *)
    echo "ERROR: Unsupported target triple: $TRIPLE" >&2
    echo "Supported: x86_64-unknown-linux-gnu, aarch64-apple-darwin, x86_64-apple-darwin" >&2
    exit 1
    ;;
esac

log "Target triple: $TRIPLE"
log "Burrito target: $BURRITO_TARGET"

# ---------------------------------------------------------------------------
# Phase 1: Package glibc ERTS for Burrito (Linux only)
# ---------------------------------------------------------------------------
# Burrito's default is musl-linked ERTS, which conflicts with glibc NIFs
# (MDEx, argon2). Tar up the glibc-linked ERTS and tell Burrito to use it.
# On macOS, Burrito downloads a universal precompiled ERTS — no custom ERTS needed.
case "$TRIPLE" in
  *-linux-*)
    log "Packaging glibc ERTS for Burrito..."

    ERTS_DIR="$(dirname "$(dirname "$(which erl)")")/lib/erlang"
    if [ ! -d "$ERTS_DIR" ]; then
      echo "ERROR: ERTS directory not found at $ERTS_DIR" >&2
      exit 1
    fi

    # Bundle OpenSSL libs alongside crypto.so when they're dynamically linked.
    # Both Docker and CI compile Erlang with --disable-dynamic-ssl-lib (static SSL)
    # via setup-erlang-elixir.sh, so ldd won't find libssl/libcrypto and the copy
    # loop below is a no-op. Kept for safety in case a future environment uses
    # a dynamically-linked Erlang.
    CRYPTO_SO="$(find "$ERTS_DIR" -name crypto.so -print -quit)"
    if [ -n "$CRYPTO_SO" ]; then
      CRYPTO_DIR="$(dirname "$CRYPTO_SO")"
      ldd "$CRYPTO_SO" | grep -oP '/\S+lib(ssl|crypto)\.so\S*' | while read -r lib; do
        cp -L "$lib" "$CRYPTO_DIR/"
        log "Bundled $(basename "$lib") into ERTS"
      done || true  # grep returns 1 when no matches (static SSL) — not an error
      # Only patch rpath if we actually copied libs
      if ldd "$CRYPTO_SO" | grep -q 'libssl\.so'; then
        patchelf --set-rpath '$ORIGIN' "$CRYPTO_SO"
        log "Patched crypto.so rpath to \$ORIGIN"
      fi
    fi

    tar czf /tmp/glibc_erts.tar.gz -C "$ERTS_DIR" .
    export BURRITO_CUSTOM_ERTS=/tmp/glibc_erts.tar.gz
    log "Packaged glibc ERTS from $ERTS_DIR"
    ;;
  *)
    log "Skipping ERTS packaging (not needed for $TRIPLE)"
    ;;
esac

# ---------------------------------------------------------------------------
# Phase 2: Fetch PostgreSQL binaries (skip if already cached)
# ---------------------------------------------------------------------------
if [ -f "$PROJECT_ROOT/priv/postgres/$TRIPLE/bin/initdb" ]; then
  log "PostgreSQL binaries already present (cache hit), skipping fetch"
else
  log "Fetching PostgreSQL binaries..."
  bash "$SCRIPT_DIR/fetch-postgres.sh" "$TRIPLE"
fi
log "PG binaries:" && ls -la "$PROJECT_ROOT/priv/postgres/$TRIPLE/bin/"

# ---------------------------------------------------------------------------
# Phase 3: Elixir build
# ---------------------------------------------------------------------------
log "Building Elixir release..."
cd "$PROJECT_ROOT"

# Ensure HOME is set so mix local.hex/rebar can write to ~/.mix
export HOME="${HOME:-/root}"

mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
npm install --prefix assets
mix compile
mix assets.deploy

# ---------------------------------------------------------------------------
# Phase 4: Burrito release
# ---------------------------------------------------------------------------
log "Building Burrito release..."
export BURRITO_TARGET="$BURRITO_TARGET"
mix release desktop --overwrite
log "Burrito output:" && ls -la burrito_out/

# ---------------------------------------------------------------------------
# Phase 5: Rename Burrito output for Tauri sidecar naming
# ---------------------------------------------------------------------------
# Burrito outputs: burrito_out/desktop_<burrito_target>
# Tauri expects:   burrito_out/desktop-<target-triple>
BURRITO_OUT="burrito_out/desktop_${BURRITO_TARGET}"
SIDECAR_NAME="burrito_out/desktop-${TRIPLE}"

if [ -f "$BURRITO_OUT" ]; then
  mv "$BURRITO_OUT" "$SIDECAR_NAME"
  log "Renamed sidecar: $BURRITO_OUT -> $SIDECAR_NAME"
else
  echo "ERROR: Burrito output not found at $BURRITO_OUT" >&2
  ls -la burrito_out/
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase 6: Build Tauri app
# ---------------------------------------------------------------------------
log "Building Tauri app..."

# Sync Tauri version from the project VERSION file
APP_VERSION="$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')"
log "Setting Tauri version to $APP_VERSION"
# sed -i behaves differently on macOS (BSD) vs Linux (GNU).
# Using .bak suffix works on both, then remove the backup.
sed -i.bak "s/\"version\": \".*\"/\"version\": \"$APP_VERSION\"/" "$PROJECT_ROOT/src-tauri/tauri.conf.json"
rm -f "$PROJECT_ROOT/src-tauri/tauri.conf.json.bak"

cd "$PROJECT_ROOT/src-tauri"
cargo tauri build
cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Phase 7: Platform-specific post-processing
# ---------------------------------------------------------------------------
case "$TRIPLE" in
  *-linux-*)
    # Strip bundled Wayland libs from AppImage.
    # linuxdeploy bundles libwayland-*.so from the build host. These conflict
    # with the host system's Wayland/EGL stack at runtime, causing WebKitGTK
    # to crash with "Could not create default EGL display: EGL_BAD_PARAMETER".
    APPIMAGE=$(find src-tauri/target/release/bundle/appimage -name '*.AppImage' -print -quit 2>/dev/null || true)
    if [ -n "$APPIMAGE" ]; then
      log "Stripping Wayland libs from AppImage..."
      chmod +x "$APPIMAGE"
      "$APPIMAGE" --appimage-extract
      rm -vf squashfs-root/usr/lib/*wayland*so*
      wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
      chmod +x appimagetool-x86_64.AppImage
      APPIMAGE_EXTRACT_AND_RUN=1 ./appimagetool-x86_64.AppImage squashfs-root "$APPIMAGE"
      rm -rf squashfs-root appimagetool-x86_64.AppImage
      log "Wayland libs stripped from AppImage"
    else
      log "No AppImage found, skipping Wayland strip"
    fi
    ;;
  *-apple-darwin)
    APP_BUNDLE=$(find src-tauri/target/release/bundle/macos -name '*.app' -print -quit 2>/dev/null || true)
    if [ -n "$APP_BUNDLE" ]; then
      # Ad-hoc sign the entire bundle (Tauri only linker-signs the binary;
      # Finder requires a proper codesign signature to launch apps).
      log "Signing app bundle..."
      codesign --force --deep --sign - "$APP_BUNDLE"

      # Create DMG for distribution
      APP_NAME="$(basename "$APP_BUNDLE" .app)"
      VERSION="$(cat VERSION | tr -d '[:space:]')"
      ARCH="${TRIPLE%%-*}"
      DMG_NAME="${APP_NAME}_${VERSION}_${ARCH}.dmg"
      DMG_DIR="$(dirname "$APP_BUNDLE")"

      log "Creating DMG: $DMG_NAME"
      hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$APP_BUNDLE" \
        -ov -format UDZO \
        "$DMG_DIR/$DMG_NAME"
      log "DMG created at $DMG_DIR/$DMG_NAME"
    else
      log "WARNING: No .app bundle found, skipping sign+DMG"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Phase 8: Verify artifacts
# ---------------------------------------------------------------------------
log "=== Build artifacts ==="
find src-tauri/target/release/bundle -type f \( \
  -name "*.AppImage" -o -name "*.deb" -o -name "*.rpm" \
  -o -name "*.dmg" -o -name "*.app" \
\) -exec ls -lh {} \; 2>/dev/null || true
log "=== BUILD SUCCESS ==="
