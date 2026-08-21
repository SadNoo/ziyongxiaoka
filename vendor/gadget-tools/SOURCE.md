# 固定版 gadget-tools

这两个 ARM64 文件从本项目已经通过镜像审计及 UFI103S-V03 实机验证的
`rootfs.raw` 中只读提取，用于 Debian 13 一键构建。

固定预编译文件是为了避免 Ubuntu 22.04 交叉链接器与 Debian 13（glibc 2.38+
符号）之间的不兼容。构建脚本会在安装前核验 `SHA256SUMS` 中的散列值；任何
文件变化都会直接中止构建。

- `gt`：USB gadget 配置工具，ARM64。
- `libusbgx.so.2.0.0`：与该 `gt` 配套并经实机验证的运行库。
