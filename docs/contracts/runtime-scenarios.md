# Boot smoke and native runtime suites

`test --mode boot` is the default and keeps the existing startup-marker check.
`test --mode runtime --scenario /path/to/suite.robot` selects a native suite.
The CLI forwards `VOLN_VP_TEST_MODE` and `VOLN_VP_SCENARIO`; conflicting CLI
and environment selections fail. Runtime is valid only for `test`, requires a
scenario, and rejects raw emulator arguments. Boot mode rejects a scenario.
Dry runs display the selection without validating or launching it.

QEMU runtime returns `unsupported` before launch: no guest management and
completion interface is bound yet. Its short post-banner stop remains exclusive
to boot mode. AxiomOS is an external, read-only artifact source.

## Renode execution

```sh
cargo run -- test --board virt-pi5 --mode runtime \
  --scenario /path/to/suite.robot --artifact-manifest /path/to/bundle/build.json
```

Install Renode's native `renode-test` dependencies in the Python environment on
PATH; `renode-test --help` must work. The adapter does not install dependencies.
The current invocation was checked against Renode `1.16.1.16973` and Robot `6.1`.

Each invocation stages the guest inputs and a copy of the `.robot` suite in a
fresh directory. Suites must be standalone or use explicit absolute paths for
resources/libraries: `${CURDIR}` is the staged directory, not the source tree.
Imported dependencies are not staged or sealed, so their identity is outside
this result contract. Run only trusted suites; native Robot can execute host code.

The adapter calls `renode-test` with one job, saved logs, and an isolated Robot
output directory. It supplies these Robot variables:

| Variable | Value |
|---|---|
| `${AXIOMOS_KERNEL}` | Private staged kernel ELF |
| `${VOLN_VP_DTB}` | Private staged DTB |
| `${VOLN_VP_BOOT_SCRIPT}` | Generated `.resc` which loads the existing Pi platform and inputs and attaches `uart.log` |
| `${VOLN_VP_RUN_DIR}` | Fresh evidence directory |

Use `Execute Script    ${VOLN_VP_BOOT_SCRIPT}` to load the common platform.
The script does not start emulation or impose a `RunFor` duration. The suite
owns readiness, real guest management commands, request-ID correlation,
completion and assertions. Use Renode's UART testers and virtual-time controls
for guest events. `VOLN_VP_TIMEOUT` remains an independent host wall timeout for
the entire native runner, followed by bounded process-group cleanup.
`VOLN_VP_VIRTUAL_TIME` has no effect in runtime mode.

## What passes

The native runner must exit zero. After cleanup, fresh `robot_output.xml`,
`log.html` and `report.html` must exist; XML must contain a passing suite and at
least one test, with every test passing. Failed/skipped tests, missing results,
XML errors, guest fatal output, and recorded emulator errors fail the adapter.
A boot banner is never consulted to decide runtime success. Final output from
cleanup is checked before success is recorded.

This proves only that the supplied native suite passed. The adapter cannot
infer whether an arbitrary suite contains adequate guest assertions. A suite
that only checks readiness is not a runtime qualification suite. Concrete
guest scenarios must require correlated completion after readiness and reject
missing, premature, or wrong-request events, with a negative case for each
assertion. Those scenarios remain blocked on qualified artifacts and a pinned
guest management interface; none are supplied as qualified tests here.

Results retain `mode`, staged suite path/hash, inputs, commands, Robot output,
logs and `scenario_result.passed_tests` on success. `qualification_claims`
remains empty for every outcome.

For model tests, `VOLN_VP_STRICT_MMIO=1` also rejects retained Renode warnings
after cleanup. See the [PWM unit-model contract](rp1-pwm-model.md) for this gate's
scope, explicit register validation and stock-model coverage limits.

## Adapter integration check

`backends/renode/tests/native-runner.robot` checks staged-variable delivery and
executes a real Renode Monitor assertion. It does not load a guest. Select it
as the scenario with explicit diagnostic input files to check the installation.
Set `VOLN_VP_SELFTEST_EXPECTED=deliberately-absent` to invert its assertion;
that run must return nonzero. Shared adapter tests additionally exercise absent
and corrupt results, skipped/failed tests, teardown failure, late fatal output,
emulator errors, timeouts and surviving helpers with stand-in runners.
