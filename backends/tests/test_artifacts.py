"""Artifact identity checks use synthetic bytes, never guest qualification."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from artifacts import prepare_inputs, validate_manifest


def bundle(root, board="virt"):
    kernel = bytearray(64)
    kernel[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", kernel, 16, 2, 183, 1)
    kernel += b"embedded rootfs"
    (root / "kernel").write_bytes(kernel)
    (root / "rootfs").write_bytes(b"external rootfs")
    (root / "dtb").write_bytes(b"test dtb")
    roles = ("kernel", "rootfs") if board == "virt" else ("kernel", "dtb")
    manifest = {
        "schema_version": 1,
        "source": {"repository": "https://example.invalid/axiomos", "commit": "a" * 40, "dirty": False},
        "build": {"target": "aarch64-unknown-none", "architecture": "aarch64", "profile": "release",
                  "features": ["aarch64_arch", "cloud-profile", "virt"] if board == "virt" else ["aarch64_arch", "embedded-profile", "embedded-rpi5", "rpi5"],
                  "board": "virt" if board == "virt" else "rpi5", "toolchain": "rustc test", "producer_id": "synthetic-test"},
        "artifacts": {role: {"path": role, "size": (root / role).stat().st_size,
                             "sha256": hashlib.sha256((root / role).read_bytes()).hexdigest()} for role in roles},
        "rootfs": {"storage": "external", "role": "rootfs"} if board == "virt" else {
            "storage": "embedded", "container": "kernel", "offset": 64, "length": len(b"embedded rootfs"),
            "sha256": hashlib.sha256(b"embedded rootfs").hexdigest()},
        "boot_contract": "axiomos-userspace-v1",
    }
    path = root / "build.json"
    path.write_text(json.dumps(manifest))
    return path, manifest


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="artifact contract ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path, self.manifest = bundle(self.root)

    def validate(self, board="virt"):
        return validate_manifest(self.path, board=board, backend="qemu" if board == "virt" else "renode", arch="aarch64")

    def test_valid_and_dirty_bundle_identify_bytes_without_qualification(self):
        for dirty in (False, True):
            self.manifest["source"]["dirty"] = dirty
            self.path.write_text(json.dumps(self.manifest))
            result = self.validate()
            self.assertEqual(result["source"]["dirty"], dirty)
            self.assertEqual(result["build"]["architecture"], "aarch64")
            self.assertEqual(result["manifest_sha256"], hashlib.sha256(self.path.read_bytes()).hexdigest())

    def test_rejects_invalid_contracts(self):
        mutations = [
            (lambda m: m.update(schema_version=2), "unsupported"),
            (lambda m: m.update(schema_version=True), "schema_version"),
            (lambda m: m["build"].update(architecture="x86_64"), "architecture"),
            (lambda m: m["build"].update(features=["embedded-rpi5"]), "features"),
            (lambda m: m["build"].update(profile="debug"), "profile"),
            (lambda m: m["source"].update(dirty="false"), "dirty"),
            (lambda m: m["source"].update(commit="a1"), "commit"),
            (lambda m: m["artifacts"]["rootfs"].update(sha256="0" * 64), "rootfs.*sha256"),
            (lambda m: m["artifacts"]["rootfs"].update(size=-1), "size"),
            (lambda m: m["artifacts"].pop("rootfs"), "roles"),
            (lambda m: m.update(boot_contract="anything-goes"), "boot_contract"),
            (lambda m: m.update(extra="ignored?"), "fields"),
        ]
        for mutate, error in mutations:
            with self.subTest(error=error):
                value = copy.deepcopy(self.manifest)
                mutate(value)
                self.path.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, error):
                    self.validate()

    def test_requires_implied_kernel_features(self):
        for board, requested, resolved in (
            ("virt", ["cloud-profile", "virt"], ["aarch64_arch", "cloud-profile", "virt"]),
            ("virt-pi5", ["embedded-rpi5"], ["aarch64_arch", "embedded-profile", "embedded-rpi5", "rpi5"]),
        ):
            with self.subTest(board=board):
                self.path, self.manifest = bundle(self.root, board)
                self.manifest["build"]["features"] = requested
                self.path.write_text(json.dumps(self.manifest))
                with self.assertRaisesRegex(ValueError, "features"):
                    self.validate(board)
                self.manifest["build"]["features"] = resolved
                self.path.write_text(json.dumps(self.manifest))
                self.validate(board)

    def test_wrong_elf_and_changed_bytes_rejected(self):
        (self.root / "rootfs").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "rootfs.*(size|sha256)"):
            self.validate()
        self.path, self.manifest = bundle(self.root)
        kernel = bytearray((self.root / "kernel").read_bytes())
        struct.pack_into("<H", kernel, 18, 62)
        (self.root / "kernel").write_bytes(kernel)
        self.manifest["artifacts"]["kernel"]["sha256"] = hashlib.sha256(kernel).hexdigest()
        self.path.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "ELF"):
            self.validate()

    def test_escape_and_duplicate_keys_rejected(self):
        self.manifest["artifacts"]["rootfs"]["path"] = "../outside"
        self.path.write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "escape"):
            self.validate()
        self.path.write_text('{"schema_version":1,"schema_version":1}')
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.validate()

    def test_embedded_rootfs_checks_actual_kernel_range(self):
        self.path, self.manifest = bundle(self.root, "virt-pi5")
        self.validate("virt-pi5")
        for field, value in (("offset", 10**10), ("length", -1), ("sha256", "0" * 64)):
            manifest = copy.deepcopy(self.manifest)
            manifest["rootfs"][field] = value
            self.path.write_text(json.dumps(manifest))
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate("virt-pi5")

    def test_staging_is_private_and_revalidates_the_copy(self):
        run_dir = self.root / "run"
        run_dir.mkdir()
        result = prepare_inputs(self.path, board="virt", backend="qemu", arch="aarch64", run_dir=run_dir)
        staged = Path(result["artifacts"]["rootfs"]["path"])
        self.assertFalse(staged.is_symlink())
        self.assertNotEqual(staged.stat().st_ino, (self.root / "rootfs").stat().st_ino)
        (self.root / "rootfs").write_bytes(b"replaced after staging")
        self.assertEqual(staged.read_bytes(), b"external rootfs")
        self.assertTrue((run_dir / "inputs.json").is_file())


if __name__ == "__main__":
    unittest.main()
