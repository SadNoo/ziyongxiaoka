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

The release image uses a locally patched VoHive build from
`hzlmy2002/vohive-collection` commit
`0c3052c524865a92d546f8fea12d873214c5f8e3`. The public patch and reproducible
build recipe are `patches/vohive-collection-wangka-work-modes.patch` and
`scripts/build_patched_vohive.sh`; the patched ARM64 binary SHA-256 is
`1a624e443e1b96fee4083db91937398a95a9c75f8e32675c5eded036139c614a`.
The same PolyForm Noncommercial terms and Required Notice apply.

## EDL client

- Release path: `tools/edl`
- Upstream: <https://github.com/bkerler/edl>
- Fixed revision: `2f8e89a848afaaef68997fcbcb5b178d958d497b`
- License: GNU General Public License version 3, with the additional upstream
  noncommercial-product notice stated in its README.
- License file: `tools/edl/LICENSE` and `LICENSES/GPL-3.0-only-edl.txt`

The complete Python source and `uv.lock` are shipped in the flashing asset;
the EDL client is not bundled into WiSiM. For privacy hygiene, the release copy
replaces one numeric example IMEI in an unrelated OnePlus help-text block with
the literal placeholder `<redacted-example>`. It does not change EDL protocol
or flashing behavior, and the complete modified source is included.

## Qualcomm Firehose loader

- Release path: `tools/edl/Loaders/qualcomm/factory/msm8916/007050e100000000_394a2e47cf830150_fhprg_peek.bin`
- SHA-256: `53f193500c03248f0d671ab57bfe9ca8a42967e97f28403294b4b3f854075aca`
- Source repository: <https://github.com/bkerler/Loaders>
- Fixed revision: `bf0d8017eb97464530114a348c5157a6ea6a3372`
- Upstream statement: `tools/edl/Loaders/README.md`

The loader repository does not provide a conventional software license. Its
README states that the loaders are provided for unbricking and repair of
devices no longer under warranty, must not be sold, and may be removed at a
copyright holder's request. The project does not relicense or claim ownership
of this binary. It is shipped only as a fixed, noncommercial repair component
for the explicitly gated MSM8916 device.

## OpenStick boot components

- Builder: <https://github.com/kinsamanka/OpenStick-Builder>, fixed revision
  `57244976de2dccec5d1c9eb527d3cc2793d580c2`
- `aboot.mbn`: SHA-256
  `223283b927ab8076e9a2f3dc86248b024ff5ddb3f510bb1595dc984f03a05ed2`,
  generated from lk2nd revision `99297666a4b0a5b0ceb67d42b2a2ee6e0c3963ff`
- `hyp.mbn`: SHA-256
  `c6414843b635a2b3e7ec58bc5a6c6c7c7aef7f5a31898dc5923c2085c9de1a2d`,
  generated from qhypstub revision `fca3c513b6fb5e5b8fabae21dac1f4a5c0b51bc6`

The builder is MIT licensed. lk2nd retains its MIT/BSD and component-specific
notices; qhypstub is GPL-2.0. License texts are included as
`LICENSES/OpenStick-Builder-MIT.txt`, `LICENSES/lk2nd-LICENSE.txt`,
`LICENSES/lk2nd-upstream-LICENSE.txt`, and
`LICENSES/GPL-2.0-only-qhypstub.txt`. Exact source revisions remain available
at the linked public repositories.

## DragonBoard 410c Qualcomm firmware

- Release path: `downloads/dragonboard410c-17.09/tz.mbn`
- SHA-256: `8d2a0cf01e3b0c7ca257333df1adc96d85a4ccda773c8258b8d7395257008171`
- Source package: `dragonboard410c_bootloader_emmc_android-88.zip`
- License file: `LICENSES/Qualcomm-DragonBoard410c-license.txt`

The source package identifies `tz.mbn` as Redistributable Binary Code. Its
license permits binary redistribution only as part of an application, only on
Qualcomm chipset platforms, and requires distribution of the license text.
The flashing package preserves those restrictions and includes the exact text.

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
