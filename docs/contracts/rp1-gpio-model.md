# RP1 IO_BANK0 and RIO output unit-model profile

`backends/renode/peripherals/RP1_GPIO.cs` is an isolated 28-pin GPIO register
model with a RIO output register window. It is not installed in the Pi platform
and does not qualify guest drivers. It accepts conditioned digital input
samples and captures output requests at the IO_BANK0 boundary, before pad
output gating.

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

`OnGPIO(pin, value)` accepts a digital sample after external pad conditioning.
Edges latch independently of IRQ masks. Repeating the same value creates no
new edge. Live high/low conditions follow the latest sample; per-pin masks
combine the selected events into INTR. Destination masking suppresses the IRQ
line without losing an edge. This is an IO_BANK0 interrupt request, not an MSI-X
message, GIC interrupt or proof that guest code handled it.

## Explicit profile limits

- Reset clears register/event/input state and deasserts IRQ. STATUS starts at
  zero; live level bits become valid at the first sample. A first high sample
  is a rising edge from reset-low. This serialized sampling policy and immediate
  IRQRESET consumption are model choices, not measured synchronization timing.
  Fixtures must resupply external input after reset. OUT/OE are initialized and
  reset to zero as an explicit unit-profile preset; the cited sources do not
  establish their hardware reset values. Firmware-preconfigured RIO state must
  be supplied by explicit register writes, not inferred from this preset.
- Only FUNCSEL 5 (GPIO) and 31 (NULL) are accepted; alternate peripheral muxing
  remains unsupported. The pinned driver's intermediate `set_function(Gpio)`
  write is now supported against the modeled RIO source. Tests reproduce the
  IO_BANK0 writes from output setup, but do not run the guest driver or its pad
  configuration operations.
- F_M is retained at its reset value 4; changes, filtered/debounced IRQ enables,
  INOVER and IRQOVER are rejected. STATUS's peripheral-input, filtered-input,
  direct-input and filtered/debounced-event fields are explicit read-field
  exclusions and remain zero. Only the STATUS fields listed above are covered.
- Pads, pulls, input-enable gating, synchronizer/filter latency and electrical
  contention are excluded. There is no implicit output-to-input loopback.
  `disabled` describes the IO_BANK0 enable request, not a pad voltage or safe
  physical actuator state. PWM mux and PCIe/IACK integration remain open.

Unsupported registers (including processor destinations and PCIE_INTF), widths,
alignment, pins, bits or control combinations emit `RP1_GPIO_UNSUPPORTED` at
Error level and throw before mutating operational state. Coverage failures and
capture sequence survive reset. The model logs its named exclusions at reset.
The existing [Renode warning gate](rp1-pwm-model.md#capture-and-strict-access-checking)
also applies; it cannot expand this model's coverage or certify stock models.

Changed state streams as `RP1_GPIO_STATE` with sequence, virtual timestamp,
cause, pin, sampled/input state, effective output request, raw events
and destination-pending state. Reset emits all pins. No unbounded event buffer
or host sleep is used.

## Verification

With the installed Renode release's Python test environment, run from the repo:

```sh
timeout --kill-after=2s 60s renode-test --jobs=1 \
  --keep-renode-output --save-logs always --results-dir /tmp/rp1-gpio-unit \
  --variable MODEL_FILE:"$PWD/backends/renode/peripherals/RP1_GPIO.cs" \
  backends/renode/tests/rp1-gpio.robot \
  backends/renode/tests/rp1-gpio-invalid.robot
```

The tests map IO_BANK0 at `0x10000` and RIO at `0x20000` using Renode's
`BusMultiRegistration` with `region: "rio"`; these are isolated fixture
addresses, not a Pi address map. Both regions explicitly reject byte, word and
quadword accesses. A named connection region does not automatically inherit
the default bus interface's width handlers.

The positive suite observes the IRQ through a connected native LED test sink.
The invalid suite expects exceptions, so its Robot assertions pass while its
Error logs must fail an adapter run. Native tests are separate from hosted
stand-in CI. [RIO verification](../probes/2026-10-01-rp1-rio-model.md) includes
a deliberately incorrect output expectation. The
[earlier GPIO evidence](../probes/2026-10-01-rp1-gpio-model.md) retains the
previous model revision and a deliberately incorrect interrupt expectation.
