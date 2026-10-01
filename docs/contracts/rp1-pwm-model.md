# RP1 PWM unit-model profile

`backends/renode/peripherals/RP1_PWM.cs` implements the pinned driver's PWM
register subset in Renode C#. It is an isolated model fixture, **not installed
in the Pi platform**. PCIe attachment, RP1 clock registers, GPIO/pads and real
guest qualification remain open. No AxiomOS source or build changes are needed.

## Supported behavior

Four channels expose GLOBAL_CTRL and each channel's CTRL, RANGE and DUTY at the
offsets in the [source inventory](rp1-driver-coverage.md). CTRL resets to `0x100`;
the other supported words reset to zero. Supported modes are constant-zero and
trailing-edge PWM, with optional output inversion. FIFO_POP_MASK is retained
but has no effect here because FIFO operation is unsupported.

The [RP1 datasheet, section 3.4](https://datasheets.raspberrypi.com/rp1/rp1-peripherals.pdf#page=36)
distinguishes SET_UPDATE synchronization of control/enables from per-channel
range/duty updates at overflow. The model stages register values separately
from applied state and uses Renode virtual timers for both operations. Thus
a SET_UPDATE write does not prematurely apply a running channel's duty change.

These are explicit simulation policies where hardware timing remains unqualified:

- The constructor requires a positive external `frequency`; the model clock
  runs continuously. It does not infer frequency or clock gating from firmware.
- SET_UPDATE clears and applies the latest control/enables one model clock
  period after its first pending trigger. Subsequent writes do not postpone it.
  This is a deterministic synchronization policy, not measured silicon latency
  or a claim of alignment with an external clock phase.
- A trailing-edge period is RANGE clock ticks. Starting a stopped channel
  begins a period and consumes its staged range/duty. Later changes apply at
  its next overflow. The datasheet does not fully specify first-enable and
  zero-range behavior; zero-range trailing-edge activation is rejected.
- Disabled output is recorded as `disabled`, not assigned a pad voltage or
  called safe. Enabled mode zero generates low before inversion. For mode one,
  zero duty is low, duty at least RANGE is high, and intermediate duty is `pwm`,
  with inversion applied to the constant cases and recorded for pulsing output.

Reset stops all timers, cancels pending activation and restores register state.
The capture sequence and unsupported-access count survive reset.

## Capture and strict access checking

Applied changes stream to retained native logs as `RP1_PWM_STATE`, with an
ordered sequence, virtual timestamp, explicit clock frequency, cause, channel,
enabled state, period/duty in ticks, inversion, mode and output classification.
Repeated unchanged periods emit nothing. Mode changes and reset are captured.
This describes the waveform configuration; it does not emit individual pulse
edges, simulate a pad, establish an e-stop bound, or validate a physical actuator.

The model always rejects unimplemented offsets/aliases, non-32-bit or unaligned
accesses, unsupported control bits/modes, and zero-range running/queued PWM.
It validates before changing registers and emits `RP1_PWM_UNSUPPORTED` at Error
level before throwing. Phase, common/FIFO, interrupt, DMA and sigma-delta
registers are intentionally unsupported. Byte/word/quadword interfaces explicitly
reject accesses so the bus cannot silently translate them into accepted writes.

`VOLN_VP_STRICT_MMIO=1` adds a conservative Renode adapter gate: every retained
native warning invalidates the run, including unmapped bus accesses. It accepts
only `0` or `1`, rejects raw emulator arguments, and is unsupported for QEMU.
Custom-model Error logs already fail regardless of this flag. Use trusted suites
which retain logging; a suite can execute host code and this is not attestation.

This flag does **not** certify all stock models. The [model audit](../probes/2026-10-01-renode-model-audit.md)
demonstrated silent reserved PL011 accesses; existing mailbox/stock-peripheral
internals are outside this model's coverage. No complete Pi strict execution
profile or qualification claim is enabled by this change.

## Native checks

Using the Python environment required by the installed Renode release, run
from the repository with a fresh output directory:

```sh
timeout --kill-after=2s 60s renode-test --jobs=1 \
  --keep-renode-output --save-logs always \
  --results-dir /tmp/rp1-pwm-unit \
  --variable MODEL_FILE:"$PWD/backends/renode/peripherals/RP1_PWM.cs" \
  backends/renode/tests/rp1-pwm.robot \
  backends/renode/tests/rp1-pwm-invalid.robot
```

The positive suite tests readback, delayed enable, overflow updates, independent
channels, inversion, disable/reset and capture. The invalid suite expects MMIO
exceptions and checks unchanged state; its native assertions pass but its error
logs must fail an adapter run. These are host-initiated register tests, not guest
driver tests. They require installed Renode and are separate from hosted
stand-in CI. [Retained verification](../probes/2026-10-01-rp1-pwm-model.md) includes
a deliberately wrong duty assertion and both warning/error adapter gates.
