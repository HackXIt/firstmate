#!/usr/bin/env bash

fm_pi_topic_state_bind() {
  local home=$1 root=$2 session=$3 state=$4 binding temporary
  home=$(CDPATH='' cd -- "$home" && pwd -P) || return 1
  root=$(CDPATH='' cd -- "$root" && pwd -P) || return 1
  state=$(CDPATH='' cd -- "$state" && pwd -P) || return 1
  if [ ! -f "$home/.fm-topic-home" ] || [ -L "$home/.fm-topic-home" ] \
     || ! cmp -s "$home/.fm-topic-home" <(printf 'version=2\nhome=%s\nroot=%s\nherdr_session=%s\n' "$home" "$root" "$session"); then
    printf 'error: Pi topic marker does not match this launch: %s\n' "$home" >&2
    return 1
  fi
  binding="$home/.fm-pi-state"
  temporary=$(umask 077; mktemp "$home/.fm-pi-state.XXXXXX") || return 1
  if ! printf 'home=%s\nroot=%s\nherdr_session=%s\nstate=%s\n' \
    "$home" "$root" "$session" "$state" > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if ! ln "$temporary" "$binding" 2>/dev/null; then
    if [ -n "$session" ] && [ -f "$binding" ] && [ ! -L "$binding" ] \
       && cmp -s "$binding" <(printf 'home=%s\nroot=%s\nherdr_session=\nstate=%s\n' "$home" "$root" "$state"); then
      mv "$temporary" "$binding" || { rm -f "$temporary"; return 1; }
      return 0
    fi
    if [ ! -f "$binding" ] || [ -L "$binding" ] || ! cmp -s "$temporary" "$binding"; then
      rm -f "$temporary"
      printf 'error: Pi state binding conflicts with this topic launch: %s\n' "$binding" >&2
      return 1
    fi
  fi
  rm -f "$temporary"
}
