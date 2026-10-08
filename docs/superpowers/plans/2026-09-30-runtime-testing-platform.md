# Reliable Runtime Testing Platform Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task by task. Steps use checkbox syntax. Implementation is a separate task from this planning review.

**Goal:** Boot an identified AxiomOS build, exercise its real update and actuation interfaces, inject a controlled failure, and retain reproducible evidence of the simulated result.

**Architecture:** Preserve board/backend discovery and the existing adapters. QEMU handles generic kernel tests; Renode owns Pi peripheral models and backend-native Robot scenarios. AxiomOS owns builds and guest fixes; voln-vp consumes explicit artifacts read-only.

**Tech stack:** Existing Rust CLI, Bash adapters, Python standard library and unittest, stock QEMU, stock Renode with Robot Framework, C# where peripheral/interconnect behavior requires it.

**Spec:** The user's September 30 proposal, captured in the scope and acceptance gates below, refines [the approved design](../specs/2026-07-14-voln-vp-design.md). This plan proposes amendments to that design; it does not silently rewrite its decisions.

**Implementation status (September 30):** Tasks 1–3 have a local consumer
implementation and regression checks. Hosted CI passed at `a5c5423` (run
`36642831486`). The [identified AxiomOS build](../../probes/2026-09-30-identified-virt-build.md)
failed to link the virt kernel. A subsequent isolated linker fix produced a
validated bundle, but [three launches timed out](../../probes/2026-09-30-virt-linker-fix.md)
at the guest entry path. No guest qualification is claimed.
Tasks 4–8 remain gated as described below, except for the task 5 transport slice.

The [native suite transport](../../contracts/runtime-scenarios.md) portion of
task 5 is implemented independently of guest boot qualification: mode dispatch,
Renode Robot results, watchdog, cleanup and adapter regression checks. Actual
guest readiness/management/correlated-completion assertions remain unbound.
No AxiomOS edits or builds are authorized from this project.

## Global constraints

- No QEMU fork, custom QEMU machine, simulator framework, or CLI workflow language.
- No building or editing `/home/utkarsh/Work/axiomOS` or its worktrees from this repository's adapters. External producer/guest changes are separately owned work.
- Prioritize QEMU AArch64 `virt`; x86_64 and RISC-V readiness does not block that first result.
- Keep generic userspace boot, RISC-V demo boot, RP1 driver coverage, and managed-runtime coverage separate.
- Use fresh run directories; preserve bounded execution, disposable disk/firmware writes, final diagnostics, and process-group cleanup.
- Guest artifacts are never selected by searching `target/` or using modification time.
- GPIO/PWM come before sensor buses. Strict coverage checking ships with models, before any driver qualification.
- Single-core reproducibility first. No claim of physical safety, Pi firmware coverage, calibrated latency, multicore determinism, or exact replay of arbitrary hardware execution.

## Review focus

| Failure class | Required handling | Owning task |
|---|---|---|
| Valid-looking manifest, wrong ELF, swapped rootfs, or file replaced during validation | Validate bytes used for launch, not only manifest declarations | 1–2 |
| Ambient environment or extra emulator flags override manifest inputs | Reject conflicts in qualification tests; diagnostic runs remain visibly unqualified | 2–3 |
| Banner or stale completion event appears without scenario success | Require fresh readiness, request correlation, completed assertions, and clean teardown | 5 |
| Zero-returning unmapped MMIO or an unimplemented register inside a mapped model | Both must invalidate strict qualification; test both deliberately | 6 |
| E-stop/update race or altered trace passes because assertions are weak | Test each assertion with a deliberately violated expectation; verify observed PWM and audit events | 7–8 |

## Baseline verified on September 30

Inspected checkout: `main`, `8457aa166041619ce376a3738229fdd86713afc6`.
There is no `.codegraph/` in this repository. Existing untracked `.hermes/`
and `renode/probes/test-logger.resc` are outside this plan's changes.

Executed successfully:

```sh
cargo test --workspace --offline
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s backends/tests -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s backends/renode/tests -v
```

Results: 19 Rust integration tests, 12 adapter tests, 5 Renode Python tests.
No guest boots were rerun. [September 28 boot evidence](../../probes/2026-09-28-prebuilt-boot.md)
remains historical evidence of Pi rootfs allocation failure, x86 root-filesystem
failure, and absent compatible AArch64/RISC-V validation. Those binaries are
not established builds of the source revision inspected in that report.

## Delivery and dependencies

Use separate, independently reviewable changes; implementation should not open or merge PRs unless requested.

```text
1 artifact contract ── 2 adapter enforcement/results ── 4 identified boot
          │                         │                         │
          └── external build producer                         │
3 baseline CI (can land independently)                        │
                                    5 scenario lifecycle ─────┤
                                    6 RP1 driver coverage ────┤
                                                             7 update/e-stop
                                                             8 faults/replay
```

Model unit work and lifecycle adapter tests can proceed before Pi boot is
qualified. Guest driver/runtime qualification cannot. Split later milestones
into their own implementation plans after their required guest revision and
interfaces have been pinned; do not invent register maps or management commands
to make a plan look executable.

## 1. Define the producer/consumer artifact contract

**Files:** Create `docs/contracts/artifacts-v1.md`, `backends/artifacts.py`,
and `backends/tests/test_artifacts.py`. Update `README.md` with the manifest
boundary. Keep `cli/src/manifest.rs` for existing board/backend manifests.

**Interface:** `validate_manifest(path, *, board, backend, arch)` returns a
normalized dictionary or raises `ValueError` with a specific reason. It does
not launch an emulator, build a guest, or return a qualification verdict.
Use `json`, `hashlib`, `pathlib`, and `struct`; no new parsing framework.

- [ ] Specify JSON `schema_version: 1`, with these required fields:

  | Field | Meaning |
  |---|---|
  | `source` | Repository identity, full commit, boolean dirty status; submodule identities if used by the build |
  | `build` | Target triple, architecture, build profile, sorted enabled features, guest board, toolchain identification, producer build ID |
  | `artifacts` | Role-keyed relative file paths, byte sizes and SHA-256 hashes; kernel and rootfs required for the first generic userspace profile |
  | `rootfs` | External artifact role, or embedded container role plus file offset, length and digest |
  | `boot_contract` | Named, versioned contract ID; never executable commands or arbitrary success expressions |

  Distinguish guest board `rpi5` from simulator board `virt-pi5`; encode the
  permitted mapping in the consumer's compatibility table. Hash the manifest
  itself in each run. Kernel, rootfs, DTB and firmware roles must be explicit
  when applicable; an absent role is not an instruction to guess a default.
  A QEMU-generated DTB is recorded as generated by the pinned command/profile,
  rather than represented as a supplied DTB file.

- [ ] Make the initial compatibility table explicit: AArch64 `virt` requires
  `virt` and `cloud-profile`; `virt-pi5` requires `embedded-rpi5`. Reject the
  opposite board's features and unsupported profile/contract combinations.
  The producer handoff must record the complete accepted feature set for each
  pinned build, not only these minimum distinguishing features. Start with
  release builds; other build profiles remain diagnostic until qualified.
  Initial manifest qualification covers these two AArch64 profiles only.
  x86_64 ISO/firmware and RISC-V demo manifests return `unsupported` until their
  loader-specific identity checks and contracts are implemented; their existing
  explicit-input diagnostic boot checks remain available.
- [ ] Reject unknown schema versions, missing/duplicate fields or artifact
  roles, malformed hashes/types, invalid sizes, missing files, paths escaping
  the bundle, and architecture/board mismatches. Read ELF class, endianness,
  and `e_machine`; changing a manifest's architecture string cannot make an
  incompatible ELF valid. Do not attempt to infer Cargo features from an ELF.
- [ ] Validate an external rootfs against the same producer manifest as its
  kernel. For an embedded image, verify the declared byte range in the actual
  kernel file; bounds-check before hashing. If the producer cannot identify
  that range, the Pi embedded-rootfs contract is unsupported for qualification.
  A hash of a separately exported rootfs does not prove it was embedded.
- [ ] Add focused table-driven tests using synthetic ELF headers and byte
  strings. They establish consumer behavior only. Include correct bundle,
  swapped rootfs, one changed byte, wrong ELF architecture, incompatible
  features, dirty source, path escape, unsupported version, and out-of-bounds
  embedded range. Dirty inputs may validate structurally but cannot qualify.

  Representative check using the new public interface:

  ```python
  before = validate_manifest(manifest_path, board="virt", backend="qemu", arch="aarch64")
  rootfs_path.write_bytes(rootfs_path.read_bytes() + b"changed")
  with self.assertRaisesRegex(ValueError, "rootfs.*sha256"):
      validate_manifest(manifest_path, board="virt", backend="qemu", arch="aarch64")
  self.assertEqual(before["build"]["architecture"], "aarch64")
  ```

- [ ] Run the new tests first with the validator absent/incomplete, then after
  implementation; run `python3 -m unittest discover -s backends/tests -v`.
  Commit this contract and validator as one reviewable change.

**External producer handoff:** AxiomOS must generate the manifest in the same
build job that packages the artifacts, capture dirty status before building,
record resolved features/toolchains, and publish one immutable bundle with
build logs. Hash agreement proves byte identity, not truth of a self-authored
source claim. Qualification additionally requires an attributable producer
build record. No retrospective source attribution for the September binaries.

**Exit gate:** Valid bundles normalize predictably; all listed mutations are
rejected. Producer and consumer agree on the first AArch64 bundle contract.
Missing producer work does not prevent merging the tested consumer.

## 2. Enforce the contract in both adapters and write results

**Files:** Modify `backends/qemu/runner.py`,
`backends/renode/adapters/run.sh`, `backends/renode/adapters/test.sh`,
`backends/artifacts.py`, `backends/tests/test_adapters.py`; create
`docs/contracts/results-v1.md` and `backends/results.py`.

**Interfaces:** Accept `VOLN_VP_ARTIFACT_MANIFEST` in direct adapters.
Extend the artifact helper with `prepare_inputs(..., run_dir)` and a small
command-line entry point for the Bash caller. Produce `inputs.json` and fixed
role filenames under `run_dir/inputs/`; Bash uses these paths without `eval`
or parsing arbitrary manifest strings as shell code. `backends/results.py`
provides one atomic JSON result writer usable by Python and Bash.

- [ ] Allocate the fresh evidence directory before artifact validation.
  Stage supplied files into private copies, validate the staged bytes, and
  launch those exact copies. Never hardlink writable inputs. Retain QEMU's
  disposable disk/firmware overlays. This avoids hash/launch races with mutable
  build outputs without introducing a cache or artifact service.
- [ ] Preserve existing manual `AXIOMOS_*` inputs as diagnostic execution.
  Record `identity: manual` and no qualification claims, even if the boot
  observation passes. With a manifest, reject conflicting environment paths,
  architecture, DTB selection, or diagnostic boot-marker overrides. Reject raw
  emulator arguments for qualification tests; allow them for diagnostic `run`
  with the resulting command recorded and qualification disabled.
- [ ] Keep backend selection out of Rust policy. Each adapter calls the same
  validator with its own known board/backend/architecture. Validation must also
  apply when adapters are invoked without the CLI.
- [ ] Define `result.json` version 1 with `run_id`, `identity`,
  `qualification_claims`, `board`, `backend`, `architecture`, `mode`,
  `boot_contract`, `observed_milestones`, `outcome`, `reason`, `exit_code`,
  artifact/manifest hashes, execution profile, and relative evidence paths.
  `outcome` is `pass`, `fail`, or `unsupported`; the claims list names only
  coverage actually established by that run. A validator success sets no claim.
- [ ] Emit a terminal result for validation errors, version failures, boot
  failures, timeout, interrupts, and successful cleanup. Preserve existing
  nonzero emulator status and timeout 124. Use an unfinished-run record until
  finalization; a killed host/process with no terminal result is never a pass.
  Failure to write required evidence is itself a nonzero result, not success.
- [ ] Record voln-vp revision/dirty status, backend script/model hashes,
  emulator executable identity/version, machine, CPU/core count, RAM, firmware,
  DTB source, exact argv, environment controls, and time settings. Capture every
  loaded custom model, including the mailbox implementation, not only `.repl`.
- [ ] Make semihosting explicit. Candidate qualified AArch64 profile defaults
  to disabled; establish whether the identified guest needs it before accepting
  that profile. If required, use a separately named trusted-artifact profile in
  an isolated execution environment. Never infer isolation from `-snapshot`.
- [ ] Extend existing stand-in tests to prove validation prevents emulator
  invocation, inputs remain unchanged, manual passes have no claims, and every
  failure path retains a result. Include conflicting flags and a file changed
  after staging. Preserve all existing cleanup and fragmented-output cases.

  Use the existing adapter helper and invocation sentinel:

  ```python
  result = self.invoke("qemu")  # fixture supplies a manifest with a bad rootfs digest
  self.assertNotEqual(result.returncode, 0)
  self.assertFalse((self.root / "invocation.json").exists())
  reports = list((self.root / "artifacts").glob("*/result.json"))
  self.assertEqual(len(reports), 1)
  self.assertEqual(json.loads(reports[0].read_text())["outcome"], "fail")
  ```

- [ ] Run both Python suites, existing Rust tests, shell syntax checks for
  changed adapters, and `git diff --check`. Commit adapter enforcement/results.

**Exit gate:** Neither backend can start a qualification run with rejected
inputs; no manual, interrupted, unsupported, or evidence-incomplete execution
can be reported as qualified.

## 3. Expose inputs through the thin CLI and land baseline CI

Treat CLI forwarding and the independent CI workflow as separate changes.

**Files:** Modify `cli/src/cli/mod.rs`, `cli/src/backend.rs`,
`cli/tests/backend_dispatch.rs`, `README.md`, `TODO_NOW.md`; create
`.github/workflows/test.yml`.

- [ ] Add `--artifact-manifest PATH` to `RunArgs`. Forward it through
  `Command::env` as `VOLN_VP_ARTIFACT_MANIFEST`; pass board/verb context without
  teaching Rust emulator names or parsing artifact JSON. Preserve spaces and
  existing adapter exit-code propagation. Conflicting CLI/env manifests fail.
- [ ] Keep `--dry-run` non-executing; show resolved adapter, selected manifest,
  arguments, and that artifact validation/guest execution has not occurred.
  Add a fake adapter test that observes the forwarded environment and a dry-run
  test whose adapter must never execute.
- [ ] Add PR and `main` push CI that installs the declared Rust/Python tools,
  uses `cargo test --workspace --locked`, and runs both Python suites. On a
  clean hosted runner, allow Cargo to obtain locked dependencies; do not copy
  the local `--offline` command without first populating its cache.
- [ ] Preserve failed stand-in run artifacts when CI requests retention, and
  upload them on failure. Label this job adapter/CLI validation; it must not
  advertise guest boot coverage. Do not create an always-green guest stub job.
- [ ] Amend tracker/design wording: C# interconnect instead of “PCIe RC python
  peripheral”; single-core GPIO/PWM as this milestone's subset; strict mode
  brought forward; early CI; canonical event comparison instead of UART-only
  determinism. Preserve full-machine aspirations as later work, and correct
  claims that hardware sensor replay guarantees identical CPU execution.

**Exit gate:** Local tests pass and the actual hosted workflow completes before
CI is described as green. No live guest dependency is required for this job.

## 4. Qualify one identified boot, then the Pi image

**Files:** Add an actual-date report under `docs/probes/`; update `README.md`
and `TODO_NOW.md`. Store the accepted execution profile beside the existing
board/backend configuration. Populate it from the real tested toolchain and
emulator; do not invent a version pin from this planning review.

- [ ] Obtain the producer-built AArch64 `virt` bundle and its build record.
  Pin its complete feature set, rootfs, userspace boot contract, machine type,
  emulator build, CPU, core count, memory and semihosting policy. Explicitly
  configure firmware/DTB inputs rather than accepting changing system defaults.
- [ ] Run three independent fresh launches with the same tuple and manifest.
  Each must reach `=== axiomos eBPF init ===`, contain no observed boot fatal,
  pass cleanup, and retain complete evidence. Three repetitions establish this
  bounded boot gate, not a reliability percentage or runtime soak guarantee.
- [ ] Publish hashes, producer identity, exact invocation, reports and durable
  evidence location. A `/tmp` path alone is not durable regression evidence.
- [ ] In separately authorized AxiomOS work, diagnose Pi rootfs allocation:
  allocation caller, requested size, initialized heap, available contiguous
  capacity, embedded range, and copy/lifetime behavior. Carry an identified
  replacement bundle back to this repo and repeat the Pi boot gate. Preserve
  canonical EL1/MMU behavior; do not hide the failure with a high-address alias.
- [ ] Diagnose x86 root-filesystem failure independently when its bundle is
  available. Keep x86/RISC-V adapters and report their own unsupported/failing
  states; never promote the RISC-V demo marker to a userspace/runtime pass.
- [ ] Retain historical failing inputs where storage and redistribution allow;
  otherwise retain hashes and logs. Do not fabricate binary regression fixtures.

**Exit gate:** Generic AArch64 userspace boot qualifies first. Pi userspace boot
is a separate prerequisite for its guest scenarios. Neither proves v0.5 runtime
behavior, RP1 operation, or compatibility of any other artifact.

## 5. Separate boot smoke from runtime scenario lifecycle

**Files:** Extend `RunArgs`/dispatch and adapter tests; modify the QEMU runner
and Renode test adapter; add `backends/renode/tests/lifecycle.robot` and a
backend-native scenario runner only as needed by those tests.

**Proposed CLI:** `test --mode boot` remains the default.
`test --mode runtime --scenario PATH` selects an explicit backend-native test.
The CLI forwards mode/path as adapter context and does not interpret steps.
Adapters reject unsupported mode/scenario combinations before launch.

- [ ] Define the lifecycle as readiness → real guest commands → correlated
  completion → assertions → cleanup → result. Keep a wall-clock watchdog
  independent of guest progress and backend virtual time.
- [ ] Leave QEMU's 0.1-second post-banner stop in boot mode only. A QEMU runtime
  scenario uses an explicit tested guest completion contract, not a longer
  sleep or boot banner. Until such a guest interface is bound, report QEMU
  runtime mode unsupported rather than claim generic scenario support.
- [ ] Use `renode-test` and Robot's assertion result for Renode runtime mode;
  retain Robot XML/HTML alongside UART and emulator logs. Readiness alone cannot
  terminate the scenario. The existing short `RunFor` boot path is not reused
  as a runtime completion rule.
- [ ] Exercise lifecycle failures using stand-ins: boot only, completion before
  readiness, wrong request ID, missing completion, failed assertion, fatal after
  completion, emulator failure, stale files, timeout, and surviving children.
  Success requires all assertions and finalized clean evidence, not a marker
  racing with an error during teardown.
- [ ] Run the real Robot lifecycle suite with the qualified Pi bundle when
  available; adapter tests alone do not satisfy guest scenario acceptance.

**Exit gate:** Boot smoke remains compatible; runtime scenarios cannot pass
from startup output and all listed failure cases produce failing results.

## 6. Model only the RP1 attachment, GPIO and PWM path needed

**Files:** Create `docs/contracts/rp1-driver-coverage.md`; modify
`boards/virt-pi5/board.toml`, `boards/virt-pi5/renode/virt-pi5.repl` and the
boot script. Place required models in `backends/renode/peripherals/` and tests
in `backends/renode/tests/`. Exact model boundaries follow the register inventory.

- [ ] Pin the AxiomOS driver commit from the accepted manifest. Inventory every
  touched register, width/alignment, mask, reset value, polling dependency,
  read/write side effect, BAR/configuration operation, IRQ route/acknowledgment,
  and PWM output-enable/polarity behavior. Map entries to driver source symbols.
- [ ] Audit the pinned Renode distribution for reusable models. The old design's
  claimed RP2040 availability is not evidence. Reuse only after comparing the
  touched register contract. Use C# for the RC/endpoint and models requiring
  IRQ connections or virtual-time scheduling; Python remains suitable for
  genuinely simple transaction-local behavior.
- [ ] Implement RC/endpoint reachability and the actual initialization sequence,
  then GPIO read/write/interrupts, then PWM configuration/output capture. Keep
  the existing five-working-day RC investigation budget as a decision gate,
  not a deadline to fake link status. Show evidence and remaining gaps at expiry.
- [ ] If that gate selects the documented flat-map fallback, name a different
  execution profile and record `pcie_enumeration: false`. Verify that the pinned
  guest already supports the fallback DTB/address path. If it does not, require
  a separately reviewed guest change; no silent bypass or “link up” constants.
- [ ] Strict mode must catch unmapped-bus accesses, unknown registers inside
  mapped peripherals, unsupported widths, and unexplained bits/operations.
  Test the pinned Renode warning/hook mechanism directly. Intentional stubs
  need named, narrow coverage exclusions; no blanket warning suppression.
- [ ] Build native model tests for reset, readback, GPIO edge/IRQ acknowledgment,
  PWM period/duty/enable/polarity, and reset while active. Emit ordered output
  events with virtual timestamps, channel, period, duty, enable and effective
  output state; capture transitions as well as final values.
- [ ] Call the real guest GPIO/PWM drivers in Robot suites. Deliberately request
  an unimplemented register and deliberately assert a wrong PWM value; both
  suites must fail. A host-side register poke is model evidence, not proof that
  the guest driver path works.

**Exit gate:** Real guest driver tests and reset behavior pass with zero
unexplained accesses. Coverage says exactly whether PCIe enumeration was tested.
No I2C, SPI, IMU, ADC, or multicore prerequisite is added to this milestone.

## 7. Bind and test managed updates and e-stop

**Files:** Create `docs/contracts/managed-runtime-scenarios.md` and
`backends/renode/tests/managed-runtime.robot`; add a small Robot resource file
only for guest commands actually shared across scenarios.

Before coding tests, derive from the pinned guest revision: callable management
transport, readiness/version query, artifact-install/activate commands, generation
and request-ID semantics, authority checks, e-stop latch/recovery policy, audit
events, resource accounting, and effective safe PWM state. Record source symbols
and real wire examples. A missing capability is an external guest prerequisite,
not permission to patch kernel memory through the emulator.

| Scenario | Positive invariant | Deliberately violated expectation must fail |
|---|---|---|
| Invalid update | Invalid signature/format rejected; active generation and authorized output unchanged | Claim acceptance, generation change, or changed output |
| Successful activation | One publication boundary; documented generation advances; no overlapping output ownership | Expect duplicate ownership or the wrong publication sequence |
| Stale activation | Old expected-active generation rejected after a newer publication | Expect stale request to take control |
| Revoked authority | Revoke after verification and before activation; activation checks current authority | Expect earlier verification to authorize publication |
| E-stop during update | Reach a defined pending state, latch e-stop through its real input, then attempt activation; outputs remain safe | Expect activation or any unsafe pulse while latched |
| Repeated failed installs | After 100 failures, compare ownership and resource counters against documented bounds and the initial state | Tighten the allowed bound below the observed value or inject an out-of-bound observation |

- [ ] Implement every positive case with both guest audit evidence and captured
  GPIO/PWM evidence. Invalid-update equality compares defined commanded/effective
  output state, not arbitrary UART string equality.
- [ ] For each assertion set, rerun with one wrong expectation and prove a
  nonzero test result. Keep assertion self-tests separate from release suites;
  an expected-negative guest result is a passing scenario, a broken oracle is not.
- [ ] Define the observation interval and maximum safe-state transition bound
  from the selected runtime contract. Do not assume “0% duty” universally means
  safe; account for channel enable, polarity and the documented actuator policy.
- [ ] If the real management API cannot expose or synchronize the required
  between-verification-and-activation boundary, mark that scenario unsupported
  until a guest-supported interface exists. Host sleeps are not evidence of the race.
- [ ] Make scenario results attributable to request IDs, artifact hashes,
  generations, runtime ABI revision, and captured output sequence numbers.

**Exit gate/demo:** Boot the pinned Pi image; activate behavior A and observe
its expected PWM; enter a pending update, assert e-stop, attempt activation of B;
observe the specified rejection and safe output through the entire defined
interval. Retain the successful scenario and evidence that its negative oracle
fails. Report a managed-runtime pass only for the scenarios actually supported.

## 8. Add controlled faults and reproducible simulated replay

**Files:** Create `docs/contracts/trace-v1.md`, `backends/renode/trace.py`,
`backends/renode/tests/test_trace.py`, and `backends/renode/tests/replay.robot`.
Place one small owned trace fixture under `traces/`.

- [ ] Start with a GPIO edge/held input and suppressed interrupt. Add device
  response failures only when that modeled interface exists. No IMU sample
  injection before its bus and real guest driver are exercised.
- [ ] Use versioned JSON Lines with one header and ordered events. The header
  binds artifact, platform/model, emulator/profile and scenario hashes, initial
  state, CPU count, time configuration and seed if used. Events carry an integer
  virtual-time tick or a defined guest trigger, sequence number, type and payload.
- [ ] Define units, tie ordering, payload bounds, checksum coverage and supported
  event types. Reject unsupported versions, corruption, truncation, unknown
  events, decreasing timestamps, ambiguous ordering, incompatible artifact or
  model identity, and impossible initial state before injecting anything.
- [ ] Schedule through Renode virtual time or documented guest events. Keep
  Python host time only for watchdog/cleanup. Record effective CPU performance,
  synchronization quantum and all relevant clock settings from the pinned backend.
- [ ] Compare canonical actuator and audit-event streams, including causal
  order and contract-required virtual timing. Exclude host timestamps/run paths
  explicitly; never normalize away a generation mismatch or unsafe output pulse.
- [ ] Repeat the same single-core trace on three clean initial states and require
  the defined event streams to match. Mutate a trace checksum/version, artifact,
  and expected output in separate checks and prove each is rejected or fails.
- [ ] Add qualified guest smoke/scenario CI only once its immutable input
  bundles and pinned emulator environment are provisioned. Upload all evidence
  on success and failure; a missing required bundle is unsupported/failing, never
  a silent skip. Add nightly replay only after the per-commit path is real.

**Exit gate:** A pinned simulated scenario is reproducible and malformed or
incompatible replay cannot silently run. Recorded physical sensor samples alone
do not determine a physical robot's interrupt history, races or initial state.

## Stop points and completion criteria

The first implementation tranche is tasks 1–3, with the producer handshake in
parallel. It is useful and independently testable before guest binaries arrive.
Do not expand that tranche into RP1 models or guest fixes.

The full milestone ends at the small demo in task 7 plus one reproducible fault
scenario in task 8. Keep QEMU native record/replay, full robot physics, GUI,
all-sensor coverage, multicore qualification and latency calibration outside it.

## Primary references checked for this plan

- QEMU `virt` is a generic, versioned platform, not Pi hardware:
  [QEMU Arm virt documentation](https://www.qemu.org/docs/master/system/arm/virt).
- Renode already supplies the Robot execution/reporting integration used in task 5:
  [Testing with Renode](https://renode.readthedocs.io/en/latest/introduction/testing.html).
- Advanced interconnect belongs in C#; bus and register coverage require explicit
  handling: [Renode peripheral modeling guide](https://renode.readthedocs.io/en/latest/advanced/writing-peripherals.html).
- Virtual and host time are separate execution concepts:
  [Renode time framework](https://renode.readthedocs.io/en/latest/advanced/time_framework.html).
- Semihosting bypasses guest/host isolation and requires trusted code:
  [QEMU semihosting documentation](https://www.qemu.org/docs/master/about/emulation.html#semihosting).
- Native QEMU replay needs more than an `icount` flag; block/network inputs have
  their own configuration: [QEMU record/replay](https://www.qemu.org/docs/master/system/replay.html).
  Instruction counting is not cycle-accurate and excludes multi-threaded TCG:
  [QEMU TCG instruction counting](https://www.qemu.org/docs/master/devel/tcg-icount.html).

These current upstream references inform the approach. Implementation must
verify concrete APIs and flags against the emulator versions selected for qualification.
