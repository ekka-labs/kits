#!/bin/sh
# A kit may only use capability codes that are on the `ekka` edition, because that is the edition
# every new organization lands on. The pricing page prints those codes and govern's CI keeps the
# page honest, so the page is the source here. Fails if a code the kit NEEDS is not on the page.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=${1:?usage: check-kit.sh <kit>}
PAGE=${PAGE:-https://docs.ekka.ai/pricing/}
LINE=$(grep -E "^$KIT[[:space:]]" "$HERE/../kits.txt") || { echo "no kit named $KIT" >&2; exit 1; }
KIT_DIR="$HERE/../$(printf '%s' "$LINE" | awk '{print $2}')"
FLOOR=$(printf '%s' "$LINE" | awk '{print $3}')
BODY=$(curl -fsSL -m 20 "$PAGE") || { echo "could not read $PAGE" >&2; exit 2; }
rc=0
while read -r code; do
  [ -z "$code" ] && continue
  if printf '%s' "$BODY" | grep -q "$code"; then echo "  ok   $code is on the ekka edition"
  else echo "  MISSING  $code is not on the ekka edition (a stranger's org cannot run this kit)"; rc=1; fi
done < "$KIT_DIR/NEEDS"
grep -q "FLOOR=$FLOOR" "$KIT_DIR/open.sh" && echo "  ok   open.sh checks for ekka >= $FLOOR" || { echo "  MISSING  open.sh floor differs from kits.txt ($FLOOR)"; rc=1; }
[ -f "$KIT_DIR/VERSION" ] && echo "  ok   kit version $(cat "$KIT_DIR/VERSION")" || { echo "  MISSING  VERSION"; rc=1; }
exit $rc
