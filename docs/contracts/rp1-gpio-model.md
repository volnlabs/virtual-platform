# RP1 IO_BANK0 unit-model profile

`backends/renode/peripherals/RP1_GPIO.cs` is an isolated 28-pin GPIO register
model. It is not installed in the Pi platform and does not qualify guest
drivers. It accepts conditioned digital input samples and captures forced
output requests at the IO_BANK0 boundary, before pad output gating.

## Supported registers

The [RP1 datasheet](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf),
sections 2.4 and 3.1, defines the offsets and fields. The
[source inventory](rp1-driver-coverage.md) identifies their driver callers.

| Register | Offset | Modeled behavior |
| --- | --- | --- |
| STATUS | `8*pin` | Read-only input bit 17, output/enable bits 9/13, unfiltered event bits 20–23 and combined IRQ bits 28/29 |
| CTRL | `8*pin+4` | Reset `0x9f`; GPIO/NULL function selection, forced output/enable, unfiltered event masks and self-clearing IRQRESET |
| INTR | `0x100` | Read-only per-pin bitmap after per-pin event masks, before destination masking |
| PCIE_INTE | `0x11c` | 28-bit destination enable bitmap, reset zero |
| PCIE_INTS | `0x124` | Read-only `INTR & PCIE_INTE`; any set bit asserts the native Renode `IRQ` line |

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
  Fixtures must resupply external input after reset.
- Only FUNCSEL 5 (GPIO) and 31 (NULL) are accepted. GPIO mode requires forced
  output enable or disable; an enabled output requires forced low/high data.
  NULL's reset source is disabled/low. Enabled outputs requiring peripheral
  data, peripheral-derived GPIO output enables, inverse overrides and alternate
  functions are rejected. With GPIO output disabled and OUTOVER=0, STATUS bit 9
  is an explicit exclusion held at zero because RIO data is not modeled; it
  does not describe the peripheral's output data. In particular the
  pinned driver's intermediate `set_function(Gpio)` write from reset requires
  a peripheral mux/RIO model and is currently unsupported. Unit tests write
  complete supported configurations; they do not run that driver sequence.
- F_M is retained at its reset value 4; changes, filtered/debounced IRQ enables,
  INOVER and IRQOVER are rejected. STATUS's peripheral-source, filtered-input,
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
cause, pin, sampled/input state, effective forced output request, raw events
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

The positive suite observes the IRQ through a connected native LED test sink.
The invalid suite expects exceptions, so its Robot assertions pass while its
Error logs must fail an adapter run. Native tests are separate from hosted
stand-in CI. [Retained evidence](../probes/2026-10-01-rp1-gpio-model.md) also
includes a deliberately incorrect interrupt expectation.
