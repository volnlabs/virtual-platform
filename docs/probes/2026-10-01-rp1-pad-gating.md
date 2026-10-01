# RP1 digital pad-gating verification — 2026-10-01

The combined GPIO/RIO/pad suite passed 21 native Robot tests on Renode
`1.16.1.16973` (`d66b0c2a-202602160923`, .NET `10.0.11`) with Robot Framework
`6.1`. The disabled-input test first failed against `e3eea24`: an external high
sample produced STATUS `0x30a20000` instead of gated-low `0x00400000`.

The [contract](../contracts/rp1-gpio-model.md) defines the strict `pads` region,
per-pin reset values, OD output gating and explicit IE input policy. Native
checks cover normal and atomic register access, pin isolation, reset,
RIO/forced-output gating, held-input resampling, IRQ effects and rejection of
unsupported widths, alignment, registers and reserved bits without mutation.
The output setup test reproduces the pinned driver's IO_BANK0 and pad writes;
it does not execute the guest driver.

| Real adapter case (`VOLN_VP_STRICT_MMIO=1`) | Native assertions | Adapter exit |
| --- | --- | --- |
| Positive GPIO/RIO/pad suite | 14 pass | 0 |
| Expected unsupported operations | 7 pass | 1: model Error logs |
| Deliberately wrong drive expectation with OD set | 13 pass, 1 fail | 1: scenario assertion |

Every verified case produced a terminal result with `strict_mmio: true` and
`qualification_claims: []`. The first adapter attempt failed because the
sandbox denied Renode's configuration lock; its terminal timeout and error
logs are retained separately. The three verified cases ran outside that
sandbox with fresh capture directories.

Shared verification passed: 32 adapter/result tests, 23 Rust CLI tests and
5 Python model/platform tests, plus Rust formatting and whitespace checks.
Hosted CI runs those shared checks; native model verification was local.

The [evidence index](2026-10-01-rp1-pad-gating-evidence/evidence.json) records
versions, binary/datasheet hashes, invocation, counts and hashes for every
member of the [native archive](2026-10-01-rp1-pad-gating-evidence/native-evidence.tar.gz).
It retains model/test sources, the failing baseline model, XML/HTML, logs,
adapter invocation script, staged inputs and terminal results. Failed-test
`.save` snapshots are omitted.

Run the contract's command for native unit reproduction. The archived adapter
script records the environment and assertions for all three cases. Adjust its
checkout and temporary paths, use the installed Renode release's Python test
environment, and choose fresh result directories. Retained absolute paths
identify this run, not portable locations.

Diagnostic kernel/DTB inputs contain only `Adapter-only fixture; not a guest
image.` The suites do not load them or execute the generated boot wrapper.
AxiomOS was neither edited nor built. IE transition behavior is an explicit
unit policy; pull/drive/slew/Schmitt fields have readback only. No analog pad,
PWM mux, PCIe, physical safe-output or real guest qualification is claimed.
