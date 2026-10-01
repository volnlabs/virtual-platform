#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
BOOT_SCRIPT="$REPO_ROOT/backends/renode/scripts/boot-virt-pi5.resc"
TIMEOUT="${VOLN_VP_TIMEOUT:-90s}"
VIRTUAL_TIME="${VOLN_VP_VIRTUAL_TIME:-0.1}"
VERB="${VOLN_VP_VERB:-run}"
MODE="${VOLN_VP_TEST_MODE:-boot}"
MARKER='=== axiomos eBPF init ==='
PANIC_PATTERN='kernel panicked|V04_PANIC|PANIC:|panicked at|BOOT_FATAL'
ERROR_PATTERN='\[(ERROR|FATAL)\]|There was an error|Error while|Unhandled exception|Could not execute|Could not tokenize|No such command'
if [[ "$VERB" == run ]]; then
  MARKER="${VOLN_VP_BOOT_MARKER:-$MARKER}"
fi
[[ "${1:-}" != -- ]] || shift

ARTIFACT_ROOT="${VOLN_VP_ARTIFACT_DIR:-/tmp}"
mkdir -p -- "$ARTIFACT_ROOT"
ARTIFACT_ROOT="$(realpath -e -- "$ARTIFACT_ROOT")"
RUN_DIR="$(mktemp -d "$ARTIFACT_ROOT/voln-vp-renode.XXXXXX")"
RESULT_REASON="adapter exited before completing the boot check"
BOOT_SUCCESS=0
RUN_CWD="$PWD"
printf 'Artifacts: %s\n' "$RUN_DIR"
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
    cd -- "$RUN_CWD"
    exec timeout --kill-after=2s "$duration" "$@"
  ) >"$output" 2>&1 &
  RENODE_PID=$!
  trap 'RESULT_REASON="interrupted by signal 2"; stop_renode; exit 130' INT
  trap 'RESULT_REASON="interrupted by signal 15"; stop_renode; exit 143' TERM
  wait "$RENODE_PID" || status=$?
  stop_renode
  trap 'RESULT_REASON="interrupted by signal 2"; exit 130' INT
  trap 'RESULT_REASON="interrupted by signal 15"; exit 143' TERM
  return "$status"
}

finish_result() {
  local status=$?
  trap - EXIT
  if (( status == 0 && BOOT_SUCCESS == 0 )); then
    status=1
  fi
  if ! python3 "$REPO_ROOT/backends/results.py" finish "$RUN_DIR" "$status" "$RESULT_REASON"; then
    exit 2
  fi
  exit "$status"
}
trap finish_result EXIT
trap 'RESULT_REASON="interrupted by signal 2"; exit 130' INT
trap 'RESULT_REASON="interrupted by signal 15"; exit 143' TERM
# Bound copying/provenance separately from the guest's execution watchdog.
if run_bounded 300s "$RUN_DIR/preflight.log" python3 "$REPO_ROOT/backends/results.py" init "$RUN_DIR" renode virt-pi5 "${VOLN_VP_ARCH:-aarch64}" "$VERB" "$@"; then
  :
else
  PREPARE_STATUS=$?
  RESULT_REASON="artifact preparation exited with status $PREPARE_STATUS"
  cat "$RUN_DIR/preflight.log" >&2
  exit "$PREPARE_STATUS"
fi
if [[ "${VOLN_VP_STRICT_MMIO:-0}" == 1 ]]; then
  # Custom models validate their own registers. Stock bus coverage also needs
  # warnings retained; any warning invalidates this deliberately narrow gate.
  ERROR_PATTERN+='|\[WARNING\]'
fi
RUN_CWD="$REPO_ROOT"
KERNEL="$RUN_DIR/inputs/kernel.elf"
DTB="$RUN_DIR/inputs/board.dtb"

if [[ ! -f "$BOOT_SCRIPT" ]]; then
  RESULT_REASON="Renode boot script not found: $BOOT_SCRIPT"
  echo "$RESULT_REASON" >&2
  exit 2
fi

if [[ ! -r "$KERNEL" || ! -f "$KERNEL" ]]; then
  RESULT_REASON="AXIOMOS_KERNEL must name a readable prebuilt embedded-rpi5 ELF: $KERNEL"
  echo "$RESULT_REASON" >&2
  exit 2
fi

if [[ ! -r "$DTB" || ! -f "$DTB" ]]; then
  RESULT_REASON="virt-pi5 DTB not found: $DTB"
  echo "$RESULT_REASON" >&2
  exit 2
fi

for binary in renode timeout realpath sha256sum; do
  if ! command -v "$binary" >/dev/null; then
    RESULT_REASON="$binary is not on PATH"
  echo "$RESULT_REASON" >&2
    exit 3
  fi
done
if [[ "$MODE" == runtime ]] && ! command -v renode-test >/dev/null; then
  RESULT_REASON="renode-test is not on PATH"
  echo "$RESULT_REASON" >&2
  exit 3
fi

if [[ ! "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]] || [[ ! "$TIMEOUT" =~ [1-9] ]]; then
  RESULT_REASON="VOLN_VP_TIMEOUT must be a positive duration (for example 90s)"
  echo "$RESULT_REASON" >&2
  exit 4
fi

if [[ "$MODE" == boot ]] && { [[ ! "$VIRTUAL_TIME" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ ! "$VIRTUAL_TIME" =~ [1-9] ]]; }; then
  RESULT_REASON="VOLN_VP_VIRTUAL_TIME must be a positive number of virtual seconds"
  echo "$RESULT_REASON" >&2
  exit 4
fi

# The CLI reparses its positional script as Monitor syntax, not as an argv
# path. Support spaces explicitly and reject other Monitor metacharacters.
MONITOR_PATH_PATTERN='^[[:alnum:]_./ -]+$'
if [[ ! "$ARTIFACT_ROOT" =~ $MONITOR_PATH_PATTERN || ! "$REPO_ROOT" =~ $MONITOR_PATH_PATTERN ]]; then
  RESULT_REASON="Renode artifact directory supports letters, digits, spaces, and _./- only"
  echo "$RESULT_REASON" >&2
  exit 4
fi
CAPTURE="$RUN_DIR/uart.log"
RENODE_LOG="$RUN_DIR/renode.log"
WRAPPER="$RUN_DIR/boot.resc"

KERNEL="$(realpath -e -- "$KERNEL")"
DTB="$(realpath -e -- "$DTB")"
# Artifact paths have already been restricted to safe Monitor characters.
KERNEL_ARG="\"$KERNEL\""
DTB_ARG="\"$DTB\""
CAPTURE_ARG="\"$CAPTURE\""
# The CLI itself prepends '@' to its positional script, so escape spaces for
# the Monitor tokenizer as well as quoting the shell argument.
WRAPPER_ARG="${WRAPPER// /\\ }"
printf '%s\n' \
  "\$axiomos_kernel=$KERNEL_ARG" \
  "\$virt_pi5_dtb=$DTB_ARG" \
  "\$virt_pi5_platform=\"$REPO_ROOT/boards/virt-pi5/renode/virt-pi5.repl\"" \
  "include \"$BOOT_SCRIPT\"" \
  >"$WRAPPER"

sha256sum -- "$KERNEL" "$DTB" "$BOOT_SCRIPT" \
  "$REPO_ROOT/boards/virt-pi5/renode/virt-pi5.repl" >"$RUN_DIR/inputs.sha256"
COMMAND=("$(command -v renode)" --config "$RUN_DIR/renode.config" --disable-gui --plain -P 0
  "$@" "$WRAPPER_ARG"
  -e "sysbus.uart0 CreateFileBackend $CAPTURE_ARG true; emulation RunFor \"$VIRTUAL_TIME\"; quit")
if [[ "$MODE" == runtime ]]; then
  printf '%s\n' "sysbus.uart0 CreateFileBackend $CAPTURE_ARG true" >>"$WRAPPER"
  COMMAND=("$(command -v renode-test)" --jobs=1 --keep-renode-output --save-logs always
    --results-dir "$RUN_DIR/robot"
    --variable "AXIOMOS_KERNEL:$KERNEL" --variable "VOLN_VP_DTB:$DTB"
    --variable "VOLN_VP_BOOT_SCRIPT:$WRAPPER" --variable "VOLN_VP_RUN_DIR:$RUN_DIR"
    "$RUN_DIR/scenario.robot")
fi
{
  printf 'cwd: %s\ntimeout: %s\nmarker: %s\ncommand: ' "$REPO_ROOT" "$TIMEOUT" "$MARKER"
  printf '%q ' "${COMMAND[@]}"
  printf '\n'
} >"$RUN_DIR/command.txt"
: >"$CAPTURE"
python3 "$REPO_ROOT/backends/results.py" execution "$RUN_DIR" "${COMMAND[@]}"

if run_bounded 10s "$RUN_DIR/version.log" renode --version; then
  :
else
  RENODE_STATUS=$?
  RESULT_REASON="Renode version query exited with status $RENODE_STATUS"
  echo "FAIL: $RESULT_REASON" >&2
  tail -80 "$RUN_DIR/version.log" >&2 || true
  exit "$RENODE_STATUS"
fi
RENODE_STATUS=0
run_bounded "$TIMEOUT" "$RENODE_LOG" "${COMMAND[@]}" || RENODE_STATUS=$?

if (( RENODE_STATUS == 0 )); then
  if grep -Eiq "$PANIC_PATTERN" "$CAPTURE" ||
     grep -Eiq "$PANIC_PATTERN|$ERROR_PATTERN" "$RENODE_LOG"; then
    RESULT_REASON="kernel panic or Renode error observed"
    echo "FAIL: $RESULT_REASON" >&2
    RENODE_STATUS=1
  elif [[ "$MODE" == runtime ]]; then
    if grep -REiq --include='*.log' "$PANIC_PATTERN|$ERROR_PATTERN" "$RUN_DIR/robot"; then
      RESULT_REASON="error observed in native Renode logs"
      RENODE_STATUS=1
    elif python3 "$REPO_ROOT/backends/results.py" robot-result "$RUN_DIR" >"$RUN_DIR/robot-result.log" 2>&1; then
      RESULT_REASON="native Robot suite passed after cleanup"
      BOOT_SUCCESS=1
      exit 0
    else
      RESULT_REASON="native Robot result missing, incomplete, or failed"
      cat "$RUN_DIR/robot-result.log" >&2
      RENODE_STATUS=1
    fi
  elif grep -Fq -- "$MARKER" "$CAPTURE"; then
    RESULT_REASON="required boot marker observed"
    BOOT_SUCCESS=1
    exit 0
  else
    RESULT_REASON="required boot marker not observed"
    echo "FAIL: $RESULT_REASON" >&2
    RENODE_STATUS=1
  fi
else
  RESULT_REASON="Renode exited with status $RENODE_STATUS"
  echo "FAIL: $RESULT_REASON" >&2
fi

echo "--- UART tail ---" >&2
tail -80 "$CAPTURE" >&2 || true
echo "--- Renode log tail ---" >&2
tail -80 "$RENODE_LOG" >&2 || true
exit "$RENODE_STATUS"
