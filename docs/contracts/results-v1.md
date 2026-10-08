# Adapter result v1

Each invocation allocates a fresh evidence directory before validating inputs.
It initially writes `result.json` with `completed: false`, `outcome: null`, and
`exit_code: null`. A terminal result is atomically installed after the adapter's
cleanup. Treat a missing or unfinished result as incomplete, never success.
Failure to allocate/write evidence returns nonzero; a full/unwritable output
filesystem cannot guarantee a retained report.

| Field | Meaning |
|---|---|
| `schema_version`, `run_id` | Version `1` and unique run directory name |
| `backend`, `board`, `architecture`, `verb`, `mode` | Selected adapter and boot invocation |
| `completed`, `exit_code`, `outcome`, `reason` | Terminal status; outcome is `pass`, `fail`, or `unsupported` |
| `identity` | `manual`, `manifest_matched`, or `unvalidated` when validation did not complete |
| `qualification_claims` | Always `[]` in this tranche; observation is not qualification |
| `boot_contract`, `observed_milestones` | Intended contract and observed UART markers; markers can also occur in a failing run |
| `inputs` | Staged artifacts/hashes and, when supplied, source/build/rootfs fields and exact manifest hash |
| `execution` | Executable path/hash, version output, argv, working directory, environment controls and adapter settings |
| `implementation` | voln-vp Git commit/dirty state when available, plus relevant adapter/model/platform file hashes |
| `evidence` | Paths relative to this run directory |

Manifest validation failures exit 2. Unsupported manifest versions/profiles and
architectures also exit 2, with outcome `unsupported`. Timeout remains 124,
SIGINT/SIGTERM remain 130/143, and other nonzero emulator statuses propagate.
Renode artifact preparation has a separate 300-second wall-clock bound and
retains `preflight.log`; the configured guest watchdog starts at guest launch.
Emulator exit zero without the required observation is failure. Boot smoke
success sets outcome `pass` while leaving qualification claims empty.

The reported machine/CPU/RAM settings describe the adapter's base command.
For unrestricted diagnostic arguments, the full argv is authoritative: later
arguments may override the base settings. Current `virt`/default machine aliases
are not versioned qualification profiles. Generated QEMU DTBs/default firmware
are not supplied artifacts; complete pinning belongs to guest qualification.
Renode's fixed platform is Cortex-A78, one core, 8 GiB RAM, EL1 entry.

Keep `uart.log`, backend/version logs, original manifest, normalized inputs,
result and staged bytes together. Existing QEMU `metadata.json` and Renode
`inputs.sha256`/`command.txt` remain available. These reports do not implement
runtime scenarios, attest producer claims, or certify any guest revision.
