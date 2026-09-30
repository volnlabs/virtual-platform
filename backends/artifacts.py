"""Versioned prebuilt artifact identity; no builds and no qualification claims."""
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct


class Unsupported(ValueError):
    """A well-formed request has no supported consumer contract."""


FILENAMES = {"kernel": "kernel.elf", "rootfs": "rootfs.img", "dtb": "board.dtb"}


def sha256(path, offset=0, length=None):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        source.seek(offset)
        remaining = length
        while remaining is None or remaining > 0:
            chunk = source.read(1024 * 1024 if remaining is None else min(remaining, 1024 * 1024))
            if not chunk:
                if remaining:
                    raise ValueError("truncated artifact range")
                break
            digest.update(chunk)
            if remaining is not None:
                remaining -= len(chunk)
    return digest.hexdigest()


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate field: {key}")
        result[key] = value
    return result


def _fields(value, required, name, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise ValueError(f"{name}: invalid fields; required {', '.join(required)}")


def _string(value, name, pattern=None):
    if not isinstance(value, str) or not value.strip() or "\x00" in value or (pattern and not re.fullmatch(pattern, value)):
        raise ValueError(f"{name}: invalid string")


def _integer(value, name, minimum=0):
    if type(value) is not int or value < minimum:
        raise ValueError(f"{name}: invalid integer")


def _validate(data, base, *, board, backend, arch):
    _fields(data, ("schema_version", "source", "build", "artifacts", "rootfs", "boot_contract"), "manifest")
    _integer(data["schema_version"], "schema_version", 1)
    if data["schema_version"] != 1:
        raise Unsupported("unsupported schema_version")
    source, build = data["source"], data["build"]
    _fields(source, ("repository", "commit", "dirty"), "source", ("submodules",))
    _string(source["repository"], "source.repository")
    _string(source["commit"], "source.commit", r"[0-9a-f]{40}|[0-9a-f]{64}")
    if type(source["dirty"]) is not bool:
        raise ValueError("source.dirty must be boolean")
    if "submodules" in source:
        if not isinstance(source["submodules"], dict):
            raise ValueError("source.submodules must map paths to commits")
        for path, commit in source["submodules"].items():
            _string(path, "submodule path")
            _string(commit, "submodule commit", r"[0-9a-f]{40}|[0-9a-f]{64}")
    _fields(build, ("target", "architecture", "profile", "features", "board", "toolchain", "producer_id"), "build")
    for field in ("target", "architecture", "profile", "board", "toolchain", "producer_id"):
        _string(build[field], f"build.{field}")
    if build["architecture"] != arch:
        raise ValueError("build.architecture conflicts with selected architecture")
    profiles = {
        ("virt", "qemu", "aarch64"): ("virt", ["aarch64_arch", "cloud-profile", "virt"], {"kernel", "rootfs"}),
        ("virt-pi5", "renode", "aarch64"): ("rpi5", ["aarch64_arch", "embedded-profile", "embedded-rpi5", "rpi5"], {"kernel", "dtb"}),
    }
    if (board, backend, arch) not in profiles:
        raise Unsupported("unsupported board/backend/architecture manifest profile")
    guest_board, features, roles = profiles[board, backend, arch]
    if build["board"] != guest_board or build["target"] != "aarch64-unknown-none":
        raise ValueError("build board/target mismatch")
    if build["profile"] != "release":
        raise Unsupported("unsupported build profile")
    if build["features"] != features:
        raise Unsupported(f"unsupported features: expected {features}")
    if data["boot_contract"] != "axiomos-userspace-v1":
        raise Unsupported("unsupported boot_contract")
    artifacts = data["artifacts"]
    if not isinstance(artifacts, dict) or set(artifacts) != roles:
        raise ValueError(f"invalid artifact roles: expected {sorted(roles)}")
    for role, artifact in artifacts.items():
        _fields(artifact, ("path", "size", "sha256"), role)
        _string(artifact["path"], f"{role}.path")
        relative = Path(artifact["path"])
        path = (base / relative).resolve()
        if relative.is_absolute() or ".." in relative.parts or not path.is_relative_to(base):
            raise ValueError(f"{role}: path escapes artifact bundle")
        _integer(artifact["size"], f"{role}.size", 1)
        _string(artifact["sha256"], f"{role}.sha256", r"[0-9a-f]{64}")
        if not path.is_file() or path.stat().st_size != artifact["size"]:
            raise ValueError(f"{role}: missing file or size mismatch")
        if sha256(path) != artifact["sha256"]:
            raise ValueError(f"{role}: sha256 mismatch")
        artifact["path"] = str(path)
    with Path(artifacts["kernel"]["path"]).open("rb") as source:
        header = source.read(64)
    if len(header) != 64 or header[:7] != b"\x7fELF\x02\x01\x01" or struct.unpack_from("<H", header, 18)[0] != 183:
        raise ValueError("kernel: expected little-endian ELF64 AArch64")
    rootfs = data["rootfs"]
    if board == "virt":
        if rootfs != {"storage": "external", "role": "rootfs"}:
            raise ValueError("rootfs: virt requires external rootfs role")
    else:
        _fields(rootfs, ("storage", "container", "offset", "length", "sha256"), "rootfs")
        if rootfs["storage"] != "embedded" or rootfs["container"] != "kernel":
            raise Unsupported("rootfs: unsupported embedded container")
        _integer(rootfs["offset"], "rootfs.offset")
        _integer(rootfs["length"], "rootfs.length", 1)
        _string(rootfs["sha256"], "rootfs.sha256", r"[0-9a-f]{64}")
        if rootfs["offset"] + rootfs["length"] > artifacts["kernel"]["size"]:
            raise ValueError("rootfs: embedded range out of bounds")
        if sha256(artifacts["kernel"]["path"], rootfs["offset"], rootfs["length"]) != rootfs["sha256"]:
            raise ValueError("rootfs: embedded sha256 mismatch")
    return data


def _read(path):
    raw = Path(path).read_bytes()
    return raw, json.loads(raw, object_pairs_hook=_unique,
                           parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"invalid JSON constant: {value}")))


def validate_manifest(path, *, board, backend, arch):
    path = Path(path).resolve(strict=True)
    raw, data = _read(path)
    result = _validate(data, path.parent, board=board, backend=backend, arch=arch)
    result["manifest_sha256"] = hashlib.sha256(raw).hexdigest()
    return result


def prepare_inputs(path, *, board, backend, arch, run_dir):
    path, run_dir = Path(path).resolve(strict=True), Path(run_dir)
    raw, data = _read(path)
    validated = _validate(copy.deepcopy(data), path.parent, board=board, backend=backend, arch=arch)
    destination = run_dir / "inputs"
    destination.mkdir()
    for role, artifact in data["artifacts"].items():
        staged = destination / FILENAMES[role]
        # ponytail: one full copy per run; add reflinks if bundle sizes make this costly.
        shutil.copyfile(validated["artifacts"][role]["path"], staged)
        artifact["path"] = staged.name
    result = _validate(data, destination.resolve(), board=board, backend=backend, arch=arch)
    result["manifest_sha256"] = hashlib.sha256(raw).hexdigest()
    (run_dir / "manifest.json").write_bytes(raw)
    (run_dir / "inputs.json").write_text(json.dumps(result, indent=2) + "\n")
    return result
