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
