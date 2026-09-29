#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
BOOT_SCRIPT="$REPO_ROOT/backends/renode/scripts/boot-virt-pi5.resc"
KERNEL="${AXIOMOS_KERNEL:-}"
DTB="${VOLN_VP_DTB:-$REPO_ROOT/boards/virt-pi5/virt-pi5.dtb}"
TIMEOUT="${VOLN_VP_TIMEOUT:-90s}"
VIRTUAL_TIME="${VOLN_VP_VIRTUAL_TIME:-0.1}"
MARKER="${VOLN_VP_BOOT_MARKER:-=== axiomos eBPF init ===}"

if [[ ! -f "$BOOT_SCRIPT" ]]; then
  echo "Renode boot script not found: $BOOT_SCRIPT" >&2
  exit 2
fi

if [[ ! -r "$KERNEL" || ! -f "$KERNEL" ]]; then
  echo "AXIOMOS_KERNEL must name a readable prebuilt embedded-rpi5 ELF: $KERNEL" >&2
  exit 2
fi

if [[ ! -r "$DTB" || ! -f "$DTB" ]]; then
  echo "virt-pi5 DTB not found: $DTB" >&2
  exit 2
fi

for binary in renode timeout realpath sha256sum; do
  if ! command -v "$binary" >/dev/null; then
    echo "$binary is not on PATH" >&2
    exit 3
  fi
done

if [[ ! "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]] || [[ ! "$TIMEOUT" =~ [1-9] ]]; then
  echo "VOLN_VP_TIMEOUT must be a positive duration (for example 90s)" >&2
  exit 4
fi

if [[ ! "$VIRTUAL_TIME" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ ! "$VIRTUAL_TIME" =~ [1-9] ]]; then
  echo "VOLN_VP_VIRTUAL_TIME must be a positive number of virtual seconds" >&2
  exit 4
fi

[[ "${1:-}" != -- ]] || shift

ARTIFACT_ROOT="${VOLN_VP_ARTIFACT_DIR:-/tmp}"
mkdir -p -- "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(realpath -e -- "$ARTIFACT_ROOT")"
# The CLI reparses its positional script as Monitor syntax, not as an argv
# path. Support spaces explicitly and reject other Monitor metacharacters.
MONITOR_PATH_PATTERN='^[[:alnum:]_./ -]+$'
if [[ ! "$ARTIFACT_ROOT" =~ $MONITOR_PATH_PATTERN ]]; then
  echo "Renode artifact directory supports letters, digits, spaces, and _./- only" >&2
  exit 4
fi
RUN_DIR="$(mktemp -d "$ARTIFACT_ROOT/voln-vp-renode.XXXXXX")"
printf 'Artifacts: %s\n' "$RUN_DIR"
CAPTURE="$RUN_DIR/uart.log"
RENODE_LOG="$RUN_DIR/renode.log"
WRAPPER="$RUN_DIR/boot.resc"

KERNEL="$(realpath -e -- "$KERNEL")"
DTB="$(realpath -e -- "$DTB")"
# Artifact paths have already been restricted to safe Monitor characters.
KERNEL_ARG="\"$RUN_DIR/kernel.elf\""
DTB_ARG="\"$RUN_DIR/virt-pi5.dtb\""
CAPTURE_ARG="\"$CAPTURE\""
# The CLI itself prepends '@' to its positional script, so escape spaces for
# the Monitor tokenizer as well as quoting the shell argument.
WRAPPER_ARG="${WRAPPER// /\\ }"
ln -s -- "$KERNEL" "$RUN_DIR/kernel.elf"
ln -s -- "$DTB" "$RUN_DIR/virt-pi5.dtb"
printf '%s\n' \
  "\$axiomos_kernel=$KERNEL_ARG" \
  "\$virt_pi5_dtb=$DTB_ARG" \
  'include @backends/renode/scripts/boot-virt-pi5.resc' \
  >"$WRAPPER"

sha256sum -- "$KERNEL" "$DTB" "$BOOT_SCRIPT" \
  "$REPO_ROOT/boards/virt-pi5/renode/virt-pi5.repl" >"$RUN_DIR/inputs.sha256"
COMMAND=(renode --config "$RUN_DIR/renode.config" --disable-gui --plain -P 0
  "$@" "$WRAPPER_ARG"
  -e "sysbus.uart0 CreateFileBackend $CAPTURE_ARG true; emulation RunFor \"$VIRTUAL_TIME\"; quit")
{
  printf 'cwd: %s\ntimeout: %s\nmarker: %s\ncommand: ' "$REPO_ROOT" "$TIMEOUT" "$MARKER"
  printf '%q ' "${COMMAND[@]}"
  printf '\n'
} >"$RUN_DIR/command.txt"
: >"$CAPTURE"

# The launcher can spawn dotnet. Timeout owns a process group so expiration
# and caller interruption stop the whole invocation, not just its shell.
stop_renode() {
  trap '' INT TERM
  if kill -0 -- "-$RENODE_PID" 2>/dev/null; then
    kill -TERM -- "-$RENODE_PID" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$RENODE_PID" 2>/dev/null || true
  fi
  wait "$RENODE_PID" 2>/dev/null || true
}
run_bounded() {
  local duration="$1" output="$2" status=0
  shift 2
  (
    cd -- "$REPO_ROOT"
    exec timeout --kill-after=2s "$duration" "$@"
  ) >"$output" 2>&1 &
  RENODE_PID=$!
  trap 'stop_renode; exit 130' INT
  trap 'stop_renode; exit 143' TERM
  wait "$RENODE_PID" || status=$?
  stop_renode
  trap - INT TERM
  return "$status"
}
if run_bounded 10s "$RUN_DIR/version.log" renode --version; then
  :
else
  RENODE_STATUS=$?
  echo "FAIL: Renode version query exited with status $RENODE_STATUS" >&2
  tail -80 "$RUN_DIR/version.log" >&2 || true
  exit "$RENODE_STATUS"
fi
RENODE_STATUS=0
run_bounded "$TIMEOUT" "$RENODE_LOG" "${COMMAND[@]}" || RENODE_STATUS=$?

if (( RENODE_STATUS == 0 )); then
  if grep -Eiq 'kernel panicked|V04_PANIC|PANIC:|panicked at|BOOT_FATAL' "$CAPTURE" ||
     grep -Eiq '\[(ERROR|FATAL)\]|There was an error|Error while|Unhandled exception|Could not execute|Could not tokenize|No such command' "$RENODE_LOG"; then
    echo "FAIL: kernel panic or Renode error observed" >&2
    RENODE_STATUS=1
  elif grep -Fq -- "$MARKER" "$CAPTURE"; then
    echo "PASS: UART boot marker '$MARKER' observed"
    exit 0
  else
    echo "FAIL: UART boot marker '$MARKER' not observed" >&2
    RENODE_STATUS=1
  fi
else
  echo "FAIL: Renode exited with status $RENODE_STATUS" >&2
fi

echo "--- UART tail ---" >&2
tail -80 "$CAPTURE" >&2 || true
echo "--- Renode log tail ---" >&2
tail -80 "$RENODE_LOG" >&2 || true
exit "$RENODE_STATUS"
