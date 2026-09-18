#!/usr/bin/env bash
# tests/fm-launcher.test.sh - topic-isolated Firstmate launcher behavior.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/firstmate"
FM_ALIAS="$ROOT/bin/fm"
FAILED=0

fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

make_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/herdr" <<'FAKE_HERDR'
#!/usr/bin/env bash
set -u
printf 'HERDR_ARGS' >> "$FM_LAUNCHER_TEST_LOG"
printf '\t%s' "$@" >> "$FM_LAUNCHER_TEST_LOG"
printf '\n' >> "$FM_LAUNCHER_TEST_LOG"
case "${1:-}" in
  workspace)
    if [ "${2:-}" = rename ]; then
      printf '{"id":"cli:workspace:rename","result":{"workspace":{"label":"%s"}}}\n' "${4:-}"
    else
      printf '{"result":{"workspace":{"workspace_id":"ws-test"},"tab":{"tab_id":"tab-test"},"root_pane":{"pane_id":"pane-test"}}}\n'
    fi
    ;;
  tab)
    if [ "${2:-}" = list ]; then
      if [ "${FM_FAKE_HERDR_CURRENT_SAFE:-}" = 1 ]; then
        if [ "${FM_FAKE_HERDR_MISSING_PANE_COUNT:-}" = 1 ]; then
          printf '{"result":{"tabs":[{"tab_id":"%s"}]}}\n' "${FM_FAKE_HERDR_LIVE_TAB_ID:-${HERDR_TAB_ID:-tab-current}}"
        else
          printf '{"result":{"tabs":[{"tab_id":"%s","pane_count":1}]}}\n' "${FM_FAKE_HERDR_LIVE_TAB_ID:-${HERDR_TAB_ID:-tab-current}}"
        fi
      else
        printf '{"result":{"tabs":[{"tab_id":"%s","pane_count":1},{"tab_id":"other-tab","pane_count":1}]}}\n' "${HERDR_TAB_ID:-tab-current}"
      fi
    fi
    if [ "${2:-}" = rename ]; then
      printf '{"id":"cli:tab:rename","result":{"tab":{"label":"%s"}}}\n' "${4:-}"
    fi
    ;;
  pane)
    if [ "${2:-}" = get ]; then
      printf '{"result":{"pane":{"workspace_id":"%s","tab_id":"%s","pane_id":"%s"}}}\n' "${FM_FAKE_HERDR_LIVE_WORKSPACE_ID:-${HERDR_WORKSPACE_ID:-ws-current}}" "${FM_FAKE_HERDR_LIVE_TAB_ID:-${HERDR_TAB_ID:-tab-current}}" "${HERDR_PANE_ID:-pane-current}"
    fi
    if [ "${2:-}" = rename ]; then
      printf '{"id":"cli:pane:rename","result":{"pane":{"label":"%s"}}}\n' "${4:-}"
    fi
    if [ "${2:-}" = run ]; then
      printf 'PANE_RUN_COMMAND\t%s\n' "${4:-}" >> "$FM_LAUNCHER_TEST_LOG"
    fi
    ;;
  --session)
    printf 'ATTACH_SESSION\t%s\n' "${2:-}" >> "$FM_LAUNCHER_TEST_LOG"
    ;;
esac
FAKE_HERDR
  chmod +x "$dir/herdr"
  cat > "$dir/pi" <<'FAKE_PI'
#!/usr/bin/env bash
set -u
printf 'PI_ENV\tFM_HOME=%s\tFM_ROOT_OVERRIDE=%s\tHERDR_SESSION=%s\tFM_PI_TOPIC_LAUNCH=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" "${HERDR_SESSION:-}" "${FM_PI_TOPIC_LAUNCH:-}" >> "$FM_LAUNCHER_TEST_LOG"
printf 'PI_ARGS' >> "$FM_LAUNCHER_TEST_LOG"
printf '\t%s' "$@" >> "$FM_LAUNCHER_TEST_LOG"
printf '\n' >> "$FM_LAUNCHER_TEST_LOG"
FAKE_PI
  chmod +x "$dir/pi"
}

without_herdr_fakebin() {
  local dir=$1 command
  mkdir -p "$dir"
  cat > "$dir/pi" <<'FAKE_PI'
#!/usr/bin/env bash
set -u
printf 'PI_ENV\tFM_HOME=%s\tFM_ROOT_OVERRIDE=%s\tHERDR_SESSION=%s\tFM_PI_TOPIC_LAUNCH=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" "${HERDR_SESSION:-}" "${FM_PI_TOPIC_LAUNCH:-}" >> "$FM_LAUNCHER_TEST_LOG"
printf 'PI_ARGS' >> "$FM_LAUNCHER_TEST_LOG"
printf '\t%s' "$@" >> "$FM_LAUNCHER_TEST_LOG"
printf '\n' >> "$FM_LAUNCHER_TEST_LOG"
FAKE_PI
  chmod +x "$dir/pi"
  for command in cat ln mv rm; do
    ln -s "/usr/bin/$command" "$dir/$command"
  done
}

assert_contains() {
  local haystack=$1 needle=$2 label=$3
  if printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null; then
    pass "$label"
  else
    fail "$label: missing [$needle] in [$haystack]"
  fi
}

unit_noninteractive_missing_topic_refuses() {
  local tmp fakebin log out status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-noninteractive.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  make_fakebin "$fakebin"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" </dev/null 2>&1)
  status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -F 'usage: firstmate <topic-or-name>' >/dev/null; then
    pass 'missing topic: non-interactive stdin refuses with usage'
  else
    fail "missing topic: expected refusal, status=$status output=$out"
  fi
  if [ ! -s "$log" ]; then
    pass 'missing topic: does not launch Herdr or Pi after refusal'
  else
    fail "missing topic: launched unexpectedly: $(cat "$log")"
  fi
  rm -rf "$tmp"
}

unit_interactive_missing_topic_refuses_without_prompt() {
  local tmp fakebin log out status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-interactive.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  make_fakebin "$fakebin"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin:$PATH" \
    FM_LAUNCHER_TEST_LOG="$log" FM_LAUNCHER_TEST_COMMAND="$LAUNCH" python3 2>&1 <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

pid, descriptor = pty.fork()
if pid == 0:
    command = os.environ["FM_LAUNCHER_TEST_COMMAND"]
    os.execve(command, [command], os.environ)

captured = bytearray()
status = None
started = time.monotonic()
eof_sent = False
while status is None:
    if not eof_sent and time.monotonic() - started >= 0.2:
        os.write(descriptor, b"\x04")
        eof_sent = True
    readable, _, _ = select.select([descriptor], [], [], 0.05)
    if readable:
        try:
            captured.extend(os.read(descriptor, 65536))
        except OSError as error:
            if error.errno != errno.EIO:
                raise
    completed, wait_status = os.waitpid(pid, os.WNOHANG)
    if completed:
        status = wait_status
        break
    if time.monotonic() - started >= 3:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        captured.extend(b"\nPTY_TIMEOUT\n")

try:
    while True:
        readable, _, _ = select.select([descriptor], [], [], 0)
        if not readable:
            break
        captured.extend(os.read(descriptor, 65536))
except OSError as error:
    if error.errno != errno.EIO:
        raise
finally:
    os.close(descriptor)

sys.stdout.buffer.write(captured)
sys.exit(os.waitstatus_to_exitcode(status))
PY
)
  status=$?
  if [ "$status" -ne 0 ] \
     && printf '%s\n' "$out" | grep -F 'usage: firstmate <topic-or-name>' >/dev/null \
     && ! printf '%s\n' "$out" | grep -F 'Firstmate topic/name:' >/dev/null \
     && ! printf '%s\n' "$out" | grep -F 'PTY_TIMEOUT' >/dev/null; then
    pass 'missing topic: interactive terminal refuses instead of prompting for a shared fallback'
  else
    fail "missing topic: interactive terminal did not refuse immediately, status=$status output=$out"
  fi
  if [ ! -s "$log" ]; then
    pass 'missing topic: interactive refusal does not launch Herdr or Pi'
  else
    fail "missing topic: interactive refusal launched unexpectedly: $(cat "$log")"
  fi
  rm -rf "$tmp"
}

unit_symlink_install_resolves_shared_checkout() {
  local tmp fakebin install_bin log out status expected_home
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-symlink.XXXXXX")
  fakebin="$tmp/fakebin"
  install_bin="$tmp/install/bin"
  log="$tmp/log"
  make_fakebin "$fakebin"
  mkdir -p "$install_bin"
  ln -s "$ROOT/bin/firstmate" "$install_bin/firstmate"
  ln -s "$ROOT/bin/fm" "$install_bin/fm"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$install_bin:$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$install_bin/fm" Symlink Topic </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'symlink install: launch succeeds through installed fm symlink'
  else
    fail "symlink install: expected success, status=$status output=$out"
  fi
  expected_home="$tmp/home/.local/share/firstmate/symlink-topic__11b05755eb17"
  out=$(cat "$log" 2>/dev/null || true)
  assert_contains "$out" $'HERDR_ARGS\tworkspace\tcreate\t--cwd\t'"$ROOT"$'\t--label\tfirstmate-symlink-topic__11b05755eb17' 'symlink install: Herdr workspace cwd uses shared checkout, not install directory'
  assert_contains "$out" "FM_ROOT_OVERRIDE='$ROOT'" 'symlink install: command exports shared checkout as Firstmate root'
  assert_contains "$out" "-e '$ROOT/.pi/extensions/fm-primary-turnend-guard.ts'" 'symlink install: extension paths use shared checkout'
  rm -rf "$tmp"
}

unit_topic_slug_home_and_command() {
  local tmp fakebin log out status home expected_home expected_marker command
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-topic.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  home="$tmp/home"
  make_fakebin "$fakebin"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" 'Workflow Improvements!' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'topic launch: exits successfully with fake Herdr attach'
  else
    fail "topic launch: expected success, status=$status output=$out"
  fi
  if printf '%s' "$out" | grep -F 'cli:tab:rename' >/dev/null || printf '%s' "$out" | grep -F 'cli:pane:rename' >/dev/null; then
    fail "topic launch: leaked Herdr rename JSON: $out"
  else
    pass 'topic launch: suppresses Herdr rename JSON'
  fi
  expected_home="$home/.local/share/firstmate/workflow-improvements__3eaec6ea7e22"
  if [ -d "$expected_home/config" ] && [ -d "$expected_home/data" ] && [ -d "$expected_home/state" ] && [ -d "$expected_home/projects" ]; then
    pass 'topic launch: creates standard per-home directories'
  else
    fail 'topic launch: did not create standard per-home directories'
  fi
  expected_marker=$(printf 'version=2\nhome=%s\nroot=%s\nherdr_session=%s' \
    "$expected_home" "$ROOT" 'firstmate-workflow-improvements__3eaec6ea7e22')
  if [ "$(cat "$expected_home/.fm-topic-home" 2>/dev/null)" = "$expected_marker" ]; then
    pass 'topic launch: publishes the canonical topic-home binding at the default base'
  else
    fail 'topic launch: default-base home is missing its canonical recovery binding'
  fi
  out=$(cat "$log")
  assert_contains "$out" $'HERDR_ARGS\tworkspace\tcreate\t--cwd\t'"$ROOT"$'\t--label\tfirstmate-workflow-improvements__3eaec6ea7e22\t--session\tfirstmate-workflow-improvements__3eaec6ea7e22' 'topic launch: creates topic-specific Herdr workspace in topic session'
  assert_contains "$out" $'HERDR_ARGS\ttab\trename\ttab-test\tfirstmate\t--session\tfirstmate-workflow-improvements__3eaec6ea7e22' 'topic launch: names initial Herdr tab firstmate'
  assert_contains "$out" $'HERDR_ARGS\tpane\trename\tpane-test\tfirstmate\t--session\tfirstmate-workflow-improvements__3eaec6ea7e22' 'topic launch: names initial Herdr pane firstmate'
  assert_contains "$out" $'ATTACH_SESSION\tfirstmate-workflow-improvements__3eaec6ea7e22' 'topic launch: attaches named Herdr session outside Herdr'
  command=$(printf '%s\n' "$out" | awk -F '\t' '/^PANE_RUN_COMMAND/{print $2; exit}')
  assert_contains "$command" "FM_HOME='$expected_home'" 'topic launch: command sets isolated FM_HOME'
  assert_contains "$command" "HERDR_SESSION='firstmate-workflow-improvements__3eaec6ea7e22'" 'topic launch: command sets generated Herdr session'
  assert_contains "$command" "--session-dir '$expected_home/pi-sessions'" 'topic launch: command isolates Pi session storage'
  assert_contains "$command" "-e '$ROOT/.pi/extensions/fm-primary-turnend-guard.ts' -e '$ROOT/.pi/extensions/fm-primary-pi-watch.ts'" 'topic launch: command loads Firstmate Pi extensions explicitly'
  if [ "$(readlink "$home/.pi/agent/extensions/fm-topic-home-recovery.ts" 2>/dev/null)" = "$ROOT/.pi/extensions/fm-topic-home-recovery.ts" ]; then
    pass 'topic launch: installs the global Pi recovery entry point for primary and worker resumes'
  else
    fail 'topic launch: did not install the global Pi recovery entry point'
  fi
  if printf '%s' "$command" | grep -F 'This is an isolated Firstmate session' >/dev/null; then
    fail "topic launch: command should not send an initial agent prompt: $command"
  else
    pass 'topic launch: opens Pi idle without an initial agent prompt'
  fi
  rm -rf "$tmp"
}

unit_custom_home_base_writes_recovery_binding() {
  local tmp fakebin log out status expected_home expected_marker
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-custom-base.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  make_fakebin "$fakebin"
  expected_home="$tmp/custom-homes/custom-topic"
  mkdir -p "$expected_home"
  printf 'version=1\nhome=%s\nroot=%s\n' "$expected_home" "$ROOT" > "$expected_home/.fm-topic-home"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" FIRSTMATE_HOME_BASE="$tmp/custom-homes" \
    PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" custom-topic </dev/null 2>&1)
  status=$?
  expected_marker=$(printf 'version=2\nhome=%s\nroot=%s\nherdr_session=%s' \
    "$expected_home" "$ROOT" 'firstmate-custom-topic')
  if [ "$status" -eq 0 ] && [ "$(cat "$expected_home/.fm-topic-home" 2>/dev/null)" = "$expected_marker" ]; then
    pass 'custom home base: launcher advances its legacy owner binding to the exact Herdr session'
  else
    fail "custom home base: recovery binding was not published, status=$status output=$out"
  fi
  rm -rf "$tmp"
}

unit_inside_herdr_reuses_safe_current_workspace() {
  local tmp fakebin log out status home expected_home
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-inside.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  home="$tmp/home"
  make_fakebin "$fakebin"
  out=$(HOME="$home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" FM_FAKE_HERDR_CURRENT_SAFE=1 HERDR_ENV=1 HERDR_SESSION=current-herdr HERDR_WORKSPACE_ID=ws-current HERDR_TAB_ID=tab-current HERDR_PANE_ID=pane-current "$LAUNCH" 'Focus Test' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'inside Herdr safe: launch command succeeds'
  else
    fail "inside Herdr safe: expected success, status=$status output=$out"
  fi
  expected_home="$home/.local/share/firstmate/focus-test__33408c7ea820"
  out=$(cat "$log")
  assert_contains "$out" $'HERDR_ARGS\ttab\tlist\t--workspace\tws-current\t--session\tcurrent-herdr' 'inside Herdr safe: inspects current workspace tabs before reuse'
  assert_contains "$out" $'HERDR_ARGS\tworkspace\trename\tws-current\tfirstmate-focus-test__33408c7ea820\t--session\tcurrent-herdr' 'inside Herdr safe: renames current workspace instead of creating another'
  assert_contains "$out" $'HERDR_ARGS\ttab\trename\ttab-current\tfirstmate\t--session\tcurrent-herdr' 'inside Herdr safe: names current Herdr tab firstmate'
  assert_contains "$out" $'HERDR_ARGS\tpane\trename\tpane-current\tfirstmate\t--session\tcurrent-herdr' 'inside Herdr safe: names current Herdr pane firstmate'
  if printf '%s' "$out" | grep -F $'HERDR_ARGS\tworkspace\tcreate' >/dev/null; then
    fail "inside Herdr safe: created a second workspace instead of reusing current: $out"
  else
    pass 'inside Herdr safe: does not create another workspace'
  fi
  if printf '%s' "$out" | grep -F 'ATTACH_SESSION' >/dev/null; then
    fail "inside Herdr safe: nested Herdr attach was attempted: $out"
  else
    pass 'inside Herdr safe: does not attach nested Herdr TUI'
  fi
  assert_contains "$out" $'PI_ENV\tFM_HOME='"$expected_home"$'\tFM_ROOT_OVERRIDE='"$ROOT"$'\tHERDR_SESSION=current-herdr\tFM_PI_TOPIC_LAUNCH=1' 'inside Herdr safe: execs Pi with validated topic-launch identity'
  rm -rf "$tmp"
}

unit_inside_herdr_uses_live_workspace_identity() {
  local tmp fakebin log out status home
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-moved.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  home="$tmp/home"
  make_fakebin "$fakebin"
  out=$(HOME="$home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" FM_FAKE_HERDR_CURRENT_SAFE=1 FM_FAKE_HERDR_LIVE_WORKSPACE_ID=ws-live FM_FAKE_HERDR_LIVE_TAB_ID=tab-live HERDR_ENV=1 HERDR_SESSION=current-herdr HERDR_WORKSPACE_ID=ws-stale HERDR_TAB_ID=tab-stale HERDR_PANE_ID=pane-current "$LAUNCH" 'Focus Test' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'inside Herdr moved: launch command succeeds'
  else
    fail "inside Herdr moved: expected success, status=$status output=$out"
  fi
  out=$(cat "$log")
  assert_contains "$out" $'HERDR_ARGS\ttab\tlist\t--workspace\tws-live\t--session\tcurrent-herdr' 'inside Herdr moved: validates the live workspace'
  assert_contains "$out" $'HERDR_ARGS\tworkspace\trename\tws-live\tfirstmate-focus-test__33408c7ea820\t--session\tcurrent-herdr' 'inside Herdr moved: renames the live workspace'
  assert_contains "$out" $'HERDR_ARGS\ttab\trename\ttab-live\tfirstmate\t--session\tcurrent-herdr' 'inside Herdr moved: renames the live tab'
  rm -rf "$tmp"
}

unit_inside_herdr_missing_pane_count_falls_back() {
  local tmp fakebin log out status home
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-missing-count.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  home="$tmp/home"
  make_fakebin "$fakebin"
  out=$(HOME="$home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" FM_FAKE_HERDR_CURRENT_SAFE=1 FM_FAKE_HERDR_MISSING_PANE_COUNT=1 HERDR_ENV=1 HERDR_SESSION=current-herdr HERDR_WORKSPACE_ID=ws-current HERDR_TAB_ID=tab-current HERDR_PANE_ID=pane-current "$LAUNCH" 'Focus Test' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'inside Herdr missing pane count: launch command succeeds'
  else
    fail "inside Herdr missing pane count: expected success, status=$status output=$out"
  fi
  out=$(cat "$log")
  assert_contains "$out" $'HERDR_ARGS\tworkspace\tcreate\t--cwd\t'"$ROOT"$'\t--label\tfirstmate-focus-test__33408c7ea820\t--session\tcurrent-herdr' 'inside Herdr missing pane count: falls back to a new workspace'
  if printf '%s' "$out" | grep -F $'HERDR_ARGS\tworkspace\trename\tws-current' >/dev/null; then
    fail "inside Herdr missing pane count: claimed an unproven workspace: $out"
  else
    pass 'inside Herdr missing pane count: refuses to claim the current workspace'
  fi
  rm -rf "$tmp"
}

unit_inside_herdr_unsafe_creates_new_workspace() {
  local tmp fakebin log out status home command
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-inside-unsafe.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  home="$tmp/home"
  make_fakebin "$fakebin"
  out=$(HOME="$home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" HERDR_ENV=1 HERDR_SESSION=current-herdr HERDR_WORKSPACE_ID=ws-current HERDR_TAB_ID=tab-current HERDR_PANE_ID=pane-current "$LAUNCH" 'Focus Test' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'inside Herdr unsafe: launch command succeeds'
  else
    fail "inside Herdr unsafe: expected success, status=$status output=$out"
  fi
  out=$(cat "$log")
  assert_contains "$out" $'HERDR_ARGS\tworkspace\tcreate\t--cwd\t'"$ROOT"$'\t--label\tfirstmate-focus-test__33408c7ea820\t--session\tcurrent-herdr' 'inside Herdr unsafe: creates a new workspace in current session'
  if printf '%s' "$out" | grep -F 'ATTACH_SESSION' >/dev/null; then
    fail "inside Herdr unsafe: nested Herdr attach was attempted: $out"
  else
    pass 'inside Herdr unsafe: does not attach nested Herdr TUI'
  fi
  command=$(printf '%s\n' "$out" | awk -F '\t' '/^PANE_RUN_COMMAND/{print $2; exit}')
  assert_contains "$command" "HERDR_SESSION='current-herdr'" 'inside Herdr unsafe: command preserves current Herdr session'
  rm -rf "$tmp"
}

unit_inactive_herdr_marker_attaches_topic_session() {
  local tmp fakebin log out status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-inactive-herdr.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  make_fakebin "$fakebin"
  out=$(HOME="$tmp/home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" HERDR_ENV=0 HERDR_SESSION=ambient-session "$LAUNCH" inactive-marker </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ] \
    && grep -F $'HERDR_ARGS\tworkspace\tcreate\t--cwd\t'"$ROOT"$'\t--label\tfirstmate-inactive-marker\t--session\tfirstmate-inactive-marker' "$log" >/dev/null \
    && grep -F $'ATTACH_SESSION\tfirstmate-inactive-marker' "$log" >/dev/null \
    && ! grep -F -- $'--session\tambient-session' "$log" >/dev/null; then
    pass 'inactive Herdr marker: attaches topic-specific session outside Herdr'
  else
    fail "inactive Herdr marker: expected outside-Herdr behavior, status=$status output=$out log=$(cat "$log" 2>/dev/null || true)"
  fi
  rm -rf "$tmp"
}

unit_without_herdr_falls_back_to_pi_without_wrapping_pi() {
  local tmp fakebin log out status home expected_home
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-direct.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  home="$tmp/home"
  without_herdr_fakebin "$fakebin"
  ln -s /usr/bin/bash "$fakebin/bash"
  ln -s /usr/bin/env "$fakebin/env"
  ln -s /usr/bin/dirname "$fakebin/dirname"
  ln -s /usr/bin/mkdir "$fakebin/mkdir"
  ln -s /usr/bin/sed "$fakebin/sed"
  ln -s /usr/bin/sha256sum "$fakebin/sha256sum"
  ln -s /usr/bin/tr "$fakebin/tr"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$home" PATH="$fakebin" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" 'Direct Run' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'direct fallback: fake Pi exits successfully'
  else
    fail "direct fallback: expected success, status=$status output=$out"
  fi
  expected_home="$home/.local/share/firstmate/direct-run__753327a3bc4b"
  out=$(cat "$log")
  assert_contains "$out" $'PI_ENV\tFM_HOME='"$expected_home"$'\tFM_ROOT_OVERRIDE='"$ROOT"$'\tHERDR_SESSION=\tFM_PI_TOPIC_LAUNCH=1' 'direct fallback: starts Pi with validated topic-launch identity and no synthetic Herdr session'
  assert_contains "$out" $'PI_ARGS\t--session-dir\t'"$expected_home/pi-sessions"$'\t--name\tfirstmate: Direct Run\t-e\t'"$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" 'direct fallback: invokes Pi directly with explicit extension flags'
  if printf '%s' "$out" | grep -F 'This is an isolated Firstmate session' >/dev/null; then
    fail "direct fallback: should not send an initial agent prompt: $out"
  else
    pass 'direct fallback: opens Pi idle without an initial agent prompt'
  fi
  rm -rf "$tmp"
}

unit_shasum_fallback_generates_stable_topic_key() {
  local tmp fakebin log out status expected_home
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-shasum.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  without_herdr_fakebin "$fakebin"
  ln -s /usr/bin/bash "$fakebin/bash"
  ln -s /usr/bin/env "$fakebin/env"
  ln -s /usr/bin/dirname "$fakebin/dirname"
  ln -s /usr/bin/mkdir "$fakebin/mkdir"
  ln -s /usr/bin/sed "$fakebin/sed"
  ln -s /usr/bin/tr "$fakebin/tr"
  cat > "$fakebin/shasum" <<'FAKE_SHASUM'
#!/usr/bin/env bash
[ "${1:-}" = -a ] && [ "${2:-}" = 256 ] || exit 64
/usr/bin/sha256sum
FAKE_SHASUM
  chmod +x "$fakebin/shasum"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" 'Road Map' </dev/null 2>&1)
  status=$?
  expected_home="$tmp/home/.local/share/firstmate/road-map__baf493d9991d"
  if [ "$status" -eq 0 ] \
    && [ -d "$expected_home/config" ] \
    && grep -F $'PI_ENV\tFM_HOME='"$expected_home" "$log" >/dev/null; then
    pass 'shasum fallback: non-normalized topic launches with stable isolated key'
  else
    fail "shasum fallback: expected stable launch, status=$status output=$out log=$(cat "$log" 2>/dev/null || true)"
  fi
  rm -rf "$tmp"
}

unit_fm_alias_delegates_to_launcher() {
  local tmp fakebin log out status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-alias.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  make_fakebin "$fakebin"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$FM_ALIAS" Alias Topic </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ] && grep -F $'ATTACH_SESSION\tfirstmate-alias-topic__e5fd5d3c9294' "$log" >/dev/null 2>&1; then
    pass 'fm alias: delegates to firstmate launcher'
  else
    fail "fm alias: expected delegated launch, status=$status output=$out log=$(cat "$log" 2>/dev/null || true)"
  fi
  rm -rf "$tmp"
}

unit_colliding_slugs_get_isolated_topic_keys() {
  local tmp fakebin log out status
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-collision.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  make_fakebin "$fakebin"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" 'Road Map' </dev/null 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "topic collision: first launch failed, status=$status output=$out"
  fi
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" 'road-map!' </dev/null 2>&1)
  status=$?
  env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" road-map--baf493d9991d </dev/null 2>&1
  env -u HERDR_ENV -u HERDR_SESSION HOME="$tmp/home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" workflow-improvements </dev/null 2>&1
  if [ "$status" -eq 0 ] \
    && [ -d "$tmp/home/.local/share/firstmate/road-map__baf493d9991d/config" ] \
    && [ -d "$tmp/home/.local/share/firstmate/road-map__535280cb1542/config" ] \
    && [ -d "$tmp/home/.local/share/firstmate/road-map-baf493d9991d__d975967f2ae6/config" ] \
    && [ -d "$tmp/home/.local/share/firstmate/workflow-improvements/config" ] \
    && grep -F $'ATTACH_SESSION\tfirstmate-road-map__baf493d9991d' "$log" >/dev/null \
    && grep -F $'ATTACH_SESSION\tfirstmate-road-map__535280cb1542' "$log" >/dev/null \
    && grep -F $'ATTACH_SESSION\tfirstmate-road-map-baf493d9991d__d975967f2ae6' "$log" >/dev/null; then
    pass 'topic collision: distinct raw topics get isolated homes and Herdr sessions'
  else
    fail "topic collision: lossy aliases were not isolated, status=$status output=$out log=$(cat "$log")"
  fi
  rm -rf "$tmp"
}

unit_noninteractive_missing_topic_refuses
unit_interactive_missing_topic_refuses_without_prompt
unit_symlink_install_resolves_shared_checkout
unit_topic_slug_home_and_command
unit_custom_home_base_writes_recovery_binding
unit_inside_herdr_reuses_safe_current_workspace
unit_inside_herdr_uses_live_workspace_identity
unit_inside_herdr_missing_pane_count_falls_back
unit_inside_herdr_unsafe_creates_new_workspace
unit_inactive_herdr_marker_attaches_topic_session
unit_without_herdr_falls_back_to_pi_without_wrapping_pi
unit_shasum_fallback_generates_stable_topic_key
unit_fm_alias_delegates_to_launcher
unit_colliding_slugs_get_isolated_topic_keys

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
