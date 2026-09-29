#!/usr/bin/env python3
"""Launch prebuilt axiomOS artifacts and check bounded guest boot over UART."""

import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time


def fail(message, code=2, run_dir=None):
    print(f"FAIL: {message}", file=sys.stderr)
    if run_dir is not None:
        for name in ("uart.log", "qemu.log", "version.log"):
            path = run_dir / name
            if path.is_file():
                print(f"--- {name} tail ---", file=sys.stderr)
                with path.open("rb") as source:
                    source.seek(max(0, path.stat().st_size - 16384))
                    tail = source.read(16384).decode(errors="replace").splitlines()[-80:]
                print("\n".join(tail), file=sys.stderr)
    raise SystemExit(code)


def input_file(variable):
    value = os.environ.get(variable)
    if not value:
        fail(f"{variable} must name a prebuilt input file")
    path = Path(value).resolve(strict=True)
    if not path.is_file():
        fail(f"{variable} is not a regular file: {path}")
    if "," in str(path):
        fail(f"{variable}: commas in QEMU input paths are unsupported: {path}")
    return str(path)


def stop(process):
    # The emulator owns its process group, including any helper children.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def boot(arch, verb, extra):
    required = {
        "aarch64": ["AXIOMOS_KERNEL", "AXIOMOS_DISK_IMAGE"],
        "x86_64": ["AXIOMOS_ISO", "AXIOMOS_DISK_IMAGE", "AXIOMOS_OVMF_CODE", "AXIOMOS_OVMF_VARS"],
        "riscv64": ["AXIOMOS_KERNEL"],
    }
    if arch not in required:
        fail(f"unsupported QEMU architecture: {arch}")
    duration = os.environ.get("VOLN_VP_TIMEOUT", "90s")
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smhd]?)", duration)
    if not match:
        fail("VOLN_VP_TIMEOUT must be a positive duration, e.g. 90s or 2m", 4)
    timeout = float(match[1]) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[match[2]]
    if not math.isfinite(timeout) or timeout <= 0:
        fail("VOLN_VP_TIMEOUT must be a finite positive duration", 4)
    inputs = {key: input_file(key) for key in required[arch]}
    executable = shutil.which(f"qemu-system-{arch}")
    if executable is None:
        fail(f"qemu-system-{arch} is not on PATH", 3)

    base = Path(os.environ.get("VOLN_VP_ARTIFACT_DIR", "/tmp")).resolve()
    base.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix=f"voln-vp-qemu-{arch}-", dir=base))
    print(f"Artifacts: {run_dir}", flush=True)
    command = [executable, "-accel", "tcg", "-display", "none", "-monitor", "none", "-serial", "stdio", "-no-reboot"]
    if arch == "aarch64":
        command += ["-machine", "virt", "-m", "1G", "-cpu", "cortex-a57",
                    "-kernel", inputs["AXIOMOS_KERNEL"], "-drive",
                    f"if=none,file={inputs['AXIOMOS_DISK_IMAGE']},format=raw,id=hd0,snapshot=on",
                    "-device", "virtio-blk-device,drive=hd0", "-semihosting"]
    elif arch == "x86_64":
        command += ["-m", "4G", "-cpu", "max", "-smp", "1", "-vga", "none",
                    "-drive", f"if=pflash,unit=0,format=raw,file={inputs['AXIOMOS_OVMF_CODE']},readonly=on",
                    "-drive", f"if=pflash,unit=1,format=raw,file={inputs['AXIOMOS_OVMF_VARS']},snapshot=on",
                    "-cdrom", inputs["AXIOMOS_ISO"], "-drive",
                    f"id=virtio-disk0,file={inputs['AXIOMOS_DISK_IMAGE']},format=raw,if=none,snapshot=on",
                    "-device", "virtio-blk-pci,drive=virtio-disk0"]
    else:
        command += ["-machine", "virt", "-bios", "default", "-kernel", inputs["AXIOMOS_KERNEL"]]
    command += extra[1:] if extra[:1] == ["--"] else extra

    version = subprocess.Popen([executable, "--version"], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        version_output, _ = version.communicate(timeout=5)
        (run_dir / "version.log").write_bytes(version_output)
        if version.returncode:
            code = version.returncode
            fail(f"QEMU version query exited with status {code}", code if code > 0 else 128 - code, run_dir)
    except subprocess.TimeoutExpired as error:
        (run_dir / "version.log").write_bytes(error.output or b"")
        fail("QEMU version query timed out", 124, run_dir)
    finally:
        stop(version)
        version.stdout.close()

    provenance = {}
    for key, path in inputs.items():
        digest = hashlib.sha256()
        with open(path, "rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        provenance[key] = {"path": path, "sha256": digest.hexdigest()}
    metadata = {"architecture": arch, "verb": verb, "inputs": provenance,
                "qemu_version": version_output.decode(errors="replace").strip(),
                "argv": command, "cwd": os.getcwd(), "timeout_seconds": timeout}
    (run_dir / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    markers = ([b"axiomos RISC-V demo", b"Kernel booted via OpenSBI firmware"]
               if arch == "riscv64" else [b"=== axiomos eBPF init ==="])
    if verb == "run" and os.environ.get("VOLN_VP_BOOT_MARKER"):
        markers = [os.environ["VOLN_VP_BOOT_MARKER"].encode()]
    seen = set()
    tail = b""
    panicked = False
    failure_at = None
    ready_at = None
    terminal = termios.tcgetattr(sys.stdin) if verb == "run" and sys.stdin.isatty() else None
    with (run_dir / "uart.log").open("wb") as uart, (run_dir / "qemu.log").open("wb") as log:
        process = subprocess.Popen(command, stdin=None if verb == "run" else subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=log, start_new_session=True,
                                   env=dict(os.environ, TMPDIR=str(run_dir)))
        deadline = time.monotonic() + timeout
        try:
            with selectors.DefaultSelector() as poller:
                poller.register(process.stdout, selectors.EVENT_READ)
                while True:
                    for key, _ in poller.select(timeout=0.05):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            poller.unregister(key.fileobj)
                            continue
                        uart.write(chunk)
                        uart.flush()
                        if verb == "run":
                            sys.stdout.buffer.write(chunk)
                            sys.stdout.buffer.flush()
                        tail += chunk
                        if re.search(rb"\b(?:panic|panicked)\b|V04_PANIC|BOOT_FATAL", tail, re.IGNORECASE):
                            panicked = True
                        seen.update(marker for marker in markers if marker in tail)
                        tail = tail[-max(4096, max(map(len, markers))):]
                    code = process.poll()
                    if code is not None:
                        # The last diagnostic may arrive between select() and poll().
                        os.set_blocking(process.stdout.fileno(), False)
                        uart.write(process.stdout.read() or b"")
                        uart.flush()
                        fail(f"QEMU exited before the boot check completed (status {code})", code if code > 0 else 128 - code if code < 0 else 1, run_dir)
                    now = time.monotonic()
                    if panicked:
                        # Serial writes can split the fatal prefix from its reason.
                        if failure_at is None:
                            failure_at = now + 0.1
                        if now >= failure_at:
                            fail("guest panic or boot failure observed in UART", 1, run_dir)
                    if now >= deadline:
                        fail(f"guest boot timed out after {duration}", 124, run_dir)
                    if not panicked and len(seen) == len(markers):
                        # Observe the remaining startup output before stopping a live guest.
                        if ready_at is None:
                            ready_at = now + 0.1
                        if now >= ready_at:
                            print("PASS: guest boot UART marker(s) observed", flush=True)
                            return 0
        finally:
            stop(process)
            process.stdout.close()
            if terminal is not None:
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, terminal)


def main():
    received_signal = signal.SIGINT

    def interrupted(signum, _frame):
        nonlocal received_signal
        received_signal = signum
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if len(sys.argv) < 3 or sys.argv[2] not in ("run", "test"):
            fail("usage: runner.py <aarch64|x86_64|riscv64> <run|test> [QEMU arguments]")
        return boot(sys.argv[1], sys.argv[2], sys.argv[3:])
    except KeyboardInterrupt:
        print(f"FAIL: interrupted by signal {received_signal}", file=sys.stderr)
        return 128 + received_signal
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
