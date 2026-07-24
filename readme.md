## 简介

面向 arm64 / armhf 嵌入式平台的 Debian rootfs 构建脚本集合。

## 推荐：Docker 内构建

宿主机只需 **Docker**（不必 `apt install` debootstrap / qemu-user-static）。**不需要 Docker Buildx。**

在 **x86_64** 上编 **arm64** rootfs 时，脚本会：

1. 用 **`multiarch/qemu-user-static`**（`--privileged`）在**宿主机内核**注册 `binfmt_misc`，使本机 Docker 能运行 arm64 镜像（与官方多架构做法一致；重启后若失效可再跑一次）。
2. **`docker pull` / `docker run --platform linux/arm64`** 官方 **`ubuntu:24.04`** arm64 变体，在容器内 `apt-get install` debootstrap 等依赖后执行 **`./mk-lite-rootfs.sh`**（不在 x86 上 `docker build` 自定义 arm64 镜像，故不依赖 buildx）。

```shell
./debian/docker/build-rootfs.sh trixie
```

常用环境变量：

| 变量 | 说明 |
|------|------|
| `ROOTFS_BASE_IMAGE` | 默认 `ubuntu:24.04` |
| `QEMU_BINFMT_IMAGE` | 默认 `multiarch/qemu-user-static` |
| `QEMU_BINFMT_SETUP=0` | 跳过第 1 步（你已手动注册过 binfmt 时） |
| `DOCKER_PLATFORM` | 覆盖 `--platform`（默认 x86→`linux/arm64`） |
| `DOCKER_AUTO_PLATFORM=0` | 不自动加 `--platform`（一般仅 aarch64 本机编 arm64 时） |

默认生成 **tar.gz** 与 **ext4**（`MAKE_EXT4=1`），产物在 `debian/out/`，并 `chown` 为当前用户。

其余与 `mk-lite-rootfs.sh` 相同，例如：

```shell
MAKE_EXT4=1 ROOTFS_EXT4_MB=3072 ./debian/docker/build-rootfs.sh bookworm
```

构建容器使用 **`--privileged`**（debootstrap / 可能的 loop 挂载 ext4）。**`debian/docker/Dockerfile`** 仅作可选（例如在 aarch64 CI 里预装依赖）；x86 默认流程不执行 `docker build`。

---

## 本地构建（需自行安装依赖）

若坚持在宿主机直接跑脚本：

```shell
sudo apt-get install -y debootstrap qemu-user-static binfmt-support rsync gzip
cd debian && ./mk-lite-rootfs.sh trixie
```

---

## 统一入口：`build.sh`

在 `debian/` 目录执行 **`./build.sh`**（无参数）进入交互菜单；非交互且存在上层 **`.buildconfig`** 时，无参数等价于旧版 **直接打板级 rootfs 镜像**（与 SDK 调用兼容）。

| 命令 | 作用 |
|------|------|
| `./build.sh` | 交互菜单 |
| `./build.sh image` | 仅走 SDK：`mk-image.sh`（需 `.buildconfig`） |
| `./build.sh config` | 选择 `compressed_files/` 或 `out/` 下的 tar，写入 `.config` |
| `./build.sh clean` | 清理 `.build-work`、`rootfs_def`、`.config` |
| `./build.sh clean-out` | 删除 `out/*.tar.gz`、`out/*.ext4` |
| `./build.sh docker-lite [trixie\|bookworm]` | 调用 `docker/build-rootfs.sh` |
| `./build.sh lite [trixie\|bookworm]` | 调用 `mk-lite-rootfs.sh` |
| `./build.sh custom <tar路径>` | 调用 `mk-debian-rootfs.sh` |

---

## 一条命令：lite rootfs（Debian 13 / 12）

默认 **trixie**、**arm64**，产物在 `debian/out/`：

```shell
cd debian
chmod +x mk-lite-rootfs.sh ch-mount.sh
./mk-lite-rootfs.sh              # 等同 trixie + arm64
./mk-lite-rootfs.sh bookworm
```

输出：

- `out/debian-<release>-lite-<arch>-<时间戳>.tar.gz`
  顶层目录为 `rootfs/`，与现有 `mk-image.sh` 解压方式一致（`--strip-components=1`）。

可选生成 **ext4**：

```shell
MAKE_EXT4=1 ./mk-lite-rootfs.sh trixie
ROOTFS_EXT4_MB=3072 MAKE_EXT4=1 ./mk-lite-rootfs.sh bookworm
```

常用环境变量：

| 变量 | 说明 |
|------|------|
| `ARCH` | `arm64`（默认）或 `armhf` |
| `DEBIAN_MIRROR` | 主镜像，默认 `http://mirrors.ustc.edu.cn/debian` |
| `DEBIAN_SECURITY_MIRROR` | security，默认 `http://mirrors.ustc.edu.cn/debian-security` |
| `ROOT_PASSWORD` | root 密码，默认 `root` |
| `SKIP_OVERLAY=1` | 不合并本目录 `overlay/` |
| `EXTRA_DEBS` | 额外 apt 包，空格分隔 |
| `MAKE_EXT4=1` | 同时生成 `.ext4` |
| `HOST_UID` / `HOST_GID` | 在容器内以 root 跑脚本时修正产物属主（Docker 脚本已传入） |

交互式菜单（仅 lite）：

```shell
./mk-base-debian.sh
```

### OEM 注入（仅 buildx 路径）

构建时可以把自己的 deb 包、文件和收尾脚本打进 rootfs，不必 fork 本仓库。把环境变量 **`OPENTINA_OEM_DIR`** 指向一个目录，`docker/build-rootfs-buildx.sh` 会将它拷进构建上下文的 `.oem-staging/`，再由 `Dockerfile.rootfs` 装入镜像：

```
$OPENTINA_OEM_DIR/
  packages/            安装这里的 *.deb（apt-get install ./packages/*.deb）
  rootfs-overlay/      整个目录按原路径覆盖到 /
  post.sh              在 chroot 内执行（需可执行权限；可选）
```

依赖策略：**不加 `-f` / `--fix-broken`**。`packages/` 里 deb 的依赖必须能由 trixie/bookworm 主源或同目录的其它 `.deb` 满足，否则 `docker build` 直接失败，不会自动卸包凑数。缺依赖时，把依赖 deb 一并放进 `packages/`，或在板级 `config` 里用 `EXTRA_DEBS` 从主源装。

板级默认目录 `configs/<板>/oem/` 的选取规则见上一级 `../../README.md`。

## 打 `rootfs.ext4`

`mk-image.sh` 是通用工具：解压 rootfs tar → 叠加 `overlay/` → 调 `mkfs.ext4 -d` 直接出 ext4 镜像。
**不再依赖任何外部 SDK / `.buildconfig` / `sys_partition.fex` / 厂商 `make_ext4fs`。**

```shell
# 方式 1：菜单选 tar 然后打镜像
./build.sh config           # 在 compressed_files/ 与 out/ 列出的 tar 里选，写入 .config
./build.sh image            # 调 mk-image.sh

# 方式 2：直接喂 tar
EXT4_SIZE_MB=3072 ./mk-image.sh out/debian-trixie-lite-arm64-*.tar.gz

# 方式 3：复用已存在的 out/binary/（已解压 rootfs）
./mk-image.sh cover
```

环境变量：

| 变量 | 默认 | 说明 |
|------|------|------|
| `EXT4_SIZE_MB` | 2048 | ext4 镜像大小（MB） |
| `EXT4_LABEL`   | rootfs | ext4 卷标 |

产物：`out/rootfs.ext4`。

## 故障排查

串口出现内核 `with environment:` 后直接进入 `/bin/sh`、`can't access tty`、无 systemd 日志：多为 rootfs **缺少 `/sbin/init`**。请重新构建 rootfs（需 **`systemd-sysv`**）。

**`dev-ttyS0.device` / `serial-getty@` 超时**：不要用 `serial-getty@`（依赖 `dev-ttyS0.device`）。当前使用 **`opentina-serial-getty@ttyS0`**（overlay）。串口名可用 **`OPENTINA_SERIAL_TTY`** 覆盖。

**`boot.mount` / `diskseq` 超时**：GPT 上另有 FAT 启动分区，但 OpenTina 不从 rootfs 挂载 `/boot`。OpenTina 构建会在 extlinux **`append`** 中加 **`systemd.gpt_auto=0`**；若手改镜像请自行加上并重建 **`bootfs`**。

---

## 目录说明

| 路径 | 作用 |
|------|------|
| **`.build-work/`** | `mk-lite-rootfs.sh` 临时 debootstrap 工作目录；可整目录删除，已在 `.gitignore` 中忽略。 |
| **`out/`** | 正式产物：tar.gz / ext4 / 解压后的 `binary/`。 |
| **`compressed_files/`** | 可选：预置或从别处拷贝的 rootfs **tar** 缓存；可留空，见该目录下 `README.md`。 |
| **`custom_rootfs_work/`** | `mk-debian-rootfs.sh` 解压与 chroot 定制用的工作目录；可删，已忽略。 |
| **`docker/`** | `build-rootfs.sh`、可选 `Dockerfile`（aarch64 CI 预装依赖）。 |
| **`overlay/`** | 板级 / 项目文件，由 `mk-image.sh` 或 `mk-debian-rootfs.sh` 合并到 rootfs。 |
