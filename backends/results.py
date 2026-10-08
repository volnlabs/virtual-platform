"""Shared run evidence for the Python and Bash adapters."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from artifacts import Unsupported, prepare_inputs, sha256

ROOT = Path(__file__).resolve().parents[1]
MARKER = "=== axiomos eBPF init ==="
MANUAL = {
    ("qemu", "aarch64"): {"kernel": "AXIOMOS_KERNEL", "rootfs": "AXIOMOS_DISK_IMAGE"},
    ("qemu", "x86_64"): {"iso": "AXIOMOS_ISO", "rootfs": "AXIOMOS_DISK_IMAGE", "firmware-code": "AXIOMOS_OVMF_CODE", "firmware-vars": "AXIOMOS_OVMF_VARS"},
    ("qemu", "riscv64"): {"kernel": "AXIOMOS_KERNEL"},
    ("renode", "aarch64"): {"kernel": "AXIOMOS_KERNEL", "dtb": "VOLN_VP_DTB"},
}
FILES = {"kernel": "kernel.elf", "rootfs": "rootfs.img", "dtb": "board.dtb",
         "iso": "boot.iso", "firmware-code": "firmware-code.fd", "firmware-vars": "firmware-vars.fd"}


def write_json(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


class RunResult:
    def __init__(self, backend, board, arch, verb, run_dir=None):
        allocated = run_dir is None
        base = Path(os.environ.get("VOLN_VP_ARTIFACT_DIR", "/tmp")).resolve()
        if run_dir is None:
            base.mkdir(parents=True, exist_ok=True)
            run_dir = tempfile.mkdtemp(prefix=f"voln-vp-{backend}-", dir=base)
        self.directory = Path(run_dir).resolve()
        self.path = self.directory / "result.json"
        self.data = {"schema_version": 1, "run_id": self.directory.name,
                     "backend": backend, "board": board, "architecture": arch, "verb": verb,
                     "mode": "boot", "completed": False, "identity": "unvalidated",
                     "qualification_claims": [], "outcome": None, "reason": "run incomplete",
                     "exit_code": None, "boot_contract": None, "observed_milestones": [],
                     "inputs": {}, "execution": {}, "evidence": []}
        self.save()
        if allocated:
            print(f"Artifacts: {self.directory}", flush=True)

    def provenance(self):
        backend, board = self.data["backend"], self.data["board"]
        paths = [ROOT / "backends/artifacts.py", ROOT / "backends/results.py"]
        paths += sorted((ROOT / "backends" / backend).rglob("*.py"))
        paths += sorted((ROOT / "backends" / backend / "adapters").glob("*.sh"))
        paths += sorted((ROOT / "backends" / backend / "scripts").glob("*.resc"))
        paths += sorted((ROOT / "boards" / board).rglob("*.repl"))
        paths += sorted((ROOT / "boards" / board / backend).glob("*.sh"))
        paths += [ROOT / "boards" / board / "board.toml", ROOT / "backends" / backend / "manifest.toml"]
        self.data["implementation"] = {"files": {str(p.relative_to(ROOT)): sha256(p) for p in paths if p.is_file() and "tests" not in p.parts}}
        try:
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL, timeout=5).strip()
            dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL, timeout=5)
            self.data["implementation"].update(commit=commit, dirty=bool(dirty))
        except (OSError, subprocess.SubprocessError):
            self.data["implementation"].update(commit=None, dirty=None)
        self.save()

    @classmethod
    def load(cls, directory):
        result = cls.__new__(cls)
        result.directory = Path(directory)
        result.path = result.directory / "result.json"
        result.data = json.loads(result.path.read_text())
        return result

    def save(self):
        write_json(self.path, self.data)

    def prepare(self, extra):
        self.provenance()
        backend, arch = self.data["backend"], self.data["architecture"]
        manifest = os.environ.get("VOLN_VP_ARTIFACT_MANIFEST")
        if "," in str(self.directory) and backend == "qemu":
            raise ValueError("commas in QEMU artifact directory are unsupported")
        if (backend, arch) not in MANUAL:
            raise Unsupported(f"unsupported {backend} architecture: {arch}")
        if os.environ.get("VOLN_VP_BOARD", self.data["board"]) != self.data["board"]:
            raise ValueError("selected board conflicts with adapter")
        if manifest is not None:
            if not manifest:
                raise ValueError("empty VOLN_VP_ARTIFACT_MANIFEST")
            for name in ("AXIOMOS_KERNEL", "AXIOMOS_DISK_IMAGE", "AXIOMOS_ISO", "AXIOMOS_OVMF_CODE", "AXIOMOS_OVMF_VARS", "VOLN_VP_DTB"):
                if name in os.environ:
                    raise ValueError(f"{name} conflicts with artifact manifest; unset manual inputs")
            if os.environ.get("VOLN_VP_BOOT_MARKER", MARKER) != MARKER:
                raise ValueError("diagnostic boot marker conflicts with artifact manifest")
            if self.data["verb"] == "test" and extra:
                raise ValueError("raw emulator arguments are not allowed for manifest tests")
            inputs = prepare_inputs(manifest, board=self.data["board"], backend=backend, arch=arch, run_dir=self.directory)
            self.data.update(inputs=inputs, identity="manifest_matched", boot_contract=inputs["boot_contract"])
        else:
            destination = self.directory / "inputs"
            destination.mkdir()
            artifacts = {}
            for role, variable in MANUAL[backend, arch].items():
                value = os.environ.get(variable)
                if role == "dtb" and value is None:
                    value = str(ROOT / "boards/virt-pi5/virt-pi5.dtb")
                if not value or not Path(value).is_file():
                    raise ValueError(f"{variable} must name a readable prebuilt input file")
                original = Path(value).resolve(strict=True)
                staged = destination / FILES[role]
                shutil.copyfile(original, staged)
                artifacts[role] = {"path": str(staged), "source_path": str(original), "size": staged.stat().st_size, "sha256": sha256(staged)}
            self.data.update(identity="manual", inputs={"artifacts": artifacts},
                             boot_contract="riscv-demo-v1" if arch == "riscv64" else "axiomos-userspace-v1")
            write_json(self.directory / "inputs.json", self.data["inputs"])
        self.save()
        return {variable: self.data["inputs"]["artifacts"][role]["path"] for role, variable in MANUAL[backend, arch].items()}

    def execution(self, argv, **settings):
        executable = Path(argv[0]).resolve(strict=True)
        self.data["execution"] = {"argv": argv, "executable": str(executable), "sha256": sha256(executable),
                                  "cwd": str(ROOT) if self.data["backend"] == "renode" else os.getcwd(),
                                  "controls": {name: value for name, value in os.environ.items() if name.startswith("VOLN_VP_")},
                                  **settings}
        self.save()

    def finish(self, code, reason, unsupported=False):
        if self.data["completed"]:
            return
        version = self.directory / "version.log"
        if version.is_file():
            self.data["execution"]["version"] = version.read_text(errors="replace").strip()
        uart = self.directory / "uart.log"
        markers = (["axiomos RISC-V demo", "Kernel booted via OpenSBI firmware"]
                   if self.data["architecture"] == "riscv64" else [MARKER])
        if self.data["verb"] == "run" and os.environ.get("VOLN_VP_BOOT_MARKER"):
            markers = [os.environ["VOLN_VP_BOOT_MARKER"]]
        if uart.is_file():
            seen = set()
            with uart.open(errors="replace") as lines:
                for line in lines:
                    seen.update(marker for marker in markers if marker in line)
            self.data["observed_milestones"] = sorted(seen)
        self.data.update(completed=True, exit_code=code, reason=reason,
                         outcome="unsupported" if unsupported else "pass" if code == 0 else "fail")
        self.data["evidence"] = sorted(str(p.relative_to(self.directory)) for p in self.directory.rglob("*") if p.is_file() and p.name != "result.tmp")
        self.save()
        if code == 0:
            print("PASS: boot observation; guest qualification is not established", flush=True)


def main():
    operation, directory, *args = sys.argv[1:]
    result = None
    try:
        if operation == "init":
            backend, board, arch, verb, *extra = args
            result = RunResult(backend, board, arch, verb, directory)
            result.prepare(extra)
        elif operation == "execution":
            result = RunResult.load(directory)
            result.execution(args, virtual_seconds=os.environ.get("VOLN_VP_VIRTUAL_TIME", "0.1"),
                             timeout=os.environ.get("VOLN_VP_TIMEOUT", "90s"),
                             cpu="cortex-a78", cores=1, ram_bytes=0x200000000, entry="EL1", semihosting=False)
        elif operation == "finish":
            result = RunResult.load(directory)
            result.finish(int(args[0]), args[1])
        else:
            raise ValueError(f"unknown evidence operation: {operation}")
        return 0
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        if result is not None:
            result.finish(2, str(error), isinstance(error, Unsupported))
        return 2


if __name__ == "__main__":
    sys.exit(main())
