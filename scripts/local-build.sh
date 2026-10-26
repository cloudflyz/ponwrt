#!/bin/bash
# ponwrt 本地增量编译脚本（ZN504XG-D / an7581）
# 用法: ./scripts/local-build.sh [jobs]
#   jobs 默认 $(nproc)；建议留 1~2 核给系统，如 10 核跑 ./scripts/local-build.sh 8
# 首次运行会装依赖 + 拉源码 + 全量编译；之后重跑同一目录即为增量编译（只重编变化的包）
set -euo pipefail

JOBS="${1:-$(nproc)}"
SRC="${PONWRT_SRC:-/opt/ponwrt}"
EXTRA_CONFIG="configs/zn504-extra.config"

echo "==> jobs=$JOBS, 源码目录=$SRC"

if [[ ! -d "$SRC/.git" ]]; then
  echo "==> 首次运行：安装依赖"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    asciidoc autoconf automake autopoint binutils bison build-essential bzip2 ccache \
    clang cmake cpio curl device-tree-compiler flex gawk gettext git g++-multilib \
    gcc-multilib gperf haveged help2man intltool libelf-dev libglib2.0-dev libgmp3-dev \
    libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev \
    libssl-dev libtool libyaml-dev lld llvm lrzsz mkisofs msmtp nano ninja-build p7zip \
    p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
    python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig \
    texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd

  echo "==> 拉取源码"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 https://github.com/cloudflyz/ponwrt.git "$SRC"
fi

cd "$SRC"

if [[ ! -d feeds/luci ]]; then
  echo "==> 安装 feeds"
  ./scripts/feeds update -a
  ./scripts/feeds install -a
fi

if [[ ! -f "$EXTRA_CONFIG" ]]; then
  echo "!! 缺少 $EXTRA_CONFIG（本机定制包配置）" >&2
  exit 1
fi

echo "==> 合并配置（链式，kconfig.pl 只接受两个操作数）"
./scripts/kconfig.pl + configs/an7581.config configs/release.config > .config.base
./scripts/kconfig.pl + .config.base "$EXTRA_CONFIG" > .config
rm -f .config.base
make defconfig

echo "==> 校验目标与定制包"
grep -q '^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_znxt_zn504xg-d=y' .config \
  || { echo "zn504xg-d 未选中" >&2; exit 1; }
for p in luci-app-ttyd luci-app-sqm luci-app-wol; do
  grep -q "^CONFIG_PACKAGE_$p=y" .config || { echo "缺少 $p" >&2; exit 1; }
done

echo "==> 下载源码包"
make download -j"$JOBS" || echo "!! 部分下载失败，继续编译（可能稍后重试）"

echo "==> 开始编译（-j$JOBS）"
make -j"$JOBS" || {
  echo "!! 编译失败，尝试单线程复跑定位错误包："
  make -j1 V=s 2>&1 | tail -60
  exit 1
}

echo "==> 产物"
ls -lh bin/targets/airoha/an7581/
sha256sum bin/targets/airoha/an7581/*zn504xg-d*
