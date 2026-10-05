#!/bin/sh
# Owned packaging-only fixture: no authentication, network, or model execution.
if [ "$#" -eq 1 ] && [ "$1" = '--version' ]; then
  printf '%s\n' 'tatwo-staging-owned-fixture-1'
  exit 0
fi
printf '%s\n' 'unexpected model execution' > "${TATWO_FIXTURE_UNEXPECTED_EXECUTION:?fixture marker required}"
exit 97
