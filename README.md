# 自用型无线网卡改（Debian+短信管理器）

## 项目介绍

这是给 UFI103S-V03 随身 Wi-Fi 棒做的一套 Debian 改造。刷完以后，它不再只是一个插卡上网的小设备，而是一台可以 SSH 管理、开启 Wi-Fi 热点、识别板载基带，并通过 VoHive 网页查看 SIM 与短信的小型 Linux 主机。项目把日常会用到的地址、账号、改密、时间校准和恢复流程尽量收在一起，同时保留原机 modem/NV 数据和原厂恢复能力，方便自己长期使用，也方便同型号设备重复部署。

本项目目前只适配主板丝印为 `UFI103S-V03`、SoC 为 Qualcomm MSM8916、eMMC 精确容量为 `3,959,422,976` 字节的设备。相似外壳不代表内部硬件相同，请勿拿其他型号直接尝试。

## 如何从零开始刷机

刷机前请准备一台 macOS 或 Linux 电脑、Docker、稳定的 USB 口，以及至少 12 GB 可用空间。每台设备都会先读取两份约 4 GB 的原厂全盘备份，所以不要使用空间不足或供电不稳的电脑。

> Git 仓库只保存源码、脚本和文档。经过审计的刷机镜像会放在本项目的 GitHub Releases，并同时提供 SHA-256 文件。原机备份、设备 NV、短信、日志和私人配置不会进入 Git，也不会打进 Release。首次 Release 发布前还要补齐固定版本的 EDL 主机依赖；Release 尚未出现时请勿从第三方地址下载所谓“一键包”。

准备工作完成后的刷机流程如下：

1. 克隆项目并进入目录：

   ```sh
   git clone https://github.com/SadNoo/ziyongxiaoka.git
   cd ziyongxiaoka
   ```

2. 打开项目的 [Releases](https://github.com/SadNoo/ziyongxiaoka/releases)，下载对应版本的 `ziyongxiaoka-UFI103S-V03-<版本>.tar.gz` 和同名 `.sha256` 文件。先校验，再解压到项目目录：

   ```sh
   shasum -a 256 -c ziyongxiaoka-UFI103S-V03-<版本>.tar.gz.sha256
   tar -xzf ziyongxiaoka-UFI103S-V03-<版本>.tar.gz -C .
   ```

   Linux 也可以使用 `sha256sum -c`。校验失败时立即停止，不要解压或刷写。

3. 按该 Release 的说明安装固定版本 EDL 客户端，然后先做离线检查。`--dry-run` 不会连接或写入设备：

   ```sh
   ./scripts/flash_new_device.sh --label card01 --dry-run
   ```

   只有看到 `PREFLIGHT=PASS` 和 `DRY_RUN=PASS` 才能继续。

4. 确认设备确实是 `UFI103S-V03`，让它进入 Qualcomm EDL 9008 模式。同一台电脑一次只连接一只待刷设备。

5. 执行刷机：

   ```sh
   ./scripts/flash_new_device.sh --label card01
   ```

   脚本会先读取两份完整原厂备份，比较大小与哈希，检查 GPT、板型和 eMMC 容量，再写入 Debian。`modem`、`modemst1/2`、`fsc`、`fsg`、`sec` 和 `persist` 等设备独有分区不会被替换，刷完后还会再次回读核对。

6. 看到 `FLASH_VERIFY=PASS` 后等待设备重启，再以普通方式重新插入。首次启动一般需要 40～90 秒。

刷机有风险，没有两份一致的原厂备份时不要继续。每台设备的备份目录都要单独保存，恢复原厂系统时也只能使用该物理设备自己的全盘备份。

## 设备实现的功能

- Debian 13 ARM64 与 Linux 6.6，可通过普通账号 SSH 管理。
- USB CDC-ECM 网卡，设备管理地址固定为 `192.168.5.1`。
- WPA2 Wi-Fi 热点 `Wangka-UFI103S`，管理地址固定为 `192.168.4.1`。
- VoHive 网页管理，可从 USB 或 Wi-Fi 查看 modem、SIM 和短信功能。
- ModemManager、QMI/AT 与 `qmi-proxy` 共存，并自动登记板载 modem。
- “系统设备”页面可以修改 SSH、Wi-Fi 和 VoHive 密码，也可以生成一个新密码统一应用。
- 网页自动校准系统时间，默认时区为 `Asia/Shanghai`；断电后会恢复最近保存的可信时间。
- VoHive 网页卸载入口已禁用，直接调用卸载接口也会被拒绝；修复和重新登记只能通过 SSH 的固定维护命令执行。
- 新设备刷写脚本包含双全盘备份、机型/容量/GPT 门禁、设备独有分区保护和刷后回读。
- 保留使用该物理设备自身备份恢复原厂系统的路径。

目前设备没有插 SIM，因此真实运营商注册、LTE 数据和短信收发仍需在实际 SIM 与 APN 环境中测试。USB 反向共享也还没有完成：现在设备不会自动借用 Mac/PC 的现有网络上网。

## 设备如何使用

出厂状态使用以下信息：

| 项目 | 地址或名称 | 初始账号 | 初始密码 |
| --- | --- | --- | --- |
| USB SSH | `192.168.5.1:22` | `user` | `123456789` |
| USB 网页 | `http://192.168.5.1` | `user` | `123456789` |
| Wi-Fi 热点 | `Wangka-UFI103S` | 无用户名 | `123456789` |
| Wi-Fi SSH | `192.168.4.1:22` | `user` | `123456789` |
| Wi-Fi 网页 | `http://192.168.4.1` | `user` | `123456789` |

直插电脑时，等待 USB 网卡出现，然后打开 `http://192.168.5.1`。使用手机或电脑连接设备热点时，打开 `http://192.168.4.1`。网页和 SSH 使用同一个 IP 不会冲突，因为网页使用 80 端口，SSH 使用 22 端口。

SSH 登录示例：

```sh
ssh user@192.168.5.1
```

需要 root 权限时先登录 `user`，再执行：

```sh
sudo -i
```

第一次登录 VoHive 后，页面会要求更新 SSH、Wi-Fi 和 VoHive 三项密码。可以手工输入一个共用密码，也可以让设备生成后复制保存。修改 Wi-Fi 密码前先记下新密码，热点重启后需要重新连接。

如果网页日志时间不对，确认手机或电脑本身的时间正确，然后进入“系统设备”，点击“用本机时间校准”。插拔 SIM 前应先执行 `sudo systemctl poweroff`，等待设备完全关机后再断电操作，不要带电移动 SIM。

## 致谢与引用

这个项目是在以下开源项目和社区工作的基础上完成的：

- [OpenStick](https://github.com/OpenStick/OpenStick)
- [OpenStick Builder](https://github.com/kinsamanka/OpenStick-Builder)
- [msm8916-mainline](https://github.com/msm8916-mainline)
- [postmarketOS](https://postmarketos.org/)
- [EDL](https://github.com/bkerler/edl)
- [ModemManager](https://github.com/linux-mobile-broadband/ModemManager) 与 [libqmi](https://gitlab.freedesktop.org/mobile-broadband/libqmi)
- [VoHive](https://github.com/jikdarren/vohive) 及本项目固定使用的 [overlook940/vohive-release](https://github.com/overlook940/vohive-release)
- [libusbgx](https://github.com/libusbgx/libusbgx) 与 gadget-tools

VoHive 固定二进制使用 PolyForm Noncommercial License 1.0.0，来源、版本、哈希和许可文件保存在 `vendor/vohive/`。第三方项目仍遵循各自许可证，本仓库的公开不代表改变其授权范围。
