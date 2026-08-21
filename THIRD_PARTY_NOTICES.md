# Third-party notices

This repository is a multi-license distribution. The top-level project
license does not relicense the components listed below. Hashes identify the
exact binary copies distributed by this repository.

## VoHive ARM64

- Distributed path: `vendor/vohive/vohive_v1.5.5-10-gf9eb85d_linux_arm64`
- SHA-256: `4cbfcec06b719609f3d88714b4df63c420e1cf958fbad0b4851a3c495c595661`
- Audited source snapshot: <https://github.com/jikdarren/vohive/tree/35ba2a238ed918155d5adaa23f16a13b2f44e79b>
- Fixed release mirror: <https://github.com/overlook940/vohive-release/releases/tag/v1.5.5>
- License: PolyForm Noncommercial License 1.0.0
- License file: `vendor/vohive/LICENSE`

Required Notice: Copyright iniwex5 (https://github.com/iniwex5/vohive)

The fixed binary depends on an upstream private module and cannot currently
be reproduced entirely from public source. Its use remains limited to the
purposes permitted by its upstream license.

## Gadget Tool (`gt`)

- Distributed path: `vendor/gadget-tools/gt`
- SHA-256: `76367a14968945c97c5dbcfd53359dc57cd26e081ccfe95274f49bac2daf5780`
- Upstream: <https://github.com/linux-usb-gadgets/gt>
- Source revision used by the pinned builder: [`a2aa973640dcfde4de1ebc4bc4906195ba5826f9`](https://github.com/linux-usb-gadgets/gt/tree/a2aa973640dcfde4de1ebc4bc4906195ba5826f9)
- License: Apache License 2.0
- License text: `LICENSES/Apache-2.0.txt`

Copyright notices in the upstream source include Copyright (c) 2012-2013
Samsung Electronics Co., Ltd. The upstream file notices remain controlling.

## libusbgx

- Distributed path: `vendor/gadget-tools/libusbgx.so.2.0.0`
- SHA-256: `720c9d2d9ee456dc3c1f73ba52278040511a33da89df4ec94bf071da37d187d7`
- Upstream: <https://github.com/linux-usb-gadgets/libusbgx>
- Source revision used by the pinned builder: [`89d3f448b9285e8834b2e3ee208cd02b8aeccb87`](https://github.com/linux-usb-gadgets/libusbgx/tree/89d3f448b9285e8834b2e3ee208cd02b8aeccb87)
- Version reported by the source checkout: 0.2.0 plus the pinned upstream revisions
- License: GNU Lesser General Public License 2.1 or later
- License text: `LICENSES/LGPL-2.1-or-later.txt`

Copyright notices in the upstream source include Copyright (C) 2013 Linaro
Limited and Copyright (C) 2013-2015 Samsung Electronics. The upstream file
notices remain controlling.

The two gadget-tools source revisions are the submodules pinned by
OpenStick-Builder commit
[`57244976de2dccec5d1c9eb527d3cc2793d580c2`](https://github.com/kinsamanka/OpenStick-Builder/tree/57244976de2dccec5d1c9eb527d3cc2793d580c2),
whose build script compiles libusbgx as a shared library and links `gt`
against it. Equivalent source access is provided by the exact revision links
above.

## No third-party relicensing

Names, logos, firmware, hardware designs, and other third-party material are
not licensed by the Wangka project except to the extent an applicable
upstream license expressly permits. When an upstream notice conflicts with a
summary here, the upstream license and source-file notices control.
