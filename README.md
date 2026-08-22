# 自用型无线网卡改（Debian + 短信管理器）

把 UFI103S-V03 随身 Wi-Fi 棒改造成一台可独立运行的 Debian 小主机：插 SIM
后可以共享 LTE 网络，也可以通过 VoHive 或 macOS App 管理设备、SIM 和短信。

项目保留每台设备自己的 modem/NV 数据，刷机前自动制作两份完整原厂备份，
并提供同设备原厂恢复脚本。它适合个人研究和自用，不是所有“高通 410 网卡”
都能通刷的万能固件。

## 当前版本

| 组件 | 版本与状态 |
| --- | --- |
| WiSiM macOS App | `1.0.0`，已完成当前样机实机验收 |
| Debian 刷机包 | `v1.0.0`，UFI103S-V03 单样机测试包 |
| GitHub Release | App 与刷机包分别提供压缩包、单独 SHA-256 和汇总 `SHA256SUMS` |

> [!WARNING]
> 刷机包目前只在一只样机上完成构建、回读和功能验证。没有更多样品前，它只应
> 作为 UFI103S-V03 测试包使用，不代表不同卖家、批次或相似外壳都兼容。

## 支持的硬件

目前只支持同时满足以下条件的设备：

| 项目 | 必须满足的条件 |
| --- | --- |
| 主板丝印 | `UFI103S-V03` |
| SoC | Qualcomm MSM8916 |
| eMMC 容量 | 精确为 `3,959,422,976` 字节 |
| EDL 设备 | Qualcomm `05c6:9008` |
| Firehose | 与包内固定 MSM8916 loader 匹配 |

外壳、商品名称和网页界面相同，并不代表内部硬件相同。主板丝印或容量不一致时
请立即停止，不要修改脚本绕过门禁。

## 功能

| 领域 | 当前提供的能力 |
| --- | --- |
| 系统 | Debian 13 ARM64、Linux 6.6、普通用户 SSH、`sudo` 管理 |
| 管理网络 | USB `192.168.5.1`、Wi-Fi `192.168.4.1`、WPA2 热点 |
| 蜂窝网络 | VoHive 独占 QMI、LTE 数据连接、USB/Wi-Fi 网络共享、国内备用 DNS |
| SIM 与短信 | SIM 状态、短信收发、长短信、会话记录和命令行备用管理 |
| 工作模式 | 双模式、网卡模式、短信模式，可按使用场景切换 |
| 系统管理 | SSH/Wi-Fi/VoHive 改密、可选网页登录保护、时间校准、误卸载保护 |
| macOS | WiSiM 查看状态、温度、模式、短信和日志，修改 Wi-Fi 与网络方向 |
| 刷机安全 | 双全盘备份、板型/容量/GPT 门禁、固定文件哈希、关键分区保护、刷后回读 |
| 原厂恢复 | 使用该物理设备自己的完整备份恢复原系统 |

设备侧 `device-uplink` 没有获得有效 DNS 时，使用 `114.114.114.114` 和
`223.5.5.5`。系统默认时区为 `Asia/Shanghai`，断电后会恢复最近保存的可信时间。

## 下载

从项目的 [GitHub Releases](https://github.com/SadNoo/ziyongxiaoka/releases)
下载需要的文件：

| 文件 | 用途 |
| --- | --- |
| `WiSiM-1.0.0-macos-universal.zip` | Apple Silicon 与 Intel Mac 日常管理 App |
| `WiSiM-1.0.0-macos-universal.zip.sha256` | WiSiM 单独校验文件 |
| `ziyongxiaoka-UFI103S-V03-v1.0.0.tar.gz` | 刷机、恢复、EDL 源码/锁文件、Debian 镜像和固定底层文件 |
| `ziyongxiaoka-UFI103S-V03-v1.0.0.tar.gz.sha256` | 刷机包单独校验文件 |
| `SHA256SUMS` | 全部发布资产的汇总校验文件 |

不要从网盘、聊天群或不明镜像下载改名后的刷机包。校验不一致时不要解压，
更不要连接设备执行刷写。

## 一键刷机

这里的“一键”指设备进入 EDL 后，只执行一条刷机命令。进入 EDL、首次安装主机
依赖和妥善保存原厂备份仍需要人工完成。

### 1. 准备电脑

支持 macOS 或常见 Linux。建议准备：

- Python 3 与 [`uv`](https://docs.astral.sh/uv/)
- 可用的 USB `libusb` 运行环境
- 稳定的直连 USB 口，不要使用供电不足的集线器
- 至少 16 GB 可用空间
- 同一时间只连接一只处于 EDL 的待刷设备

macOS 可使用 Homebrew 安装 `libusb`：

```sh
brew install libusb
```

Debian/Ubuntu 可安装：

```sh
sudo apt update
sudo apt install -y libusb-1.0-0 python3 python3-venv
```

### 2. 校验并解压

把刷机包和同名 `.sha256` 放在同一目录：

```sh
shasum -a 256 -c ziyongxiaoka-UFI103S-V03-v1.0.0.tar.gz.sha256
mkdir ziyongxiaoka-v1.0.0
tar -xzf ziyongxiaoka-UFI103S-V03-v1.0.0.tar.gz -C ziyongxiaoka-v1.0.0
cd ziyongxiaoka-v1.0.0
```

Linux 也可以使用 `sha256sum -c`。只有显示 `OK` 才能继续。

### 3. 准备固定 EDL 环境

发布包已经附带固定 EDL 源码和 `uv.lock`：

```sh
uv sync --project tools/edl --locked
export WANGKA_EDL="$PWD/tools/edl/.venv/bin/edl"
```

先运行离线预检。它不会连接设备，也不会写入 eMMC：

```sh
./scripts/flash_new_device.sh --label card01 --dry-run
```

只有同时看到以下内容才能继续：

```text
PREFLIGHT=PASS
DRY_RUN=PASS
```

`card01` 是这只设备的备份标签。以后刷其他设备时必须换成新的唯一标签。

### 4. 进入 EDL 9008

先断开设备电源，再按已经确认适用于该批次的方式进入 EDL。部分板子可以按住
板载按键后插入 USB；不同批次可能不同，不要随意短接未知测试点。

macOS 检查命令：

```sh
system_profiler SPUSBDataType | grep -B 5 -A 5 '0x9008'
```

Linux 检查命令：

```sh
lsusb -d 05c6:9008
```

没有识别到 `05c6:9008` 时不要运行正式刷机命令。

### 5. 执行刷机

```sh
./scripts/flash_new_device.sh --label card01
```

脚本会依次完成：

1. 确认固定 loader、启动组件和 Debian 镜像的大小与 SHA-256。
2. 读取两份约 4 GB 的原厂全盘备份，并确认两份逐字节一致。
3. 检查原厂 GPT 和 eMMC 精确容量，生成该设备自己的 Debian GPT。
4. 保留 `modem`、`modemst1/2`、`fsc`、`fsg`、`sec`、`persist` 等独有分区。
5. 写入启动组件、boot 和 rootfs。
6. 回读 GPT、boot、rootfs 抽样和受保护分区，逐项比较。

正式写入前需要输入：

```text
UFI103S-V03
```

看到 `FLASH_VERIFY=PASS` 后，等待脚本发送复位，再把设备以普通方式重新插入。
首次启动通常需要 40～90 秒；板载 modem 最长预留约 180 秒完成冷启动注册。

> [!CAUTION]
> 两份原厂备份不一致、容量不符、设备数量不是一只或任一回读失败时，立即停止。
> 不要使用 `--yes` 掩盖硬件检查；它只会跳过最后的文字确认，不会跳过备份与门禁。

## 原厂备份与恢复

备份默认保存在：

```text
backups/UFI103S-V03/<标签-时间>/
```

请把整个目录复制到另外一块可靠磁盘。目录中可能包含 IMEI、NV、运营商参数和
其他设备独有数据，不要上传 GitHub、网盘公开链接或发送给陌生人。

需要恢复时，只能使用这只物理设备自己的完整备份：

```sh
export WANGKA_EDL="$PWD/tools/edl/.venv/bin/edl"
./scripts/restore_original_device.sh \
  backups/UFI103S-V03/<设备目录>/original-emmc-read1.bin
```

恢复脚本会要求输入 `RESTORE-ORIGINAL`，写回完整 eMMC 后再回读主 GPT 比较。
绝对不要拿另一只设备的备份恢复，否则会覆盖本机 modem/NV 数据。

## 刷机后的首次使用

出厂状态如下：

| 项目 | 地址或名称 | 账号 | 初始密码 |
| --- | --- | --- | --- |
| USB SSH | `192.168.5.1:22` | `user` | `123456789` |
| USB 网页 | `http://192.168.5.1` | `user` | `123456789` |
| Wi-Fi 热点 | `Wangka-UFI103S` | 无 | `123456789` |
| Wi-Fi SSH | `192.168.4.1:22` | `user` | `123456789` |
| Wi-Fi 网页 | `http://192.168.4.1` | `user` | `123456789` |

直插电脑后打开 `http://192.168.5.1`；连接设备 Wi-Fi 后打开
`http://192.168.4.1`。网页使用 80 端口，SSH 使用 22 端口，地址相同不会冲突。

SSH 示例：

```sh
ssh user@192.168.5.1
sudo -i
```

首次登录后请在“系统设备”中修改 SSH、Wi-Fi 和 VoHive 密码。可以手工设置同一
新密码，也可以让设备生成并复制保存。管理登录保护默认开启，可在“系统设置”
中关闭；关闭后，任何连接该设备 USB 或 Wi-Fi 的人都能直接进入管理页面。

## LTE、短信和工作模式

插卡前建议先执行 `sudo systemctl poweroff`，完全断电后再移动 SIM。

常用命令：

```sh
sudo wangka-modem status
sudo wangka-modem sim
sudo wangka-modem data-connect YOUR_APN
sudo wangka-modem data-disconnect
```

短信优先使用网页或 WiSiM。备用 CLI 支持：

```text
sms-list
sms-read PEER
sms-send NUMBER TEXT
sms-delete ID
```

发送普通手机号时必须带 `+国家/地区码`，例如中国大陆使用 `+86`。系统不会自动
补中国区号，以免影响其他国家或地区。界面显示“已提交”只代表 modem 已接受请求，
最终送达仍以运营商网络为准。

三种工作模式：

| 模式 | 行为 |
| --- | --- |
| 双模式 | 默认，同时提供 LTE 上网与短信 |
| 网卡模式 | 保留蜂窝数据，停用短信引擎 |
| 短信模式 | 保留短信，断开蜂窝数据 |

切换涉及 VoHive/QMI 服务短暂重启，页面恢复前不要连续点击。温度来自 Debian
`thermal_zone`：85°C 起警告，92°C 起严重警告。持续高温时应停止大流量使用并改善散热。

不要解除 `ModemManager.service` 的屏蔽，也不要在 VoHive 运行时直接用 `qmicli`
访问同一 QMI 设备，否则可能重新引入双控制器冲突。

## WiSiM for macOS

WiSiM `1.0.0` 是首个通过当前样机实机验收的正式日常管理版，支持 Apple Silicon
和 Intel Mac。它可以：

- 自动尝试 USB `192.168.5.1` 和 Wi-Fi `192.168.4.1`
- 查看设备、温度、蜂窝状态和工作模式
- 查看、发送和回复短信
- 查看最新日志
- 修改 Wi-Fi 名称、密码与网络方向
- 配置设备网页已有的通知集成

WiSiM 不负责刷机，也不保存密码或令牌到 Keychain/UserDefaults。设备开启登录
保护时，每次退出 App 后都需要重新登录。

下载安装：

```sh
shasum -a 256 -c WiSiM-1.0.0-macos-universal.zip.sha256
unzip WiSiM-1.0.0-macos-universal.zip
```

把 `WiSiM-1.0.0.app` 移到“应用程序”。当前公开包未做 Apple Developer ID 公证，
首次启动如被 Gatekeeper 拦截，请在 Finder 中右键 App 并选择“打开”，确认下载来源
和 SHA-256 后再继续。

## 当前验证范围

当前样机已经通过：

- Debian 启动、USB/Wi-Fi 管理网络与 SSH
- LTE 默认路由、国内 DNS、HTTPS 和故障恢复
- 手机 Wi-Fi 与 iPad USB 共享网络
- 带国际区号的普通短信、中文长短信和重启恢复
- 双模式、网卡模式、短信模式的空载长时切换
- WiSiM 1.0.0 日常管理功能

仍待更多样品或后续版本验证：

- 不同卖家/生产批次的 3/5/10 台兼容性
- 持续热点大流量、弱信号和高温边界
- Windows/Linux 主机兼容
- WiSiM 短信删除
- 图形化刷机工具、通话、eSIM 和集中多设备管理

## 从源码开发

公开仓库只保存源码、配置、补丁、测试和许可证。设备备份、NV、短信、日志、
本地凭据、下载缓存以及构建镜像全部由 `.gitignore` 排除。

主要目录：

```text
config/                         设备网络、VoHive、SSH 与 systemd 配置
host/macos/WangkaManager/       WiSiM macOS 源码与测试
patches/                        固定上游版本使用的公开补丁
scripts/                        镜像构建、刷机、恢复、部署与验证脚本
tests/                          设备控制面自动化测试
vendor/                         固定第三方组件来源、哈希与许可
LICENSES/                       完整许可证文本
```

运行设备侧测试：

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

构建发布镜像需要 Docker 和固定的本地构建依赖；普通用户刷写 Release 不需要自己
重新构建 rootfs。

## 安全与隐私

- 每台设备刷机前必须保存两份一致的原厂全盘备份。
- 发布镜像不包含预生成 SSH 主机密钥、machine-id、短信数据库、日志、APN 或备份。
- 每台设备首次启动独立生成 SSH 主机密钥。
- GitHub Release 不包含 IMEI、IMSI、ICCID、序列号、NV、真实短信或修改后的密码。
- 外部短信通知的 Token、SMTP 密码和 Webhook 密钥只应保存在设备受保护配置中。
- 只操作属于你或明确授权你维护的设备与 SIM。

## 致谢

本项目建立在以下项目和社区工作的基础上：

- [OpenStick](https://github.com/OpenStick/OpenStick)
- [OpenStick Builder](https://github.com/kinsamanka/OpenStick-Builder)
- [msm8916-mainline](https://github.com/msm8916-mainline)
- [postmarketOS](https://postmarketos.org/)
- [EDL](https://github.com/bkerler/edl) 与 [Loaders](https://github.com/bkerler/Loaders)
- [ModemManager](https://github.com/linux-mobile-broadband/ModemManager) 与 [libqmi](https://gitlab.freedesktop.org/mobile-broadband/libqmi)
- [VoHive](https://github.com/jikdarren/vohive)、[vohive-collection](https://github.com/hzlmy2002/vohive-collection) 及固定使用的 [overlook940/vohive-release](https://github.com/overlook940/vohive-release)
- [libusbgx](https://github.com/linux-usb-gadgets/libusbgx) 与 [gadget-tool](https://github.com/linux-usb-gadgets/gt)

## 许可证

本仓库采用多许可证。项目原创内容使用 PolyForm Noncommercial License 1.0.0；
VoHive、EDL、Firehose loader、lk2nd/qhypstub、Qualcomm 固件和 gadget-tools 等组件
继续遵循各自许可证或上游发布条件，本项目不对它们重新授权。

完整范围、Required Notice、固定提交、SHA-256 和许可证文本见
[`LICENSE`](LICENSE)、[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 与
[`LICENSES/`](LICENSES/)。
