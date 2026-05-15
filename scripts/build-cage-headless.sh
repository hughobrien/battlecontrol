#!/usr/bin/env bash
# TIM-709 — Build cage 0.3.0 + wlroots 0.20 from source for headless Wayland.
#
# Debian Trixie ships cage 0.2.0 / wlroots 0.16 which has a virtual-pointer
# button-forwarding bug — wlrctl pointer click is silently dropped by the
# compositor. cage 0.3.0 / wlroots 0.20 fix this. Debian doesn't package
# libwlroots-0.20 anywhere, so we build from source.
#
# ─── Verified result ─────────────────────────────────────────────────────────
# After running this script:
#   /usr/local/bin/cage                       — cage 0.3.0
#   /usr/local/lib/x86_64-linux-gnu/libwlroots-0.20.so — wlroots 0.20
#
# Smoke test under the new compositor:
#   WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
#     /usr/local/bin/cage -d -- bash -c '
#       /opt/wine-devel/bin/wine notepad &
#       sleep 5
#       wlrctl pointer click left
#       wtype HELLO
#       grim /tmp/notepad-after-input.png
#     '
# Then view /tmp/notepad-after-input.png — text area should show typed chars.
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#   bash scripts/build-cage-headless.sh
#
# Time: ~15-20 minutes (mostly compiling pixman + libxkbcommon + wlroots)
# Disk: ~500 MB in /tmp during build; ~80 MB installed in /usr/local
# Requires: sudo for /usr/local install
#
set -euo pipefail

WORK=${WORK:-/tmp}

echo "=== install build deps ==="
sudo apt-get install -y --no-install-recommends \
  meson ninja-build pkg-config bison \
  libdrm-dev libegl-dev libgles-dev libgbm-dev \
  libxkbcommon-dev libudev-dev libseat-dev \
  libinput-dev libpixman-1-dev libexpat1-dev \
  libwayland-dev wayland-protocols \
  libxcb1-dev libxcb-composite0-dev libxcb-icccm4-dev \
  libxcb-render-util0-dev libxcb-res0-dev libxcb-xinput-dev \
  glslang-tools libvulkan-dev libliftoff-dev libdisplay-info-dev \
  hwdata libdisplay-info-bin

echo "=== clone + build wlroots 0.20.0 ==="
cd "$WORK"
rm -rf wlroots-build
git clone --depth 1 --branch 0.20.0 https://gitlab.freedesktop.org/wlroots/wlroots.git wlroots-build
cd wlroots-build

# Pin the libdrm wrap to a tag that compiles under gcc 14 (HEAD doesn't).
cat > subprojects/libdrm.wrap <<'EOF'
[wrap-git]
url = https://gitlab.freedesktop.org/mesa/drm.git
revision = libdrm-2.4.129

[provide]
libdrm = ext_libdrm
EOF

meson setup build \
  --prefix=/usr/local \
  --buildtype=release \
  --wrap-mode=default \
  --force-fallback-for=pixman,libdrm \
  -Dlibdrm:werror=false \
  -Dlibdrm:intel=disabled \
  -Dexamples=false \
  -Dxwayland=disabled \
  -Dxcb-errors=disabled

ninja -C build
sudo ninja -C build install
sudo ldconfig

echo "=== clone + build cage 0.3.0 ==="
cd "$WORK"
rm -rf cage-build
git clone --depth 1 --branch v0.3.0 https://github.com/cage-kiosk/cage.git cage-build
cd cage-build

PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig \
  meson setup build --prefix=/usr/local --buildtype=release

ninja -C build
sudo ninja -C build install
sudo ldconfig

echo "=== verify ==="
which cage
cage -v
pkg-config --modversion wlroots-0.20

echo ""
echo "Done. Use WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 cage -- <command>"
