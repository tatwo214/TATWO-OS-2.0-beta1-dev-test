#!/usr/bin/env bash
# Caller-only composition. No SSH configuration or pin source is written.
TATWO_SSH_PIN_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Engines/gbrain-adapter/ssh-pins.mjs"

tatwo_pin_options() {
  local output
  output="$(node "$TATWO_SSH_PIN_HELPER" "$1")" || return 1
  TATWO_PIN_OPTIONS=()
  while IFS= read -r option; do TATWO_PIN_OPTIONS+=("$option"); done <<< "$output"
}

tatwo_pinned_run() {
  local target="$1" executable="$2"
  shift 2
  tatwo_pin_options "$target" || return 1
  "$executable" "${TATWO_PIN_OPTIONS[@]}" "$@"
}

tatwo_ssh_transport() {
  tatwo_pin_options "$1" || return 1
  # rsync's -e parser accepts single-quoted arguments (including embedded spaces).
  local option
  printf '/usr/bin/ssh '
  for option in "${TATWO_PIN_OPTIONS[@]}"; do
    option="${option//\'/\'\\\'\'}"
    printf "'%s' " "$option"
  done
}
