#!/bin/sh
set -eu

# Device-specific layout for the backed-up UFI103S-V03 eMMC.
# Exact capacity: 7,733,248 sectors * 512 bytes = 3,959,422,976 bytes.
DISK_SECTORS=7733248
LAST_USABLE_SECTOR=7733214
BACKUP_GPT_SECTOR=7733215
OUTPUT_DIR=${1:-artifacts/UFI103S-V03}
WORK_DIR=$(mktemp -d)
GPT_IMAGE="${WORK_DIR}/gpt-ufi103s.img"

cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT INT TERM

mkdir -p "${OUTPUT_DIR}"
truncate -s $((DISK_SECTORS * 512)) "${GPT_IMAGE}"

# The first 21 partitions retain their stock locations, sizes, attributes and
# unique GUIDs byte-for-byte. Use the DragonBoard 410c 17.09 android-88 TZ
# image, which fits the stock 512 KiB tz/tzbak slots; newer 591 KiB images do
# not fit this UFI103S-V03. The boot partition is expanded in place to 64 MiB.
# Persist stays at its stock location. Rootfs replaces
# cache/recovery/userdata and consumes the remaining usable sectors.
sfdisk "${GPT_IMAGE}" << 'EOF'
label: gpt
label-id: 98101B32-BBE2-4BF2-A06E-2BB33D000C20
unit: sectors
first-lba: 34
last-lba: 7733214
table-length: 28
sector-size: 512

start=131072, size=131072, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=F202334C-7239-17E5-232F-93572E235C8F, name="modem", attrs="GUID:60"
start=262144, size=1024, type=DEA0BA2C-CBDD-4805-B4F9-F428251C3E98, uuid=240D65B6-CAE4-4F02-7575-E5C7852D2CC1, name="sbl1"
start=263168, size=1024, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=5CD3B64C-2081-BD72-6C30-D8A497592506, name="sbl1bak"
start=264192, size=2048, type=400FFDCD-22E0-47E7-9A23-F16ED9382388, uuid=CDC87237-A238-AA25-11EE-0AC6094DB845, name="aboot"
start=266240, size=2048, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=13D52BCE-8C77-A4E2-3542-5A47803B956F, name="abootbak"
start=268288, size=1024, type=098DF793-D712-413D-9D4E-89D711772228, uuid=4D5F212F-7DDE-08D3-6BBD-C3F4FAEB9B46, name="rpm"
start=269312, size=1024, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=1D3926AF-B3C2-4F7C-EA77-B80CEDE253F4, name="rpmbak"
start=270336, size=1024, type=A053AA7F-40B8-4B1C-BA08-2F68AC71A4F4, uuid=2C6F74BE-4F53-E91D-93A4-CCDF6B083658, name="tz"
start=271360, size=1024, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=AD543DB5-3B76-23ED-F0E7-0BFC76A20867, name="tzbak"
start=272384, size=1024, type=E1A6A689-0C8D-4CC6-B4E8-55A4320FBD8A, uuid=59A6CC8E-96FB-3CC0-F36B-5298E5A15505, name="hyp"
start=273408, size=1024, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=E53D6B40-0BAC-0EB5-7E83-5F9ACD1894BC, name="hypbak"
start=274432, size=2048, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=10C9A0A4-5B33-FCF6-BD06-5D61B1541231, name="pad"
start=276480, size=3072, type=EBBEADAF-22C9-E33B-8F5D-0E81686A68CB, uuid=59D29285-5CFA-DEED-4601-E1FF8E5AE01A, name="modemst1"
start=279552, size=3072, type=0A288B1F-22C9-E33B-8F5D-0E81686A68CB, uuid=42088F49-E2E5-4CBE-354D-A5054776D23A, name="modemst2"
start=282624, size=2048, type=20117F86-E985-4357-B9EE-374BC1D8487D, uuid=50988588-E26B-8BE4-3D09-6427A25CEE72, name="misc"
start=284672, size=2, type=57B90A16-22C9-E33B-8F5D-0E81686A68CB, uuid=189F41D8-77F9-194B-DB38-C80357BBF011, name="fsc"
start=284674, size=16, type=2C86E742-745E-4FDD-BFD8-B6A7AC638772, uuid=996DC2D2-1E53-4CEB-A5F5-E355011C0CFB, name="ssd"
start=284690, size=20480, type=20117F86-E985-4357-B9EE-374BC1D8487D, uuid=7AF86780-46C2-7C2D-4683-2E2749611479, name="splash"
start=393216, size=64, type=20A0C19C-286A-42FA-9CE7-F64C3226A794, uuid=50956725-B15D-198A-4FFB-889CB5A5ECDE, name="DDR", attrs="GUID:60"
start=393280, size=3072, type=638FF8E2-22C9-E33B-8F5D-0E81686A68CB, uuid=486CA85E-96FE-765A-ECCD-2137B4FD7A97, name="fsg", attrs="GUID:60"
start=396352, size=32, type=303E6AC3-AF15-4C54-9E9B-D9A8FBECF401, uuid=F3904D7F-7282-9D53-340A-74A55C59F9EF, name="sec", attrs="GUID:60"
start=396384, size=131072, type=20117F86-E985-4357-B9EE-374BC1D8487D, uuid=80780B1D-0FE1-27D3-23E4-9244E62F8C46, name="boot"
start=2067552, size=65536, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, uuid=7B8DDECB-A286-77E1-0CD3-8439E1EA51FE, name="persist", attrs="GUID:60"
start=2133088, size=5600127, type=1B81E7E6-F50D-419B-A739-2AEEF8DA3335, uuid=A7AB80E8-E9D1-E8CD-F157-93F69B1D141E, name="rootfs"
EOF

sfdisk --verify "${GPT_IMAGE}"

dd if="${GPT_IMAGE}" of="${OUTPUT_DIR}/gpt_main0-ufi103s.bin" \
    bs=512 count=34 status=none
dd if="${GPT_IMAGE}" of="${OUTPUT_DIR}/gpt_backup0-ufi103s.bin" \
    bs=512 skip="${BACKUP_GPT_SECTOR}" count=33 status=none
cp "${OUTPUT_DIR}/gpt_main0-ufi103s.bin" \
    "${OUTPUT_DIR}/gpt_both0-ufi103s.bin"
dd if="${GPT_IMAGE}" bs=512 skip="${BACKUP_GPT_SECTOR}" count=33 status=none \
    >> "${OUTPUT_DIR}/gpt_both0-ufi103s.bin"
sfdisk --dump "${GPT_IMAGE}" \
    | sed "s|${GPT_IMAGE}|gpt-ufi103s.img|g" \
    > "${OUTPUT_DIR}/partition-layout.sfdisk"

(
    cd "${OUTPUT_DIR}"
    sha256sum \
        gpt_main0-ufi103s.bin \
        gpt_backup0-ufi103s.bin \
        gpt_both0-ufi103s.bin \
        partition-layout.sfdisk > SHA256SUMS
)

printf 'GPT_OUTPUT_DIR=%s\n' "${OUTPUT_DIR}"
printf 'DISK_SECTORS=%s\n' "${DISK_SECTORS}"
printf 'ROOTFS_START_SECTOR=2133088\n'
printf 'ROOTFS_SECTORS=5600127\n'
