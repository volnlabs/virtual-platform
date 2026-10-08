# voln-vp Design: Virtual Platform for axiomOS Development

**Date:** 2026-07-14 (revised 2026-07-15 after two external review rounds)
**Status:** Approved design, pre-implementation
**September 30 scope amendment:** The next milestone is an identified build,
qualified boot, strict single-core GPIO/PWM, then real managed-update/e-stop
scenarios and one reproducible fault replay. Full peripheral inventory and four
cores remain later goals. Artifact identity and adapter/CLI CI ship first;
none of their stand-in checks qualifies a guest. See the
[implementation plan](../plans/2026-09-30-runtime-testing-platform.md).

**Context (historical design assumptions, not current qualification):** axiomOS boots on QEMU virt (x86_64, AArch64, RISC-V) and on real
Raspberry Pi 5 with full userspace, eBPF, GPIO/PWM/IIO drivers, and a measured
211ns single-core interrupt latency. No simulation infrastructure beyond QEMU
virt exists. Jetson is a future target; nothing Jetson-specific is built now.

## Goal

voln-vp is a **developer platform**, not another simulator: glue that makes
existing simulation/emulation infrastructure feel like one coherent
development environment. It answers, before touching hardware:

1. **Will it work?** — peripheral drivers (RP1 GPIO/PWM/I²C/SPI/UART/ADC),
   post-firmware boot path, robotics app logic against sensors.
2. **How fast is it?** — deterministic reproduction of timing-dependent bugs
   now; calibrated latency numbers via a reserved gem5 backend when latency
   work starts.

Composition over construction: QEMU, Renode, and gem5 do what they already do
well; voln-vp never reimplements a simulator and never forks QEMU.

**Ownership split:** the *data* belongs to voln-vp — board descriptions and
trace files are simulator-neutral, versioned voln-vp formats. The *execution*
belongs to backends. Backend-native artifacts (Renode `.repl` renders, Python
device models, Robot suites) are accepted as backend-specific: if a backend
is ever replaced, register-level device models port mechanically; we document
that risk rather than building speculative converter layers around it.

**Developer experience is the product.** A developer who clones axiomOS
should get a workflow that feels like web development:

```
cargo install voln-vp
voln-vp doctor          # verify qemu/renode/toolchains present
voln-vp run  --board virt-pi5
voln-vp test --board virt-pi5
voln-vp replay imu.trace     (later)
voln-vp flash                (later, real hardware)
```

Nobody should need to remember which simulator runs underneath.

## Non-Goals / Stated Boundaries

- **Firmware stage is not simulated.** No open tool models the Pi 5 bootrom →
  EEPROM → VideoCore chain. Simulation entry point is kernel entry with a DTB.
  Firmware-stage bugs are hardware-only.
- **GPU is not simulated** (VideoCore VII, and Jetson GPU later).
- **Jetson:** deferred entirely. Backend/board structure leaves a slot for a
  future `virt-jetson` board; no code is written for it now.
- **Physics simulation:** never built in-house. Sensor fidelity today is value
  injection and trace replay; when robotics work demands physics, a Gazebo/
  Webots **bridge backend** feeds their sensor outputs into Renode's virtual
  devices. voln-vp carries data, not dynamics.
- **Custom GUI / visualization:** not built. Future slots: perfetto trace
  export (kernel trace events → Perfetto timeline) and a VS Code extension
  wrapping the CLI. Nothing now.
- **Distributed simulation** (Pi5 + MCU + CAN + sensors as separate
  simulators): not built. Backends are already separate processes, so a
  future bridge backend over sockets is not foreclosed. No message-bus
  abstraction is designed today.

## Architecture

### Boards first, backends second

Users think in boards, not simulators: the primary axis is
`voln-vp run --board virt-pi5`. Each board manifest (`board.toml`) declares
which backends support it and which is the default; `--backend` overrides.
The board list grows (virt-pi5 today; rk3588, jetson, MCUs later) without the
user learning a new tool per simulator.

### Backends and the adapter contract

The core knows **no backend by name**. Each backend is a self-describing
directory implementing a small adapter contract; the runner discovers backend
directories and dispatches to them.

```
                       voln-vp
              ┌─────────────────────┐
              │     cli (runner)    │   discovers backends/,
              └──────────┬──────────┘   dispatches via adapter contract
                         │
     ┌───────────┬───────┴──────┬─────────────────┐
     │           │              │                 │
   qemu/      renode/      gem5/ (reserved)   future: gazebo-bridge/,
   boot,      virt-pi5     calibrated         perfetto/, vscode/
   smoke,     machine,     latency            (slots only)
   gdb,       drivers,
   snapshots  sensors,
              determinism
     └───────────┴──────────────┴─────────────────┘
                         │
                  axiomOS ELF — same unmodified kernel everywhere
```

**Adapter contract** (per backend directory):
- `manifest.toml` — name, supported verbs, supported boards.
- Entry points for the verbs it supports: `run`, `test`, `bench`.
- Exit code discipline: simulator failure propagates; CI cannot false-green.

Adding a backend later (gazebo bridge, perfetto exporter, webots) = new
directory satisfying the contract. Zero core change. No plugin-manager
subsystem is built — directory discovery + contract is the entire mechanism;
a manager appears only if backend count ever makes discovery insufficient.

**Boards** are simulator-neutral declarative descriptions owned by voln-vp:
`board.toml` (memory map, peripheral inventory, DTB reference, supported
backends + default) plus per-backend renders in subdirectories (e.g.
`boards/virt-pi5/renode/virt-pi5.repl`). The neutral manifest is the source
of truth; backend renders derive from it.

**The CLI stays stupid.** Its complete job description:
discover → validate → launch → collect exit code. It is explicitly forbidden
from growing into a scheduler, workflow engine, configuration language, or
plugin loader. Verbs now: `doctor` (verify simulators/toolchains installed),
`run`, `test`. Reserved verbs, no code now: `bench`, `replay`, `trace`,
`flash`.

### What each backend answers

| Backend | Question | Speed | Status |
|---|---|---|---|
| `qemu` | Does it boot? Multi-arch smoke (x86_64/AArch64/RISC-V), GDB, snapshots | seconds | exists, wrapped |
| `renode` | Will it WORK on Pi 5? Drivers, sensors, deterministic execution | fast, deterministic | **primary build** |
| `gem5` | How fast? Calibrated latency | minutes–hours | **reserved slot, deferred** |

**Timing fidelity contract:** Renode gives *determinism and instruction-count
timing proxies* (catches "IRQ path grew 3×" regressions), never nanosecond
accuracy. The gem5 backend, when built, gives *calibrated cycle-level
estimates* (target ±15% of hardware). Only hardware gives true numbers.

## Renode Backend: `virt-pi5` Machine

### Platform (`boards/virt-pi5/virt-pi5.repl`)

| Block | Model | Source |
|---|---|---|
| CPU | 4× Cortex-A76 (closest available Renode ARMv8-A core — A75/A78 acceptable; exact core chosen at Phase 1) | built-in |
| Interrupt controller | GIC-400 (GICv2, as on Pi 5) | built-in |
| Timer | ARM generic timer @ 54 MHz | built-in |
| Debug UART | PL011 at Pi 5 address | built-in |
| RAM | Pi 5 memory map, 8 GB configuration | built-in |
| Mailbox / firmware properties | Stub returning canned firmware responses the kernel expects | custom, small |
| PCIe root complex | BCM2712-style RC | **custom** |
| RP1 peripheral block | GPIO banks, PWM channels, I²C, SPI, RP1 UARTs, ADC | **adapt existing first, write what's missing** |

### RP1 attachment: full PCIe model (decided)

RP1 is modeled as a PCIe endpoint behind a custom BCM2712-style root complex,
with registers exposed through BARs — the kernel's real PCIe enumeration and
probe path runs in simulation.

**Risk:** Renode's PCIe infrastructure is thin; the RC model is likely built
from scratch. **Fallback (logged here deliberately):** if PCIe modeling stalls
past its phase budget, flat-map RP1 registers on the system bus at
DTB-described addresses. Driver register logic stays fully tested; only PCIe
enumeration falls back to hardware-only coverage.

### RP1 peripheral models — reuse before building

RP1 has related peripheral IP, but usable RP2040 models must be verified in
the pinned Renode distribution; the earlier availability assumption was not
established by the local audit. Phase 3 starts with an audit:
map each RP1 block the axiomOS drivers touch against Renode's RP2040 models,
adapt what matches, and write only the genuinely missing pieces.

- Simple transaction-local models may use **Python peripherals**. Advanced
  interconnect, interrupt wiring and virtual-time behavior use C# as required. Python
  peripherals are interpreted per register access — a peripheral hammered on
  every GPIO toggle or interrupt may bottleneck. Migration path, explicit:
  prototype in Python → profile once the driver suite is green → rewrite
  measured-hot simple peripherals in C#. The PCIe RC/endpoint is C# from the start.
- **Register-accurate for registers the axiomOS drivers touch**;
  datasheet-complete where the driver needs it. Models are built in the phase
  where the driver test suite demands them — never speculatively.
- **Unmodeled-register tripwire:** any access to an unimplemented register
  logs a warning; **strict mode** ships with the first models and makes both
  unmapped bus accesses and unexplained mapped-register operations fatal. Gaps surface
  loudly, never silently.
- No generic `Device → GPIO/PWM/…` abstraction layer: the kernel image is
  unmodified, so drivers speak RP1 registers — an abstract device interface
  would require a sim-specific kernel HAL, defeating the point of testing
  real drivers.

### Sensor simulation

- **Fake bus devices** (`devices/`): IMU, ADC chips, etc., as Python
  peripherals on the modeled I²C/SPI buses. Drivers perform real bus
  transactions; devices answer with injected values.
- **Value injection:** Renode monitor commands + Robot Framework keywords,
  e.g. `inject imu.accel_x 9.81 @ t=10ms`.
- **Trace replay:** traces recorded from real Pi 5 runs, delivered at
  virtual-time timestamps. Reproducibility applies to pinned simulated
  scenarios with defined initial state and virtual-time settings; physical
  sensor samples alone cannot reproduce arbitrary hardware execution. Trace format is a voln-vp-owned specification (see Trace
  Format), not a Renode artifact.
- **Actuator capture:** PWM model logs duty/period changes with virtual
  timestamps, enabling assertions like "PWM reached 50% within 5 ms (virtual)
  of IMU spike".
- The same fake-device interfaces are the attachment point for a future
  Gazebo/Webots bridge: physics engine output replaces injected values, the
  Renode side is unchanged.

## gem5 Backend (Reserved, Deferred)

Future latency-analysis backend, built when latency work actually starts.
One design fact preserved: latency numbers are only trustworthy after
**calibration against real Pi 5 golden numbers** (211 ns IRQ latency is the
first anchor) with a committed tolerance band. Until then, latency
regressions are caught by Renode instruction-count proxies and validated on
hardware.

## Trace Format

Traces are a voln-vp-owned, simulator-neutral asset (`traces/`). One-page
specification, versioned:

- **Header:** format version, sensor type, units, sample rate, calibration
  reference, recording provenance (board, date, kernel version), checksum.
- **Body:** timestamped samples.

Consumers today: Renode replay. The spec stays one page until a second
consumer (Gazebo bridge, another simulator, offline analysis) exists.

## Repository Layout

This repository, renamed **voln-vp**:

```
voln-vp/
  cli/                     # thin Rust runner: discover, validate, launch,
                           #   collect exit code — nothing else
  backends/
    qemu/                  # manifest + adapters wrapping existing virt configs
    renode/
      peripherals/         # C# interconnect, mailbox.py, RP1 models (only what existing
                           #   models don't cover)
      scripts/             # .resc boot/scenario scripts
      tests/               # Robot Framework suites
    gem5/                  # reserved: manifest only, no implementation
  boards/
    virt/                  # board.toml (neutral) — generic QEMU virt, 3 arches
    virt-pi5/
      board.toml           # neutral source of truth: memory map, peripherals,
                           #   DTB ref, supported backends + default
      renode/virt-pi5.repl # backend-specific render
  devices/                 # fake sensors: imu.py, adc_chip.py
  traces/                  # voln-vp trace format (see Trace Format section)
  ci/
  docs/
```

One thin CLI crate only. Rejected twice now: the research report's five-crate
simulator framework, and a plugin-manager subsystem — both reimplement or
over-wrap what the backends already are.

## Interfaces

- **CLI** is the single entry point for humans and CI:
  `voln-vp <doctor|run|test> --board <name> [--backend <name>] [args]`.
  Board manifest picks the default backend; backends are discovered from
  `backends/`, never hardcoded. Simulator exit codes propagate.
- **Kernel ↔ backend:** the unmodified axiomOS image. No sim-specific kernel
  code paths; the machine is made to fit the kernel, not vice versa.
- **Backend ↔ core:** the adapter contract (manifest + verb entry points +
  exit-code discipline).
- **Tests ↔ renode backend:** Robot Framework keywords (UART expectations,
  sensor injection, PWM capture assertions).

## Testing & CI

**Per-commit (fast, deterministic, minutes total):**
- qemu backend: boot smoke on x86_64, AArch64, RISC-V.
- renode backend: `virt-pi5` boot-to-userspace; driver suite — GPIO toggle
  readback, PWM sweep capture, I²C IMU read, SPI transfer; one determinism
  check (clean single-core runs → matching canonical actuator/audit streams).
  Strict mode on. These guest jobs remain gated on qualified artifacts/models;
  adapter/CLI checks run independently now.

**Nightly:**
- Full Robot scenario suites and trace replays.
- (When gem5 backend exists: benchmark suite with regression thresholds.)

**Hardware:** manual for now; HIL automation is future work.

## Error Handling

- Unmodeled RP1 register access: warn in dev, fatal in CI (strict mode).
- CLI: propagates non-zero simulator exits; timeout per test with diagnostic
  UART dump on failure.
- Trace replay: version-checked trace format; mismatch is a hard error.
- Backend manifest invalid or verb unsupported: hard error at dispatch, named
  clearly.

## Build Order (each phase a usable milestone)

1. **Risk gate:** boot axiomOS to UART on a stock Renode ARMv8-A board.
   Proves Renode CPU viability before any custom modeling. If Renode's
   ARMv8-A support proves inadequate here, revisit backend choice before
   proceeding.
2. CLI skeleton (`doctor`, `run`, `test`) + adapter contract + board
   manifests; qemu backend wrapped (existing flow); `virt-pi5.repl` +
   mailbox stub → boot to userspace on the Pi 5 memory map.
3. **RP2040-model audit**, then PCIe RC + remaining RP1 models → per-commit
   driver suite green. *(Largest phase; the flat-map fallback decision point
   lives here.)*
4. Sensor devices, injection API, trace replay.
5. CI hardening throughout (partial wiring begins in Phase 2).

*(gem5 backend: built when latency work starts — slot and design ready.)*

## Decisions Log

| Decision | Choice | Alternative rejected |
|---|---|---|
| Project framing | Developer platform (voln-vp): compose existing tools behind one CLI | Building/owning another simulator |
| Overall approach | Hybrid: QEMU smoke + Renode complete machine + gem5 latency slot | Renode-only; QEMU fork with raspi5 machine |
| Machine completeness | Full — all RP1 peripherals drivers touch, 4 cores, full memory map | Trimmed minimal machine |
| Latency backend | gem5 reserved slot, design compressed to calibration note (revised twice 2026-07-15; was "day one") | Day-one calibrated gem5 build; full deletion per reviewer |
| Primary CLI axis | Board-first (`--board`, backend defaulted from board manifest) | Backend-first `--tier`/`--backend` axis |
| Artifact ownership | Traces + board manifests = neutral voln-vp formats; device models + Robot suites = backend-native, port cost accepted | Simulator-agnostic device/scenario abstraction with converters |
| Peripheral language | Python for simple transactions; C# for required interconnect/IRQ/time behavior and measured hot paths | Python-only interconnect; speculative model rewrites |
| Distributed sim | Not foreclosed (backends are processes); nothing designed | Message-bus abstraction now |
| RP1 attachment | Full PCIe model (RC + endpoint + BARs) | Flat-mapped registers (kept as fallback) |
| RP1 model sourcing | Adapt Renode RP2040 models first, write only gaps (added 2026-07-15) | Writing all models from scratch |
| Device abstraction | None — drivers speak RP1 registers, kernel unmodified | Generic Device→GPIO/PWM interface layer |
| Extensibility | Backend directories + adapter contract, runner discovery | Plugin-manager subsystem; hardcoded `--tier` CLI |
| Sensor fidelity | Value injection + trace replay; future Gazebo bridge feeds same interfaces | In-house physics |
| Visualization | Future slots: perfetto export, VS Code extension | Custom GUI/timeline tooling |
| Jetson | Deferred, board slot reserved | CPU-arch-level support now |
| Repo shape | One thin CLI crate + backend/board dirs | Five-crate simulator framework |
