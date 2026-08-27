# WiSiM for iPhone and iPad

这是 WiSiM `0.2.0` 的 iOS/iPadOS 原生客户端源码，最低支持 iOS 17。连接 UFI 的 USB
网络或 Wi-Fi 后，App 会依次查找 `192.168.5.1` 和 `192.168.4.1`，也可以在设置中
手动填写管理地址。

当前版本支持 UFI 与大疆 QDC507 的设备能力聚合展示，以及 UFI 的设备状态、温度、工作模式、SIM 信息、短信会话、回复、新建短信、
单条删除和前台新短信通知。网页登录保护开启时，凭据只保存在本次 App 运行的
内存中，退出后需要重新登录。

通话页已经接入 CallKit 动作层，但不会虚构硬件能力：UFI103S 显示不支持；大疆
QDC507 在 Mac 中继、模块初始化和真实双向音频链路完成前显示“需要 Mac 中继”，
拨号入口保持禁用。

iOS/iPadOS 不允许本 App 像 macOS 一样通过 `libusb` 直接读取 QDC507 的 USB AT
与 USB 音频接口。因此，仅连接 QDC507 时，App 会明确显示该型号已支持但需要
Mac WiSiM 中继，不会用“没有任何设备”概括，也不会把无法确认的模块伪报为在线。

## 构建

1. 安装 Xcode 与 XcodeGen。
2. 在本目录执行 `xcodegen generate`。
3. 打开 `WiSiM.xcodeproj`。
4. 在 Signing & Capabilities 中选择自己的 Apple Developer Team。
5. 选择 iPhone 或 iPad 后运行。

本仓库不保存开发者证书、描述文件、设备 UDID、账号或密码。未签名构建不能直接
安装到真机；需要由使用者自己的 Apple 开发者身份签名。
