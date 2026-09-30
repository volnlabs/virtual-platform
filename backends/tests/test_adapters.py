"""Exercise the real adapters with deterministic emulator stand-ins, without a guest build."""
import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time
import unittest

from test_artifacts import bundle


ROOT = Path(__file__).resolve().parents[2]
MARKER = "=== axiomos eBPF init ==="
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ["FAKE_ROOT"])
mode = os.environ.get("FAKE_MODE", "success")
if "--version" in sys.argv:
    if mode == "version_exit":
        print("version probe failure")
        sys.exit(7)
    if mode == "version_child":
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        (root / "child-pid").write_text(str(child.pid))
        (root / "pid").write_text(str(os.getpid()))
        time.sleep(60)
    print("test emulator 1.0")
    sys.exit(0)
(root / "invocation.json").write_text(json.dumps(sys.argv))
(root / "pid").write_text(str(os.getpid()))
if mode == "large_exit":
    print("x" * 120000 + "final guest diagnostic", flush=True)
    sys.exit(7)
if mode == "orphan":
    child = subprocess.Popen([sys.executable, "-c",
                              "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"])
    (root / "child-pid").write_text(str(child.pid))
if mode == "child":
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    (root / "child-pid").write_text(str(child.pid))
    time.sleep(60)
if mode == "timeout":
    time.sleep(60)
if mode == "exit":
    sys.exit(7)
if mode == "empty":
    sys.exit(0)
text = "=== axiomos eBPF init ===\n"
if "riscv64" in sys.argv[0]:
    text = "axiomos RISC-V demo\nKernel booted via OpenSBI firmware\n"
if mode == "custom":
    text = "custom diagnostic marker\n"
if mode == "panic":
    text += "kernel panicked at guest.rs:1\n"
if mode == "fatal":
    text += "BOOT_FATAL code=root-filesystem-invalid\n"
if "renode" in sys.argv[0]:
    # Capture is a fresh sibling of the generated script, independent of quoting.
    script = next(pathlib.Path(arg.replace("\\ ", " "))
                  for arg in sys.argv[1:] if arg.endswith(".resc"))
    (script.parent / "uart.log").write_text(text)
    if mode == "monitor":
        print("There was an error executing command 'bad'")
else:
    if mode == "fragment":
        print(text[:12], end="", flush=True)
        time.sleep(0.03)
        text = text[12:]
    if mode == "cleanup_hold":
        import signal
        def hold(signum, frame):
            (root / "cleanup-started").write_text("ready")
        signal.signal(signal.SIGTERM, hold)
    if mode == "shutdown_fatal":
        import signal
        def terminate(signum, frame):
            print("BOOT_FATAL during shutdown", flush=True)
            sys.exit(0)
        signal.signal(signal.SIGTERM, terminate)
    print(text, flush=True)
    if mode == "early":
        sys.exit(0)
    time.sleep(60)
'''


FAKE_ROBOT = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ["FAKE_ROOT"])
mode = os.environ.get("FAKE_MODE", "success")
(root / "invocation.json").write_text(json.dumps(sys.argv))
(root / "pid").write_text(str(os.getpid()))
out = pathlib.Path(sys.argv[sys.argv.index("--results-dir") + 1])
out.mkdir()
(out.parent / "uart.log").write_text("=== axiomos eBPF init ===\n")
if mode == "exit": sys.exit(7)
if mode == "timeout": time.sleep(60)
if mode == "boot_only": sys.exit(0)
status = "FAIL" if mode == "assertion" else "SKIP" if mode == "skip" else "PASS"
test = '<test name="runtime assertion"><status status="' + status + '"/></test>'
if mode == "empty": test = ""
suite_status = "FAIL" if mode == "teardown" else "PASS"
xml = '<robot><suite>' + test + '<status status="' + suite_status + '"/></suite></robot>'
if mode == "malformed": xml = "<robot>"
(out / "robot_output.xml").write_text(xml)
for name in ("log.html", "report.html"):
    (out / name).write_text("retained report")
if mode == "incomplete": (out / "report.html").unlink()
if mode == "fatal":
    (out.parent / "uart.log").write_text("BOOT_FATAL after completion\n")
if mode == "emulator_error":
    (out / "emulator.log").write_text("[ERROR] peripheral failure\n")
if mode.startswith("native_"):
    (out / "emulator.log").write_text({"native_panic": "PANIC: guest crashed",
                                      "native_panicked": "guest panicked at main.rs:1",
                                      "native_command": "No such command: invalid"}[mode])
if mode in ("orphan", "shutdown_fatal"):
    code = """import os, pathlib, signal, sys, time
root = pathlib.Path(os.environ['FAKE_ROOT'])
def terminate(number, frame):
    pathlib.Path(sys.argv[1]).write_text('BOOT_FATAL during cleanup\\n')
    sys.exit(0)
signal.signal(signal.SIGTERM, terminate if sys.argv[2] == 'shutdown_fatal' else signal.SIG_IGN)
(root / 'helper-ready').write_text('yes')
time.sleep(60)
"""
    child = subprocess.Popen([sys.executable, "-c", code, str(out.parent / "uart.log"), mode])
    (root / "child-pid").write_text(str(child.pid))
    while not (root / "helper-ready").exists(): time.sleep(.01)
'''


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="voln-vp tests ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        if os.environ.get("VOLN_VP_TEST_ARTIFACT_DIR"):
            destination = Path(os.environ["VOLN_VP_TEST_ARTIFACT_DIR"]).resolve() / self.id()
            self.addCleanup(shutil.copytree, self.root, destination, dirs_exist_ok=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("renode", "qemu-system-aarch64", "qemu-system-x86_64", "qemu-system-riscv64"):
            executable = self.bin / name
            executable.write_text(FAKE)
            executable.chmod(0o755)
        robot = self.bin / "renode-test"
        robot.write_text(FAKE_ROBOT)
        robot.chmod(0o755)
        cargo = self.bin / "cargo"
        cargo.write_text('#!/bin/sh\nprintf invoked > "$FAKE_ROOT/cargo-called"\nexit 99\n')
        cargo.chmod(0o755)
        self.input = self.root / "readonly source" / "guest image"
        self.input.parent.mkdir()
        self.input.write_bytes(b"prebuilt guest input")
        self.input.chmod(0o444)
        self.before = hashlib.sha256(self.input.read_bytes()).hexdigest()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("VOLN_VP_", "AXIOMOS_"))}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_ROOT=str(self.root),
                        VOLN_VP_TIMEOUT="2s", VOLN_VP_ARTIFACT_DIR=str(self.root / "artifacts"),
                        AXIOMOS_ROOT=str(self.input.parent))
        for key in ("AXIOMOS_KERNEL", "AXIOMOS_DISK_IMAGE", "AXIOMOS_ISO",
                    "AXIOMOS_OVMF_CODE", "AXIOMOS_OVMF_VARS"):
            self.env[key] = str(self.input)

    def invoke(self, backend, verb="test", *args):
        result = subprocess.run([str(ROOT / "backends" / backend / "adapters" / f"{verb}.sh"), *args],
                                env=self.env, cwd=self.root, text=True, capture_output=True, timeout=8)
        self.assertFalse((self.root / "cargo-called").exists(), result.stderr)
        self.assertEqual(hashlib.sha256(self.input.read_bytes()).hexdigest(), self.before)
        self.assertEqual(list(self.input.parent.iterdir()), [self.input])
        return result

    def test_all_targets_launch_and_capture_fresh_boot(self):
        for backend, arch in (("qemu", "aarch64"), ("qemu", "x86_64"),
                              ("qemu", "riscv64"), ("renode", "aarch64")):
            with self.subTest(backend=backend, arch=arch):
                self.env["VOLN_VP_ARCH"] = arch
                result = self.invoke(backend, "test", "--", "-name", "test guest")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = (self.root / "invocation.json").read_text()
                self.assertIn("test guest", args)
                self.assertIn("Artifacts:", result.stdout + result.stderr)
        captures = list((self.root / "artifacts").glob("*/uart.log"))
        self.assertEqual(len(captures), 4)
        self.assertTrue(all(path.stat().st_size for path in captures))

    def test_missing_inputs_and_unsupported_architecture_fail(self):
        self.env["AXIOMOS_KERNEL"] = str(self.root / "missing")
        for backend in ("qemu", "renode"):
            with self.subTest(backend=backend):
                result = self.invoke(backend)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "invocation.json").exists())
        self.env["VOLN_VP_ARCH"] = "../../wrong"
        self.assertNotEqual(self.invoke("qemu").returncode, 0)

    def test_failures_cannot_pass_on_process_status_or_stale_uart(self):
        for backend in ("qemu", "renode"):
            for mode, expected in (("exit", 7), ("empty", 1), ("panic", 1), ("fatal", 1), ("timeout", 124)):
                with self.subTest(backend=backend, mode=mode):
                    self.env.update(FAKE_MODE=mode, VOLN_VP_TIMEOUT="0.3s")
                    artifacts = self.root / "artifacts"
                    artifacts.mkdir(exist_ok=True)
                    (artifacts / "uart.log").write_text(MARKER)
                    self.assertEqual(self.invoke(backend).returncode, expected)
        self.env["FAKE_MODE"] = "monitor"
        self.assertEqual(self.invoke("renode").returncode, 1)
        self.env["FAKE_MODE"] = "early"
        self.assertEqual(self.invoke("qemu").returncode, 1)

    def test_qemu_marker_can_arrive_in_separate_reads(self):
        self.env["FAKE_MODE"] = "fragment"
        self.assertEqual(self.invoke("qemu").returncode, 0)

    def runtime(self):
        scenario = self.root / "scenario with spaces.robot"
        scenario.write_text("*** Test Cases ***\nExplicit Completion\n    Fail    stand-in only\n")
        self.env.update(VOLN_VP_TEST_MODE="runtime", VOLN_VP_SCENARIO=str(scenario))

    def test_runtime_modes_reject_unsupported_or_conflicting_requests(self):
        self.runtime()
        self.assertEqual(self.invoke("qemu").returncode, 2)
        self.assertEqual(self.reports()[-1]["outcome"], "unsupported")
        self.assertFalse((self.root / "invocation.json").exists())
        for backend in ("qemu", "renode"):
            self.assertNotEqual(self.invoke(backend, "run").returncode, 0)
        self.env["VOLN_VP_TEST_MODE"] = "boot"
        self.assertNotEqual(self.invoke("renode").returncode, 0)

    def test_native_runtime_requires_complete_passing_robot_evidence(self):
        self.runtime()
        for mode, expected in (("success", 0), ("boot_only", 1), ("assertion", 1),
                               ("skip", 1), ("empty", 1), ("teardown", 1),
                               ("malformed", 1), ("incomplete", 1), ("fatal", 1),
                               ("emulator_error", 1), ("native_panic", 1),
                               ("native_panicked", 1), ("native_command", 1),
                               ("exit", 7), ("timeout", 124)):
            with self.subTest(mode=mode):
                self.env.update(FAKE_MODE=mode, VOLN_VP_TIMEOUT="0.3s")
                result = self.invoke("renode")
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        reports = self.reports()
        self.assertTrue(all(r["mode"] == "runtime" and r["completed"] for r in reports))
        self.assertEqual(sum(r["outcome"] == "pass" for r in reports), 1)
        self.assertTrue(all(r["qualification_claims"] == [] for r in reports))

    def test_runtime_cleanup_handles_children_and_late_fatal(self):
        self.runtime()
        for mode, expected in (("orphan", 0), ("shutdown_fatal", 1)):
            with self.subTest(mode=mode):
                (self.root / "helper-ready").unlink(missing_ok=True)
                self.env["FAKE_MODE"] = mode
                result = self.invoke("renode")
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assert_stopped(int((self.root / "child-pid").read_text()))

    def test_version_failure_retains_diagnostic(self):
        self.env["FAKE_MODE"] = "version_exit"
        for backend in ("qemu", "renode"):
            with self.subTest(backend=backend):
                result = self.invoke(backend)
                self.assertEqual(result.returncode, 7)
                self.assertIn("version probe failure", result.stderr)
                self.assertIn("Artifacts:", result.stdout)

    def test_qemu_retains_final_diagnostic_on_exit(self):
        self.env["FAKE_MODE"] = "large_exit"
        result = self.invoke("qemu")
        self.assertEqual(result.returncode, 7)
        self.assertIn("final guest diagnostic", result.stderr)

    def test_renode_cleans_helpers_after_launcher_exits(self):
        self.env["FAKE_MODE"] = "orphan"
        self.assertEqual(self.invoke("renode").returncode, 0)
        self.assert_stopped(int((self.root / "child-pid").read_text()))

    def test_custom_marker_only_applies_to_diagnostic_run(self):
        self.env.update(FAKE_MODE="custom", VOLN_VP_BOOT_MARKER="custom diagnostic marker",
                        VOLN_VP_TIMEOUT="0.3s")
        for backend in ("qemu", "renode"):
            with self.subTest(backend=backend):
                self.assertNotEqual(self.invoke(backend).returncode, 0)
                self.assertEqual(self.invoke(backend, "run").returncode, 0)

    def test_qemu_snapshots_and_no_implicit_listeners(self):
        self.env["VOLN_VP_ARCH"] = "x86_64"
        self.assertEqual(self.invoke("qemu").returncode, 0)
        args = json.loads((self.root / "invocation.json").read_text())
        self.assertEqual(args[args.index("-monitor") + 1], "none")
        self.assertIn("tcg", args)
        self.assertNotIn("-s", args)
        drives = [args[index + 1] for index, arg in enumerate(args[:-1]) if arg == "-drive"]
        self.assertTrue(all("snapshot=on" in drive or "readonly=on" in drive for drive in drives))

    def test_invalid_timeouts_are_rejected(self):
        for backend in ("qemu", "renode"):
            for value in ("0", "nan", "-1s"):
                with self.subTest(backend=backend, timeout=value):
                    self.env["VOLN_VP_TIMEOUT"] = value
                    self.assertNotEqual(self.invoke(backend).returncode, 0)

    def test_qemu_fatal_during_cleanup_cannot_be_reported_as_pass(self):
        self.env["FAKE_MODE"] = "shutdown_fatal"
        result = self.invoke("qemu")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("BOOT_FATAL during shutdown", result.stderr)
        self.assertEqual(self.reports()[0]["outcome"], "fail")

    def test_qemu_run_invalid_architecture_retains_result(self):
        self.env["VOLN_VP_ARCH"] = "unsupported"
        self.assertNotEqual(self.invoke("qemu", "run").returncode, 0)
        self.assertEqual(len(self.reports()), 1)
        self.assertEqual(self.reports()[0]["outcome"], "unsupported")

    def wait_for_file(self, path):
        deadline = time.monotonic() + 3
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(path.exists(), f"timed out waiting for {path.name}")

    def test_interrupt_during_cleanup_still_stops_qemu(self):
        self.env["FAKE_MODE"] = "cleanup_hold"
        process = subprocess.Popen([str(ROOT / "backends/qemu/adapters/test.sh")],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        guest_pid = None
        try:
            self.wait_for_file(self.root / "cleanup-started")
            guest_pid = int((self.root / "pid").read_text())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 143, stdout + stderr)
            self.assert_stopped(guest_pid)
            self.assertEqual(self.reports()[0]["exit_code"], 143)
        finally:
            if guest_pid is not None:
                try:
                    os.killpg(guest_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()

    def test_interrupt_during_provenance_has_terminal_result(self):
        git = self.bin / "git"
        git.write_text("#!/usr/bin/env python3\nimport os,pathlib,time\np = pathlib.Path(os.environ['FAKE_ROOT'])\n(p / 'git-started').write_text(str(os.getpid()))\ntime.sleep(60)\n")
        git.chmod(0o755)
        for backend in ("qemu", "renode"):
            with self.subTest(backend=backend):
                marker = self.root / "git-started"
                marker.unlink(missing_ok=True)
                process = subprocess.Popen([str(ROOT / "backends" / backend / "adapters/test.sh")],
                                           env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True, start_new_session=True)
                try:
                    self.wait_for_file(marker)
                    process.send_signal(signal.SIGTERM)
                    stdout, stderr = process.communicate(timeout=8)
                    self.assertEqual(process.returncode, 143, stdout + stderr)
                    reports = [r for r in self.reports() if r["backend"] == backend]
                    self.assertEqual(len(reports), 1)
                    self.assertTrue(reports[0]["completed"])
                    self.assertEqual(reports[0]["outcome"], "fail")
                    self.assertEqual(reports[0]["exit_code"], 143)
                    self.assert_stopped(int(marker.read_text()))
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()

    def reports(self):
        return [json.loads(path.read_text()) for path in (self.root / "artifacts").glob("*/result.json")]

    def manifest_bundle(self, backend):
        directory = self.root / "bundle"
        directory.mkdir(exist_ok=True)
        path, manifest = bundle(directory, "virt" if backend == "qemu" else "virt-pi5")
        for key in list(self.env):
            if key.startswith("AXIOMOS_"):
                del self.env[key]
        self.env["VOLN_VP_ARTIFACT_MANIFEST"] = str(path)
        return path, manifest

    def test_manual_result_never_claims_qualification(self):
        for backend in ("qemu", "renode"):
            result = self.invoke(backend)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.reports()), 2)
        for report in self.reports():
            self.assertEqual(report["outcome"], "pass")
            self.assertEqual(report["identity"], "manual")
            self.assertEqual(report["qualification_claims"], [])
            self.assertTrue(report["completed"])
            self.assertIn("uart.log", report["evidence"])
            self.assertTrue(report["execution"]["argv"])
            self.assertTrue(report["execution"]["version"])
            self.assertTrue(report["implementation"]["files"])

    def test_manifest_launches_staged_bytes_and_retains_identity(self):
        for backend in ("qemu", "renode"):
            path, manifest = self.manifest_bundle(backend)
            result = self.invoke(backend)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for report in self.reports():
            self.assertEqual(report["identity"], "manifest_matched")
            self.assertEqual(report["qualification_claims"], [])
            self.assertEqual(report["boot_contract"], "axiomos-userspace-v1")
            self.assertEqual(report["inputs"]["source"]["commit"], "a" * 40)
            self.assertTrue(report["observed_milestones"])
        args = json.loads((self.root / "invocation.json").read_text())
        self.assertNotIn("-semihosting", args)

    def test_manifest_rejection_never_launches_and_writes_result(self):
        for backend in ("qemu", "renode"):
            path, manifest = self.manifest_bundle(backend)
            manifest["artifacts"]["kernel"]["sha256"] = "0" * 64
            path.write_text(json.dumps(manifest))
            result = self.invoke(backend)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / "invocation.json").exists())
        self.assertEqual(len(self.reports()), 2)
        for report in self.reports():
            self.assertEqual(report["outcome"], "fail")
            self.assertIn("sha256", report["reason"])

    def test_manifest_environment_and_argument_conflicts_rejected(self):
        for backend in ("qemu", "renode"):
            self.manifest_bundle(backend)
            for key, value in (("AXIOMOS_KERNEL", str(self.input)), ("VOLN_VP_BOOT_MARKER", "weakened"),
                               ("VOLN_VP_DTB", str(self.input)), ("VOLN_VP_ARCH", "x86_64")):
                with self.subTest(backend=backend, key=key):
                    self.env[key] = value
                    self.assertNotEqual(self.invoke(backend).returncode, 0)
                    del self.env[key]
            self.assertNotEqual(self.invoke(backend, "test", "--", "-smp", "2").returncode, 0)
            self.assertFalse((self.root / "invocation.json").exists())

    def test_all_failure_modes_have_terminal_results(self):
        for backend in ("qemu", "renode"):
            for mode, code in (("fatal", 1), ("timeout", 124), ("version_exit", 7)):
                self.env.update(FAKE_MODE=mode, VOLN_VP_TIMEOUT="0.3s")
                self.assertEqual(self.invoke(backend).returncode, code)
        self.assertEqual(len(self.reports()), 6)
        for report in self.reports():
            self.assertTrue(report["completed"])
            self.assertEqual(report["outcome"], "fail")
            self.assertEqual(report["qualification_claims"], [])

    def assert_stopped(self, pid):
        # An adopted zombie is already stopped; only its parent can reap it.
        stat = Path(f"/proc/{pid}/stat")
        if stat.exists():
            self.assertEqual(stat.read_text().split(") ", 1)[1].split()[0], "Z")

    def test_timeout_stops_emulator_and_helpers(self):
        self.env.update(FAKE_MODE="child", VOLN_VP_TIMEOUT="0.3s")
        for backend in ("qemu", "renode"):
            with self.subTest(backend=backend):
                self.assertEqual(self.invoke(backend).returncode, 124)
                self.assert_stopped(int((self.root / "pid").read_text()))
                self.assert_stopped(int((self.root / "child-pid").read_text()))

    def test_interrupt_stops_emulator_and_helpers(self):
        self.env["VOLN_VP_TIMEOUT"] = "20s"
        for backend, mode in (("qemu", "child"), ("renode", "child"),
                              ("qemu", "version_child"), ("renode", "version_child")):
            with self.subTest(backend=backend, mode=mode):
                self.env["FAKE_MODE"] = mode
                (self.root / "child-pid").unlink(missing_ok=True)
                command = ROOT / "backends" / backend / "adapters/test.sh"
                process = subprocess.Popen([str(command)], env=self.env, cwd=self.root,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    deadline = time.monotonic() + 4
                    while not (self.root / "child-pid").exists() and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue((self.root / "child-pid").exists())
                    process.send_signal(signal.SIGTERM)
                    stdout, stderr = process.communicate(timeout=4)
                    self.assertEqual(process.returncode, 143, stdout + stderr)
                    self.assert_stopped(int((self.root / "pid").read_text()))
                    self.assert_stopped(int((self.root / "child-pid").read_text()))
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()


if __name__ == "__main__":
    unittest.main()
