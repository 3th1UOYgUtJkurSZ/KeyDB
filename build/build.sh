#!/usr/bin/env bash
#
# KeyDB 自包含二进制构建脚本(在 macOS/arm64 开发机上运行)
#
#   ./build/build.sh [linux|darwin|all]     默认 all
#
# 产物:
#   build/linux-x64_64/   x86_64 Linux 交叉编译。静态链入 crypto/z/uuid/atomic 及
#                         libstdc++/libgcc —— 运行时仅依赖 glibc 自带核心库
#                         (libc/libm/libpthread/librt/libdl),任何 glibc 系统开箱即跑,
#                         不再需要 libssl1.1 / libatomic1 等。最低 glibc 2.28。
#   build/darwin-arm64/   本机(macOS arm64)构建。
#
# 说明:均为最小构建(BUILD_TLS=no ENABLE_FLASH=no,分配器 libc)。如需 TLS/FLASH
# 请另行调整(需为目标平台准备 OpenSSL/RocksDB 等依赖)。
#
# 依赖:
#   - Linux 目标:交叉工具链 ${LINUX_TRIPLE}-gcc(默认 x86_64-unknown-linux-gnu),
#     以及 Docker(仅首次用于提取目标平台的 z/crypto/uuid 库到 sysroot 缓存)。
#   - darwin 目标:Xcode 命令行工具 + Homebrew 的 openssl。
#
set -euo pipefail

# ---- 路径与参数 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR"
SYSROOT_CACHE="$BUILD_DIR/.sysroot"          # 目标库/头缓存(可 gitignore)
INC="$SYSROOT_CACHE/inc"                     # 暴露给编译的第三方头
LOS="$SYSROOT_CACHE/libonly-static"          # 仅含 .a,使 -lxxx 解析到静态库

LINUX_TRIPLE="${LINUX_TRIPLE:-x86_64-unknown-linux-gnu}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:20.04}" # 提取目标库的发行版(glibc 2.31,与官方 builder 对齐)
OPENSSL_PREFIX="${OPENSSL_PREFIX:-$(brew --prefix openssl 2>/dev/null || echo /opt/homebrew/opt/openssl)}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

BINARIES=(keydb-server keydb-cli keydb-benchmark keydb-check-rdb keydb-check-aof keydb-sentinel keydb-diagnostic-tool)

TARGET="${1:-all}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# macOS 自带的 BSD tar 会把 AppleDouble(._*)条目与扩展属性写进归档,解到 Linux 上
# 会多出一堆垃圾文件;装了 gtar(brew install gnu-tar)就优先用它。
TAR="$(command -v gtar || command -v tar)" || die "找不到 tar"

# ---- 打包产物 ----
# 只打包 BINARIES 里列出的文件:用 keydb-* 通配会把上一轮生成的 keydb-bin.tar.bz2
# 自己也打进去。放在子 shell 里 cd,避免污染调用方的工作目录。
package() {                     # package <dest_dir>
  local dest="$1"
  ( cd "$dest" && "$TAR" -jcf keydb-bin.tar.bz2 "${BINARIES[@]}" )
  log "打包 -> $dest/keydb-bin.tar.bz2($(basename "$TAR"))"
}

# ---- 准备 Linux 目标 sysroot(带缓存)----
prepare_linux_sysroot() {
  if [ -f "$LOS/libcrypto.a" ] && [ -f "$LOS/libz.a" ] && [ -f "$LOS/libuuid.a" ] && [ -d "$INC/openssl" ]; then
    log "sysroot 缓存已存在,跳过提取($SYSROOT_CACHE)"
  else
    command -v docker >/dev/null || die "需要 Docker 提取目标库(首次)。或手动放置 $LOS 下的 .a"
    log "用 Docker 从 $UBUNTU_IMAGE(amd64)提取 zlib/openssl/uuid 库与头 ..."
    mkdir -p "$SYSROOT_CACHE"
    docker run --rm --platform linux/amd64 "$UBUNTU_IMAGE" bash -c '
      set -e; export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null
      apt-get install -y -qq zlib1g-dev libssl-dev uuid-dev >/dev/null
      cd / && tar czf - usr/include usr/lib/x86_64-linux-gnu lib/x86_64-linux-gnu
    ' > "$SYSROOT_CACHE/usr.tar.gz"
    tar xzf "$SYSROOT_CACHE/usr.tar.gz" -C "$SYSROOT_CACHE"

    # 精简头目录(只暴露第三方头,避免遮蔽工具链 glibc 头)
    rm -rf "$INC"; mkdir -p "$INC"
    cp -a "$SYSROOT_CACHE/usr/include/openssl" "$INC/openssl"
    cp -a "$SYSROOT_CACHE/usr/include/x86_64-linux-gnu/openssl/opensslconf.h" "$INC/openssl/opensslconf.h"
    cp -a "$SYSROOT_CACHE/usr/include/uuid" "$INC/uuid"
    cp -a "$SYSROOT_CACHE/usr/include/zlib.h" "$SYSROOT_CACHE/usr/include/zconf.h" "$INC/"

    # 仅含 .a 的静态链接目录:crypto/z/uuid 来自 Ubuntu,atomic 来自交叉工具链
    rm -rf "$LOS"; mkdir -p "$LOS"
    for a in libcrypto.a libz.a libuuid.a; do
      src="$(find "$SYSROOT_CACHE/usr/lib/x86_64-linux-gnu" "$SYSROOT_CACHE/lib/x86_64-linux-gnu" -maxdepth 1 -name "$a" 2>/dev/null | head -1)"
      [ -n "$src" ] || die "未找到 $a"
      cp -p "$src" "$LOS/"
    done
    local atomic_a
    atomic_a="$("${LINUX_TRIPLE}-gcc" -print-file-name=libatomic.a)"
    [ -f "$atomic_a" ] || die "工具链缺少 libatomic.a"
    cp -p "$atomic_a" "$LOS/"
    log "sysroot 就绪:$LOS"
  fi
}

# ---- 构建 Linux x86_64(静态自包含)----
build_linux() {
  command -v "${LINUX_TRIPLE}-gcc" >/dev/null || die "找不到交叉工具链 ${LINUX_TRIPLE}-gcc"
  prepare_linux_sysroot
  log "交叉编译 Linux x86_64 ..."
  ( cd "$REPO_ROOT" && make distclean >/dev/null 2>&1 || true )
  ( cd "$REPO_ROOT/src" && make -j"$JOBS" \
      CC="${LINUX_TRIPLE}-gcc" CXX="${LINUX_TRIPLE}-g++" \
      AR="${LINUX_TRIPLE}-ar" RANLIB="${LINUX_TRIPLE}-ranlib" \
      KEYDB_AS="${LINUX_TRIPLE}-as --64 -g" \
      uname_S=Linux uname_M=x86_64 \
      MALLOC=libc BUILD_TLS=no ENABLE_FLASH=no NO_MOTD=yes USE_SYSTEMD=no \
      OPTIMIZATION=-O2 \
      KEYDB_CFLAGS="-I$INC" \
      LDFLAGS="-L$LOS -static-libstdc++ -static-libgcc" )

  local dest="$BUILD_DIR/linux-x64_64"; mkdir -p "$dest"
  for b in "${BINARIES[@]}"; do
    cp -p "$REPO_ROOT/src/$b" "$dest/"
    "${LINUX_TRIPLE}-strip" --strip-all "$dest/$b"
  done
  log "校验 Linux 产物依赖(应仅 glibc 核心库):"
  "${LINUX_TRIPLE}-readelf" -d "$dest/keydb-server" | awk '/NEEDED/{print "    " $NF}'
  log "Linux 产物 -> $dest"
  package "$dest"
}

# ---- 构建 darwin-arm64(本机)----
build_darwin() {
  [ "$(uname -s)" = "Darwin" ] || die "darwin 目标需在 macOS 上构建"
  [ -d "$OPENSSL_PREFIX/lib" ] || die "找不到 OpenSSL($OPENSSL_PREFIX);请 brew install openssl"
  log "本机构建 darwin-arm64 ..."
  ( cd "$REPO_ROOT" && make distclean >/dev/null 2>&1 || true )
  ( cd "$REPO_ROOT/src" && make -j"$JOBS" \
      MALLOC=libc BUILD_TLS=no ENABLE_FLASH=no \
      LDFLAGS="-L$OPENSSL_PREFIX/lib" )

  local dest="$BUILD_DIR/darwin-arm64"; mkdir -p "$dest"
  for b in "${BINARIES[@]}"; do
    cp -p "$REPO_ROOT/src/$b" "$dest/"
    strip -x "$dest/$b"
  done
  log "验证:$("$dest/keydb-server" --version)"
  log "darwin 产物 -> $dest"
  package "$dest"
}

case "$TARGET" in
  linux)  build_linux ;;
  darwin) build_darwin ;;
  all)    build_linux; build_darwin ;;
  *)      die "用法: $0 [linux|darwin|all]" ;;
esac

log "完成。"
