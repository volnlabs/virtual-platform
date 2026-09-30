# Prebuilt artifact manifest v1

The AxiomOS build producer emits one JSON manifest alongside its immutable
artifacts. voln-vp validates and copies inputs; it never builds a guest or infers
source identity from filenames. `--artifact-manifest PATH` and
`VOLN_VP_ARTIFACT_MANIFEST` select the same contract.

All objects reject unknown and duplicate keys. Paths are relative to the
manifest directory, must resolve inside it, and must name regular files.
SHA-256 values are 64 lowercase hexadecimal characters. Byte counts are positive
integers (not booleans); embedded offsets may be zero. Source commits are full
40- or 64-character lowercase Git object IDs.

| Required top-level field | Contents |
|---|---|
| `schema_version` | Integer `1` |
| `source` | `repository`, `commit`, `dirty` (boolean); optional `submodules` mapping paths to full commit IDs |
| `build` | String `target`, `architecture`, `profile`, `board`, `toolchain`, `producer_id`; sorted array `features` |
| `artifacts` | Map of roles to objects with `path`, `size`, `sha256` |
| `rootfs` | External or embedded descriptor below |
| `boot_contract` | String `axiomos-userspace-v1` |

Currently supported combinations:

| Adapter board/backend | Guest board | Target / architecture | Profile / exact enabled features | Artifact roles |
|---|---|---|---|---|
| `virt` / QEMU | `virt` | `aarch64-unknown-none` / `aarch64` | `release` / `["aarch64_arch", "cloud-profile", "virt"]` | `kernel`, `rootfs` |
| `virt-pi5` / Renode | `rpi5` | `aarch64-unknown-none` / `aarch64` | `release` / `["aarch64_arch", "embedded-profile", "embedded-rpi5", "rpi5"]` | `kernel`, `dtb` |

`features` lists all enabled features of the `kernel` package, including those
implied by aliases, sorted and with default features disabled. These closures
were checked against AxiomOS commit `b8953b593d5f3be2a15960aef24ccef0fc507ca3`.
The producer build record must also retain the rootfs build's features and the
resolved dependency feature graph; this field does not describe every package.

These are deliberately narrow consumer profiles, not claims that a producer
build is available. A different enabled feature set requires a reviewed contract
change; do not omit features to fit the table. x86_64 and RISC-V manifest profiles
are unsupported; their existing manual diagnostic inputs remain usable.

For generic `virt`, the rootfs descriptor is exactly:

```json
{"storage": "external", "role": "rootfs"}
```

For Pi, it contains `storage: "embedded"`, `container: "kernel"`, integer
`offset` and `length`, and `sha256`. The offset is a **file byte offset in the
supplied ELF**, not a guest address. The consumer verifies both the entire ELF
and the exact embedded bytes. Compressed containers and unidentified embedded
ranges are unsupported. The kernel must have an ELF64 little-endian AArch64
header; this is an architecture check, not a full ELF/guest qualification.

The boot contract requires the literal UART milestone
`=== axiomos eBPF init ===`, no observed panic/boot fatal, and successful bounded
adapter cleanup. It establishes only the observed userspace boot milestone.

## Producer responsibilities

Capture source commit/dirty state before building. Record the actual enabled
features and toolchain, package matching kernel/rootfs/DTB together, hash final
bytes, and associate `producer_id` with retained build logs. Include submodule
identities where applicable. Publish atomically so consumers never see a partial
bundle. voln-vp does not retrospectively attribute older binaries to a commit.

Hash agreement proves byte identity, not truth of a source claim. A real build
record and accepted emulator profile remain prerequisites for qualification.
Dirty bundles are usable for diagnosis but cannot establish qualification.
This tranche makes **no qualification claims**, even for a clean valid manifest.

## Consumer behavior

Manifest mode rejects any ambient manual artifact variable (`AXIOMOS_KERNEL`,
`AXIOMOS_DISK_IMAGE`, `AXIOMOS_ISO`, `AXIOMOS_OVMF_CODE`, `AXIOMOS_OVMF_VARS`,
`VOLN_VP_DTB`): unset them rather than silently overriding them. A conflicting
architecture or diagnostic boot marker is rejected. Manifest `test` rejects
raw emulator arguments and QEMU semihosting; diagnostic `run` may accept raw
arguments, always without qualification.

Inputs are copied into a fresh run directory, revalidated there, and those
private copies are passed to the emulator. `manifest.json` preserves the exact
producer manifest; `inputs.json` records normalized staged paths and hashes.
QEMU writes still use disposable disk/firmware snapshots. Private copies cost
one bundle's disk space per run and are retained with the evidence.
