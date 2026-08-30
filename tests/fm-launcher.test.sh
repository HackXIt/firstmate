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
    printf '{"result":{"workspace":{"workspace_id":"ws-test"},"tab":{"tab_id":"tab-test"},"root_pane":{"pane_id":"pane-test"}}}\n'
    ;;
  tab)
    :
    ;;
  pane)
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
printf 'PI_ENV\tFM_HOME=%s\tFM_ROOT_OVERRIDE=%s\tHERDR_SESSION=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" "${HERDR_SESSION:-}" >> "$FM_LAUNCHER_TEST_LOG"
printf 'PI_ARGS' >> "$FM_LAUNCHER_TEST_LOG"
printf '\t%s' "$@" >> "$FM_LAUNCHER_TEST_LOG"
printf '\n' >> "$FM_LAUNCHER_TEST_LOG"
FAKE_PI
  chmod +x "$dir/pi"
}

without_herdr_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/pi" <<'FAKE_PI'
#!/usr/bin/env bash
set -u
printf 'PI_ENV\tFM_HOME=%s\tFM_ROOT_OVERRIDE=%s\tHERDR_SESSION=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" "${HERDR_SESSION:-}" >> "$FM_LAUNCHER_TEST_LOG"
printf 'PI_ARGS' >> "$FM_LAUNCHER_TEST_LOG"
printf '\t%s' "$@" >> "$FM_LAUNCHER_TEST_LOG"
printf '\n' >> "$FM_LAUNCHER_TEST_LOG"
FAKE_PI
  chmod +x "$dir/pi"
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

unit_topic_slug_home_and_command() {
  local tmp fakebin log out status home expected_home command
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
  expected_home="$home/.local/share/firstmate/workflow-improvements"
  if [ -d "$expected_home/config" ] && [ -d "$expected_home/data" ] && [ -d "$expected_home/state" ] && [ -d "$expected_home/projects" ]; then
    pass 'topic launch: creates standard per-home directories'
  else
    fail 'topic launch: did not create standard per-home directories'
  fi
  out=$(cat "$log")
  assert_contains "$out" $'HERDR_ARGS\tworkspace\tcreate\t--cwd\t'"$ROOT"$'\t--label\tfirstmate-workflow-improvements\t--session\tfirstmate-workflow-improvements' 'topic launch: creates topic-specific Herdr workspace in topic session'
  assert_contains "$out" $'HERDR_ARGS\ttab\trename\ttab-test\tfirstmate\t--session\tfirstmate-workflow-improvements' 'topic launch: names initial Herdr tab firstmate'
  assert_contains "$out" $'HERDR_ARGS\tpane\trename\tpane-test\tfirstmate\t--session\tfirstmate-workflow-improvements' 'topic launch: names initial Herdr pane firstmate'
  assert_contains "$out" $'ATTACH_SESSION\tfirstmate-workflow-improvements' 'topic launch: attaches named Herdr session outside Herdr'
  command=$(printf '%s\n' "$out" | awk -F '\t' '/^PANE_RUN_COMMAND/{print $2; exit}')
  assert_contains "$command" "FM_HOME='$expected_home'" 'topic launch: command sets isolated FM_HOME'
  assert_contains "$command" "HERDR_SESSION='firstmate-workflow-improvements'" 'topic launch: command sets generated Herdr session'
  assert_contains "$command" "--session-dir '$expected_home/pi-sessions'" 'topic launch: command isolates Pi session storage'
  assert_contains "$command" "-e '$ROOT/.pi/extensions/fm-primary-turnend-guard.ts' -e '$ROOT/.pi/extensions/fm-primary-pi-watch.ts'" 'topic launch: command loads Firstmate Pi extensions explicitly'
  assert_contains "$out" "Other Firstmate sessions and their workers are unrelated to this one" 'topic launch: startup prompt names isolation boundary'
  rm -rf "$tmp"
}

unit_inside_herdr_uses_current_session_without_nested_attach() {
  local tmp fakebin log out status home command
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-inside.XXXXXX")
  fakebin="$tmp/bin"
  log="$tmp/log"
  home="$tmp/home"
  make_fakebin "$fakebin"
  out=$(HOME="$home" PATH="$fakebin:$PATH" FM_LAUNCHER_TEST_LOG="$log" HERDR_ENV=1 HERDR_SESSION=current-herdr "$LAUNCH" 'Focus Test' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'inside Herdr: launch command succeeds'
  else
    fail "inside Herdr: expected success, status=$status output=$out"
  fi
  out=$(cat "$log")
  assert_contains "$out" $'HERDR_ARGS\tworkspace\tcreate\t--cwd\t'"$ROOT"$'\t--label\tfirstmate-focus-test\t--session\tcurrent-herdr' 'inside Herdr: creates workspace in current session'
  assert_contains "$out" $'HERDR_ARGS\ttab\trename\ttab-test\tfirstmate\t--session\tcurrent-herdr' 'inside Herdr: names initial Herdr tab firstmate'
  if printf '%s' "$out" | grep -F 'ATTACH_SESSION' >/dev/null; then
    fail "inside Herdr: nested Herdr attach was attempted: $out"
  else
    pass 'inside Herdr: does not attach nested Herdr TUI'
  fi
  command=$(printf '%s\n' "$out" | awk -F '\t' '/^PANE_RUN_COMMAND/{print $2; exit}')
  assert_contains "$command" "HERDR_SESSION='current-herdr'" 'inside Herdr: command preserves current Herdr session'
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
  ln -s /usr/bin/tr "$fakebin/tr"
  out=$(env -u HERDR_ENV -u HERDR_SESSION HOME="$home" PATH="$fakebin" FM_LAUNCHER_TEST_LOG="$log" "$LAUNCH" 'Direct Run' </dev/null 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    pass 'direct fallback: fake Pi exits successfully'
  else
    fail "direct fallback: expected success, status=$status output=$out"
  fi
  expected_home="$home/.local/share/firstmate/direct-run"
  out=$(cat "$log")
  assert_contains "$out" $'PI_ENV\tFM_HOME='"$expected_home"$'\tFM_ROOT_OVERRIDE='"$ROOT"$'\tHERDR_SESSION=' 'direct fallback: starts Pi with isolated home and no synthetic Herdr session'
  assert_contains "$out" $'PI_ARGS\t--session-dir\t'"$expected_home/pi-sessions"$'\t--name\tfirstmate: Direct Run\t-e\t'"$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" 'direct fallback: invokes Pi directly with explicit extension flags'
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
  if [ "$status" -eq 0 ] && grep -F $'ATTACH_SESSION\tfirstmate-alias-topic' "$log" >/dev/null 2>&1; then
    pass 'fm alias: delegates to firstmate launcher'
  else
    fail "fm alias: expected delegated launch, status=$status output=$out log=$(cat "$log" 2>/dev/null || true)"
  fi
  rm -rf "$tmp"
}

unit_noninteractive_missing_topic_refuses
unit_topic_slug_home_and_command
unit_inside_herdr_uses_current_session_without_nested_attach
unit_without_herdr_falls_back_to_pi_without_wrapping_pi
unit_fm_alias_delegates_to_launcher

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
