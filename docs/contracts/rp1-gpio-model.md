# RP1 GPIO, RIO output and digital pad unit-model profile

`backends/renode/peripherals/RP1_GPIO.cs` is an isolated 28-pin GPIO register
model with RIO output and PADS_BANK0 register windows. It is not installed in
the Pi platform and does not qualify guest drivers. It accepts externally
driven digital input samples and captures both IO_BANK0 output requests and
the resulting digital drive state after pad output gating.

## Supported registers

The [RP1 datasheet](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf),
sections 2.4, 3.1 and 3.3, defines the GPIO fields, atomic aliases and RIO roles. The
[source inventory](rp1-driver-coverage.md) identifies their driver callers.

| Register | Offset | Modeled behavior |
| --- | --- | --- |
| STATUS | `8*pin` | Read-only input bit 17, peripheral output/enable bits 8/12, effective output/enable bits 9/13, unfiltered event bits 20–23 and combined IRQ bits 28/29 |
| CTRL | `8*pin+4` | Reset `0x9f`; GPIO/NULL function selection, output/enable overrides, unfiltered event masks and self-clearing IRQRESET |
| INTR | `0x100` | Read-only per-pin bitmap after per-pin event masks, before destination masking |
| PCIE_INTE | `0x11c` | 28-bit destination enable bitmap, reset zero |
| PCIE_INTS | `0x124` | Read-only `INTR & PCIE_INTE`; any set bit asserts the native Renode `IRQ` line |

RIO is a second `rio` connection region on the same model, with aligned 32-bit
OUT at `0x00` and OE at `0x04`, each limited to GPIO0–27. Offsets and their
output/enable use are confirmed by the
[official Raspberry Pi GPIO utility at `ebc4a56`](https://github.com/raspberrypi/utils/blob/ebc4a56bac3a896d5c14e56fe27dcd6cb36dd373/pinctrl/gpiochip_rp1.c#L42-L44).
Both registers support ordinary read/write and the atomic aliases below.
RIO input registers remain unsupported: the documented SYNC_IN at `0x08`
requires a clocked synchronizer, and this model does not substitute immediate
IO_BANK0 samples for that behavior.

FUNCSEL 5 selects the corresponding OUT/OE bits as the peripheral signal
source. FUNCSEL 31 selects NULL's low/disabled source. OUTOVER and OEOVER each
select the source, its inverse, forced low/disabled or forced high/enabled.
STATUS exposes both the selected source and the effective override result,
including output data while its enable is off. Output changes never implicitly
change input samples or manufacture GPIO interrupts.

All registers require aligned 32-bit accesses. Alias windows at `+0x1000`,
`+0x2000` and `+0x3000` implement XOR, SET and CLEAR writes respectively;
alias reads return ordinary register data without mutation. Writing IRQRESET
through ordinary, SET or XOR access clears both edge latches and immediately
reads back zero. CLEAR does not pulse a self-clearing bit already at zero.
Acknowledgment does not clear a live level condition or alter the input.

`OnGPIO(pin, value)` supplies an externally driven digital level, gated by IE.
Edges latch independently of IRQ masks. Repeating the same value creates no
new edge. Live high/low conditions follow the latest sample; per-pin masks
combine the selected events into INTR. Destination masking suppresses the IRQ
line without losing an edge. This is an IO_BANK0 interrupt request, not an MSI-X
message, GIC interrupt or proof that guest code handled it.

## Digital pad gates

The `pads` connection region exposes GPIO0–27 at `4 + 4*pin`, with the same
aligned 32-bit access and atomic aliases. Bits 7:0 are stored; writes containing
reserved bits are rejected before mutation, including CLEAR aliases.
VOLTAGE_SELECT at offset zero and all other registers are unsupported.

OD (bit 7) disables digital output drive regardless of the IO_BANK0 request.
IE (bit 6) enables input sampling. The remaining bits (drive strength, pull-up,
pull-down, Schmitt and slew controls) have register readback only. This is not
an analog model: pull resolution, floating inputs, contention, drive current,
thresholds and transition timing are excluded. The fixture must supply each
external digital level explicitly; outputs never loop back into inputs.

Reset values are `0x9a` for GPIO0–8 and `0x96` for GPIO9–27: OD set, IE clear,
and the documented per-pin default pulls. The datasheet's section 3.1.3,
tables 19–21, defines the fields and fixed reset bits. Raspberry Pi's
[engineer clarification](https://forums.raspberrypi.com/viewtopic.php?p=2200050#p2200050)
identifies the pull defaults and disabled buffers; a
[further clarification](https://forums.raspberrypi.com/viewtopic.php?p=2200728#p2200728)
notes that pull resistors remain active independently of those buffers.
Stored pull bits here do not synthesize a level for an undriven pin.

The digital input policy is explicit: IE clear samples low; changing IE
immediately resamples a previously supplied external level. Thus enabling IE
with a held high level latches a rising edge, and disabling it while high
latches a falling edge. Further external changes while IE is clear create no
edges, but the sampled low-level condition can still assert an enabled level
IRQ. Before the first supplied sample, live levels remain invalid. The sources
do not establish these exact IE transition semantics; they are a serialized
unit-test policy, not validated hardware timing or behavior.

## Explicit profile limits

- Reset clears register/event/input state and deasserts IRQ. STATUS starts at
  zero; live level bits become valid at the first sample. A first high sample
  with IE set is a rising edge from reset-low. This serialized sampling policy
  and immediate IRQRESET consumption are model choices, not measured synchronization timing.
  Fixtures must resupply external input after reset. OUT/OE are initialized and
  reset to zero as an explicit unit-profile preset; the cited sources do not
  establish their hardware reset values. Firmware-preconfigured RIO state must
  be supplied by explicit register writes, not inferred from this preset.
- Only FUNCSEL 5 (GPIO) and 31 (NULL) are accepted; alternate peripheral muxing
  remains unsupported. The pinned driver's intermediate `set_function(Gpio)`
  write is now supported against the modeled RIO source. Tests reproduce the
  IO_BANK0 and pad writes from output setup, but do not run the guest driver.
- F_M is retained at its reset value 4; changes, filtered/debounced IRQ enables,
  INOVER and IRQOVER are rejected. STATUS's peripheral-input, filtered-input,
  direct-input and filtered/debounced-event fields are explicit read-field
  exclusions and remain zero. Only the STATUS fields listed above are covered.
- Analog pad behavior and synchronizer/filter latency are excluded.
  `output=` describes the IO_BANK0 request, while `drive=` describes that request
  after OD gating. `disabled` is neither a measured pad voltage nor proof of a
  safe physical actuator state. PWM mux and PCIe/IACK integration remain open.

Unsupported registers (including processor destinations and PCIE_INTF), widths,
alignment, pins, bits or control combinations emit `RP1_GPIO_UNSUPPORTED` at
Error level and throw before mutating operational state. Coverage failures and
capture sequence survive reset. The model logs its named exclusions at reset.
The existing [Renode warning gate](rp1-pwm-model.md#capture-and-strict-access-checking)
also applies; it cannot expand this model's coverage or certify stock models.

Changed state streams as `RP1_GPIO_STATE` with sequence, virtual timestamp,
cause, pin, external and sampled/input state, effective output request, pad
register, digital drive, raw events and destination-pending state. Reset emits
all pins. No unbounded event buffer or host sleep is used.

## Verification

With the installed Renode release's Python test environment, run from the repo:

```sh
timeout --kill-after=2s 60s renode-test --jobs=1 \
  --keep-renode-output --save-logs always --results-dir /tmp/rp1-gpio-unit \
  --variable MODEL_FILE:"$PWD/backends/renode/peripherals/RP1_GPIO.cs" \
  backends/renode/tests/rp1-gpio.robot \
  backends/renode/tests/rp1-gpio-invalid.robot
```

The tests map IO_BANK0 at `0x10000`, RIO at `0x20000` and PADS_BANK0 at `0x30000`
using Renode's `BusMultiRegistration` with `region: "rio"` and `region: "pads"`;
these are isolated fixture addresses, not a Pi address map. All regions
explicitly reject byte, word and quadword accesses. A named connection region does not automatically inherit
the default bus interface's width handlers.

The positive suite observes the IRQ through a connected native LED test sink.
The invalid suite expects exceptions, so its Robot assertions pass while its
Error logs must fail an adapter run. Native tests are separate from hosted
stand-in CI. [Pad verification](../probes/2026-10-01-rp1-pad-gating.md) includes
a deliberately incorrect drive expectation.
[Earlier RIO verification](../probes/2026-10-01-rp1-rio-model.md) includes a
deliberately incorrect output expectation. The
[earlier GPIO evidence](../probes/2026-10-01-rp1-gpio-model.md) retains the
previous model revision and a deliberately incorrect interrupt expectation.
