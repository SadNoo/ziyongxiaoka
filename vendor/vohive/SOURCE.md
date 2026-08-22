# VoHive ARM64 binary provenance

- File: `vohive_v1.5.5-10-gf9eb85d_linux_arm64`
- Architecture: Linux AArch64, statically linked, UPX-packed
- SHA-256: `4cbfcec06b719609f3d88714b4df63c420e1cf958fbad0b4851a3c495c595661`
- Pinned release mirror: <https://github.com/6mb/vohive-release/releases/tag/v1.5.5>
- Cross-check mirror: <https://github.com/yinyuangu/vohive-release>
- User-approved fixed mirror: <https://github.com/overlook940/vohive-release/releases/tag/v1.5.5>
- User-approved ARM64 asset: <https://github.com/overlook940/vohive-release/releases/download/v1.5.5/vohive_v1.5.5_linux_arm64>
- Audited source snapshot: <https://github.com/jikdarren/vohive> commit
  `35ba2a238ed918155d5adaa23f16a13b2f44e79b`
- License: PolyForm Noncommercial License 1.0.0; see `LICENSE`.

On 2026-08-21, two independently downloaded mirror copies were byte-for-byte
identical.  The same hash and byte size were also published by the GitHub
release APIs for both the 6mb and overlook940 mirrors.

The original `iniwex5/vohive-release` repository removed the real v1.5.5
assets, and its v9.9.9 AArch64 asset is only a 12-byte end-of-maintenance
marker.  The currently public source snapshot also depends on the unavailable
private module `github.com/iniwex5/vowifi-go`, so the binary cannot be fully
reproduced from public source.  Keep this exact offline copy, verify the hash
before every install, restrict the service to the management networks, and do
not replace it with an unpinned download.

Use is limited to purposes allowed by the included non-commercial license.

## Local work-mode build

The three-mode appliance uses a local, ignored build named
`private/build/vohive_v1.5.5-wangka1_linux_arm64`; the replacement binary is
not committed to Git history and is embedded only in audited release images.
It is built from
`hzlmy2002/vohive-collection` commit
`0c3052c524865a92d546f8fea12d873214c5f8e3` with
`patches/vohive-collection-wangka-work-modes.patch`. The expected local
SHA-256 is
`1a624e443e1b96fee4083db91937398a95a9c75f8e32675c5eded036139c614a`.

Run `scripts/build_patched_vohive.sh /path/to/vohive-collection` before image
assembly. The patch makes data mode disable QMI WMS indications and SMS work;
dual and SMS modes retain the original engine. The public patch, fixed source
commit, build recipe, resulting hash, upstream license and Required Notice are
preserved for every redistributed release image.
