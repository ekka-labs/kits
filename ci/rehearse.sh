#!/bin/sh
# Run one kit end to end against the stand-in ekka, with canned answers, and check the screens
# that matter appeared. No server, no key, no network except one read of a public website.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=${1:?usage: rehearse.sh <kit>}
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export REHEARSAL_STATE="$WORK/state"; mkdir -p "$REHEARSAL_STATE/art/abc123" "$REHEARSAL_STATE/art/sig1"
cat > "$REHEARSAL_STATE/art/abc123/call.json" <<'EOF'
{"resource":"apis/steves-org/eth-balance-sepolia","body":{"hash":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","coin_balance":"1234500000000000000"}}
EOF
cat > "$REHEARSAL_STATE/art/sig1/call.json" <<'EOF'
{"op":"sign","resource":"keys/SEPOLIA_WALLET_KEY","alg":"secp256k1","digest":"7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069","signature":"0xaaaa","recovery_id":1}
EOF
mkdir -p "$WORK/bin"; cp "$HERE/rehearsal/fake-ekka" "$WORK/bin/ekka"; chmod +x "$WORK/bin/ekka"
cp -R "$HERE/../$KIT" "$WORK/kit"; rm -f "$WORK/kit/.demo-state"
cd "$WORK/kit"
ROLL=0 NO_COLOR=1 OPEN_SH_INPUT="$HERE/rehearsal/$KIT.answers" PATH="$WORK/bin:$PATH" sh ./open.sh > "$WORK/out.txt" 2>&1 || { echo "open.sh exited non-zero"; tail -20 "$WORK/out.txt"; exit 1; }
rc=0
for must in "Plan completed" "balance  1.234500 ETH" "RESOURCE_GRANT_DENIED" "Refused again" "records check out" "nobody wrote code"; do
  if grep -q "$must" "$WORK/out.txt"; then echo "  ok   saw: $must"; else echo "  MISSING: $must"; rc=1; fi
done
for m in steps try why commands; do printf 's\ns\n\n\n\n\n\n\n' > "$WORK/s"; ROLL=0 NO_COLOR=1 OPEN_SH_INPUT="$WORK/s" PATH="$WORK/bin:$PATH" sh ./open.sh $m >/dev/null 2>&1 && echo "  ok   ./open.sh $m" || { echo "  FAIL ./open.sh $m"; rc=1; }; done
exit $rc
