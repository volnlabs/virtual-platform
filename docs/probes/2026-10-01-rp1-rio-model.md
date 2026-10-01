# RP1 RIO output-model verification — 2026-10-01

The combined GPIO/RIO suite passed 15 native Robot tests on Renode
`1.16.1.16973` (`d66b0c2a-202602160923`, .NET `10.0.11`) with Robot Framework
`6.1`. The new GPIO function-selection test first failed against the previous
model's unsupported peripheral-source check, then passed with the RIO model.

The [contract](../contracts/rp1-gpio-model.md) defines the output-only RIO
region and its explicit zero initialization/reset preset. Tests cover
OUT/OE readback and aliases, pin isolation, NULL versus GPIO selection,
normal/inverse/forced overrides, source/effective STATUS fields, reset of both
register windows and strict rejection without state mutation. Existing GPIO
input/IRQ tests also pass; changing RIO output does not invent input loopback.

This reproduces the IO_BANK0 writes from the pinned driver's output setup,
not execution of the guest driver or its pad accesses. There is no canonical
Pi-platform change, guest boot or physical actuation claim. The cited sources
do not establish RIO hardware reset values; SYNC_IN and other RIO inputs are
rejected until their clocked behavior is modeled.

| Real adapter case (`VOLN_VP_STRICT_MMIO=1`) | Native assertions | Adapter exit |
| --- | --- | --- |
| Positive GPIO/RIO suite | 10 pass | 0 |
| Expected unsupported operations | 5 pass | 1: model Error logs |
| Deliberately wrong GPIO27 output expectation | 9 pass, 1 fail | 1: scenario assertion |

Every case produced a terminal result with `strict_mmio: true` and
`qualification_claims: []`. The diagnostic kernel/DTB fixtures contain only
`Adapter-only fixture; not a guest image.` No scenario loads those files or
executes the generated boot wrapper. AxiomOS was neither edited nor built.

Shared verification passed: 32 adapter/result tests, 23 Rust CLI tests and
5 Python model/platform tests, plus Rust formatting and whitespace checks.
Hosted CI runs the shared checks; native model verification was local.

The [evidence index](2026-10-01-rp1-rio-model-evidence/evidence.json) records
versions, binary/datasheet hashes, invocation, counts and hashes for every
member of the [native archive](2026-10-01-rp1-rio-model-evidence/native-evidence.tar.gz).
Source, XML/HTML, native/shared-test logs, commands, staged scenarios, inputs
and terminal results are retained; failed-test `.save` snapshots are omitted.

Run the contract's native command for unit reproduction. For adapter cases,
extract the archive and update each retained `scenario.robot`'s absolute
`MODEL_FILE` to this checkout. Select `VOLN_VP_VERB=test`,
`VOLN_VP_TEST_MODE=runtime`, `VOLN_VP_STRICT_MMIO=1`, set `VOLN_VP_SCENARIO` to
that scenario and `AXIOMOS_KERNEL`/`VOLN_VP_DTB` to the diagnostic inputs, and
run `backends/renode/adapters/run.sh` with a fresh `VOLN_VP_ARTIFACT_DIR` using
the installed Renode release's Python environment. Original absolute paths
identify this run and must be adjusted for another checkout.

Pads, filtered/clocked inputs, alternate peripheral muxing, PCIe/IACK delivery
and real guest-driver qualification remain open.
