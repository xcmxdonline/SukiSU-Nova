# 内置（builtin）SUSFS 集成

本目录把 susfs4ksu 官方的“手工拷 patch + 逐条 patch”流程固化成脚本：在官方 GKI 内核源码里**把 SUSFS 编译进内核**（`CONFIG_KSU=y` + `CONFIG_KSU_SUSFS=y`），而不是 LKM 外挂 `.ko`。

- 目标内核：`android13-5.15` GKI（Redmi K70 / vermeer，`5.15.194-android13-8-00019`）
- 补丁源：[`simonpunk/susfs4ksu`](https://gitlab.com/simonpunk/susfs4ksu) 分支 `gki-android13-5.15`
- 内核侧 root：本仓库 `kernel/`（SukiSU Nova）

## 前置

1. Linux 构建机（Ubuntu 22.04+，≥ 16 核 / 32G 内存 / 100G 空闲盘更稳）。
2. 按 KernelSU 官方文档拉好 GKI 源码树：

```bash
tools/repohb init -b common-android13-5.15 -u https://android.googlesource.com/kernel/manifest common
repo sync -c -j8
```

源码根应该是 `~/kernel/common`（脚本会自动识别 `common/` 与直接源码树两种布局）。

3. 确认 `common/Makefile` 里 `VERSION=5.15`、`SUBLEVEL` 与设备 `uname -r` 对齐（`5.15.194`）。

## 用法

```bash
cd <SukiSU-Nova 仓库根>
./susfs-builtin/apply_susfs.sh --gki-root ~/kernel
```

常用参数：

| 参数 | 说明 |
|---|---|
| `--gki-root PATH` | GKI 源码根（含 `common/`）或直接是 `common/` |
| `--ref BRANCH` | susfs4ksu 分支，默认 `gki-android13-5.15` |
| `--merge` | 补丁有冲突时用 `patch --merge` 合入（会留下冲突标记，需人工处理） |
| `--cleanup` | 只撤销 `drivers/kernelsu` 链接、Makefile/Kconfig 行，不动补丁 |

脚本做的事：

1. clone/fetch susfs4ksu → `<仓库>/.susfs4ksu`，检出 `gki-android13-5.15`；
2. 拷 `kernel_patches/fs/*`、`kernel_patches/include/linux/*` 到内核树；
3. 打入 `50_add_susfs_in_gki-android13-5.15.patch`（先 `--dry-run` 检查）；
4. 把 `kernel/` 以符号链接挂到 `common/drivers/kernelsu`，并写入 Makefile/Kconfig 入口；
5. 在本仓库根部应用 `KernelSU/10_enable_susfs_for_ksu.patch`；
6. 追加 `susfs.fragment` 到 `arch/arm64/configs/gki_defconfig`；
7. 删除 `android/abi_gki_protected_exports_*`（否则部分 vendor 模块加载失败）。

## 已知风险（务必先读）

- **补丁同源问题**：`10_enable_susfs_for_ksu.patch` 是对着上游 `tiann/KernelSU` 的 `kernel/` 结构写的。SukiSU Nova 的 kernel 目录已重构（`core/ hook/ infra/ policy/ runtime/ supercall/ extension/`），直接 `patch -p1` 很可能 hunk 失败。脚本会先 dry-run 并把冲突清单打出来，**不会假装成功**。
- **功能重叠**：Nova 自带 `kernel/feature/selinux_hide.c`、`avc_spoof.c`、`mount_hide.c`，与 SUSFS 的 `selinux_hide` / `SUS_MOUNT` 语义重叠。同时启用可能出现双重 hook，建议二者只留一套（通常留 SUSFS，禁用 Nova 对应特性）。
- **ABI/模块**：自编译 GKI 必须与设备 `vendor_dlkm` 模块的 vermagic、KMI 一致，否则 WiFi / 相机 / 指纹 / 音频会挂。先备份原 `vendor_boot.img`、`vendor_dlkm`，保留可回滚路径。
- **bootconfig**：`SPOOF_CMDLINE_OR_BOOTCONFIG` 依赖 `vendor_boot` 里的 bootconfig，篡改前先 `unpack_bootimg --boot_img vendor_boot.img --out out/` 备份。
- 本机（vermeer）当前为 `HyperOS 3.0.307.0`，**不要为了这个内核回退到 C09 或整包线刷降级**。

## 验证

刷入后：

```bash
uname -r                                  # 应仍为 5.15.194-android13-8-...
zcat /proc/config.gz | grep KSU_SUSFS      # 应有 CONFIG_KSU_SUSFS=y
su -c 'ksu_susfs version'                  # SUSFS 用户态可用
su -c 'ksu_susfs show default'             # 看当前配置
```

同时 `dmesg | grep -i susfs` 应能看到 susfs 初始化日志，管理器「内核扩展中心 → SUSFS」应显示已启用。
