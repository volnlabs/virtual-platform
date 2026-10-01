# RP1 GPIO unit-model verification — 2026-10-01

Nine native Robot tests passed on Renode `1.16.1.16973`
(`d66b0c2a-202602160923`, .NET `10.0.11`) with Robot Framework `6.1`.
Tests use conditioned digital samples and host register accesses; no guest was
executed. The model is not attached to the canonical Pi platform.

The [model contract](../contracts/rp1-gpio-model.md) records the supported
registers, sampling assumptions and field exclusions. Tests observe the native
IRQ through a connected LED sink and check forced output capture, independent
edge latches, live levels, destination masking, ordinary/atomic acknowledgment,
reset while active and invalid-access rejection without state mutation.

| Real adapter case (`VOLN_VP_STRICT_MMIO=1`) | Native assertions | Adapter exit |
| --- | --- | --- |
| Positive GPIO suite | 6 pass | 0 |
| Expected unsupported operations | 3 pass | 1: model Error logs |
| Deliberately wrong IRQ expectation | 5 pass, 1 fail | 1: scenario assertion |

Every case has a terminal result with `strict_mmio: true` and
`qualification_claims: []`. Manual kernel/DTB inputs contain only
`Adapter-only fixture; not a guest image.` The suites never load those files
or execute the generated boot wrapper. This is evidence for the model and
adapter gates, not guest boot, management commands or physical actuation.

The 32 shared adapter/result tests, 23 Rust CLI tests and 5 Python
peripheral/platform tests also passed, as did Rust formatting and whitespace
checks. Hosted CI exercises the shared tests; the native GPIO suite was run
locally. AxiomOS was neither edited nor built.

The [evidence index](2026-10-01-rp1-gpio-model-evidence/evidence.json) retains
versions, binary/datasheet hashes, invocation, counts and SHA-256 hashes for
every member of the [native archive](2026-10-01-rp1-gpio-model-evidence/native-evidence.tar.gz).
The archive includes source, native XML/HTML and logs, shared-test logs, staged
scenarios, inputs, commands and terminal adapter results. Failed-test `.save`
snapshots are omitted.

For reproduction, run the native command in the contract. To repeat adapter
cases, extract the archive, update each retained `scenario.robot`'s absolute
`MODEL_FILE` to this checkout and set `VOLN_VP_VERB=test`,
`VOLN_VP_TEST_MODE=runtime`, `VOLN_VP_STRICT_MMIO=1`, `VOLN_VP_SCENARIO` to that
scenario, and `AXIOMOS_KERNEL`/`VOLN_VP_DTB` to the retained diagnostic inputs.
Run `backends/renode/adapters/run.sh` with a fresh `VOLN_VP_ARTIFACT_DIR` and the
installed Renode release's Python test environment. Recorded absolute paths
describe this run and must be adjusted on another machine.

Pads, filtering, RIO/mux, PCIe/IACK delivery and the pinned driver's complete
configuration sequence remain outside this profile. A passing unit suite
does not advance the guest qualification gate.
