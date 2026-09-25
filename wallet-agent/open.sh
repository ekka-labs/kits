#!/bin/sh
# Wallet Kit: your AI decides whether to pay, your Enclave signs, you control what it is allowed
# to do. A hosted model applies YOUR rule to one invoice and your live balance; its `pay` is the
# only thing that can lead to a signature, and only while you have given permission to sign.
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
AMOUNT_WEI=1000000000000000               # 0.001 test ETH
AMOUNT_ETH=0.001
FLOOR_ETH=0.01                            # the rule keeps at least this much
FLOOR_WEI=10000000000000000
GAS=21000                                 # a plain payment always uses exactly this much
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
# ONE WALK PER FOLDER. Two walks share one saved state and one payment number, and each would act
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
  # payment with this key, so a walk that stops after step 2 gave it takes it back first.
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
ADDRESS='$ADDRESS'
PAYEE='$PAYEE'
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

# ⛔ A LOW BALANCE NEVER REACHES THE AI. If the wallet cannot pay the invoice, the fee and still keep
# the rule's floor, the AI would rightly say hold and the walk would show nothing. So the kit stops
# BEFORE the AI is asked, at setup and again at step 1, and says how to get free test ETH.
funds_check() {  # output.json of a balance read. Sets BAL_WEI and BAL_ETH, or stops.
  BAL_WEI=$("$HERE/bin/wallet" wei "$1"); BAL_ETH=$("$HERE/bin/wallet" balance "$1")
  NEED_WEI=$((AMOUNT_WEI + FLOOR_WEI + GAS * 20000000000))
  [ "$BAL_WEI" -ge "$NEED_WEI" ] && return 0
  say "  ${Y}Your wallet holds $BAL_ETH test ETH.${N} The walk needs at least $(eth_of "$NEED_WEI"): the $AMOUNT_ETH"
  say "  payment, the network fee, and the $FLOOR_ETH the rule keeps. Test ETH is free. One minute:"
  say "    1. Open ${C}$FAUCET${N}"
  say "    2. Sign in with a Google account, paste $(short "$ADDRESS"), click ${B}Receive 0.05 Sepolia ETH${N}."
  say "    3. Wait about a minute, then run ${C}./open.sh steps${N}"
  say "    ${D}If Google says no (daily limit):${N} ${C}$FAUCET2${N}"
  say "  Step by step, with MetaMask:  ${C}$WALLET_HELP${N}"
  say "  Nothing was asked of the AI, and nothing was signed."
  stop_walk
}

# Build the payment: the next payment number, today's fee cap, 0.001 test ETH to the payee.
# Writes pay.json and sets DIGEST, the 64 characters the Enclave will sign. Sets NONCE.
build_payment() {  # [nonce]
  if [ -n "${1:-}" ]; then NONCE=$1
  else read_plan "Reading your wallet's payments" "$SNT_VER"; NONCE=$("$HERE/bin/wallet" nonce "$P"); fi
  read_plan "Reading the network's fees" "$FEE_VER"
  set -- $("$HERE/bin/wallet" fees "$P"); MAXFEE=${1:-}; TIP=${2:-}
  printf '%s' "$MAXFEE" | grep -qE '^[0-9]+$' || { say "      ${R}The network did not say what fees are today.${N} Try again in a minute."; stop_walk; }
  cat > "$HERE/pay.json" <<EOF
{"chain_id": $CHAIN_ID, "nonce": $NONCE, "max_priority_fee_per_gas": $TIP, "max_fee_per_gas": $MAXFEE, "gas": $GAS, "to": "$PAYEE", "value": $AMOUNT_WEI, "data": "0x"}
EOF
  DIGEST=$("$HERE/bin/tx" digest "$HERE/pay.json") || { say "      ${R}The payment could not be built.${N}"; stop_walk; }
  FEE_CAP_WEI=$((GAS * MAXFEE))
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
    pay)  say "      ${B}The AI decides: pay.${N}" ;;
    hold) say "      ${B}The AI decides: hold.${N}" ;;
    invalid_model_output) say "      ${B}The AI did not answer clearly with pay or hold.${N}" ;;
  esac
  [ -n "$WHY" ] && printf 'Its reason: %s\n' "$WHY" | fold -s -w 88 | while IFS= read -r l; do say "      $l"; done
  if [ "$DECISION" = no_verdict ]; then
    say "      ${R}The AI gave no answer: the run stopped for a reason that is not the AI's.${N}"
    explain_failure; stop_walk
  fi
  vw set decision "$DECISION"; vw set explanation "$WHY"
}

# Sign the recorded payment with the permission live, check the key is this wallet's, assemble.
# Sets RAW and TX_HASH. Refuses to go on if the Enclave's key belongs to another address.
signed_payment() {  # output.json of a sign step
  SIG=$(field "$1" signature); RID_=$(field "$1" recovery_id); PUB=$(field "$1" public_key); SIGNED=$(field "$1" digest)
  [ "$SIGNED" = "$DIGEST" ] || { say "      ${R}The Enclave signed something other than this payment.${N} Nothing is sent."; stop_walk; }
  WHO=$("$HERE/bin/tx" address "$PUB" 2>/dev/null || echo unknown)
  WANT=$(printf '%s' "$ADDRESS" | tr 'A-F' 'a-f')
  if [ "$WHO" != "$WANT" ]; then
    say "      ${R}The key in your Enclave belongs to a different wallet${N} ($(short "$WHO")), not $(short "$ADDRESS")."
    say "      A payment signed with it would come from that other wallet, so the kit sends nothing."
    say "      Store the private key of $(short "$ADDRESS") again:  ${C}$EK secret remove $KEY${N}   then   ${C}./open.sh${N}"
    stop_walk
  fi
  ok "Signed by the Enclave. The signature belongs to your wallet, $(short "$ADDRESS")."
  OUT=$("$HERE/bin/tx" assemble "$HERE/pay.json" "$SIG" "$RID_") || { say "      ${R}The signed payment could not be assembled.${N}"; stop_walk; }
  RAW=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["raw_tx"])')
  TX_HASH=$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hash"])')
  save_state
}

# Send the signed payment. The SAME signed payment may be sent any number of times: it carries its
# payment number, so the network takes it once and refuses every copy. That is why a busy service
# or a lost answer is retried with the same bytes, and never signed again.
send_payment() {
  TRY=0
  while :; do
    TRY=$((TRY + 1))
    busy "Sending your payment to the network" "$EK plan run $SND_VER --input raw_tx=$RAW"
    if plan_completed; then
      ANS=$("$HERE/bin/wallet" sent "$(out_path)" 2>/dev/null || echo "error=unreadable")
      case "$ANS" in
        result=*) TX_OUTCOME=sent; save_state; ok "The network took the payment."; return 0 ;;
        *"already known"*|*"nonce too low"*) TX_OUTCOME=sent; save_state; ok "The network already has this payment."; return 0 ;;
        *) say "      ${R}The network refused the payment:${N} ${ANS#error=}"
           case "$ANS" in *[Ii]nsufficient*) say "      Your wallet does not hold enough test ETH for it. Get more, free:  ${C}$FAUCET${N}" ;; esac
           TX_OUTCOME=refused; save_state; stop_walk ;;
      esac
    fi
    if grep -qE "answered 429|Too many requests" "$OUTF" && [ "$TRY" -lt 4 ]; then
      say "      ${Y}The Sepolia service is busy right now.${N} Its free tier takes only a few sends every few"
      say "      minutes. Nothing was sent. Sending again is safe: it is the same signed payment."
      wait_enter "Wait a minute, then press Enter to send it again."
      continue
    fi
    say "      ${Y}No clear answer.${N} The kit looks the payment up by its hash instead of guessing:"
    lookup_payment 3
    [ "$PAY_STATE" != pending ] && [ "$PAY_STATE" != unknown ] && { TX_OUTCOME=sent; save_state; return 0; }
    say "      ${R}Still not clear.${N} Nothing more is sent. Look it up yourself:  ${C}$EXPLORER/tx/$TX_HASH${N}"
    TX_OUTCOME=uncertain; save_state; stop_walk
  done
}

# Look the payment up by its hash until the network names a final status. Sets PAY_STATE
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
say "  and send a payment that is already signed. One agent, ${B}$AGENT${N}, and its plans, as files here."
say "  Three standing permissions: read the network, send an already-signed payment, ask the AI."
say "  ${B}None of them can sign.${N} Only you can allow that, in step 2."
cmd "$EK gate grant list --agent $AGENT"
say "  ${B}Where is my private key?${N} Encrypted in your Enclave's vault on this computer. The Enclave"
say "  signs with it and never hands it out: there is no command that reads it back."
cmd "$EK secret list"
say "  ${B}What exactly did the AI see?${N} The file ${B}prompt.txt${N} in this folder, and nothing else:"
say "  the rule, the invoice, your approved list and your balance. EKKA's control plane is sent it"
say "  to decide yes or no, and the AI gate carries it to the model, a third party, not EKKA."
say "  ${B}Can a strange answer pay?${N} No. Only the exact words pay or hold cross to EKKA, and only"
say "  pay leads to the signing step. Anything else goes to the plan's default, which fails."
cmd "cat wallet.decide.json"
say "  ${B}What does the sign permission NOT limit?${N} EKKA sees a 32-byte fingerprint, not the payee or"
say "  the amount. While the permission lasts, the agent may sign ANY payment with this key."
say "  That is why you choose how many minutes, and why the kit takes it back in step 3."
say "  ${B}Could it reach real money?${N} No. The kit builds payments for the Sepolia test network only"
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
say ""; say "      ${C}$EK plan run $DEC_VER \\${N}"; say "      ${C}    --input user_message=@prompt.txt --input digest=\$(bin/tx digest pay.json)${N}"
say ""; say "      ${C}$EK gate grant add --agent $AGENT --type secret --instance $SINST \\${N}"
say "      ${C}    --resource keys/$KEY --capability secret.vault.sign \\${N}"
say "      ${C}    --ttl 600 --no-fingerprint${N}"; say ""
cmd "$EK plan run $SIG_VER --input digest=\$(bin/tx digest pay.json)"
cmd "$EK receipts verify"
say "  ${B}To let an AI run these plans and nothing else${N}: publish the plans and give the AI the session"
say "  of an organization ${B}member${N}. A member may dispatch plans and may NOT issue or revoke a grant."
cmd "$EK org members invite ai-operator@example.com --role member"
}

# ⛔ AN UNRESOLVED ATTEMPT IS NEVER REPLAYED. A sign permission may still exist, or a payment was
# signed and its fate is not known: then every mode inspects, and nothing is signed again.
unresolved_attempt() {
  [ -n "${SIGN_INTENT:-}" ] && return 0
  [ "${TX_OUTCOME:-}" = uncertain ] && return 0
  return 1
}
recover() {
  head_ "Inspect the saved attempt; do not sign it again"
  [ -n "${TX_HASH:-}" ] && say "  The last signed payment: ${C}$EXPLORER/tx/$TX_HASH${N}"
  say "  Sending that same payment again is safe (it can be taken once), signing a new one is not done here."
  [ -n "${SIGN_GRANT_ID:-}" ] && { say "  A sign permission may still be live. Take it back:"; cmd "$EK gate grant revoke $SIGN_GRANT_ID"; }
  cmd "$EK gate grant list --agent $AGENT"
  say "  When no sign permission is left, run ${C}./open.sh steps${N} again. To start over:  ${C}rm .demo-state${N}"
}

# ================================================================ the four steps
# The AI is asked ONCE. Its recorded pay is then governed three times: refused without
# permission, signed and sent with it, refused again after the permission is taken back.
steps() {
save_state
vw set model_where "the AI gate $LLM, carrying the message to $MODEL, a third party, not EKKA"
vw set exec_where "your Enclave: signing with keys/$KEY, sending through $API_ROW"
vw set wallet "$ADDRESS"; vw set payee "$PAYEE"
vw authority network_read "granted"; vw authority send "granted (only an already-signed payment)"; vw authority sign "not granted"
say ""
say "  Four steps. Each one shows what it runs, waits for you to press Enter, runs it, and says"
say "  what happened. ${B}q${N} stops at any point."

# ---- 1. The AI decides, and tries to pay
say ""; say "  ${Y}▶ Step 1 of 4. The AI reads the invoice, decides, and tries to pay.${N}"
say "      You have not given it permission to sign yet, so EKKA should stop the payment."
wait_enter "Enter reads your balance."
read_plan "Reading your balance" "$BAL_VER"
funds_check "$P"
ok "Your wallet holds ${B}$BAL_ETH test ETH${N}. Read from the network just now."
build_payment
python3 - "$HERE/inputs.json" <<EOF
import json; json.dump({"amount_eth": "$AMOUNT_ETH", "payee": "$PAYEE", "for": "September API credits",
  "approved": ["$PAYEE"], "balance_eth": "$BAL_ETH", "fee_cap_eth": "$(eth_of "$FEE_CAP_WEI")", "floor_eth": "$FLOOR_ETH"},
  open(__import__("sys").argv[1], "w"))
EOF
"$HERE/bin/prompt" "$HERE/inputs.json" "$HERE/prompt.txt" >/dev/null
[ "$PAYEE" = "$ADDRESS" ] && TO_WHO="$(short "$PAYEE"), your own address" || TO_WHO="$(short "$PAYEE")"
say ""
say "  ${B}What the AI is sent${N}"
say "    · The invoice: pay $AMOUNT_ETH test ETH to $TO_WHO, for September API credits."
say "    · Your rule: pay only if the payee is on your list and at least $FLOOR_ETH test ETH is left."
say "    · Your balance now: $BAL_ETH test ETH. Your approved list: $(short "$PAYEE")."
say "    Nothing else: not your private key, not your other payments."
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
  hold) say "      So nothing is signed: only a pay leads to the signing step. Change the invoice or the"
        say "      rule in ${C}bin/prompt${N}, then ${C}./open.sh steps${N}."
        vw event "1. The AI decides" "AI decision (hold)" "decide" "nothing to sign" "not sent"; stop_walk ;;
  invalid_model_output) say "      So nothing can be signed: only a clear pay can lead to a signature."
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
say "      ${G}${B}EKKA stopped the payment.${N} Your AI agent has no permission to sign, so the Enclave did not"
say "      sign and nothing was sent."
say "      ${B}See it yourself:${N} no new payment is on your wallet's page:"
say "      ${C}$EXPLORER/address/$ADDRESS${N}"
vw event "1. The AI decides, and is stopped" "AI decision (pay)" "sign the payment" "refused: no permission" "not sent"
vw render

# ---- 2. You give permission; the AI's payment goes through
say ""; say "  ${Y}▶ Step 2 of 4. You give the AI permission to sign, for as long as you choose.${N}"
say "      EKKA sees only a fingerprint of what is signed, not who is paid or how much. So while the"
say "      permission lasts, your AI agent may sign ANY payment with this key, not only this one."
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
say "      Now the AI's payment from step 1 goes to EKKA again, as the same payment:"
say "      $AMOUNT_ETH test ETH to $TO_WHO."
say "      The AI is not asked again. Its decision stands; only your permission changed."
SIG_CMD="$EK plan run $SIG_VER --input digest=$DIGEST"
runs "$SIG_CMD"
wait_enter "Enter signs and sends the payment."
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
        say "      ${B}See it yourself:${N} it is the newest payment on your wallet's page:"
        say "      ${C}$EXPLORER/address/$ADDRESS${N}"
        say "      Its hash begins $(printf '%s' "$TX_HASH" | cut -c1-12). The full link is on the evidence page."
        if [ "$PAYEE" = "$ADDRESS" ]; then
          say "      Why your balance dropped a little: the network charged a fee of ${B}$FEE_ETH test ETH${N} to carry"
          say "      it. The $AMOUNT_ETH came back to you, because the example pays you back. Test ETH has no value."
        else
          say "      It cost a network fee of ${B}$FEE_ETH test ETH${N}, on top of the $AMOUNT_ETH. Test ETH has no value."
        fi ;;
  error) say "      ${R}The network took the payment and it failed there.${N} Your wallet's page says why:"
         say "      ${C}$EXPLORER/address/$ADDRESS${N}" ;;
  *)    say "      ${Y}The network has not confirmed it yet.${N} It usually takes about 15 seconds. Watch it:"
        say "      ${C}$EXPLORER/address/$ADDRESS${N}" ;;
esac
vw set tx "$TX_HASH"; vw set tx_status "$PAY_STATE"
vw event "2. Permission given" "AI decision (pay)" "sign, then send" "allowed ($PERMIT)" "$PAY_STATE"
vw render

# ---- 3. Take the permission back
say ""; say "  ${Y}▶ Step 3 of 4. Take the permission back.${N}"
say "      There is nothing to cancel: a confirmed payment is final. So take the permission back as"
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

# ---- 4. The same payment again: stopped
say ""; say "  ${Y}▶ Step 4 of 4. The AI's payment once more, after you took the permission back.${N}"
say "      The same payment, as a brand-new one (the next payment number). EKKA should stop it."
build_payment $((NONCE + 1))
AGAIN_CMD="$EK plan run $SIG_VER --input digest=$DIGEST"
runs "$AGAIN_CMD"
wait_enter "Enter sends the payment."
busy "The Enclave is asked to sign" "$AGAIN_CMD"
if refused_by_ekka; then
  ok "EKKA stopped it. The permission is yours to give, and yours to take back."
  # ⛔ SAY ONLY WHAT THE PAGE WILL SHOW (ekka-ai/ekka-kits#45). A wallet that has been paid
  # or has paid before lists every one of those payments, so "only the one" was false for
  # anyone but a brand-new wallet. What the kit can prove: the newest is still step 2's.
  say "      ${B}See it yourself:${N} the newest payment on your wallet's page is still the one from step 2"
  say "      (its hash begins $(printf '%s' "$TX_HASH" | cut -c1-12)). Nothing new was sent:"
  say "      ${C}$EXPLORER/address/$ADDRESS${N}"
elif plan_completed; then
  say "      ${R}THE ENCLAVE SIGNED AFTER YOU TOOK THE PERMISSION BACK.${N} That must never happen."
  say "      Nothing was sent. Report this run with the output above."
  stop_walk
else
  explain_failure; stop_walk
fi
vw event "4. Once more, no permission" "AI decision (pay), new payment" "sign the payment" "refused: permission taken back" "not sent"

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
say "  1. The AI decided to ${B}pay${N}. It had no permission, so ${B}EKKA stopped the signature.${N}"
say "  2. You allowed it for $PERMIT. The same payment was signed, and $GONE."
say "  3. You took the permission back."
say "  4. The same payment once more: ${B}EKKA stopped it.${N}"
say ""
if [ "$VERIFY_RC" = 0 ]; then
say "  ${B}Trust${N}      Every step was written down and signed on this computer, and the record checks out."
else
say "  ${B}Trust${N}      ${R}The record did not check out,${N} so this walk is not proven. See above."
fi
say "  ${B}Security${N}   The AI's payment was signed only while you allowed it."
say "             Before and after, EKKA stopped it."
say "  ${B}Privacy${N}    Your private key stayed in the Enclave on this computer, which signed with it."
say "             ${B}EKKA NEVER SAW YOUR PRIVATE KEY.${N} To decide yes or no, EKKA's control plane was sent"
say "             the message to the AI and the payment's fingerprint, then the signed payment, which"
say "             is public on the network once it is sent."
say "             The AI gate carried the message to the model, a third party, not EKKA."
say "             It saw only the invoice, your rule, your list and your balance. Never your key."
say "             ${B}Want your own model instead?${N} Add its API to your catalog the same way this kit added"
say "             the Sepolia network. Then the message goes to your model, not a third party's."
say ""
say "  ${B}Good to know:${N} while a sign permission lasts, the agent may sign ANY payment with this key."
say "  EKKA checks who may sign and for how long, not who is paid or how much. Your rule and this kit"
say "  check those. Taking the permission back stops new signatures; a payment already sent is final."
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
command -v python3 >/dev/null 2>&1 || stop "This machine is missing python3." "The kit builds the payment with it. On Debian or Ubuntu: apt-get install -y python3"
# ⛔ 0.1.88: this kit catalogues its row in the person's OWN organization (`apis/<org>/eth-sepolia`),
# which an Enclave before 0.1.88 refuses with API_NAME_INVALID. The sign op has been there since 0.1.87.
FLOOR=0.1.88; KIT_VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo dev)
HAVE=$(run --version 2>/dev/null | awk 'NR==1{print $2}')
[ "$(printf '%s\n%s\n' "$FLOOR" "$HAVE" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$FLOOR" ] || stop "This kit needs EKKA $FLOOR or later; you have ${HAVE:-an unknown version}." "Run the install line again, then open a new terminal window."
"$HERE/bin/tx" selftest >/dev/null 2>&1 || stop "This kit's payment builder failed its own tests." "Nothing was changed. Report it with: bin/tx selftest"
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
head_ "Let an AI pay for you. You decide what it may do."
say "  An invoice arrives. An AI checks it against your rule and decides whether to pay."
say "  You give it permission to sign, for as long as you choose, and its payment goes through."
say "  Take the permission back whenever you want, and it stops."
say ""
say "  ${B}Trust${N}      Every action is recorded and signed, so you can prove what happened."
say "  ${B}Security${N}   The AI can do only what you allowed, and only for as long as you allowed it."
say "  ${B}Privacy${N}    Your wallet's private key stays in the Enclave on this computer, which signs with it."
say "             ${B}EKKA NEVER SEES YOUR PRIVATE KEY.${N} Neither does the AI, a third-party model, not EKKA."
say "             To decide yes or no, EKKA's control plane is sent the message to the AI and the"
say "             payment's fingerprint, then the signed payment, which is public once it is sent."
say "             The AI gate carries the message to the model, a third party, not EKKA."
say ""
say "  ${B}Safe to try${N}"
say "    · The Sepolia test network only. Test ETH is free and has no value. No real money."
say "    · Your key stays on this computer, encrypted. Use a wallet you made for this."
say "    · Nothing is signed unless you have given permission."
say "    · The payment rule is an example, not advice."
say ""
say "  ${B}You need${N} a test wallet with a little test ETH. How to make one in MetaMask and fill it,"
say "  two minutes: ${C}$WALLET_HELP${N}"
say ""
say "  ${D}What gets set up, in detail:  ./open.sh why        kit $KIT_VERSION, EKKA $HAVE${N}"
say ""
ask "Ready? [y/N]"
case "$REPLY" in y|Y|yes|YES) ;; *) say ""; say "  Nothing was changed."; say ""; exit 0 ;; esac

head_ "Setting up"

# ---------------- ⛔ THE ONLY BLOCK THAT TOUCHES YOUR KEY ----------------
if [ "$HAVE_KEY" = 1 ]; then
  ok "Your key is already stored on this computer, as ${B}$KEY${N}."
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
  ok "Your key is stored on this computer, encrypted. The AI cannot see it, and neither can EKKA."
fi
# ---------------- end of the block that touches your key ----------------

say "  Now your wallet's ${B}address${N}, the public half: 0x and 40 characters. It is public on purpose."
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
say "  The invoice in this walk pays $AMOUNT_ETH test ETH. By default it pays ${B}you back${N}, so only the"
say "  network fee is spent. Or type another address to pay."
while :; do
  ask "Who does the invoice pay? Enter pays you back:"
  PAYEE=$(printf '%s' "${REPLY:-$ADDRESS}" | tr -d ' \r\t' | tr 'A-F' 'a-f')
  printf '%s' "$PAYEE" | grep -qE '^0x[0-9a-f]{40}$' && break
  say "  ${R}That does not look like an address${N} (0x and 40 characters)."
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
item_start "Saved its plan: read the payments you have sent";      create_plan "$HERE/wallet.sent.json" wallet.sent; SNT_VER=$V; item_done
item_start "Saved its plan: read the network's fees";              create_plan "$HERE/wallet.fees.json" wallet.fees; FEE_VER=$V; item_done
item_start "Saved its plan: decide whether to pay, then sign";     create_plan "$HERE/wallet.decide.json" wallet.decide; DEC_VER=$V; item_done
item_start "Saved its plan: sign its decision again";              create_plan "$HERE/wallet.sign.json" wallet.sign; SIG_VER=$V; item_done
item_start "Saved its plan: send a payment that is already signed"; create_plan "$HERE/wallet.send.json" wallet.send; SND_VER=$V; item_done

grant() {  # label type instance resource capability words
  item_start "$1"; shift
  quiet "$EK gate grant add --agent $AGENT --type $1 --instance $2 --resource $3 --capability $4${5:+ $5}"
  [ "$RC" = 0 ] || grep -qiE "already|exists" "$OUTF" || { spin_stop; show_failure; say "      ${R}The grant was not created.${N} The red lines above name the reason."; stop_walk; }
  item_done
}
grant "Allowed it to read the Sepolia network"              api "$AINST" "apis/$API_ROW" api.read --no-fingerprint
grant "Allowed it to send a payment that is already signed" api "$AINST" "apis/$API_ROW" api.write --no-fingerprint
grant "Allowed it to ask the AI"                            llm "$LLM" "$MODEL" llm.infer ""
ok "Your AI agent is ready. It may NOT sign. Only you can allow that, in step 2."
save_state

read_plan "Checking your wallet" "$BAL_VER"
funds_check "$P"
ok "Your wallet holds ${B}$BAL_ETH test ETH${N}: enough for the walk."
steps
