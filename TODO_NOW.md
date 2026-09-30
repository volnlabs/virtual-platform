voln-vp — implementation checklist

plans: docs/superpowers/plans/2026-09-30-runtime-testing-platform.md
this file is the at-a-glance tracker
follow the spec's phase order. stop gates between phases are real.

2026-09-30 — artifact identity and baseline CI (first tranche)
  [x] versioned JSON manifest and shared stdlib validator
  [x] AArch64 ELF, feature profile, hashes and embedded-rootfs range checks
  [x] private staged copies; no producer inputs are modified
  [x] terminal result.json for observed success, failure and unsupported inputs
  [x] --artifact-manifest CLI forwarding, conflict rejection and honest dry-run
  [x] adapter/CLI CI workflow and retained stand-in test evidence
  [x] hosted workflow completion (run 36642831486 passed at a5c5423)
  [ ] attributable AxiomOS producer bundle and pinned execution profile
  [!] clean b8953b5 virt build: rootfs built; kernel link lacks __kernel_end
  Evidence: docs/probes/2026-09-30-identified-virt-build.md
  Manifest identity is not guest qualification. All qualification claims remain empty.

2026-09-28 — prebuilt boot/test milestone
  [x] QEMU adapters launch explicit prebuilt inputs; no source-tree builds
  [x] real bounded boot tests for all three QEMU targets
  [x] unique UART/log captures, input hashes, version and command evidence
  [x] QEMU disk/firmware snapshots and timeout/signal process cleanup
  [x] Renode explicit input, fixed test marker, Monitor/panic failure checks
  [x] adapter regression checks, including spaces and stale captures
  [!] live Pi 5 image: 10 MiB embedded-rootfs allocation panic
  [!] live x86_64 image: BOOT_FATAL code=root-filesystem-invalid
  [ ] compatible QEMU AArch64 and RISC-V prebuilt-image validation
  Evidence: docs/probes/2026-09-28-prebuilt-boot.md
  Adapter checks are not guest boot PASS. AxiomOS remains read-only.

phase 0 — precondition
  [x] design spec read (docs/superpowers/specs/2026-07-14-voln-vp-design.md)
  [x] axiomOS sibling repo confirmed buildable

phase 1 — risk gate (probes only, no voln-vp structure)
  [x] 1.1 confirm axiomOS produces DTB-aware AArch64 ELF
  [x] 1.2 probes-only skeleton (renode/probes/, tools/, docs/probes/)
  [x] 1.3 minimal Pi 5 DTB stub
  [x] 1.4 stock ARMv8-A boot .resc
  [x] 1.5 UART capture (Renode file backend; legacy python shim retained)
  [x] 1.6 install renode, pin stock core model (Cortex-A78, Renode 1.16.1)
  [x] 1.7 probe driver shell script
  [x] 1.8 RUN PROBE — PASS recorded in docs/probes/2026-07-30-armv8a-risk-gate.md
        -> PASS: proceed
        -> FAIL with diagnostic: iterate DTB / kernel entry
        -> HARD FAIL: spec says revisit backend choice. STOP.

phase 2 — CLI + adapter contract + virt-pi5 boot
  [x] 2.1 workspace + cli crate skeleton (cargo build, --version)
  [x] 2.2 errors module
  [x] 2.3 manifest types + validation (TDD, 5 cases)
  [x] 2.4 backend discovery (TDD, 3 cases)
  [x] 2.5 backend dispatch + run/test wiring (TDD, 6 cases)
  [x] 2.6 qemu backend wrapped
  [x] 2.7 renode backend manifest + doctor
  [x] 2.8 virt-pi5 board manifest
  [x] 2.9 --dry-run flag
  [x] 2.10 mailbox stub Python peripheral
  [x] 2.11 virt-pi5 DTB (real, not phase 1 stub)
  [x] 2.12 virt-pi5.repl + boot script
  [x] 2.12a direct-kernel EL1 contract; Renode high-half translation verified
  [!] 2.13 verify boot-to-userspace — BLOCKED: current axiomOS image panics
        allocating the embedded rootfs before EL0 (20 MiB July image;
        10 MiB image found on disk in September).
        Evidence: docs/probes/2026-07-30-phase2-virt-pi5-boot.md

phase 3 — RP1 models + driver suite
  First guest milestone: strict single-core GPIO/PWM. Remaining peripherals
  and full multicore machine coverage follow only when that milestone is green.
  MODEL UNIT WORK UNBLOCKED: the corrected kernel reaches RP1 initialization.
  Guest integration remains blocked by 2.13. Audit found no installed
  RP2040/Pico model; `picosoc` is PicoRV32, and interconnect/PCIe modeling
  requires C# rather than a Renode request-based Python peripheral.
  [ ] 3.1 RP2040 reuse audit (BLOCKER for 3.2-3.6)
  [ ] 3.2 PCIe RC/endpoint C# model (5-day investigation budget)
  [ ] 3.12 strict-mode enforcement (required with the first model)
  [ ] 3.3 RP1 GPIO (TDD)
  [ ] 3.4 RP1 PWM with capture (TDD)
  [ ] 3.5 RP1 I²C + imu fake (TDD)
  [ ] 3.6 RP1 SPI loopback (TDD)
  [ ] 3.7 wire peripherals into virt-pi5.repl
  [ ] 3.8 robot: GPIO toggle readback
  [ ] 3.9 robot: PWM sweep capture
  [ ] 3.10 robot: I²C IMU + SPI loopback
  [ ] 3.11 robot: canonical actuator/audit event determinism (single core first)
  [ ] 3.13 PCIe flat-map fallback (DECISION gate, only if 3.2 stalls)
  [ ] 3.14 full driver suite green

phase 4 — sensors, injection, trace replay
  BLOCKED by 2.13, Phase 3 integration, and the absence of guest I²C/SPI/ADC
  driver behavior.
  [ ] 4.1 trace format v1 spec (one page)
  [ ] 4.2 trace parser (TDD, 7 cases)
  [ ] 4.3 trace writer (TDD, 2 cases)
  [ ] 4.4 IMU device with injection (TDD)
  [ ] 4.5 sensor hub dispatcher (TDD)
  [ ] 4.6 robot keyword: inject imu.accel_x 9.81 @ t=10ms
  [ ] 4.7 robot: IMU inject scenario
  [ ] 4.8 trace replay integration (TDD)
  [ ] 4.9 robot: IMU replay + actuator capture
  [ ] 4.10 bridge interface contract (NO implementation)
  [ ] 4.11 verify full suite green

phase 5 — CI hardening, nightly, error handling
  BLOCKED for scenario wiring by 2.13. CLI-only CI may proceed separately
  but cannot satisfy the planned green pipeline.
  [ ] 5.1 CI log helper
  [ ] 5.2 per-commit driver
  [ ] 5.3 nightly driver
  [ ] 5.4 verify.sh local wrapper
  [ ] 5.5 error-handling audit
  [ ] 5.6 UART dump on simulator failure (TDD)
  [x] 5.7 GH Actions adapter/CLI workflow; guest jobs still gated
  [ ] 5.8 GH Actions nightly workflow
  [ ] 5.9 CI docs
  [ ] 5.10 verify pipeline green

notes
- commit after every task
- spec decisions log is the source of truth for "is X in scope?"
- never fudge exit codes; never report PASS without real artifact
- amber (FAIL with diagnostic) is normal and publishable; HARD FAIL is the only blocker
- canonical Renode boots at EL1 and must exercise real translation; no
  high-address alias is present. Any future alias must be experimental,
  opt-in, ineligible for semantic gates, and removed after its narrow use.
