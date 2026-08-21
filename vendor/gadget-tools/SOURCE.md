# 固定版 gadget-tools

这两个 ARM64 文件从本项目已经通过镜像审计及 UFI103S-V03 实机验证的
`rootfs.raw` 中只读提取，用于 Debian 13 一键构建。

固定预编译文件是为了避免 Ubuntu 22.04 交叉链接器与 Debian 13（glibc 2.38+
符号）之间的不兼容。构建脚本会在安装前核验 `SHA256SUMS` 中的散列值；任何
文件变化都会直接中止构建。

- `gt`：USB gadget 配置工具，ARM64。
- `libusbgx.so.2.0.0`：与该 `gt` 配套并经实机验证的运行库。

## 上游源码与许可

- `gt` 上游：<https://github.com/linux-usb-gadgets/gt>，固定源码提交
  `a2aa973640dcfde4de1ebc4bc4906195ba5826f9`，Apache License 2.0。
- `libusbgx` 上游：<https://github.com/linux-usb-gadgets/libusbgx>，固定源码提交
  `89d3f448b9285e8834b2e3ee208cd02b8aeccb87`，库使用 GNU LGPL 2.1 或更新版本。
- 两个提交均由 OpenStick-Builder 提交
  `57244976de2dccec5d1c9eb527d3cc2793d580c2` 的 submodule 清单固定；该版本的
  `scripts/build_gt.sh` 先构建共享 `libusbgx`，再动态链接构建 `gt`。
- 完整许可文本和版权说明见仓库根目录 `LICENSES/` 与
  `THIRD_PARTY_NOTICES.md`。固定源码提交链接提供对应源码访问入口。

当前分发文件 SHA-256：

- `gt`：`76367a14968945c97c5dbcfd53359dc57cd26e081ccfe95274f49bac2daf5780`
- `libusbgx.so.2.0.0`：`720c9d2d9ee456dc3c1f73ba52278040511a33da89df4ec94bf071da37d187d7`
