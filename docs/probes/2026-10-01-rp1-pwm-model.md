# RP1 PWM unit-model verification — 2026-10-01

The isolated C# PWM model passed 12 native Robot tests on Renode
`1.16.1.16973` (`d66b0c2a-202602160923`, .NET `10.0.11`) with Robot Framework
`6.1`. These are host-initiated register tests; no guest was executed.
The model is not attached to the canonical Pi platform.

The [model contract](../contracts/rp1-pwm-model.md) describes the register subset,
explicit timing assumptions, unsupported behavior and native test command.
Tests cover reset/readback, delayed control application, range/duty updates at
overflow, independent channels, inversion, capture and rejected accesses.
Queued activation cannot consume a zero range, and mode changes are captured
even when the output classification stays low.

## Adapter gate checks

Each case used the real Renode runtime adapter with `VOLN_VP_STRICT_MMIO=1`:

| Case | Native Robot result | Adapter exit | Observation |
| --- | --- | --- | --- |
| Positive model suite | 6 pass | 0 | Terminal suite success after cleanup |
| Unsupported model accesses | 6 pass | 1 | Expected exceptions still leave disqualifying Error logs |
| Unmapped bus read | 1 pass | 1 | Renode's zero-valued read still leaves a disqualifying warning |
| Deliberately wrong duty assertion | 5 pass, 1 fail | 1 | Incorrect output expectation fails the scenario |

All four results are terminal, record `strict_mmio: true`, and retain
`qualification_claims: []`. Manual kernel/DTB inputs contain only
`Adapter-only fixture; not a guest image.` The standalone scenarios do not
load these inputs or execute the generated boot wrapper. This checks the
adapter lifecycle and log gates, not a boot or managed-runtime contract.

The shared validation also passed: 32 adapter/result checks, 23 Rust CLI tests,
5 Python peripheral tests, Rust formatting, shell syntax and whitespace checks.
Hosted CI runs these shared checks; the native model tests were run locally.

## Retained evidence and reproduction

- [Evidence index](2026-10-01-rp1-pwm-model-evidence/evidence.json): emulator
  binary hashes, versions, invocation, test counts, adapter outcomes and hashes
  of every archive member.
- [Native evidence archive](2026-10-01-rp1-pwm-model-evidence/native-evidence.tar.gz):
  model/test source, Robot XML/HTML, native logs, adapter commands, staged
  scenarios, inputs and terminal results. Failed-test `.save` snapshots are
  omitted; their logs and assertions are retained.

Run the contract's native command against the checked-in source to reproduce
the unit tests. For adapter cases, extract the archive into a fresh directory
and use each retained `scenario.robot`; update its absolute `MODEL_FILE`
variable to this checkout. Supply the retained diagnostic inputs with
`AXIOMOS_KERNEL` and `VOLN_VP_DTB`, select `VOLN_VP_VERB=test` and
`VOLN_VP_TEST_MODE=runtime`, set
`VOLN_VP_SCENARIO` to that scenario and `VOLN_VP_STRICT_MMIO=1`, then run
`backends/renode/adapters/run.sh` with a fresh `VOLN_VP_ARTIFACT_DIR`.
Original absolute paths in retained commands/results identify this run and
must be adjusted for another checkout.

PCIe discovery, clock-controller behavior, GPIO/pads, real guest-driver tests,
runtime updates and physical actuation remain unqualified. The warning gate
cannot detect silent reserved accesses inside stock peripheral models.
