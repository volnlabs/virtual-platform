# AxiomOS RP1 driver source contract

This is a source-only inventory of the AxiomOS driver at commit
[`a6f48d167437f94807899c53e2f2b1c92abd8b24`](https://github.com/pro-utkarshM/axiomOS/tree/a6f48d167437f94807899c53e2f2b1c92abd8b24).
It records the operations a simulator scenario may need to observe; it does not
assert that the hardware effects have been qualified. The retained source pin
is associated with a `virt,cloud-profile` build, not a Pi target. No accepted
Pi-target producer manifest or Pi qualification evidence is available. The installed
Renode substrate observations are recorded in
[`../probes/2026-10-01-renode-model-audit.md`](../probes/2026-10-01-renode-model-audit.md).

## Addressing and access rules

The driver assumes firmware has pre-mapped RP1 peripherals using the documented
shortcuts. `phys_to_virt` converts physical addresses to kernel MMIO addresses;
peripheral addresses are the RP1 base plus internal offsets. Its register
helpers use volatile 32-bit reads/writes. PCIe route helpers add `dsb osh`
ordering around access. These are source assumptions, not proof that a given
machine has established the aperture or clocks.

| Block | Physical base / RP1 offset | Driver address or use |
|---|---:|---|
| RP1 BAR1 peripheral aperture | `0x1f_0000_0000` | `phys_to_virt(base) + offset` |
| BCM2712 PCIe2 root complex | `0x10_0012_0000` | `phys_to_virt(base)` |
| BCM2712 MIP0 | `0x10_0013_0000` | `phys_to_virt(base)` |
| RP1 IO_BANK0 / GPIO | `0x000d_0000` | RP1 aperture + offset |
| RP1 PADS_BANK0 | `0x000f_0000` | RP1 aperture + offset |
| RP1 PWM0 / PWM1 | `0x0009_8000` / `0x0009_c000` | RP1 aperture + offset |
| RP1 PCIe APBS | `0x0010_8000` | RP1 aperture + offset |

Sources: [`memory_map.rs`](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/memory_map.rs#L6-L27), [RP1 offsets and address helpers](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/memory_map.rs#L39-L86), [`MmioReg`](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/mmio.rs#L9-L60), [ordered PCIe access](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/rp1_irq.rs#L120-L165).

## PCIe, BAR and MSI-X route

The route setup uses aligned 32-bit accesses. PCI config reads/writes select bus
1, device 0, function 0 through the PCIe config address/data aperture. The
capability walker is bounded to 48 aligned entries in `0x40..=0xfc`; it is not
a time-based link poll.

| Register / operation | Offset | Source operation and check |
|---|---:|---|
| PCIe link status | RC `+0x4068` | Read; requires bits 4 and 5 set. Returns `PcieLinkDown` otherwise. |
| PCIe outbound window low/high | RC `+0x400c/+0x4010` | Write zero to both. |
| Outbound base/limit low | RC `+0x4070` | Write 9 MiB window encoding for RP1 CPU aperture. |
| Outbound base/limit high | RC `+0x4080/+0x4084` | Write upper MiB fields. No explicit window readback. |
| RC inbound BAR1 config low/high | RC `+0x402c/+0x4030` | Map PCI message target `0xff_ffff_f000`; 4 KiB size encoding `0x1c`. |
| RC UBUS BAR1 remap low/high | RC `+0x40ac/+0x40b0` | Map inbound message to MIP0 physical `0x10_0013_0000`; low word includes enable bit 0. All four words read back. |
| Config address/data | RC `+0x9000/+0x8000` | Address writes `1 << 20`; data register accessed at `+offset`. |
| RC bus numbers | RC `+0x18` | Set primary 0, secondary 1, subordinate 1 (`0x0001_0100`, mask `0x00ff_ffff`); read back and fail on mismatch. |
| RC command/status | RC `+0x04` | Write back the read status half and set MEMORY bit 1 and MASTER bit 2. PCI status W1C effects are unresolved; no explicit command-bit readback. |
| RP1 vendor/device ID | PCI config `+0x00` | Read and require `0x0001_1de4`; otherwise endpoint-unavailable error. |
| RP1 command/status | PCI config `+0x04` | Write back the read status half; set MEMORY and MASTER; clear INTx-disable bit 10. PCI status W1C effects are unresolved. |
| RP1 BAR0 / BAR1 / BAR2 | PCI config `+0x10/+0x14/+0x18` | Read, reject all-ones/error or low reserved/type bits (`bar & 7`), write mapped bases preserving low 4 flag bits. BAR0=8 MiB, BAR1=0, BAR2=4 MiB in PCIe window. |
| Capability pointer | PCI config `+0x34` | Initial pointer masked with `0xfc`; each link must be aligned and in `0x40..=0xfc`. Walk at most 48 entries; require ID `0x11`. |
| MSI-X control/table info | capability `+0/+4` | Function-mask bit 30 and disable enable bit 31 during remap. Entry count=`((control >> 16) & 0x7ff)+1`; BIR=`table_info & 7`; offset=`table_info & !7`. Require BIR=0, 1–64 entries, end within 64 KiB BAR0. Enable MSI-X and clear function mask after setup; read back both bits. |
| RP1 chip ID | RP1 aperture `+0x0000_0000` | Read and require `0x2000_1927` after BAR remap. |
| MSI-X table entries | BAR0 + capability table offset; 16-byte stride | Mask every advertised vector; program vector 0 address low/high=`0xff_ffff_f000`, data=0, then unmask vector 0; read back all four words. |
| RP1 MSI-X local config 0 | APBS `+0x008` | Clear via `+0xc00` alias with all ones; set via `+0x800` alias with enable bit 0 and IACK-enable bit 3; verify both bits. |
| RP1 MSI-X vector acknowledge | APBS `+0x808` | Write IACK bit 2 through `+0x800` set alias after clearing GPIO sources. |
| MIP host config low/high | MIP0 `+0x20/+0x30` | Write all ones (driver comment describes edge mode); read back. |
| MIP host mask low/high | MIP0 `+0x40/+0x50` | Write zero (unmask host); read back. |
| MIP VPU mask low/high | MIP0 `+0x60/+0x70` | Write all ones (mask VPU); read back. |

The PCIe driver checks PCIe link status once and has no retry/delay loop. It
does check bus-number, inbound-window, MIP, MSI-X-table, vector-config, and
global MSI-X readbacks. The outbound-window writes and RP1 command bits lack
dedicated readback checks. Register meanings above describe the source's chosen
values and comments; firmware state and physical routing remain unverified.

Source: [`rp1_irq.rs`](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/rp1_irq.rs#L16-L87), [volatile helpers/capability walk](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/rp1_irq.rs#L120-L189), [bus setup](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/rp1_irq.rs#L191-L220), [BARs and inbound aperture](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/rp1_irq.rs#L223-L285), [quiesce/MIP/table](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/rp1_irq.rs#L287-L340), [route sequence and acknowledger](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/rp1_irq.rs#L342-L454).

## GPIO and interrupt contract

All GPIO and pad words are accessed as 32-bit registers. There are 28 GPIOs;
per-pin register stride is 8 bytes. GPIO status is read-only; control and pad
configuration use read/modify/write. Set/clear aliases are used for interrupt
enables and the self-clearing IRQ reset pulse. The ordinary RP1 alias offsets
are `+0x2000` set and `+0x3000` clear.

| Register | Offset / fields | Driver behavior |
|---|---|---|
| STATUS | pin `+0x00` | Read-only; input level bit 17, event bits 20–23 (fall/rise/low/high). |
| CTRL | pin `+0x04` | FUNCSEL bits 4:0 mask `0x1f`; OUTOVER bits 13:12; OEOVER bits 15:14; IRQ enables bits 20–23; IRQRESET bit 28 self-clearing pulse. |
| Raw interrupt status | `+0x100` | Read; masked to 28 GPIO bits for diagnostic state. |
| PCIe interrupt enable/status | `+0x11c/+0x124` | Read/write through aliases for enable; read pending bitmap masked to 28 bits. |
| PADS_BANK0 GPIO pad | `+0x04 + 4*pin` | Schmitt bit 1; pull bits 3:2 (none=0/down=1/up=2); input enable bit 6; output disable bit 7. |
| Atomic aliases | base `+0x2000/+0x3000` | Write-one set / clear, including CTRL IRQRESET set alias. |

Output setup selects GPIO function, sets forced OUTOVER low/high (encodings 2/3),
enables OEOVER (3), enables pad input and clears pad output-disable. Peripheral
output selects the requested alternate function, clears OUTOVER and forces
OEOVER enabled (3), and configures the pad. Input setup selects GPIO function,
disables OEOVER, and enables pad input plus Schmitt. Source has no API for
drive strength, debounce, or level-event arming; interrupt enable exposes only
rising/falling edges.

The [vendor datasheet, section 3.1](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf#page=18)
specifies CTRL reset `0x9f` (NULL function, F_M=4).
STATUS's unfiltered edge bits latch independently of masks; its level bits
track the input and survive IRQRESET while their level remains present.
Pad pull-up/down controls are independent enable bits; the driver's enum uses
the none/down/up subset. The [isolated GPIO model](rp1-gpio-model.md) covers
only the named unfiltered IO_BANK0 fields, not the complete driver sequence.

The IRQ route sequence in `initialize_gpio_route()` is: check PCIe link; assign
bus range; locate RP1 MSI-X; mask/disable MSI-X; map BARs and outbound window;
check RP1 chip ID; clear all 28 pin enables/events; install inbound MIP mapping,
MIP masks/config and vector-0 table entry; enable local vector/IACK; enable
global MSI-X. The GIC config uses IRQ 160, edge-triggered, priority `0x80`.
At interrupt time, the AArch64 handler acknowledges GIC, calls the GPIO handler,
then EOIs GIC. In this commit, the route initializer's only caller is the
Pi5-gated `bench::init()` path; the general platform `init()` does not call it.
GPIO handler snapshots PCIe pending pins, reads event bits,
clears each pin event through IRQRESET before dispatch, and IACKs RP1 vector 0
after scanning. It dispatches to BPF for configured GPIO edges; source supports
no GPIO-side polling worker or threaded interrupt path. Actual interrupt
delivery and ordering are hardware semantics still needing Pi evidence.

Source: [`gpio.rs` register layout and masks](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/gpio.rs#L58-L146), [GPIO setup/accessors and route wrapper](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/gpio.rs#L189-L405), [edge arm/clear/read APIs](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/gpio.rs#L425-L493), [ISR body](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/gpio.rs#L531-L671), [bench-only route callsite](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/bench.rs#L474-L497), [GIC dispatch](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/interrupts.rs#L49-L76) and [handler/EOI](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/interrupts.rs#L81-L142).

## PWM contract and caveats

PWM words are 32-bit. The source describes four channels per controller, with
public API channels 1–4 mapped to hardware channels 0–3. PWM0's functional clock
is separate from APB register access.

| Block/register | RP1 offset | Fields and observed writes |
|---|---:|---|
| CLOCKS PWM0 CTRL | `0x18000 + 0x74` | AUXSRC bits 9:5 set to 2 (xosc), SRC bits 2:0 set to 1 (AUX), enable bit 11 set by RMW. |
| CLOCKS PWM0 DIV_INT / DIV_FRAC | `0x18000 + 0x78/+0x7c` | Write 1 / 0; no post-write validation in the clock-enable function. |
| PWM GLOBAL_CTRL | controller `+0x00` | Channel enable bits 0–3; SET_UPDATE bit 31 latches shadow config. |
| Channel CTRL | `0x14 + 0x10*n` | `0x101` default (documented as trailing-edge mode/FIFO pop mask); no polarity API. |
| Channel RANGE | `0x18 + 0x10*n` | Write period in assumed PWM clocks; frequency computes integer `50_000_000 / Hz`. |
| Channel DUTY | `0x20 + 0x10*n` | Write high-time cycles; percentage path clamps to 100 and computes `range*percent/100`. |

`set_range` and `set_data` write the channel register then pulse GLOBAL_CTRL;
that records the source's sequence, not proof of the update boundary. The
[vendor PWM register contract](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf#page=40)
says individual range/duty writes take effect at channel overflow, independently
of SET_UPDATE, which synchronizes enable/control/phase and common-range changes.
enable writes channel CTRL default and sets the channel-enable plus update bits;
disable clears the channel bit and latches. PWM init performs a full GLOBAL_CTRL
write of `0x8000_0000`: enable bits 0–3 are zero and SET_UPDATE is one, so all
channels are expected to be disabled if those bits are ordinary RW controls and
the update bit latches that state. This expected effect and shadow/latch timing
still require the controller's authoritative semantics. The 50 MHz source rate
is explicitly an assumption, not measured frequency. Methods assert that the
channel is in API range 1–4 and the percentage setter clamps to 0–100, but no
programmed range, duty or channel-enable value is read back and validated.

The explicit `enable_pwm0_clock()` call occurs in the bench PWM initialization
path, before setting zero duty and selecting the pin alternate function. The
ordinary syscall/actuation path uses PWM setters/enables, but does not call this
clock routine. PWM1 clock setup is absent. Thus normal waveform generation and
the claimed clock defaults are not established by this source inventory.

Sources: [`pwm.rs` clock fields/setup](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/pwm.rs#L23-L93), [channel layout/assumed rate](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/pwm.rs#L103-L165), [driver methods](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/pwm.rs#L167-L282), [bench setup and mux ordering](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/bench.rs#L508-L535), [`rpi5` lazy init](https://github.com/pro-utkarshM/axiomOS/blob/a6f48d167437f94807899c53e2f2b1c92abd8b24/kernel/src/arch/aarch64/platform/rpi5/mod.rs#L36-L61).

## Model boundary and remaining gates

This is implemented source using volatile MMIO, PCI config writes/readbacks,
GPIO interrupt dispatch and PWM register operations, not a mock driver. A
simulator contract therefore needs the BCM2712 PCIe2 root complex and MIP0
register behavior plus RP1 BAR/config, GPIO, pads, PWM and APBS/MSI-X behavior.
An existing generic PCIe substrate could be reused conditionally for transport
and generic BAR concepts; the installed Renode audit does not establish a
BCM2712 root-complex model or an RP1 endpoint model. Custom BCM2712/RP1 contracts
are needed for this source sequence. No stock model is certified by this audit.

Remaining gates are a Pi-target identified producer manifest, review of the
producer commit/configuration, confirmed vendor/datasheet semantics and reset
state for ambiguous registers (including PCI command/status W1C behavior and
RP1/PWM reset defaults), modeled read/write side effects and interrupt
delivery, then independent Pi hardware observations for link/BAR routing, GPIO
events, PWM clock and waveform. Source-derived simulator tests can validate
driver expectations only; they cannot turn the current virt/cloud-profile pin
into Pi or physical qualification.
