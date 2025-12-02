# Yocto 升级到 walnascar (5.2.x) 计划

> 约定：完成下列每一个主步骤后立即生成单独的 Git commit，方便逐步回溯。


> 目标：把当前基于 scarthgap / linux-yocto 6.6/6.9 的构建体系迁移到 Yocto Project 5.2.x（walnascar），并为后续自维护 6.17 内核留好接口。

## 1. 仓库基线
- [ ] 将 `poky` 切换到 `yocto-5.2.4`（commit 9afa7bdac9c5…），更新子模块/引用与 CI 缓存路径。
- [ ] `bitbake`、脚本与 `oe-init-build-env` 重新同步；确认宿主环境满足 Python ≥ 3.9、glibc/gcc 等新版依赖。
- [ ] 调整 `build/conf/bblayers.conf`、`bb-build/conf/bblayers.conf` 指向更新后的本地路径；清理临时 `tmp/poky-yocto-5.2.4` 副本。

## 2. 上游 Layer 迁移
- [x] `meta-openembedded` → `origin/walnascar`（07330a98cf93…），检查动态层生成脚本。
- [x] `meta-security` → `origin/walnascar`（1f7eeb8e8481…），同步其子层 `LAYERSERIES_COMPAT = "styhead walnascar"`。
- [x] `meta-virtualization`：将本地分支 `reproducible` 等 rebase 到 upstream walnascar（38008d99d5be…），逐一确认自有 Docker/Xen 等补丁。
- [x] `meta-rust-bin` 若继续跟踪 master，补充 `LAYERSERIES_COMPAT_rust-bin-layer += "walnascar"`，并校验 1.86 二进制是否可在 glibc 2.41 上编译。

## 3. 自有 Layer 适配
- [x] 更新 `meta-dstack/conf/layer.conf`、`meta-confidential-compute/conf/layer.conf`、`meta-security` 相关动态层的 `LAYERSERIES_COMPAT` 到 `walnascar`。
- [x] bump `DISTRO_VERSION`，同步 changelog / release note。
- [x] 按 walnascar 迁移指南重写 `PREFERRED_PROVIDER_virtual/*`（切换到 `virtual/cross-*` 写法），清理遗留的 `${TARGET_PREFIX}` 字符串（确认无遗留写法）。

## 4. 镜像与配方修复
- [x] 替换所有 `debug-tweaks`（例如 `meta-dstack/recipes-core/images/dstack-rootfs-dev.inc:4`、`meta-confidential-compute/recipes-core/images/cvm-initramfs.bb:15`）为显式 `allow-empty-password` 等组合。
- [ ] 检查 `systemd` 255 带来的安装目录变化：确认 `meta-dstack/recipes-core/systemd/systemd_%.bbappend` 仍能安装 blacklist、`docker.service` override 仍被打包。
- [ ] 移除 `pahole_1.25.bbappend`（walnascar 自带 1.29），确认 BTF 依赖满足。
- [ ] 校验 `docker-moby`、`docker-compose`、`containerd` 名称/插件目录是否有改动，必要时调整 `IMAGE_INSTALL`。
- [ ] `meta-confidential-compute` busybox/systemd 片段与安全特性 (`disk-encryption.scc`、`tpm2.scc`) 重新跑 `bitbake -c kernel_configcheck`。

## 5. 内核策略
- [ ] 如果接受官方 6.12：改用 `linux-yocto_6.12.bb` 或 `linux-yocto-tiny_6.12.bb`，重生成 `KMACHINE` 所需的 `scc`/`cfg`，确保 `KERNEL_DEBUG = "True"` 正常触发 `pahole-native`。
- [x] 若坚持 6.17：拉取 Yocto 邮件列表的 6.17 系列（14 个 patch），或自建 `linux-custom_6.17.bb`，将现有 `.scc` / `.cfg` 排查冲突后重放；同步最新 `yocto-kernel-cache` feature 分支。
- [ ] Tiny 发行版（cvm/tdx）需要验证新内核 config 片段是否满足 TDX/TDX driver、EFI secret 等选项。

## 6. 安全与存储
- [ ] 对 `meta-dstack/recipes-core/dstack-zfs/dstack-zfs_2.2.5.bb` 与上游 `meta-openembedded` 文档对比，决定保留/合并 vendor、pam 相关配置，确保在 6.12/6.17 编译通过。
- [ ] 重新测试 dm-verity、ZFS、WireGuard、TDX guest module (`tdx-guest.bb`) 在新 toolchain 下的构建与运行。

## 7. 构建与验证
- [x] 新建独立构建目录，运行 `bitbake-layers show-layers` 校验兼容性检查。
- [ ] 全量编译 `dstack-rootfs`、`dstack-initramfs`、`cvm-initramfs`，比对 `tmp/deploy/images` 与 `kernel-config`。
- [ ] 执行 `oe-selftest`（virtualization、security）和 dstack 自有 CI：TDX 启动、Docker/Container runtime、dm-verity、ZFS 功能验证。
- [ ] 更新文档、脚本（`README.md`、`build.sh` 等）和 CI 步骤，说明新的 Yocto 版本与宿主要求。

## 8. 收尾
- [ ] 清理/更新 SSTATE 与 downloads 缓存策略，防止新旧版本混用。
- [ ] 记录回滚策略：保留 scarthgap 分支，确认 release 构建成功后再切换主线。
- [ ] 若需要上游贡献（例如 6.17 patch、ZFS 兼容性），准备邮件列表 patch 或反馈。
