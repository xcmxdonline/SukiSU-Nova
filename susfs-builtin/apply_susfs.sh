#!/bin/sh
# ============================================================
# SukiSU Nova — builtin SUSFS 集成脚本
# 目标: GKI android13-5.15 (vermeer / 5.15.194-android13-8)
# 用法: ./apply_susfs.sh --gki-root ~/kernel [--ref BRANCH] [--merge] [--cleanup]
# ============================================================
set -eu

SUSFS_REPO="${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}"
SUSFS_REF="${SUSFS_REF:-gki-android13-5.15}"
MERGE=0
CLEAN=0
GKI_ROOT=""

NOVA_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK="$NOVA_ROOT/.susfs4ksu"

usage() {
    sed -n '2,6p' "$0" | sed 's/^# //'
    echo "  --gki-root DIR   GKI 源码根 (含 common/) 或直接 common/"
    echo "  --ref BRANCH     susfs4ksu 分支 (默认 gki-android13-5.15)"
    echo "  --merge          冲突时使用 patch --merge"
    echo "  --cleanup        撤销 kernelsu 链接与 Makefile/Kconfig 改动"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gki-root) GKI_ROOT=$2; shift 2 ;;
        --ref) SUSFS_REF=$2; shift 2 ;;
        --merge) MERGE=1; shift ;;
        --cleanup) CLEAN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] 未知参数: $1" >&2; exit 2 ;;
    esac
done

[ -n "$GKI_ROOT" ] || { echo '[ERROR] 必须指定 --gki-root' >&2; exit 2; }

if [ -d "$GKI_ROOT/common/drivers" ]; then
    KDIR="$GKI_ROOT/common"
elif [ -d "$GKI_ROOT/drivers" ]; then
    KDIR="$GKI_ROOT"
else
    echo '[ERROR] 找不到 drivers/，检查 --gki-root 指向' >&2; exit 127
fi

DRV="$KDIR/drivers"
DRV_MK="$DRV/Makefile"
DRV_KC="$DRV/Kconfig"
PATCH_NAME="50_add_susfs_in_${SUSFS_REF}.patch"

if [ "$CLEAN" -eq 1 ]; then
    echo '[+] 清理 kernelsu 挂载点...'
    [ -L "$DRV/kernelsu" ] && rm -f "$DRV/kernelsu" && echo '[-] 符号链接已移除'
    grep -q 'kernelsu' "$DRV_MK" && sed -i '/kernelsu/d' "$DRV_MK" && echo '[-] Makefile 已还原'
    grep -q 'drivers/kernelsu/Kconfig' "$DRV_KC" && sed -i '\#drivers/kernelsu/Kconfig#d' "$DRV_KC" && echo '[-] Kconfig 已还原'
    echo '[+] 完成（补丁本身请用 git 还原内核树）'
    exit 0
fi

# ---------- 1. 获取 susfs4ksu ----------
if [ -d "$WORK/.git" ]; then
    echo "[+] 更新 susfs4ksu ($SUSFS_REF)..."
    git -C "$WORK" fetch --all --tags --prune -q || true
else
    echo '[+] 克隆 susfs4ksu...'
    git clone "$SUSFS_REPO" "$WORK"
fi
git -C "$WORK" checkout "$SUSFS_REF" -q
git -C "$WORK" pull --ff-only -q 2>/dev/null || echo '[-] 无法 fast-forward，使用本地提交'
git -C "$WORK" log -1 --oneline

KP="$WORK/kernel_patches"
if [ ! -f "$KP/$PATCH_NAME" ]; then
    echo "[ERROR] 缺少 $PATCH_NAME，可用补丁：" >&2
    ls -1 "$KP" >&2
    exit 1
fi

# ---------- 2. 铺 fs/include 补丁文件 ----------
echo '[+] 复制 fs/ 与 include/linux/ 补丁文件...'
cp -f "$KP"/fs/* "$KDIR/fs/"
cp -f "$KP"/include/linux/* "$KDIR/include/linux/"

# ---------- 3. 打 50 patch ----------
echo "[+] dry-run: $PATCH_NAME"
if patch -p1 -d "$KDIR" --dry-run < "$KP/$PATCH_NAME" > /tmp/susfs50.log 2>&1; then
    patch -p1 -d "$KDIR" < "$KP/$PATCH_NAME"
    echo '[-] 内核侧补丁已应用'
elif [ "$MERGE" -eq 1 ]; then
    echo '[!] 有冲突，使用 --merge 合入（请人工处理冲突标记）'
    patch -p1 --merge -d "$KDIR" < "$KP/$PATCH_NAME" || true
else
    echo '[!] 内核侧补丁无法干净应用，冲突摘要：' >&2
    sed -n '1,60p' /tmp/susfs50.log >&2
    echo '[!] 处理后重跑，或用 --merge' >&2
    exit 1
fi

# ---------- 4. 挂载 SukiSU Nova 内核 ----------
echo '[+] 挂载 drivers/kernelsu -> kernel/'
[ -L "$DRV/kernelsu" ] && rm -f "$DRV/kernelsu"
ln -s "$NOVA_ROOT/kernel" "$DRV/kernelsu"
grep -q 'kernelsu' "$DRV_MK" || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRV_MK"
grep -q 'drivers/kernelsu/Kconfig' "$DRV_KC" || sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$DRV_KC"
echo '[-] Makefile / Kconfig 已更新'

# ---------- 5. KernelSU 侧补丁（对 Nova ） ----------
KSUP="$KP/KernelSU/10_enable_susfs_for_ksu.patch"
if [ -f "$KSUP" ]; then
    echo '[+] dry-run: KernelSU/10_enable_susfs_for_ksu.patch (p1 @ Nova 根)'
    if patch -p1 -d "$NOVA_ROOT" --dry-run < "$KSUP" > /tmp/susfs10.log 2>&1; then
        patch -p1 -d "$NOVA_ROOT" < "$KSUP"
        echo '[-] KernelSU 侧补丁已应用'
    else
        echo '[!] KernelSU 侧补丁与 Nova 结构不兼容，未应用。冲突摘要：' >&2
        sed -n '1,60p' /tmp/susfs10.log >&2
        echo '[!] 需要手工移植（apk_sign/manager 签名校验、selinux_hide 挂载点），详见 README「已知风险」' >&2
    fi
fi

# ---------- 6. defconfig ----------
FRAG="$NOVA_ROOT/susfs-builtin/susfs.fragment"
DEFCONFIG="$KDIR/arch/arm64/configs/gki_defconfig"
if [ -f "$DEFCONFIG" ] && [ -f "$FRAG" ]; then
    echo '[+] 追加 defconfig 片段...'
    grep -v '^#' "$FRAG" | grep -v '^$' | while IFS= read -r line; do
        key=${line%%=*}
        sed -i "\#^${key}=#d" "$DEFCONFIG"
        printf '%s\n' "$line" >> "$DEFCONFIG"
    done
    echo '[-] gki_defconfig 已更新'
fi

# ---------- 7. 保护导出表 ----------
rm -f "$KDIR/android/abi_gki_protected_exports_aarch64" \
      "$KDIR/android/abi_gki_protected_exports_x86_64" 2>/dev/null || true

cat <<'EOF'

[+] 集成完成。下一步：
    cd "$GKI_ROOT" && BUILD_KERNEL=1 tools/bazel build //common:kernel_aarch64_dist
    或在旧版构建脚本下: build/build.sh
  产物: common/out/kernel_aarch64/dist/Image
  再按 README 说明用 unpack_bootimg + 原始 vendor_boot.img 重打包。
EOF
