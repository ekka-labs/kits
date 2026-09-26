#!/bin/sh
# Wallet Kit: your AI decides whether to move the extra in your everyday wallet to your savings
# wallet, your Enclave signs, you control what it is allowed to do. A hosted model applies YOUR rule
# to your live balance; its `transfer` is the only thing that can lead to a signature, and only
# while you have given permission to sign. THE KIT, NOT THE AI, SETS THE AMOUNT AND THE ADDRESS.
# Sepolia test network only: test ETH has no value.
# It touches your wallet's private key exactly once: reads it at a hidden prompt, checks the
# shape, hands it to the Enclave, forgets it. Everything else is plans, grants and explanations.
set -eu

EKKA=${EKKA:-ekka}
EKKA_FLAG=${EKKA_FLAG:-}
AGENT=${AGENT:-wallet-agent}
KEY=${KEY:-SEPOLIA_WALLET_KEY}
ENCLAVE=${ENCLAVE:-}
MODEL=${MODEL:-anthropic/sonnet-4}
ROW=eth-sepolia                           # the Sepolia row, catalog/ekka-$ROW.json
CHAIN_ID=11155111                         # Sepolia
EXPLORER=https://eth-sepolia.blockscout.com
FAUCET=https://cloud.google.com/application/web3/faucet/ethereum/sepolia
FAUCET2=https://www.alchemy.com/faucets/ethereum-sepolia
# The docs section with MetaMask AND the faucets. `#what-you-need` exists on the kit 1.0 page and
# on the 2.0 page alike, so this link works before and after the new page ships.
WALLET_HELP=https://docs.ekka.ai/kits/wallet-agent/#what-you-need
KEEP_ETH=0.01                             # the rule keeps at least this much in the everyday wallet
KEEP_WEI=10000000000000000
MIN_MOVE_WEI=1000000000000000             # less extra than 0.001 test ETH is not worth a transfer
AMOUNT_WEI=""; AMOUNT_ETH=""              # set in step 1 by the kit, from the balance: never by the AI
GAS=21000                                 # a plain transfer always uses exactly this much
DOCS=https://docs.ekka.ai
KIT_DOC=https://github.com/ekka-labs/kits/tree/main/wallet-agent
HERE=$(cd "$(dirname "$0")" && pwd)
# Work inside the kit's folder, so the command a person is shown is the command that runs.
cd "$HERE"
STATE="$HERE/.demo-state"
VIEWD="$HERE/.view"
MODE=${1:-setup}                # setup (default) | steps | commands | why | view

# ---------------------------------------------------------------- colors, only on a terminal
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$(printf '\033[1m'); D=$(printf '\033[2m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); C=$(printf '\033[36m'); N=$(printf '\033[0m')
else
  B=""; D=""; G=""; Y=""; R=""; C=""; N=""
fi
ROLL=${ROLL:-0.04}
say()   { printf '%s\n' "$*"; [ "$ROLL" = 0 ] || sleep "$ROLL"; }
head_() { say ""; say "  ${B}$1${N}"; say "  ${D}$(printf '%*s' "${#1}" '' | tr ' ' '-')${N}"; }
ok()    { say "  ${G}✔${N} $*"; }
note()  { say "      ${D}$*${N}"; }
# A command gets air: a line somebody is meant to read and type has blank lines around it.
cmd()   { say ""; say "      ${C}$*${N}"; say ""; }
stop()  { say ""; say "  ${R}✖ Stopped.${N} $1"; say "    $2"; say ""; exit 1; }
run()   { $EKKA $EKKA_FLAG "$@"; }
EK="$EKKA${EKKA_FLAG:+ $EKKA_FLAG}"
# Answers come from the terminal even when the script is piped. OPEN_SH_INPUT=file rehearses with canned answers.
if [ -n "${OPEN_SH_INPUT:-}" ]; then exec 3<"$OPEN_SH_INPUT"
elif ( : </dev/tty ) 2>/dev/null; then exec 3</dev/tty
else exec 3</dev/null; fi
# A timestamped trace of every key read and every wait, so a walk that ever sticks shows WHERE.
trace() { mkdir -p "$VIEWD" 2>/dev/null && printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$VIEWD/trace.log" 2>/dev/null; return 0; }
ask()   { printf "  ${Y}%s${N} " "$1"; trace "waiting for a key: $1"; read -r REPLY <&3 || REPLY=""; trace "got: ${REPLY:-Enter}"; }
wait_enter() { printf "  ${Y}%s${N} " "$1"; trace "waiting for a key: $1"; read -r REPLY <&3 || REPLY=q; trace "got: ${REPLY:-Enter}"; case "$REPLY" in q|Q) say ""; say "  Stopped. Inspect the saved attempt with: ./open.sh steps"; say ""; exit 0 ;; esac; }
OUTF=$(mktemp)
# ONE WALK PER FOLDER. Two walks share one saved state and one transfer number, and each would act
# on the other's half-finished attempt. A lock whose process is gone is stale and is taken over.
LOCK="$HERE/.walk.lock"; HAVE_LOCK=""
take_lock() {
  if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    OTHER=$(cat "$LOCK")
    say ""; say "  ${Y}Another walk is already running in this folder${N} (process $OTHER)."
    ask "If you left it behind, press t to stop it and start fresh. [t/N]"
    case "$REPLY" in
      t|T) kill "$OTHER" 2>/dev/null || true; sleep 1; trace "took over from process $OTHER"
           say "  Stopped the old walk." ;;
      *)   say "  Nothing was changed. Finish the other walk in its own window."; say ""; exit 1 ;;
    esac
  fi
  echo $$ > "$LOCK"; HAVE_LOCK=1
}
trap 'rm -f "$OUTF" "$OUTF.rc" "$OUTF.show"; [ -n "$HAVE_LOCK" ] && rm -f "$LOCK"; [ -n "${SPIN_PID:-}" ] && kill "$SPIN_PID" 2>/dev/null; true' EXIT
trap 'trace "terminal hung up"; exit 129' HUP

# The evidence file and its read-only page. A failure to write evidence never stops the walk,
# and never counts as a pass: the page shows only what was written.
vw() { "$HERE/bin/view" "$VIEWD" "$@" >/dev/null 2>&1 || true; }

# The command a step runs, as one short dim line: the plan's name, not its every input.
runs() {
  if [ -n "${VERBOSE:-}" ]; then cmd "$1"; return; fi
  short=$(printf '%s' "$1" | sed -E 's/(plan run [^ ]+).*/\1/; s/(grant revoke) .*/\1/; s/(grant add) .*/\1/; s/^[^ ]*ekka( --[a-z]+)? /ekka /')
  say "      ${D}runs: $short${N}"
}
# ONE way to show a wait: a line naming what is happening, with moving dots, on a terminal only.
# `|| true` is not decoration: `wait` on a killed job returns 143, and under `set -e` that ended
# the WHOLE KIT the first time a wait finished (found by a real-terminal walk of the Financial Kit).
SPIN_PID=""
spin_start() {
  [ -t 1 ] && [ -z "${VERBOSE:-}" ] || return 0
  ( i=0; while :; do printf '\r  %s%-3s ' "$1" "$(printf '%*s' $((i % 4)) '' | tr ' ' '.')"; i=$((i + 1)); sleep 0.4; done ) &
  SPIN_PID=$!
}
spin_stop() {
  [ -n "$SPIN_PID" ] || return 0
  kill "$SPIN_PID" 2>/dev/null || true; wait "$SPIN_PID" 2>/dev/null || true; SPIN_PID=""
  printf '\r%74s\r' ""
}
item_start() { ITEM="$1"; trace "setup: $1"; spin_start "$1"; }
item_done()  { spin_stop; ok "$ITEM"; }
busy() {  # message  command
  if [ -t 1 ] && [ -z "${VERBOSE:-}" ]; then
    spin_start "$1"; trace "busy: $1"; quiet "$2"; trace "done: $1 (rc=$RC)"; spin_stop
  else
    quiet "$2"
  fi
}
quiet() { RC=0; sh -c "$1" > "$OUTF" 2>&1 || RC=$?; }
show_failure() { sed 's/^/      /' "$OUTF" | while IFS= read -r l; do say "${R}$l${N}"; done; }

stop_walk() {
  # ⛔ A STOP NEVER LEAVES A SIGN PERMISSION BEHIND. While one lasts, the agent may sign ANY
  # transfer with this key, so a walk that stops after step 2 gave it takes it back first.
  if [ -n "${SIGN_GRANT_ID:-}" ] && [ -n "${SIGN_INTENT:-}" ]; then
    spin_stop
    if run gate grant revoke "$SIGN_GRANT_ID" >/dev/null 2>&1; then
      SIGN_GRANT_ID=""; SIGN_INTENT=""; save_state 2>/dev/null || true
      say "      The sign permission was taken back, so nothing more can be signed."
    else
      say "      ${R}The sign permission could not be taken back for you.${N} Do it now:"
      cmd "$EK gate grant revoke $SIGN_GRANT_ID"
    fi
  fi
  vw render
  say ""
  say "  ${R}✖ The walkthrough has stopped.${N} Each step has to mean what it says before the next one can."
  say "    Inspect the saved attempt with:  ${C}./open.sh steps${N}     The evidence page:  ${C}$VIEWD/view.html${N}"
  say ""
  exit 1
}

explain_failure() {
  say "      ${R}The plan did not run.${N}"
  if grep -q "GOVERN_AUTH_REJECTED" "$OUTF"; then
    say "      EKKA could not authenticate the Enclave. The action's permissions were not evaluated."
  elif grep -q "session expired" "$OUTF"; then
    say "      Your sign-in on this machine expired. Sign in again, then come back:"
    cmd "$EK login --email <your email>    then    ./open.sh steps"
  elif grep -q "credit_exhausted" "$OUTF"; then
    say "      Your organization has no EKKA credit yet. Reply to the email you were sent and name"
    say "      your organization (${B}$ORG${N}); it is one command on our side. Then ${C}./open.sh steps${N}"
  elif grep -q "USAGE_CEILING_EXCEEDED" "$OUTF"; then
    # Measured on prod 2026-09-25: a daily run limit answers HTTP 429 too, and used to be told as
    # "EKKA is not answering", which sends a person to wait for an outage that is not happening.
    say "      Your organization has used all of today's EKKA runs (its daily limit). Nothing was changed."
    say "      It resets at the start of the next day (UTC), or an admin raises it:  ${C}$EK org limits set${N}"
  elif grep -qE "answered 429|Too many requests" "$OUTF"; then
    say "      The Sepolia service is busy: its free tier takes only a few requests every few minutes."
    say "      Nothing changed. Wait a few minutes, then:  ${C}./open.sh steps${N}"
  elif grep -qE "GOVERN_HTTP_ERROR|50[234]|52[0-9]|unreachable" "$OUTF"; then
    say "      EKKA is not answering right now. Nothing else was changed. Try again in a few minutes:"
    cmd "./open.sh steps"
  else
    say "      The red line above names the reason. Fix it, then run the steps again:  ${C}./open.sh steps${N}"
  fi
}

refused_by_ekka() { grep -q RESOURCE_GRANT_DENIED "$OUTF"; }
plan_completed()  { grep -q "✓ Plan completed" "$OUTF"; }
out_path()        { grep -oE 'output is at .*' "$OUTF" | sed 's/output is at //' | tail -1 || true; }
run_id()          { grep -oE 'run [0-9a-f-]{36}' "$OUTF" | head -1 | cut -c5- || true; }
field()           { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null || true; }
short()           { printf '%s…%s' "$(printf '%s' "$1" | cut -c1-6)" "$(printf '%s' "$1" | rev | cut -c1-4 | rev)"; }
eth_of()          { python3 -c 'import sys; print("%.6f" % (int(sys.argv[1]) / 1e18))' "$1" 2>/dev/null || echo "?"; }
save_state() {
  cat > "$STATE" <<EOF
ORG='$ORG'
AGENT='$AGENT'
KEY='$KEY'
AINST='$AINST'
SINST='$SINST'
LLM='$LLM'
MODEL='$MODEL'
API_ROW='$API_ROW'
KIT_MAJOR=3
ADDRESS='$ADDRESS'
SAVINGS='$SAVINGS'
AMOUNT_WEI='${AMOUNT_WEI:-}'
AMOUNT_ETH='${AMOUNT_ETH:-}'
BAL_VER='$BAL_VER'
SNT_VER='$SNT_VER'
FEE_VER='$FEE_VER'
DEC_VER='$DEC_VER'
SIG_VER='$SIG_VER'
SND_VER='$SND_VER'
DECISION='${DECISION:-}'
SIGN_GRANT_ID='${SIGN_GRANT_ID:-}'
SIGN_INTENT='${SIGN_INTENT:-}'
TX_HASH='${TX_HASH:-}'
TX_OUTCOME='${TX_OUTCOME:-}'
EOF
}

# Reads one fixed plan and sets P to the saved answer's path. Stops the walk on a failure.
read_plan() {  # label  plan
  busy "$1" "$EK plan run $2"
  plan_completed || { show_failure; explain_failure; stop_walk; }
  P=$(out_path)
}

# ⛔ A LOW BALANCE NEVER REACHES THE AI. If the everyday wallet holds no extra above what the rule
# keeps, the AI would rightly say hold and the walk would show nothing. So the kit stops BEFORE the
# AI is asked, at setup and again at step 1, and says how to put test ETH back. This is also what a
# SECOND walk meets: the first one moved the extra to savings.
funds_check() {  # output.json of a balance read. Sets BAL_WEI and BAL_ETH, or stops.
  BAL_WEI=$("$HERE/bin/wallet" wei "$1"); BAL_ETH=$("$HERE/bin/wallet" balance "$1")
  NEED_WEI=$((KEEP_WEI + MIN_MOVE_WEI + GAS * 20000000000))
  # Compared in python: a balance in wei passes the shell's 64-bit limit above about 9.2 ETH.
  python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)' "$BAL_WEI" "$NEED_WEI" && return 0
  say "  ${Y}Your everyday wallet holds $BAL_ETH test ETH:${N} nothing worth moving above the $KEEP_ETH it keeps."
  say "  The walk needs at least $(eth_of "$NEED_WEI"). Test ETH is free."
  [ "$SAVINGS" != "$ADDRESS" ] && say "  Moved it to savings in an earlier walk? Send some back to $(short "$ADDRESS") in MetaMask. Or:"
  say "    1. Open ${C}$FAUCET${N}"
  say "    2. Sign in with a Google account, paste $(short "$ADDRESS"), click ${B}Receive 0.05 Sepolia ETH${N}."
  say "    3. Wait about a minute, then run ${C}./open.sh steps${N}"
  say "    ${D}If Google says no (daily limit):${N} ${C}$FAUCET2${N}"
  say "  Step by step, with MetaMask:  ${C}$WALLET_HELP${N}"
  say "  Nothing was asked of the AI, and nothing was signed."
  stop_walk
}

# Build the transfer: the next transfer number, today's fee cap, the extra to the savings wallet.
# Writes transfer.json and sets DIGEST, the 64 characters the Enclave will sign. Sets NONCE.
# ⛔ THE AMOUNT IS THE KIT'S, WORKED OUT HERE FROM THE BALANCE, NEVER THE AI'S. The first build
# (step 1) sets it: everything above what the rule keeps, less the most the fee can be, rounded
# DOWN to 0.0001, so at least $KEEP_ETH is left whatever the fee turns out to be. Step 4 builds the
# same transfer again with the next number, and keeps this amount.
build_payment() {  # [nonce]
  # ⚠️ Read the argument FIRST: `set --` below reuses $1 for the fee, and a check of $1 after it
  # would read the fee (found by the rehearsal: the amount was never set).
  AGAIN=${1:-}
  if [ -n "$AGAIN" ]; then NONCE=$AGAIN
  else read_plan "Reading your wallet's transfers" "$SNT_VER"; NONCE=$("$HERE/bin/wallet" nonce "$P"); fi
  read_plan "Reading the network's fees" "$FEE_VER"
  set -- $("$HERE/bin/wallet" fees "$P"); MAXFEE=${1:-}; TIP=${2:-}
  printf '%s' "$MAXFEE" | grep -qE '^[0-9]+$' || { say "      ${R}The network did not say what fees are today.${N} Try again in a minute."; stop_walk; }
  FEE_CAP_WEI=$((GAS * MAXFEE))
  if [ -z "$AGAIN" ]; then
    # In python, not $(( )): the balance in wei can pass the shell's 64-bit limit.
    AMOUNT_WEI=$(python3 -c 'import sys; b, k, f = map(int, sys.argv[1:]); print(max(0, (b - k - f) // 10**14 * 10**14))' "$BAL_WEI" "$KEEP_WEI" "$FEE_CAP_WEI")
    if python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) < int(sys.argv[2]) else 1)' "$AMOUNT_WEI" "$MIN_MOVE_WEI"; then
      say "  ${Y}After today's network fee there is less than 0.001 test ETH above the $KEEP_ETH your rule keeps.${N}"
      say "  Nothing is worth moving, so the AI is not asked. Add test ETH, then ${C}./open.sh steps${N}"
      stop_walk
    fi
    AMOUNT_ETH=$(python3 -c 'import sys; print("%.4f" % (int(sys.argv[1]) / 1e18))' "$AMOUNT_WEI")
  fi
  cat > "$HERE/transfer.json" <<EOF
{"chain_id": $CHAIN_ID, "nonce": $NONCE, "max_priority_fee_per_gas": $TIP, "max_fee_per_gas": $MAXFEE, "gas": $GAS, "to": "$SAVINGS", "value": $AMOUNT_WEI, "data": "0x"}
EOF
  DIGEST=$("$HERE/bin/tx" digest "$HERE/transfer.json") || { say "      ${R}The transfer could not be built.${N}"; stop_walk; }
}

# The decision of the run just shown, from what EKKA recorded. Sets DECISION.
read_verdict() {
  RID=$(run_id)
  DECISION=no_verdict
  [ -n "$RID" ] || { explain_failure; stop_walk; }
  run run show "$RID" > "$OUTF.show" 2>&1 || true
  DECISION=$("$HERE/bin/show-verdict" "$OUTF.show" --word 2>/dev/null || echo no_verdict)
  WHY=$("$HERE/bin/show-verdict" "$OUTF.show" | sed -n 's/^explanation   //p')
  case "$DECISION" in
    transfer) say "      ${B}The AI decides: transfer.${N}" ;;
    hold)     say "      ${B}The AI decides: hold.${N}" ;;
    invalid_model_output) say "      ${B}The AI did not answer clearly with transfer or hold.${N}" ;;
  esac
  [ -n "$WHY" ] && printf 'Its reason: %s\n' "$WHY" | fold -s -w 88 | while IFS= read -r l; do say "      $l"; done
  if [ "$DECISION" = no_verdict ]; then
    say "      ${R}The AI gave no answer: the run stopped for a reason that is not the AI's.${N}"
    explain_failure; stop_walk
  fi
  vw set decision "$DECISION"; vw set explanation "$WHY"
}

# Sign the recorded transfer with the permission live, check the key is this wallet's, assemble.
# Sets RAW and TX_HASH. Refuses to go on if the Enclave's key belongs to another address.
signed_payment() {  # output.json of a sign step
  SIG=$(field "$1" signature); RID_=$(field "$1" recovery_id); PUB=$(field "$1" public_key); SIGNED=$(field "$1" digest)
  [ "$SIGNED" = "$DIGEST" ] || { say "      ${R}The Enclave signed something other than this transfer.${N} Nothing is sent."; stop_walk; }
  WHO=$("$HERE/bin/tx" address "$PUB" 2>/dev/null || echo unknown)
  WANT=$(printf '%s' "$ADDRESS" | tr 'A-F' 'a-f')
  if [ "$WHO" != "$WANT" ]; then
    say "      ${R}The key in your Enclave belongs to a different wallet${N} ($(short "$WHO")), not $(short "$ADDRESS")."
    say "      A transfer signed with it would come from that other wallet, so the kit sends nothing."
    say "      Store the private key of $(short "$ADDRESS") again:  ${C}$EK secret remove $KEY${N}   then   ${C}./open.sh${N}"
    stop_walk
  fi
  ok "Signed by the Enclave. The signature belongs to your wallet, $(short "$ADDRESS")."
  OUT=$("$HERE/bin/tx" assemble "$HERE/transfer.json" "$SIG" "$RID_") || { say "      ${R}The signed transfer could not be assembled.${N}"; stop_walk; }
  RAW=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["raw_tx"])')
  TX_HASH=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hash"])')
  save_state
}

# Send the signed transfer. The SAME signed transfer may be sent any number of times: it carries its
# transfer number, so the network takes it once and refuses every copy. That is why a busy service
# or a lost answer is retried with the same bytes, and never signed again.
send_payment() {
  TRY=0
  while :; do
    TRY=$((TRY + 1))
    busy "Sending your transfer to the network" "$EK plan run $SND_VER --input raw_tx=$RAW"
    if plan_completed; then
      ANS=$("$HERE/bin/wallet" sent "$(out_path)" 2>/dev/null || echo "error=unreadable")
      case "$ANS" in
        result=*) TX_OUTCOME=sent; save_state; ok "The network took the transfer."; return 0 ;;
        *"already known"*|*"nonce too low"*) TX_OUTCOME=sent; save_state; ok "The network already has this transfer."; return 0 ;;
        *) say "      ${R}The network refused the transfer:${N} ${ANS#error=}"
           case "$ANS" in *[Ii]nsufficient*) say "      Your wallet does not hold enough test ETH for it. Get more, free:  ${C}$FAUCET${N}" ;; esac
           TX_OUTCOME=refused; save_state; stop_walk ;;
      esac
    fi
    if grep -qE "answered 429|Too many requests" "$OUTF" && [ "$TRY" -lt 4 ]; then
      say "      ${Y}The Sepolia service is busy right now.${N} Its free tier takes only a few sends every few"
      say "      minutes. Nothing was sent. Sending again is safe: it is the same signed transfer."
      wait_enter "Wait a minute, then press Enter to send it again."
      continue
    fi
    say "      ${Y}No clear answer.${N} The kit looks the transfer up by its hash instead of guessing:"
    lookup_payment 3
    [ "$PAY_STATE" != pending ] && [ "$PAY_STATE" != unknown ] && { TX_OUTCOME=sent; save_state; return 0; }
    say "      ${R}Still not clear.${N} Nothing more is sent. Look it up yourself:  ${C}$EXPLORER/tx/$TX_HASH${N}"
    TX_OUTCOME=uncertain; save_state; stop_walk
  done
}

# Look the transfer up by its hash until the network names a final status. Sets PAY_STATE
# (ok | error | pending | unknown) and PAY_FEE (wei).
lookup_payment() {  # tries
  "$HERE/bin/write-plans" lookup "$HERE" "$AGENT" "$AINST" "$API_ROW" "$TX_HASH" >/dev/null
  LV=$(run plan create "$HERE/wallet.lookup.json" 2>&1 | grep -oE "[a-z0-9-]+\.wallet\.lookup@[0-9.]+" | head -1 || true)
  [ -n "$LV" ] || { PAY_STATE=unknown; return 0; }
  PAY_STATE=pending; PAY_FEE=0; N_=0
  spin_start "Waiting for the network to confirm it"
  while [ "$N_" -lt "$1" ]; do
    N_=$((N_ + 1)); quiet "$EK plan run $LV"
    if plan_completed; then
      set -- "$1" $("$HERE/bin/wallet" payment "$(out_path)" 2>/dev/null || echo pending)
      case "${2:-pending}" in ok|error) PAY_STATE=$2; PAY_FEE=${3:-0}; break ;; esac
    fi
    sleep "${LOOKUP_WAIT:-5}"
  done
  spin_stop
}

why() {
head_ "Questions people ask at this point, and how to check the answer yourself"
say "  ${B}What gets set up in my organization?${N} One catalog entry, ${B}$API_ROW${N}: read your wallet"
say "  and send a transfer that is already signed. One agent, ${B}$AGENT${N}, and its plans, as files here."
say "  Three standing permissions: read the network, send an already-signed transfer, ask the AI."
say "  ${B}None of them can sign.${N} Only you can allow that, in step 2."
cmd "$EK gate grant list --agent $AGENT"
say "  ${B}Where is my private key?${N} Encrypted in your Enclave's vault on this computer. The Enclave"
say "  signs with it and never hands it out: there is no command that reads it back."
cmd "$EK secret list"
say "  ${B}What exactly did the AI see?${N} The file ${B}prompt.txt${N} in this folder, and nothing else:"
say "  your rule, your balance, your savings wallet and the amount. EKKA's control plane is sent it"
say "  to decide yes or no, and the AI gate carries it to the model, a third party, not EKKA."
say "  ${B}Can a strange answer move money?${N} No. Only the exact words transfer or hold cross to EKKA,"
say "  and only transfer leads to the signing step. Anything else goes to the plan's default, which"
say "  fails. The amount and the address are the kit's, worked out before the AI is asked: the AI"
say "  never names either, so no answer of its can send more, or send it somewhere else."
cmd "cat wallet.decide.json"
say "  ${B}What does the sign permission NOT limit?${N} Where the transfer goes, or how much. It checks who"
say "  may sign and for how long. When the Enclave signs, EKKA sees only a 32-byte fingerprint of"
say "  what is signed, never your key. While the permission lasts, the agent may sign ANY transfer"
say "  with this key, to anyone, any amount. The kit sets the address and the amount; EKKA saw both"
say "  in the message to the AI, but the permission itself does not restrict them."
say "  That is why you choose how many minutes, and why the kit takes it back in step 3."
say "  ${B}Could it reach real money?${N} No. The kit builds transfers for the Sepolia test network only"
say "  (network id $CHAIN_ID). A Sepolia signature is refused on every other network."
say "  ${B}Is the record real?${N} Each governed step produces signed evidence binding the authorized scope"
say "  to hashes of its input and output. Check it on this computer:"
cmd "$EK receipts verify"
}

commands() {
head_ "Operator commands: keep administration with the human"
say "  These use your session. They are not a restricted AI execution interface."
cmd "$EK gate grant list --agent $AGENT"
cmd "$EK plan run $BAL_VER"
say ""; say "      ${C}$EK plan run $DEC_VER \\${N}"; say "      ${C}    --input user_message=@prompt.txt --input digest=\$(bin/tx digest transfer.json)${N}"
say ""; say "      ${C}$EK gate grant add --agent $AGENT --type secret --instance $SINST \\${N}"
say "      ${C}    --resource keys/$KEY --capability secret.vault.sign \\${N}"
say "      ${C}    --ttl 600 --no-fingerprint${N}"; say ""
cmd "$EK plan run $SIG_VER --input digest=\$(bin/tx digest transfer.json)"
cmd "$EK receipts verify"
say "  ${B}To let an AI run these plans and nothing else${N}: publish the plans and give the AI the session"
say "  of an organization ${B}member${N}. A member may dispatch plans and may NOT issue or revoke a grant."
cmd "$EK org members invite ai-operator@example.com --role member"
}

# ⛔ AN UNRESOLVED ATTEMPT IS NEVER REPLAYED. A sign permission may still exist, or a transfer was
# signed and its fate is not known: then every mode inspects, and nothing is signed again.
unresolved_attempt() {
  [ -n "${SIGN_INTENT:-}" ] && return 0
  [ "${TX_OUTCOME:-}" = uncertain ] && return 0
  return 1
}
recover() {
  head_ "Inspect the saved attempt; do not sign it again"
  [ -n "${TX_HASH:-}" ] && say "  The last signed transfer: ${C}$EXPLORER/tx/$TX_HASH${N}"
  say "  Sending that same transfer again is safe (it can be taken once), signing a new one is not done here."
  [ -n "${SIGN_GRANT_ID:-}" ] && { say "  A sign permission may still be live. Take it back:"; cmd "$EK gate grant revoke $SIGN_GRANT_ID"; }
  cmd "$EK gate grant list --agent $AGENT"
  say "  When no sign permission is left, run ${C}./open.sh steps${N} again. To start over:  ${C}rm .demo-state${N}"
}

# ================================================================ the four steps
# The AI is asked ONCE. Its recorded transfer is then governed three times: refused without
# permission, signed and sent with it, refused again after the permission is taken back.
steps() {
save_state
vw set model_where "the AI gate $LLM, carrying the message to $MODEL, a third party, not EKKA"
vw set exec_where "your Enclave: signing with keys/$KEY, sending through $API_ROW"
vw set wallet "$ADDRESS"; vw set savings "$SAVINGS"
vw authority network_read "granted"; vw authority send "granted (only an already-signed transfer)"; vw authority sign "not granted"
say ""
say "  Four steps. Each one shows what it runs, waits for you to press Enter, runs it, and says"
say "  what happened. ${B}q${N} stops at any point."

# ---- 1. The AI decides, and tries to move the extra
say ""; say "  ${Y}▶ Step 1 of 4. The AI checks your wallet, decides, and tries to move the extra.${N}"
say "      You have not given it permission to sign yet, so EKKA should stop the transfer."
wait_enter "Enter reads your balance."
read_plan "Reading your balance" "$BAL_VER"
funds_check "$P"
ok "Your everyday wallet holds ${B}$BAL_ETH test ETH${N}. Read from the network just now."
build_payment
python3 - "$HERE/inputs.json" <<EOF
import json; json.dump({"amount_eth": "$AMOUNT_ETH", "savings": "$SAVINGS", "savings_list": ["$SAVINGS"],
  "balance_eth": "$BAL_ETH", "fee_cap_eth": "$(eth_of "$FEE_CAP_WEI")", "keep_eth": "$KEEP_ETH"},
  open(__import__("sys").argv[1], "w"))
EOF
"$HERE/bin/prompt" "$HERE/inputs.json" "$HERE/prompt.txt" >/dev/null
[ "$SAVINGS" = "$ADDRESS" ] && TO_WHO="this same wallet, $(short "$SAVINGS")" || TO_WHO="your savings wallet, $(short "$SAVINGS")"
say ""
say "  ${B}What the AI is sent${N}"
say "    · Your rule: when your everyday wallet holds more than $KEEP_ETH test ETH, move the extra to savings."
if [ "$SAVINGS" = "$ADDRESS" ]; then SAV_LINE="this same wallet (you gave no second one)"; else SAV_LINE="$(short "$SAVINGS"), on your list"; fi
say "    · Your balance now: $BAL_ETH test ETH. Your savings wallet: $SAV_LINE."
say "    · The transfer the kit prepared: $AMOUNT_ETH test ETH to savings, leaving at least $KEEP_ETH."
say "    Nothing else: not your private key, not your other transfers."
say ""
say "  ${B}The AI decides only yes or no.${N} The kit worked out the amount and the address before asking,"
say "  so no answer from the AI can send more, or send it somewhere else."
say ""
say "  ${B}You control this message.${N} Change the rule in ${C}bin/prompt${N}. EKKA's AI gate carries it to"
say "  the AI, and EKKA keeps a copy with the run, so you can see later exactly what the AI was told."
say ""
printf "  ${Y}Press p to see the full message, or Enter to ask the AI.${N} "
read -r REPLY <&3 || REPLY=q
case "$REPLY" in
  q|Q) say ""; say "  Stopped. Inspect the saved attempt with: ./open.sh steps"; say ""; exit 0 ;;
  p|P) say ""; sed 's/^/        /' "$HERE/prompt.txt"; say ""; wait_enter "Enter asks the AI." ;;
esac
DEC_CMD="$EK plan run $DEC_VER --input user_message=@prompt.txt --input digest=$DIGEST"
runs "$DEC_CMD"
busy "Asking the AI" "$DEC_CMD"
read_verdict
case "$DECISION" in
  hold) say "      So nothing is signed: only a transfer leads to the signing step. Change the rule in"
        say "      ${C}bin/prompt${N}, then ${C}./open.sh steps${N}."
        vw event "1. The AI decides" "AI decision (hold)" "decide" "nothing to sign" "not sent"; stop_walk ;;
  invalid_model_output) say "      So nothing can be signed: only a clear transfer can lead to a signature."
        say "      Ask again with ${C}./open.sh steps${N}."
        vw event "1. The AI decides" "AI answer unclear" "decide" "no signature" "not sent"; stop_walk ;;
esac
# ⛔ THE ONE THING THIS KIT MUST NEVER SEE: a signature with no permission.
if plan_completed; then
  say "      ${R}THE ENCLAVE SIGNED WITHOUT YOUR PERMISSION.${N} That must never happen. Nothing was sent."
  say "      Report this run with the output above: it is a governance failure, not your setup."
  stop_walk
fi
refused_by_ekka || { explain_failure; stop_walk; }
say "      ${G}${B}EKKA stopped the transfer.${N} Your AI agent has no permission to sign, so the Enclave did not"
say "      sign and nothing was sent."
say "      ${B}See it yourself:${N} nothing new is on your wallet's page:"
say "      ${C}$EXPLORER/address/$ADDRESS${N}"
vw event "1. The AI decides, and is stopped" "AI decision (transfer)" "sign the transfer" "refused: no permission" "not sent"
vw render

# ---- 2. You give permission; the AI's transfer goes through
say ""; say "  ${Y}▶ Step 2 of 4. You give the AI permission to sign, for as long as you choose.${N}"
say "      The signing permission checks who may sign and for how long. It does not restrict the"
say "      transfer's destination or amount. So while it lasts, your AI agent may sign ANY transfer"
say "      with this key, to anyone, any amount, not only this one."
say "      That is why you choose how long it lasts. It ends by itself then."
MINUTES=${PERMIT_MINUTES:-}
while ! printf '%s' "$MINUTES" | grep -qE '^[1-9][0-9]{0,3}$' || [ "$MINUTES" -gt 1440 ]; do
  ask "For how many minutes may it sign? [10]"; MINUTES=${REPLY:-10}
done
PERMIT="$MINUTES minute"; [ "$MINUTES" = 1 ] || PERMIT="${PERMIT}s"
say ""
say "      You are telling EKKA: ${B}your AI agent may sign with your wallet key${N},"
say "      on this computer only, ${B}for $PERMIT${N}. Nothing else."
GRANT_SIGN="$EK gate grant add --agent $AGENT --type secret --instance $SINST --resource keys/$KEY --capability secret.vault.sign --ttl $((MINUTES * 60)) --no-fingerprint"
wait_enter "Enter gives the permission."
SIGN_INTENT=1; save_state
busy "Telling EKKA" "$GRANT_SIGN"
[ "$RC" = 0 ] || { show_failure; say "      ${R}The permission was not given.${N} The red lines above say why."; SIGN_INTENT=""; save_state; stop_walk; }
SIGN_GRANT_ID=$(grep -oE 'revoke +[0-9a-f-]{16,}' "$OUTF" | head -1 | awk '{print $2}')
save_state
vw authority sign "granted for $PERMIT"
ok "Permission given, for $PERMIT."
say "      Now the AI's transfer from step 1 goes to EKKA again, as the same transfer:"
say "      $AMOUNT_ETH test ETH to $TO_WHO."
say "      The AI is not asked again. Its decision stands; only your permission changed."
SIG_CMD="$EK plan run $SIG_VER --input digest=$DIGEST"
runs "$SIG_CMD"
wait_enter "Enter signs and sends the transfer."
busy "The Enclave is signing" "$SIG_CMD"
if ! plan_completed; then
  if refused_by_ekka; then
    say "      ${B}Refused: your $PERMIT had already run out.${N} The permission ended exactly when you set it"
    say "      to, so nothing was signed. Run ${C}./open.sh steps${N} again and give it a little longer."
    SIGN_INTENT=""; save_state
  else show_failure; explain_failure; fi
  stop_walk
fi
signed_payment "$(out_path)"
send_payment
lookup_payment "${LOOKUP_TRIES:-24}"
case "$PAY_STATE" in
  ok)   FEE_ETH=$(eth_of "$PAY_FEE")
        ok "The network confirmed it: $AMOUNT_ETH test ETH to $TO_WHO."
        say "      ${B}See it yourself:${N} it is the newest transfer on your wallet's page:"
        say "      ${C}$EXPLORER/address/$ADDRESS${N}"
        say "      Its hash begins $(printf '%s' "$TX_HASH" | cut -c1-12). The full link is on the evidence page."
        if [ "$SAVINGS" = "$ADDRESS" ]; then
          say "      Why your balance dropped a little: the network charged a fee of ${B}$FEE_ETH test ETH${N} to carry"
          say "      it. The $AMOUNT_ETH came back to this same wallet, because you gave no savings wallet."
        else
          say "      The network charged a fee of ${B}$FEE_ETH test ETH${N} to carry it. Your everyday wallet keeps at"
          say "      least $KEEP_ETH, as your rule says."
        fi
        say "      Test ETH has no value." ;;
  error) say "      ${R}The network took the transfer and it failed there.${N} Your wallet's page says why:"
         say "      ${C}$EXPLORER/address/$ADDRESS${N}" ;;
  *)    say "      ${Y}The network has not confirmed it yet.${N} It usually takes about 15 seconds. Watch it:"
        say "      ${C}$EXPLORER/address/$ADDRESS${N}" ;;
esac
vw set tx "$TX_HASH"; vw set tx_status "$PAY_STATE"
vw event "2. Permission given" "AI decision (transfer)" "sign, then send" "allowed ($PERMIT)" "$PAY_STATE"
vw render

# ---- 3. Take the permission back
say ""; say "  ${Y}▶ Step 3 of 4. Take the permission back.${N}"
say "      There is nothing to cancel: a confirmed transfer is final. So take the permission back as"
say "      soon as it has done its one job. You do not have to wait for your $PERMIT to run out."
[ -n "${SIGN_GRANT_ID:-}" ] || { cmd "$EK gate grant list --agent $AGENT"; stop "The permission's id could not be read, so it cannot be taken back for you." "Take the kit's secret.vault.sign grant back by hand, then ./open.sh steps"; }
runs "$EK gate grant revoke $SIGN_GRANT_ID"
wait_enter "Enter takes the permission back."
busy "Telling EKKA" "$EK gate grant revoke $SIGN_GRANT_ID"
[ "$RC" = 0 ] || { show_failure; say "      ${R}The permission could not be taken back.${N} Step 4 would prove nothing, so the kit stops here."; stop_walk; }
ok "Permission taken back."
SIGN_GRANT_ID=""; SIGN_INTENT=""; save_state
vw authority sign "revoked"
vw event "3. Take it back" "you" "take the permission back" "taken back" "final"
vw render

# ---- 4. The same transfer again: stopped
say ""; say "  ${Y}▶ Step 4 of 4. The AI's transfer once more, after you took the permission back.${N}"
say "      The same transfer, as a brand-new one (the next transfer number). EKKA should stop it."
build_payment $((NONCE + 1))
AGAIN_CMD="$EK plan run $SIG_VER --input digest=$DIGEST"
runs "$AGAIN_CMD"
wait_enter "Enter sends the transfer."
busy "The Enclave is asked to sign" "$AGAIN_CMD"
if refused_by_ekka; then
  ok "EKKA stopped it. The permission is yours to give, and yours to take back."
  # ⛔ SAY ONLY WHAT THE PAGE WILL SHOW (ekka-ai/ekka-kits#45). A wallet that has sent or received
  # before lists every one of those transfers, so "only the one" was false for anyone but a
  # brand-new wallet. What the kit can prove: the newest is still step 2's.
  say "      ${B}See it yourself:${N} the newest transfer on your wallet's page is still the one from step 2"
  say "      (its hash begins $(printf '%s' "$TX_HASH" | cut -c1-12)). Nothing new was sent:"
  say "      ${C}$EXPLORER/address/$ADDRESS${N}"
elif plan_completed; then
  say "      ${R}THE ENCLAVE SIGNED AFTER YOU TOOK THE PERMISSION BACK.${N} That must never happen."
  say "      Nothing was sent. Report this run with the output above."
  stop_walk
else
  explain_failure; stop_walk
fi
vw event "4. Once more, no permission" "AI decision (transfer), new transfer" "sign the transfer" "refused: permission taken back" "not sent"

# ---- the record
say ""; say "  ${Y}▶ The record.${N} While you watched, EKKA wrote down every step on this computer: what the AI"
say "      was asked, what it decided, each permission you gave and took back, each signature allowed"
say "      or stopped. Each entry is locked to the one before it, so no one can change one unseen."
runs "$EK receipts verify"
wait_enter "Enter checks the record. (It works even with wifi off.)"
busy "Checking the record" "$EK receipts verify --json"
if [ "$RC" = 0 ] && grep -q '"ok": *true' "$OUTF"; then
  VERIFY_RC=0
  ok "The record checks out. Nothing in it was changed."
  say "      Checked here, on your computer, without asking EKKA."
  say "      Proof that needs us to check it is not proof."
else
  VERIFY_RC=1
  say "      ${R}The record did not check out.${N} To see why:  ${C}$EK receipts verify${N}"
fi
vw render
head_ "What just happened"
case "$PAY_STATE" in ok) GONE="the network confirmed it" ;; error) GONE="the network took it and it failed" ;; *) GONE="the network took it" ;; esac
say "  1. The AI decided to ${B}transfer${N} the extra. It had no permission, so ${B}EKKA stopped the signature.${N}"
say "  2. You allowed it for $PERMIT. The same transfer was signed, and $GONE."
say "  3. You took the permission back."
say "  4. The same transfer once more: ${B}EKKA stopped it.${N}"
say ""
if [ "$VERIFY_RC" = 0 ]; then
say "  ${B}Trust${N}      Every step was written down and signed on this computer, and the record checks out."
else
say "  ${B}Trust${N}      ${R}The record did not check out,${N} so this walk is not proven. See above."
fi
say "  ${B}Security${N}   The AI's transfer was signed only while you allowed it."
say "             Before and after, EKKA stopped it."
say "  ${B}Privacy${N}    Your private key stayed in the Enclave on this computer, which signed with it."
say "             EKKA and the AI could only ask it to sign, and only while you allowed that."
say "             ${B}YOUR PRIVATE KEY NEVER LEFT THIS COMPUTER.${N} To decide yes or no, EKKA's control plane"
say "             was sent the message to the AI, which names the amount and the savings wallet. When your"
say "             Enclave signed, EKKA saw only a fingerprint of what was signed, never your key. Then the"
say "             signed transfer, which is public on the network once it is sent."
say "             The AI gate carried the message to the model, a third party, not EKKA."
say "             It saw only your rule, your balance, your savings wallet and the amount. Never your key."
say "             ${B}Want your own model instead?${N} Add its API to your catalog the same way this kit added"
say "             the Sepolia network. Then the message goes to your model, not a third party's."
say ""
say "  ${B}Good to know:${N} while a sign permission lasts, the agent may sign ANY transfer with this key."
say "  The signing permission checks who may sign and for how long. It does not restrict the transfer's"
say "  destination or amount: the kit sets both, never the AI. Revoking permission prevents new"
say "  signatures. It cannot invalidate a signature already created or undo a confirmed transfer."
say ""
say "  ${B}Next${N}"
say "    See everything on one page     ${C}open .view/view.html${N}"
say "    Change the AI's rule           edit ${C}bin/prompt${N}, then run ${C}./open.sh steps${N} again"
say "    How it works                   ${C}./open.sh why${N}"
say "    Every command it ran           ${C}./open.sh commands${N}"
say "    The code                       ${C}$KIT_DOC${N}"
say ""
[ "$VERIFY_RC" = 0 ] || return 1
}

case "$MODE" in steps|setup) take_lock; trace "walk starts: $MODE" ;; esac
if [ -f "$STATE" ]; then
  . "$STATE"
  # ⛔ A FOLDER SET UP BY KIT 2 (an invoice, the words pay or hold) IS SET UP AGAIN. Its saved plans
  # would still say pay, which this kit's steps never accept. An open attempt is inspected first.
  SAVINGS=${SAVINGS:-${PAYEE:-}}
  if [ "${KIT_MAJOR:-2}" != 3 ] && ! unresolved_attempt; then
    case "$MODE" in steps|setup) say ""; say "  This folder was set up by an earlier version of the kit, so it is set up again."
                                 rm -f "$STATE"; MODE=setup ;; esac
  fi
fi
if [ -f "$STATE" ]; then
  case "$MODE" in
    why) why ;;
    commands) commands ;;
    view) vw render; say "  $VIEWD/view.html" ;;
    steps|setup)
      if unresolved_attempt; then recover; exit 0; fi
      if [ "$MODE" = steps ]; then DECISION=''; TX_HASH=''; TX_OUTCOME=''; steps; exit 0; fi
      rm -f "$STATE" ;;
    *) stop "Unknown mode: $MODE" "Use steps, why, commands or view." ;;
  esac
  [ -f "$STATE" ] && exit 0
fi
if [ "$MODE" != setup ]; then stop "No saved Kit setup exists." "Run ./open.sh first."; fi

# ================================================================ setup
command -v "$EKKA" >/dev/null 2>&1 || stop "EKKA is not installed." "Install it with the line in your email, then: ekka login --email you@example.com"
command -v python3 >/dev/null 2>&1 || stop "This machine is missing python3." "The kit builds the transfer with it. On Debian or Ubuntu: apt-get install -y python3"
# ⛔ 0.1.88: this kit catalogues its row in the person's OWN organization (`apis/<org>/eth-sepolia`),
# which an Enclave before 0.1.88 refuses with API_NAME_INVALID. The sign op has been there since 0.1.87.
FLOOR=0.1.88; KIT_VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo dev)
HAVE=$(run --version 2>/dev/null | awk 'NR==1{print $2}')
[ "$(printf '%s\n%s\n' "$FLOOR" "$HAVE" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$FLOOR" ] || stop "This kit needs EKKA $FLOOR or later; you have ${HAVE:-an unknown version}." "Run the install line again, then open a new terminal window."
"$HERE/bin/tx" selftest >/dev/null 2>&1 || stop "This kit's transfer builder failed its own tests." "Nothing was changed. Report it with: bin/tx selftest"
run secret list >/dev/null 2>&1 || stop "Your Enclave is not running." "In your other window: ekka enclave start <id>"
GATES=$(run gate list 2>/dev/null || true)
# ⛔ THIS MACHINE'S Enclave, never the first one listed (measured 2026-09-24 on the Financial Kit).
[ -n "$ENCLAVE" ] || ENCLAVE=$(run whoami 2>/dev/null | sed -n 's/^ *enclave id  *\([0-9a-f]\{8\}\).*/\1/p' | head -1)
[ -n "$ENCLAVE" ] || stop "This machine is not an Enclave of your organization." "Start one here first: ekka enclave create --name \"this machine\", then ekka enclave start <id>"
AINST="enclave${ENCLAVE}Api"; SINST="enclave${ENCLAVE}Secret"
printf '%s\n' "$GATES" | grep -q "api/$AINST" || stop "This machine's Enclave ($ENCLAVE) offers no api gate yet." "Is it running? In your other window: ekka enclave start <id>"
printf '%s\n' "$GATES" | grep -q "secret/$SINST" || stop "This machine's Enclave ($ENCLAVE) offers no signing gate yet." "Is it running? In your other window: ekka enclave start <id>"
LLM=${LLM:-$(printf '%s\n' "$GATES" | awk -v m="$MODEL" '/^  [a-z]+\//{n=""; u=0} /^  llm\//{n=$1; next} n && /url/{u=1} n && u && index($0, m){sub("llm/","",n); print n; exit}')}
GATEWAY=${GATEWAY:-https://gateway.ekka.ai}
NEED_LLM_REG=""; [ -n "$LLM" ] || NEED_LLM_REG=1
ORG=$(run whoami 2>/dev/null | sed -n 's/.*Signed in as [^,]*, *\([^ ]*\) (.*/\1/p; s/^ *organization  *\([^ ]*\) (.*/\1/p' | head -1)
[ -n "$ORG" ] || stop "Could not read your organization name." "Check: ekka whoami"
API_ROW="$ORG/$ROW"
HAVE_KEY=0; run secret list 2>/dev/null | grep -q "$KEY" && HAVE_KEY=1

[ -t 1 ] && clear 2>/dev/null || true
head_ "Let an AI move your crypto. It never sees your private key, and neither does EKKA."
say "  Your everyday wallet holds more than it needs. An AI checks it against your rule and decides"
say "  whether to move the extra to your savings wallet."
say "  You give it permission to sign, for as long as you choose, and its transfer goes through."
say "  Take the permission back whenever you want, and it stops."
say ""
say "  ${B}Trust${N}      Every action is recorded and signed, so you can prove what happened."
say "  ${B}Security${N}   The AI can do only what you allowed, and only for as long as you allowed it."
say "  ${B}Privacy${N}    Your wallet's private key stays in the Enclave on this computer, which signs with it."
say "             ${B}YOUR PRIVATE KEY NEVER LEAVES THIS COMPUTER.${N} Not to EKKA, not to the AI."
say "             They can only ask your Enclave to sign with it, and only while you allow that."
say "             To decide yes or no, EKKA's control plane is sent the message to the AI, which names"
say "             the amount and the savings wallet. When your Enclave signs, EKKA sees only a"
say "             fingerprint of what is signed. Then the signed transfer, public once it is sent."
say "             The AI gate carries the message to the model, a third party, not EKKA."
say ""
say "  ${B}Safe to try${N}"
say "    · The Sepolia test network only. Test ETH is free and has no value. No real money."
say "    · Your key stays on this computer, encrypted. Use a wallet you made for this."
say "    · Nothing is signed unless you have given permission."
say "    · The transfer rule is an example, not advice."
say ""
say "  ${B}You need${N} a test wallet with a little test ETH, and a second account for savings. How to make"
say "  both in MetaMask and fill the first, two minutes: ${C}$WALLET_HELP${N}"
say ""
say "  ${D}What gets set up, in detail:  ./open.sh why        kit $KIT_VERSION, EKKA $HAVE${N}"
say ""
ask "Ready? [y/N]"
case "$REPLY" in y|Y|yes|YES) ;; *) say ""; say "  Nothing was changed."; say ""; exit 0 ;; esac

head_ "Setting up"

# ---------------- ⛔ THE ONLY BLOCK THAT TOUCHES YOUR KEY ----------------
if [ "$HAVE_KEY" = 1 ]; then
  ok "Your key is already stored on this computer, as ${B}$KEY${N}. The AI cannot see it, and neither can EKKA."
  say "    They can only ask your Enclave to sign with it, and only while you allow that."
else
  say "  In MetaMask: the account's ${B}three dots${N}, ${B}Account details${N}, ${B}Show private key${N}."
  say "  Paste it below. It stays hidden while you paste. ${Y}Use a wallet you made for this.${N}"
  TRIES=0
  while :; do
    printf "  ${Y}Private key of your test wallet (hidden):${N} "
    stty -echo 2>/dev/null || true; read -r K <&3 || K=""; stty echo 2>/dev/null || true; say ""
    K=$(printf '%s' "$K" | tr -d ' \r\t'); case "$K" in 0x*|0X*) K=${K#??} ;; esac
    printf '%s' "$K" | grep -qE '^[0-9a-fA-F]{64}$' && break
    if printf '%s' "$K" | grep -qE '^[0-9a-fA-F]{40}$'; then
      say "  ${R}That is the wallet's address, the public half.${N} The private key is 64 characters."
    else
      say "  ${R}That does not look like a private key${N} (64 characters, 0-9 and a-f). Nothing was stored."
    fi
    TRIES=$((TRIES+1)); [ "$TRIES" -ge 3 ] && { K=""; stop "Three tries. Nothing was stored." "Find the key in MetaMask (Account details, Show private key), then ./open.sh again."; }
  done
  printf '%s' "$K" | run secret put "$KEY" --stdin >/dev/null 2>&1 || { K=""; stop "The Enclave did not store the key." "Is it running? In your other window: ekka enclave start <id>"; }
  K=""
  # ⛔ SEE versus USE (owner, 2026-09-26: "Even they cant see it. they can only use it. its
  # important thing to mention."). Both lines, every time the key is mentioned at setup.
  ok "Your key is stored on this computer, encrypted. The AI cannot see it, and neither can EKKA."
  say "    They can only ask your Enclave to sign with it, and only while you allow that."
fi
# ---------------- end of the block that touches your key ----------------

say "  Now this wallet's ${B}address${N}, the public half: 0x and 40 characters. It is public on purpose."
TRIES=0
while :; do
  ask "Your wallet address:"
  ADDRESS=$(printf '%s' "$REPLY" | tr -d ' \r\t')
  if printf '%s' "$ADDRESS" | grep -qE '^(0x)?[0-9a-fA-F]{64}$'; then
    ADDRESS=""; stop "That is a PRIVATE key, and it was just shown on this screen. Treat that wallet as burned." "Make a new account in MetaMask, then run ./open.sh again and paste its ADDRESS here."
  fi
  printf '%s' "$ADDRESS" | grep -qE '^0x[0-9a-fA-F]{40}$' && break
  say "  ${R}That does not look like an address${N} (0x and 40 characters). Copy it from MetaMask."
  TRIES=$((TRIES+1)); [ "$TRIES" -ge 3 ] && stop "Three tries. Nothing was changed." "Copy the address from MetaMask, then ./open.sh again."
done
ADDRESS=$(printf '%s' "$ADDRESS" | tr 'A-F' 'a-f')
say "  Now your ${B}savings${N} wallet: where the extra goes. In MetaMask, ${B}Add account${N} makes one; copy its"
say "  address. No second account? Press Enter: the extra goes back to this same wallet, and only the"
say "  network fee is spent."
TRIES=0
while :; do
  ask "Your savings wallet address (Enter: this same wallet):"
  SAVINGS=$(printf '%s' "${REPLY:-$ADDRESS}" | tr -d ' \r\t')
  if printf '%s' "$SAVINGS" | grep -qE '^(0x)?[0-9a-fA-F]{64}$'; then
    SAVINGS=""; stop "That is a PRIVATE key, and it was just shown on this screen. Treat that wallet as burned." "Make a new account in MetaMask, then run ./open.sh again and paste its ADDRESS here."
  fi
  SAVINGS=$(printf '%s' "$SAVINGS" | tr 'A-F' 'a-f')
  printf '%s' "$SAVINGS" | grep -qE '^0x[0-9a-f]{40}$' && break
  say "  ${R}That does not look like an address${N} (0x and 40 characters)."
  TRIES=$((TRIES+1)); [ "$TRIES" -ge 3 ] && stop "Three tries. Nothing was changed." "Copy the savings address from MetaMask, then ./open.sh again."
done

# ---- the hosted model gate, when the org has not registered it
if [ -n "$NEED_LLM_REG" ]; then
  item_start "Connected EKKA's AI to your organization"
  quiet "$EK gate register $GATEWAY"
  [ "$RC" = 0 ] || { spin_stop; show_failure; stop "EKKA's AI could not be connected to your organization." "Check: ekka gate list"; }
  LLM=$(run gate list 2>/dev/null | awk -v m="$MODEL" '/^  [a-z]+\//{n=""; u=0} /^  llm\//{n=$1; next} n && /url/{u=1} n && u && index($0, m){sub("llm/","",n); print n; exit}')
  [ -n "$LLM" ] || { spin_stop; stop "The gateway registered, but no gate serving $MODEL appeared." "Check: ekka gate list"; }
  item_done
fi

# ---- the catalog row, and its connection on this machine (public: no key of yours)
item_start "Added the Sepolia test network to your catalog"
LIST=$(run api list 2>/dev/null || true)
if ! printf '%s\n' "$LIST" | grep -qE "^\s*$API_ROW(\s|@)"; then
  sed "s#\"ekka/$ROW\"#\"$API_ROW\"#" "$HERE/catalog/ekka-$ROW.json" > "$OUTF"
  ADD_OUT=$(run api create "$OUTF" 2>&1) || { spin_stop; stop "Could not add $API_ROW to your catalog." "$(printf '%s\n' "$ADD_OUT" | grep -vE '^\s*$' | head -3)"; }
fi
if ! run api list 2>/dev/null | grep -E "^\s*$API_ROW(\s|@)" | grep -q "connected here"; then
  # The service is public and needs no key. EKKA still stores a placeholder, because a connection
  # with no credential at all is not something it allows yet.
  printf 'public' | run api connect "$API_ROW" --stdin >/dev/null 2>&1 || { spin_stop; stop "Could not connect $API_ROW." "Run it by hand to see why: ekka api connect $API_ROW"; }
fi
item_done

# ---- the agent, its plans as files, and its three standing grants
item_start "Created your AI agent"
AG_OUT=$(run agent create "$AGENT" --name "Wallet Agent" 2>&1) || true
if printf '%s\n' "$AG_OUT" | grep -qiE "already|exists"; then
  # ⛔ AN OLD SIGN GRANT WOULD SPOIL STEP 1, and nothing else about an existing agent does.
  EXISTING=$(run gate grant list --agent "$AGENT" 2>&1) || { spin_stop; stop "Could not check this agent's existing grants." "Run ekka gate grant list --agent $AGENT and resolve the error first."; }
  if printf '%s\n' "$EXISTING" | grep -F "keys/$KEY" | grep -q "vault.sign"; then
    spin_stop; stop "The agent $AGENT can already sign with $KEY, so step 1's refusal would prove nothing." \
         "Revoke it (ekka gate grant list --agent $AGENT, then revoke its id), or run with AGENT=<a-new-name> ./open.sh."
  fi
elif printf '%s\n' "$AG_OUT" | grep -q "✓"; then
  :
elif printf '%s\n' "$AG_OUT" | grep -qiE "waiting to be approved|org.agents: 0"; then
  spin_stop; stop "Your organization is not let in yet, so it cannot have an agent." "Reply to the email you were sent and say your organization name ($ORG). Then run ./open.sh again."
else
  spin_stop; stop "Could not create the agent $AGENT." "$(printf '%s\n' "$AG_OUT" | grep -vE '^\s*$' | head -3)"
fi
item_done

ver_from() { printf '%s\n' "$1" | grep -oE "[a-z0-9-]+\.$2@[0-9.]+" | head -1; }
# Saves one plan and sets V to its version. NOT called inside $( ... ): a failure there was
# captured with its message and, under `set -e`, ended the kit with NOTHING on screen.
create_plan() {  # file code -> sets V
  OUT=$(run plan create "$1" 2>&1 || true)
  if ! printf '%s\n' "$OUT" | grep -qE "✓|already"; then
    spin_stop
    printf '%s\n' "$OUT" > "$OUTF"; show_failure
    if grep -qiE "unreachable|timed out|connect|dns|resolve|52[0-9]|50[234]|GOVERN_HTTP_ERROR" "$OUTF"; then
      say "      ${R}EKKA is not answering right now,${N} so the plan '$2' could not be saved. Nothing else"
      say "      was changed. Try again in a few minutes:  ${C}./open.sh${N}"
    else
      say "      ${R}EKKA refused the plan '$2'.${N} The red lines above say why."
    fi
    stop_walk
  fi
  V=$(ver_from "$OUT" "$2"); V=${V:-ekka.$2@1.0.0}
}
"$HERE/bin/write-plans" "$HERE" "$AGENT" "$AINST" "$LLM" "$API_ROW" "$MODEL" "$KEY" "$ADDRESS" >/dev/null
item_start "Saved its plan: read your balance";                    create_plan "$HERE/wallet.balance.json" wallet.balance; BAL_VER=$V; item_done
item_start "Saved its plan: read the transfers you have sent";     create_plan "$HERE/wallet.sent.json" wallet.sent; SNT_VER=$V; item_done
item_start "Saved its plan: read the network's fees";              create_plan "$HERE/wallet.fees.json" wallet.fees; FEE_VER=$V; item_done
item_start "Saved its plan: decide whether to move the extra, then sign"; create_plan "$HERE/wallet.decide.json" wallet.decide; DEC_VER=$V; item_done
item_start "Saved its plan: sign its decision again";              create_plan "$HERE/wallet.sign.json" wallet.sign; SIG_VER=$V; item_done
item_start "Saved its plan: send a transfer that is already signed"; create_plan "$HERE/wallet.send.json" wallet.send; SND_VER=$V; item_done

grant() {  # label type instance resource capability words
  item_start "$1"; shift
  quiet "$EK gate grant add --agent $AGENT --type $1 --instance $2 --resource $3 --capability $4${5:+ $5}"
  [ "$RC" = 0 ] || grep -qiE "already|exists" "$OUTF" || { spin_stop; show_failure; say "      ${R}The grant was not created.${N} The red lines above name the reason."; stop_walk; }
  item_done
}
grant "Allowed it to read the Sepolia network"              api "$AINST" "apis/$API_ROW" api.read --no-fingerprint
grant "Allowed it to send a transfer that is already signed" api "$AINST" "apis/$API_ROW" api.write --no-fingerprint
grant "Allowed it to ask the AI"                            llm "$LLM" "$MODEL" llm.infer ""
ok "Your AI agent is ready. It may NOT sign. Only you can allow that, in step 2."
save_state

read_plan "Checking your wallet" "$BAL_VER"
funds_check "$P"
ok "Your everyday wallet holds ${B}$BAL_ETH test ETH${N}: enough for the walk."
steps
