# Installed Renode model and access-warning audit

The installed Renode has PCI building blocks but no named RP1, RP2040 or
BCM2712 peripheral types. Warning detection alone cannot establish strict
register coverage: the tested PL011 silently ignores a reserved register.
No guest was loaded, no AxiomOS checkout was changed, and no RP1 model or
guest qualification is delivered by this audit.

## Pinned installation and evidence

Executed October 1, 2026 with Renode `1.16.1.16973`, build
`d66b0c2a-202602160923`, .NET `10.0.11` and Robot Framework `6.1`.
The [evidence index](2026-10-01-renode-model-audit-evidence/evidence.json)
pins the installed `Infrastructure.dll`, `Renode.dll`, relevant platform
descriptions, probe and every member of the
[native evidence archive](2026-10-01-renode-model-audit-evidence/native-audit.tar.gz).
The archive retains XML, native logs, launcher output and type inventories for
both runs. HTML reports can be regenerated from the XML with Robot's `rebot`.

The probe enumerated 1,234 public `Antmicro.Renode.Peripherals.*` types in the
loaded `Infrastructure` assembly. This is an inventory of this installation,
not proof that no third-party or later implementation exists.

| Candidate | Observed availability | Reuse decision |
|---|---|---|
| RP1/RP2040/BCM2712 | No matching public type names; no matching installed platform/script/test entries | No demonstrated drop-in register model |
| `PCIeBasePeripheral`, `PCIeEndpoint`, `PCIeRootComplex`, BAR classes, PCI interfaces | Public types present | Candidates for C# endpoint/configuration plumbing; no BCM2712 initialization or RP1 behavior tested |
| `MPFS_PCIe` | Present; used by `platforms/cpus/polarfire-soc.repl` | A different controller; cannot substitute for the pinned BCM2712 register contract |
| `picosoc.repl` | Instantiates `CPU.PicoRV32`, `UART.PicoSoC_SimpleUART`; GPIO region only tagged | Not an RP2040 peripheral implementation |
| `PWMTester`, other chip-specific GPIO/PWM types | Present | Potential testing infrastructure, not RP1 register compatibility |

The pinned [driver inventory](../contracts/rp1-driver-coverage.md) determines
the custom behavior still needed. Type presence does not establish API or
register compatibility. Examine the installed-version source/API before reusing
the generic PCI classes; a from-scratch PCI framework is not justified here.

## Native observations

All accesses below are Monitor-initiated on a synthetic bus. They establish
model/logger behavior, not guest driver execution or CPU instruction behavior.
The PL011 instance is mapped at `0x10000`.

| Operation | Observed behavior |
|---|---|
| 32-bit read at unmapped `0x20000` | Returns zero; `non existing peripheral` warning |
| 32-bit write at unmapped `0x20000` | `non existing peripheral` warning |
| 32-bit read/write/read at PL011 offset `0x40` | Both reads return zero; no `uart:` log entry; write does not establish modeled storage |
| 64-bit read at PL011 offset `0` | `Attempted QuadWord read isn't supported` warning |
| Write `0xffffffff` to PL011 control offset `0x30` | Reports unhandled bits and tagged fields |

The four audit tests passed. Overriding the expected unmapped-warning string
with `deliberately-absent` caused that test to fail and the native runner to
return 1. The other three tests passed. A passing audit confirms the observed
limitations; it is **not** a strict-mode pass.

Renode's [logger documentation](https://renode.readthedocs.io/en/latest/basic/logger.html)
describes unmapped-access warnings. Its
[modeling guide](https://renode.readthedocs.io/en/latest/advanced/writing-peripherals.html)
describes register modeling and C# versus simple Python peripherals. The live
probe adds an important limit: an existing model can silently ignore reserved
addresses. Do not extend the runtime adapter's error regex and label that
complete strict enforcement.

The first RP1 models must validate offset, width, alignment, bits and operation
at their MMIO entry points and emit a failing coverage event for unsupported
accesses. Native bus warnings must also invalidate strict qualification.
Reset state and intentional stubs require explicit coverage rules. Those
guards and their positive/negative tests belong with the first model; neither
the model nor the strict gate is implemented in this audit.

## Reproduce without guest inputs

Use an environment containing the installed Renode release's own Python
requirements. Run from the simulator repository; use fresh absolute output
directories. The outer timeout bounds host execution.

```sh
timeout --kill-after=2s 60s renode-test --jobs=1 \
  --keep-renode-output --save-logs always \
  --results-dir /tmp/rp1-model-audit-positive \
  --variable AUDIT_DIRECTORY:/tmp/rp1-model-audit-positive \
  backends/renode/tests/model-audit.robot

# Expected nonzero: deliberately wrong assertion, not a guest fault.
timeout --kill-after=2s 60s renode-test --jobs=1 \
  --keep-renode-output --save-logs always \
  --results-dir /tmp/rp1-model-audit-negative \
  --variable AUDIT_DIRECTORY:/tmp/rp1-model-audit-negative \
  --variable UNMAPPED_WARNING:deliberately-absent \
  backends/renode/tests/model-audit.robot
```

This probe runs directly through `renode-test` because it does not load guest
artifacts. It is not wired into the stand-in-only hosted CI job. On another
Renode build, re-audit changed observations rather than treating these pinned
warning strings or silent reserved accesses as a hardware specification.
