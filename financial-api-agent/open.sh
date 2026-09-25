#!/bin/sh
# Financial Kit: your AI does the thinking, your infrastructure does the work, you control what
# it is allowed to do. A hosted model applies YOUR rule to named market inputs; its buy verdict
# is the only thing that can lead to a paper order, and only while you have granted write
# access. Orders use an Alpaca paper account.
# It touches your Alpaca keys exactly once: reads them at a hidden prompt, checks the shape, hands
# them to the Enclave for both catalog rows, forgets them. Everything else is plans, grants and
# explanations.
set -eu

EKKA=${EKKA:-ekka}
EKKA_FLAG=${EKKA_FLAG:-}
AGENT=${AGENT:-trading-agent}
ENCLAVE=${ENCLAVE:-}
MODEL=${MODEL:-anthropic/sonnet-4}
ROW=alpaca-paper                          # the paper orders server, catalog/ekka-$ROW.json
DROW=alpaca-data                          # the market data server, catalog/ekka-$DROW.json
PAPER=https://paper-api.alpaca.markets
ALPACA_KEYS=https://app.alpaca.markets/
DOCS=https://docs.ekka.ai
KIT_DOC=https://github.com/ekka-labs/kits/tree/main/financial-api-agent
HERE=$(cd "$(dirname "$0")" && pwd)
# Work inside the kit's folder, so the command a person is shown (prompt.txt, bin/...) is the
# command that runs, character for character, and a folder name with a space cannot split it.
cd "$HERE"
STATE="$HERE/.demo-state"
VIEWD="$HERE/.view"
MODE=${1:-setup}                # setup (default) | steps | commands | why | schedule | view

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
learn() { say "      ${D}Learn more:${N} ${C}$*${N}"; }
stop()  { say ""; say "  ${R}✖ Stopped.${N} $1"; say "    $2"; say ""; exit 1; }
run()   { $EKKA $EKKA_FLAG "$@"; }
# The command a person is shown, and the command that runs, are one string.
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
# ONE WALK PER FOLDER. Two walks share one saved state and one order id, and each would act on the
# other's half-finished attempt. A lock whose process is gone is stale and is taken over.
LOCK="$HERE/.walk.lock"; HAVE_LOCK=""
take_lock() {
  if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    OTHER=$(cat "$LOCK")
    say ""; say "  ${Y}Another walk is already running in this folder${N} (process $OTHER)."
    # A terminal that disconnects (a dropped docker exec, a closed laptop) does not always tell the
    # walk inside, so a walk can be left behind waiting for keys. One key takes over from it.
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
# A walk whose terminal went away ends instead of sitting orphaned, waiting for keys nobody types.
trap 'trace "terminal hung up"; exit 129' HUP

# The evidence file and its read-only page. A failure to write evidence never stops the walk,
# and never counts as a pass: the page shows only what was written.
vw() { "$HERE/bin/view" "$VIEWD" "$@" >/dev/null 2>&1 || true; }

# Runs one command, shows its output line by line, keeps it in $OUTF and its exit status in $RC.
# Runs one command, shows its output in plain words, keeps the RAW output in $OUTF and its exit
# status in $RC. Every check in this kit reads $OUTF, never the screen, so the plain display
# changes nothing it decides. VERBOSE=1 ./open.sh shows the raw output instead.
show_run() {
  RC=0; rm -f "$OUTF.rc"
  { sh -c "$1" 2>&1 && echo 0 >"$OUTF.rc" || echo "$?" >"$OUTF.rc"; } | tee "$OUTF" | while IFS= read -r line; do
    if [ -n "${VERBOSE:-}" ]; then say "      ${D}$line${N}"; continue; fi
    case "$line" in
      ""|*"Dispatching plan"*|*"Waiting for the run"*|*"produced no text"*|*"Content hash:"*|*"Verify the signed receipts"*|*"Run detail:"*) ;;
      *"✓ Plan completed"*) say "      ${G}✓ Done.${N}" ;;
      *"40410000"*) say "      Alpaca answers: there is no such order." ;;
      *"✗ Plan failed"*) say "      ${R}✗ Not done.${N}" ;;
      *"RESOURCE_GRANT_DENIED: agent "*|*"dispatch failed: RESOURCE_GRANT_DENIED"*) say "      ${R}EKKA refused it: there is no permission for this.${N}" ;;
      *RESOURCE_GRANT_DENIED) ;;
      ✓*|*"✓ "*) say "      ${G}$line${N}" ;;
      *✗*|*refused*|*failed*|*denied*|*DENIED*|*ERROR*|*error*|*expired*|*rejected*) say "      ${R}$line${N}" ;;
      *) say "      $line" ;;
    esac
  done
  RC=$(cat "$OUTF.rc" 2>/dev/null || echo 0)
}
# The command a step runs, as one short dim line: the plan's name, not its every input.
runs() {
  if [ -n "${VERBOSE:-}" ]; then cmd "$1"; return; fi
  short=$(printf '%s' "$1" | sed -E 's/(plan run [^ ]+).*/\1/; s/(grant revoke) .*/\1/; s/^[^ ]*ekka( --[a-z]+)? /ekka /')
  say "      ${D}runs: $short${N}"
}
# Progress on ONE line that updates in place, so a slow network never looks like a frozen kit.
# Only on a terminal: a pipe, a log or the rehearsal gets nothing extra.
# ONE way to show a wait: a line naming what is happening, with moving dots, on a terminal only.
# spin_stop clears it. `|| true` is not decoration: `wait` on a killed job returns 143, and under
# `set -e` that ended the WHOLE KIT the first time a wait finished (found by a real-terminal walk).
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
# A setup item: what is being set up, moving dots while it runs, then a line that stays.
item_start() { ITEM="$1"; trace "setup: $1"; spin_start "$1"; }
item_done()  { spin_stop; ok "$ITEM"; }
# A slow call says what it is waiting for, on ONE line with moving dots, cleared when done.
# Only on a terminal; a pipe or the rehearsal gets the plain quiet run.
busy() {  # message  command
  if [ -t 1 ] && [ -z "${VERBOSE:-}" ]; then
    spin_start "$1"
    trace "busy: $1"; quiet "$2"; trace "done: $1 (rc=$RC)"
    spin_stop
  else
    quiet "$2"
  fi
}
# The same, with nothing on screen: for work a person does not need to watch. On failure the
# caller prints $OUTF with show_failure.
quiet() { RC=0; sh -c "$1" > "$OUTF" 2>&1 || RC=$?; }
show_failure() { sed 's/^/      /' "$OUTF" | while IFS= read -r l; do say "${R}$l${N}"; done; }

stop_walk() {
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
  elif grep -qE "GOVERN_HTTP_ERROR|50[234]" "$OUTF"; then
    say "      EKKA did not answer clearly. Inspect the saved attempt before trying another write:"
    cmd "./open.sh steps"
  elif grep -qE "401|403|unauthorized|forbidden|Authorization Required" "$OUTF"; then
    say "      Alpaca refused the credentials. EKKA allowed the request and it reached Alpaca, which did"
    say "      not accept the key. Check it is a PAPER key from ${C}$ALPACA_KEYS${N} and reconnect both rows:"
    cmd "$EK api disconnect $API_ROW ; $EK api disconnect $DATA_ROW    then    ./open.sh"
  else
    say "      The red line above names the reason. Fix it, then run the steps again:  ${C}./open.sh steps${N}"
  fi
}

explain_grant() {  # type instance resource capability what-it-means [ttl]
  # One sentence a person can repeat. The flags are explained under ./open.sh why.
  case "$3" in
    *alpaca-paper) what="your Alpaca paper account" ;;
    *alpaca-data)  what="Alpaca prices" ;;
    *)             what="EKKA's AI" ;;
  esac
  say "      You are telling EKKA: ${B}your AI agent may $5${N}, on ${B}$what${N},"
  say "      from this computer only${6:+, ${B}for $6${N}}. Nothing else."
}

# Refused by EKKA before the network, or something else? The words are govern's own.
refused_by_ekka() { grep -q RESOURCE_GRANT_DENIED "$OUTF"; }
plan_completed()  { grep -q "✓ Plan completed" "$OUTF"; }
out_path()        { grep -oE 'output is at .*' "$OUTF" | sed 's/output is at //' | head -1 || true; }
run_id()          { grep -oE 'run [0-9a-f-]{36}' "$OUTF" | head -1 | cut -c5- || true; }
new_client_id()   { printf 'ekka-kit-%s' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; }
save_state() {
  cat > "$STATE" <<EOF
API_ROW='$API_ROW'
DATA_ROW='$DATA_ROW'
ORG='$ORG'
AGENT='$AGENT'
AINST='$AINST'
LLM='$LLM'
MODEL='$MODEL'
QTY='$QTY'
LIMIT='${LIMIT:-}'
LIMIT_AAPL='$LIMIT_AAPL'
LIMIT_SPY='$LIMIT_SPY'
CLIENT_ID='$CLIENT_ID'
MKT_VER='$MKT_VER'
ACC_VER='$ACC_VER'
POS_VER='$POS_VER'
STA_VER='$STA_VER'
DEC_VER='$DEC_VER'
EXE_VER='$EXE_VER'
ANA_VER='$ANA_VER'
CAN_VER='$CAN_VER'
ORDER_ID='${ORDER_ID:-}'
ORDER_OUTCOME='${ORDER_OUTCOME:-}'
ORDER_BY='${ORDER_BY:-}'
WALK_STARTED='${WALK_STARTED:-}'
WRITE_GRANT_ID='${WRITE_GRANT_ID:-}'
WRITE_INTENT='${WRITE_INTENT:-}'
ORDER_RESOLVED='${ORDER_RESOLVED:-}'
VERDICT='${VERDICT:-}'
EOF
}

# Look the kit's order up by its own id, with the read permission. 404 from the server means the
# order does not exist there, which is the proof moment 2 and moment 5 need.
lookup() {  # client_id -> sets LOOK=found|absent|unknown. Every caller says the result.
  busy "Checking with Alpaca" "$EK plan run $STA_VER --input client_order_id=$1"
  if plan_completed; then LOOK=found
  elif grep -q '40410000' "$OUTF"; then LOOK=absent
  else LOOK=unknown; fi
}

# The verdict of the run just shown, from what EKKA recorded: `ekka run show` prints the bounded
# fact the Enclave let cross. Sets VERDICT to buy | hold | sell | invalid_model_output.
read_verdict() {
  RID=$(run_id)
  VERDICT=no_verdict
  [ -n "$RID" ] || { explain_failure; stop_walk; }
  run run show "$RID" > "$OUTF.show" 2>&1 || true
  VERDICT=$("$HERE/bin/show-verdict" "$OUTF.show" --word 2>/dev/null || echo no_verdict)
  WHY=$("$HERE/bin/show-verdict" "$OUTF.show" | sed -n 's/^explanation   //p')
  case "$VERDICT" in
    AAPL) say "      ${B}The AI picks: Apple (AAPL)${N}"; say "      Its reason: $WHY" ;;
    SPY)  say "      ${B}The AI picks: the S&P 500 fund (SPY)${N}"; say "      Its reason: $WHY" ;;
    invalid_model_output) say "      ${B}The AI did not answer clearly with AAPL or SPY.${N}" ;;
  esac
  if [ "$VERDICT" = no_verdict ]; then
    say "      ${R}The model gave no answer: the run stopped for a reason that is not the model's.${N}"
    explain_failure; stop_walk
  fi
  vw set verdict "$VERDICT"
  EXPL=$("$HERE/bin/show-verdict" "$OUTF.show" | sed -n 's/^explanation   //p')
  vw set explanation "$EXPL"
}
# The price and the plain name for the AI's pick: its limit is about 10% under the last close.
pick_limit() {
  case "$VERDICT" in
    AAPL) LIMIT=$LIMIT_AAPL; PICK_NAME="Apple (AAPL)" ;;
    SPY)  LIMIT=$LIMIT_SPY;  PICK_NAME="the S&P 500 fund (SPY)" ;;
    *)    LIMIT=""; PICK_NAME="" ;;
  esac
  save_state
}

# The fresh inputs, the prompt built from them, and nothing else. Sets PROMPT_FILE.
build_prompt() {
  START=$(python3 -c 'import datetime;print((datetime.date.today()-datetime.timedelta(days=21)).isoformat())')
  if [ -n "${BARS_FILE:-}" ] && [ -f "$BARS_FILE" ]; then
    BARS=$BARS_FILE     # setup fetched them seconds ago, in this same run: no second fetch
  else
    busy "Getting today's prices" "$EK plan run $MKT_VER --input start=$START"
    plan_completed || { show_failure; explain_failure; stop_walk; }
    BARS=$(out_path)
  fi
  quiet "bin/market-inputs ${BARS:-missing} $HERE/inputs.json"
  [ "$RC" = 0 ] || { show_failure; say "      ${R}The prices could not be turned into the AI's inputs.${N} The line above says why."; stop_walk; }
  python3 - "$HERE/inputs.json" <<'PY' | while IFS= read -r l; do say "$l"; done
import json, sys
i = json.load(open(sys.argv[1]))
print("  \u2714 Got the last 5 days of prices from Alpaca.")
print(f"      Apple      {i['aapl_close_from']} \u2192 {i['aapl_close_to']}   {i['aapl_return_pct']:+.2f}%")
print(f"      S&P 500    {i['spy_close_from']} \u2192 {i['spy_close_to']}   {i['spy_return_pct']:+.2f}%")
gap = i['spread_pts']
side = "ahead of" if gap > 0 else "behind"
print(f"      Apple is {abs(gap):.2f} points {side} the S&P 500. Worked out here, on your computer, not by the AI.")
PY
  busy "Checking your paper account" "$EK plan run $POS_VER"
  plan_completed || { show_failure; explain_failure; stop_walk; }
  POSITION=$("$HERE/bin/show-positions" "$(out_path)" --qty 2>/dev/null || echo unknown)
  [ "$POSITION" = unknown ] && { say "      ${R}Your paper account could not be read.${N} The AI is given nothing it cannot see."; stop_walk; }
  if [ "$POSITION" = none ]; then ok "Checked your paper account: you own neither Apple nor SPY."
  else ok "Checked your paper account: you own $POSITION."; fi
  OPEN_ORDER=none
  [ -n "${ORDER_ID:-}" ] && [ -z "${ORDER_RESOLVED:-}" ] && OPEN_ORDER="$CLIENT_ID (not yet resolved)"
  "$HERE/bin/prompt" "$HERE/inputs.json" "$POSITION" "$OPEN_ORDER" "$HERE/prompt.txt" >/dev/null
  PROMPT_FILE="$HERE/prompt.txt"
  python3 - "$HERE/inputs.json" "$VIEWD" "$HERE/bin/view" "$POSITION" "$OPEN_ORDER" <<'PY' || true
import json, subprocess, sys
i = json.load(open(sys.argv[1])); v = lambda k, x: subprocess.run([sys.argv[3], sys.argv[2], "set", k, x])
v("window", f"{i['window_trading_days']} trading days, {i['aapl_from'][:10]} to {i['as_of'][:10]} closes (IEX, adjusted)")
v("aapl_return", f"{i['aapl_return_pct']:+.2f}%"); v("spy_return", f"{i['spy_return_pct']:+.2f}%")
v("spread", f"{i['spread_pts']:+.2f} points"); v("position", sys.argv[4]); v("open_order", sys.argv[5])
PY
}

why() {
head_ "Questions people ask at this point, and how to check the answer yourself"
say "  ${B}What gets set up in my organization?${N} Two catalog entries: ${B}$DATA_ROW${N} (prices, read only) and"
say "  ${B}$API_ROW${N} (paper orders). One agent, ${B}$AGENT${N}, and its plans, written in this folder as files."
say "  Three standing permissions: read prices, read the paper account, ask the hosted model ${B}$MODEL${N}."
say "  None of them can place an order. The rule is in ${B}bin/prompt${N}; edit it and it is your rule."
cmd "$EK gate grant list --agent $AGENT"
say "  ${B}Where are my Alpaca keys?${N} Encrypted in your Enclave's connection store. The Enclave adds"
say "  them to the vetted broker request; they are never a plan input and never a model input."
say "  This walkthrough runs as ${B}you${N}, and your session can issue grants. Never hand it to an AI."
cmd "$EK secret list"
say "  ${B}What exactly did the model see?${N} The file ${B}prompt.txt${N} in this folder, and nothing else:"
say "  the mandate, the rule, two returns computed on this machine, your AAPL position and the kit's order."
say "  It runs on EKKA's hosted model path, so that message leaves this machine for the model provider."
say "  ${B}Can a strange answer trade?${N} No. Only the exact words AAPL or SPY cross to EKKA, and"
say "  each leads only to the order for that one symbol. Anything else goes to the plan's default, which fails."
cmd "cat trade.decide.json"
say "  ${B}What is in a grant?${N} One row on EKKA's server with five parts: --agent (who), --type and"
say "  --instance (which gate, on which machine), --resource (which server or model), --capability (which"
say "  action: read, write, ask the model) and --ttl (for how long). --no-fingerprint means it is not tied to"
say "  one catalog revision, so do not read it as approval of every future change to that row."
say "  ${B}What does the write grant NOT limit?${N} Symbol, side, quantity, price, order count, exposure, loss."
say "  ${B}Could this reach my real brokerage account?${N}  No. The orders row names ${B}$PAPER${N} only,"
say "  pinned by the Enclave: no redirects, no other host. A live key is refused before it is stored."
say "  ${B}Is the record real?${N} Each governed step produces signed evidence binding the authorized scope"
say "  to hashes of its input and output. The full model reply and broker answers stay local. Offline"
say "  verification checks the local chain and signatures but cannot prove that the chain has not been"
say "  truncated at the end; online verification can also check signing-key revocation."
cmd "$EK receipts verify"
say ""
}

commands() {
head_ "Operator commands: keep administration with the human"
say "  These use your session. They are not a restricted AI execution interface."
cmd "$EK gate grant list --agent $AGENT"
say "  Revoke only the Kit's grants, using their full IDs from the list."
cmd "$EK plan run $DEC_VER --input user_message=@prompt.txt --input qty=1 --input limit_aapl=<price> --input limit_spy=<price> --input client_order_id=<new id>"
cmd "$EK plan run $STA_VER --input client_order_id=$CLIENT_ID"
[ -n "${CAN_VER:-}" ] && { cmd "$EK plan run $CAN_VER"; note "This cancel plan names the Kit order. It needs an active api.write grant."; }
cmd "$EK receipts verify"
say "  ${B}To let an AI run these plans and nothing else${N}: publish the plans and give the AI the session"
say "  of an organization ${B}member${N}. A member may dispatch plans and may NOT issue or revoke a grant."
cmd "$EK plan publish $DEC_VER      then      ekka plan approve $DEC_VER"
cmd "$EK org members invite ai-operator@example.com --role member"
}

# The optional analysis-only schedule. It is run once first, in front of you, so it is never
# offered on the strength of a plan nobody has seen answer.
schedule() {
head_ "Optional: analysis only, on a schedule"
say "  ${B}trade.analyze${N} reads the bars and asks the model for a recommendation. It has ${B}no order step${N}:"
say "  read ${C}trade.analyze.json${N}. On a schedule the model reads the closes itself, so its numbers are"
say "  its own arithmetic, unlike the walk, where the returns are computed on this machine."
say "  ${B}This example enforces no repeat-order and no exposure limit.${N} It stays safe because this plan"
say "  has no order step, not because of a limit. A live write grant plus a repeating buy signal in a"
say "  plan that CAN order would place order after order."
START=$(python3 -c 'import datetime;print((datetime.date.today()-datetime.timedelta(days=21)).isoformat())')
sed -n '1,/^INPUTS/p' "$HERE/prompt.txt" 2>/dev/null | sed '$d' > "$HERE/analyze.txt" || true
cat >> "$HERE/analyze.txt" <<'EOF'
INPUTS: the daily closes in `bars`, adjusted for splits and dividends, for AAPL and SPY. Compute each
symbol's 5-day total return from the last six closes and apply the rule. You have no position data.

Answer with JSON and nothing else, in exactly this shape:
{"pick": "AAPL" | "SPY", "explanation": "<two sentences at most, naming the numbers you used>"}
EOF
say "  Run it once now, and read what it says:"
cmd "$EK plan run $ANA_VER --input start=$START --input user_message=@analyze.txt"
wait_enter "Enter runs it."
show_run "$EK plan run $ANA_VER --input start=$START --input user_message=@analyze.txt"
if plan_completed; then read_verdict
else explain_failure; return 1; fi
say ""
say "  Each run is one market read and one hosted model call, charged to your EKKA credit. Every 15"
say "  minutes is about 96 model calls a day. To schedule it:"
cmd "$EK plan schedule $ANA_VER --every 15m --input start=$START --input user_message=@analyze.txt"
note "The start date is fixed when you schedule; the window it reads grows until you reschedule."
}

write_cancel_plan() {   # $1 = the provider's order id
  cat > "$HERE/trade.cancel.json" <<EOF
{
  "plan": { "agent": "$AGENT", "code": "trade.cancel", "name": "trade.cancel" },
  "definition": {
    "schema_version": "ekka.plan.v2",
    "run_context": [],
    "inputs": {},
    "operations": [{
      "id": "cancelOrder",
      "display_name": "Cancel the one order this plan names",
      "execution": { "allowed": [], "preferred": { "mode": "async", "runtime": "node" } },
      "steps": [{
        "id": "call",
        "action_ref": "ekka.gate.api.v1",
        "target": "$AINST",
        "op": "write",
        "call": "cancelOrder",
        "inputs": { "resource": "apis/$API_ROW", "order_id": "$1", "expect": { "status": 204 } },
        "action_input": {},
        "step_input_contract": { "type": "object", "properties": { "resource": { "type": "string" }, "key": { "type": "string" }, "value": { "type": "object" } }, "required": ["resource", "key", "value"] },
        "step_output_contract": { "type": "object" },
        "identity": { "requires_user_context": false }
      }]
    }]
  }
}
EOF
}

ver_of() { printf '%s\n' "$1" | grep -oE "ekka\.$2@[0-9.]+" | head -1; }
# Saves one plan and sets V to its version. NOT called inside $( ... ): a failure there was
# captured with its message and, under `set -e`, ended the kit with NOTHING on screen (measured
# 2026-09-25 while prod was unreachable). Here a failure stops the walk and says why.
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
  V=$(printf '%s\n' "$OUT" | grep -oE "[a-z0-9-]+\.$2@[0-9.]+" | head -1); V=${V:-ekka.$2@1.0.0}
}

# After a write attempt shown in $OUTF: decide what happened, never by guessing.
# Sets ORDER_OUTCOME submitted|rejected|accepted|absent|uncertain and ORDER_ID when known.
settle_submission() {
  if plan_completed; then
    ORDER_OUTCOME=submitted
    ORDER_ID=$("$HERE/bin/show-order" --client="$CLIENT_ID" --id 2>/dev/null || true)
    ST=$("$HERE/bin/show-order" --client="$CLIENT_ID" --status 2>/dev/null || echo unknown)
    case "$ST" in new|accepted|pending_new) ST="waiting to be filled" ;; filled) ST="filled" ;; esac
    ok "Alpaca accepted the order: buy $QTY share of $PICK_NAME at up to \$$LIMIT."
    say "      Status at Alpaca: $ST."
    say "      ${B}See it yourself:${N} open ${C}$ALPACA_KEYS${N}, switch to your paper account, and open ${B}Orders${N}."
    say "      It is there as: buy $QTY $VERDICT, limit \$$LIMIT. Its client order id is $CLIENT_ID."
  elif refused_by_ekka; then
    say "      ${B}Refused: your $PERMIT had already run out.${N} The permission ended exactly when you set it to,"
    say "      so nothing reached Alpaca. Run ${C}./open.sh steps${N} again and give it a little longer."
    stop_walk
  elif grep -qE '422|rejected|insufficient|not tradable|market is closed' "$OUTF"; then
    ORDER_OUTCOME=rejected
    say "      ${B}EKKA allowed it, and Alpaca turned it down.${N} That is Alpaca's own answer, shown as it came."
    vw event "3. Orders allowed" "$ORDER_BY" "place order" "allowed (write grant)" "rejected"
    save_state; stop_walk
  else
    say "      ${Y}No clear answer.${N} The request may or may not have reached the broker. The kit does NOT"
    say "      send it again, because a second send could place a second order. It asks instead, by id:"
    lookup "$CLIENT_ID"
    case "$LOOK" in
      found)  ORDER_OUTCOME=accepted; say "      ${B}The order is there.${N} It got through; only the reply was lost on the way back."
              ORDER_ID=$("$HERE/bin/show-order" --client="$CLIENT_ID" --id 2>/dev/null || true) ;;
      # `absent` is deliberately NOT resolved: a lookup that found nothing is not
      # proof the provider has nothing. Only a read-back that NAMES a final status is.
      absent) ORDER_OUTCOME=absent; say "      ${B}This lookup returned no such order.${N} Keep this id and check the paper dashboard before any new submission."; save_state; stop_walk ;;
      *)      ORDER_OUTCOME=uncertain; say "      ${R}Still uncertain.${N} The kit stops here rather than guess. Restarting it will not send this order again."; save_state; stop_walk ;;
    esac
  fi
  save_state
}

# ================================================================ the four steps
# The AI is asked ONCE. Its recorded pick is then governed three times: refused without
# permission, let through with it, refused again after the permission is taken back.
steps() {
WALK_STARTED=1
save_state
M1=skipped; M2=skipped; CANCEL_RESULT=not-checked; M4=skipped
vw set model_where "EKKA's hosted model path ($LLM gate, $MODEL)"
vw set exec_where "your Enclave, gate $AINST, calling the Alpaca paper server"
vw set client_id "$CLIENT_ID"
vw authority market_read "granted"
vw authority orders_read "granted"
vw authority orders_write "not granted"
say ""
say "  Four steps. Each one shows the real command, waits for you to press Enter, runs it, and says"
say "  what happened. ${B}q${N} stops at any point."

# ---- 1. The AI picks what to buy, and tries to buy it
say ""; say "  ${Y}▶ Step 1 of 4. The AI picks what to buy, and tries to buy it.${N}"
say "      You have not given it permission to buy yet, so EKKA should stop the order."
wait_enter "Enter gets today's prices."
build_prompt
SUMMARY=$(python3 - "$HERE/inputs.json" "$POSITION" "$OPEN_ORDER" <<'PY'
import json, sys
i = json.load(open(sys.argv[1])); pos, order = sys.argv[2], sys.argv[3]
print("    · The rule: buy whichever of Apple (AAPL) and the S&P 500 fund (SPY) did better over 5 days.")
print(f"    · Today's numbers: Apple {i['aapl_return_pct']:+.2f}%, S&P 500 {i['spy_return_pct']:+.2f}% over the last 5 trading days.")
print(f"    · What you own of the two now: {'neither' if pos == 'none' else pos}. Any open order from this kit: {'none' if order == 'none' else 'one'}.")
PY
)
say ""
say "  ${B}What the AI is sent${N}"
printf '%s\n' "$SUMMARY" | while IFS= read -r l; do say "$l"; done
say "    Nothing else: not your keys, not your account number, not your other orders."
say ""
say "  ${B}You control this message.${N} Change the rule in ${C}bin/prompt${N}. EKKA passes it to the AI and"
say "  keeps a copy with the run, so you can see later exactly what the AI was told."
say ""
printf "  ${Y}Press p to see the full message, or Enter to ask the AI.${N} "
read -r REPLY <&3 || REPLY=q
case "$REPLY" in
  q|Q) say ""; say "  Stopped. Inspect the saved attempt with: ./open.sh steps"; say ""; exit 0 ;;
  p|P) say ""; sed 's/^/        /' "$PROMPT_FILE"; say ""
       wait_enter "Enter asks the AI." ;;
esac
DEC_CMD="$EK plan run $DEC_VER --input user_message=@prompt.txt --input qty=$QTY --input limit_aapl=$LIMIT_AAPL --input limit_spy=$LIMIT_SPY --input client_order_id=$CLIENT_ID"
runs "$DEC_CMD"
busy "Asking the AI" "$DEC_CMD"
read_verdict
M1=$VERDICT
pick_limit
if [ "$VERDICT" = invalid_model_output ]; then
  say "      So nothing can be bought: only a clear AAPL or SPY can become an order."
  say "      Ask again with ${C}./open.sh steps${N}."
  vw event "1. The AI picks" "AI answer unclear" "pick and buy" "no order: the answer was not AAPL or SPY" "not called"
  stop_walk
fi
# ⛔ THE ONE THING THIS KIT MUST NEVER SEE: the AI's order went through with no permission.
if plan_completed; then
  say "      ${R}THE AI'S ORDER REACHED ALPACA WITHOUT YOUR PERMISSION.${N} That must never happen."
  say "      Check the paper dashboard for the kit's order ($CLIENT_ID), cancel it there, and report this run"
  say "      with the output above: it is a governance failure, not a problem with your setup."
  stop_walk
fi
refused_by_ekka || { explain_failure; stop_walk; }
say "      ${G}${B}EKKA stopped the order.${N} Your AI agent has no permission to buy, so nothing was sent to Alpaca."
say "      Don't take our word for it. The kit asks Alpaca directly:"
lookup "$CLIENT_ID"
case "$LOOK" in
  absent)  M2=passed; say "      ${B}Alpaca confirms: no order was placed.${N}" ;;
  found)   say "      ${R}Unexpected: Alpaca HAS an order with this id.${N} Stop and look."; stop_walk ;;
  *)       M2=passed; say "      ${Y}Alpaca did not answer clearly.${N} EKKA's refusal stands on its own record." ;;
esac
vw event "1. The AI picks, and is stopped" "AI pick ($VERDICT)" "buy $VERDICT" "refused: no permission" "no such order"
vw render

# ---- 2. You give permission; the AI's pick goes through
say ""; say "  ${Y}▶ Step 2 of 4. You give the AI permission to trade, for as long as you choose.${N}"
say "      Your AI agent may then place and cancel orders on your paper account. The permission has no"
say "      limit on which stock or how much, so you choose how long it lasts. It ends by itself then."
MINUTES=${PERMIT_MINUTES:-}
while ! printf '%s' "$MINUTES" | grep -qE '^[1-9][0-9]{0,3}$' || [ "$MINUTES" -gt 1440 ]; do
  ask "For how many minutes may it trade? [10]"; MINUTES=${REPLY:-10}
done
PERMIT="$MINUTES minute"; [ "$MINUTES" = 1 ] || PERMIT="${PERMIT}s"
say ""
explain_grant api "$AINST" "apis/$API_ROW" api.write "place and cancel orders" "$PERMIT"
GRANT_WRITE="$EK gate grant add --agent $AGENT --type api --instance $AINST --resource apis/$API_ROW --capability api.write --ttl $((MINUTES * 60)) --no-fingerprint"
wait_enter "Enter gives the permission."
WRITE_INTENT=1; save_state
busy "Telling EKKA" "$GRANT_WRITE"
[ "$RC" = 0 ] || { show_failure; say "      ${R}The permission was not given.${N} The red lines above say why."; stop_walk; }
WRITE_GRANT_ID=$(grep -oE 'revoke +[0-9a-f-]{16,}' "$OUTF" | head -1 | awk '{print $2}')
save_state
vw authority orders_write "granted for $PERMIT"
ok "Permission given, for $PERMIT."
say "      Now the AI's pick from step 1 goes to EKKA again, as the same order:"
say "      buy $QTY share of $PICK_NAME."
say "      The AI is not asked again. Its decision stands; only your permission changed."
EXE_CMD="$EK plan run $EXE_VER --input symbol=$VERDICT --input qty=$QTY --input limit_price=$LIMIT --input client_order_id=$CLIENT_ID"
runs "$EXE_CMD"
wait_enter "Enter sends the AI's order."
ORDER_OUTCOME=uncertain; ORDER_BY="AI pick ($VERDICT)"; save_state
busy "Sending the AI's order" "$EXE_CMD"
settle_submission
vw set order_status "$("$HERE/bin/show-order" --client="$CLIENT_ID" --status 2>/dev/null || echo "$ORDER_OUTCOME")"
vw event "2. Permission given" "AI pick ($VERDICT)" "buy $VERDICT" "allowed ($PERMIT)" "$ORDER_OUTCOME"
vw render

# ---- 3. Cancel the order, then take the permission back
say ""; say "  ${Y}▶ Step 3 of 4. Cancel the order, then take the permission back.${N}"
if [ -n "${ORDER_ID:-}" ]; then
  write_cancel_plan "$ORDER_ID"
  create_plan "$HERE/trade.cancel.json" trade.cancel; CAN_VER=$V; save_state
  runs "$EK plan run $CAN_VER"
  wait_enter "Enter cancels the order."
  busy "Asking Alpaca to cancel" "$EK plan run $CAN_VER"
  if plan_completed; then
    say "      Asked Alpaca to cancel. Checking that it really did:"
    CANCEL_RESULT=unknown; TRY=0
    while [ "$TRY" -lt 5 ]; do
      TRY=$((TRY+1)); lookup "$CLIENT_ID"
      [ "$LOOK" = found ] && CANCEL_RESULT=$("$HERE/bin/show-order" "$(out_path)" --client="$CLIENT_ID" --status 2>/dev/null || echo unknown)
      case "$CANCEL_RESULT" in canceled|cancelled|expired|rejected|filled) ORDER_RESOLVED=1; break ;; esac
      sleep 2
    done
    save_state
  elif refused_by_ekka; then
    CANCEL_RESULT=left-open; PERMIT_ENDED=1
    say "      ${B}Your permission has already ended, exactly as you set it.${N} So EKKA refused the cancel too."
    say "      The order may still be open at Alpaca: cancel it in the paper dashboard ($ALPACA_KEYS)."
  else CANCEL_RESULT=failed; say "      ${R}Cancellation did not complete.${N} Check the paper dashboard."; fi
  vw set order_status "$CANCEL_RESULT"
  case "$CANCEL_RESULT" in
    canceled|cancelled) ok "Alpaca confirms: the order is cancelled."
                        say "      Refresh ${B}Orders${N} in your paper dashboard: it now shows as canceled." ;;
    filled) say "      ${B}It was filled before the cancel.${N} You now own $PICK_NAME in your paper account."
            say "      Taking the permission back does not sell it. Sell it in the paper dashboard if you want to." ;;
    expired|rejected) say "      Alpaca says the order ${B}$CANCEL_RESULT${N}. It will not be filled." ;;
    left-open) : ;;
    *) say "      ${Y}Alpaca has not given a final answer yet.${N} Choose:"
       ask "r takes the permission back now (then cancel in the dashboard); k keeps it for cleanup [r/k]"
       case "$REPLY" in k|K) say "      Permission kept. Take it back yourself when the order is final:"; cmd "$EK gate grant revoke $WRITE_GRANT_ID"; save_state; stop_walk ;; esac ;;
  esac
else
  ORDER_RESOLVED=1
  say "      No order was accepted, so there is nothing to cancel."
fi
say ""
if [ -n "${PERMIT_ENDED:-}" ]; then
  say "      There is nothing to take back: the permission ended by itself when your $PERMIT ran out."
  WRITE_GRANT_ID=""; WRITE_INTENT=""; ORDER_RESOLVED=1; save_state
  vw authority orders_write "ended by itself after $PERMIT"
else
  say "      ${B}Now take the permission back.${N} You do not have to wait for your $PERMIT to run out."
  [ -n "${WRITE_GRANT_ID:-}" ] || { cmd "$EK gate grant list --agent $AGENT"; stop "The permission's id could not be read, so it cannot be taken back for you." "Take the kit's api.write grant back by hand, then ./open.sh steps"; }
  runs "$EK gate grant revoke $WRITE_GRANT_ID"
  wait_enter "Enter takes the permission back."
  busy "Telling EKKA" "$EK gate grant revoke $WRITE_GRANT_ID"
  [ "$RC" = 0 ] || { show_failure; say "      ${R}The permission could not be taken back.${N} Step 4 would prove nothing, so the kit stops here."; stop_walk; }
  ok "Permission taken back."
  WRITE_GRANT_ID=""; WRITE_INTENT=""; save_state
  vw authority orders_write "revoked"
fi
vw event "3. Cancel, then take back" "you" "cancel, then take the permission back" "allowed, then taken back" "$CANCEL_RESULT"
vw render

# ---- 4. The same order again: stopped
NEW_ID=$(new_client_id)
say ""; say "  ${Y}▶ Step 4 of 4. The AI's order once more, after you took the permission back.${N}"
say "      The same pick, as a brand-new order. EKKA should stop it."
AGAIN_CMD="$EK plan run $EXE_VER --input symbol=$VERDICT --input qty=$QTY --input limit_price=$LIMIT --input client_order_id=$NEW_ID"
runs "$AGAIN_CMD"
wait_enter "Enter sends the order."
busy "Sending the order" "$AGAIN_CMD"
if refused_by_ekka; then
  ok "EKKA stopped it. The permission is yours to give, and yours to take back."
  lookup "$NEW_ID"
  case "$LOOK" in
    absent) M4=passed; say "      ${B}Alpaca confirms: no order was placed.${N}" ;;
    found)  say "      ${R}Unexpected: an order with the new id exists.${N} Stop and look."; stop_walk ;;
    *)      M4=passed; say "      ${Y}Alpaca did not answer clearly.${N} EKKA's refusal stands on its own record." ;;
  esac
elif plan_completed; then
  say "      ${R}THE ORDER REACHED ALPACA AFTER YOU TOOK THE PERMISSION BACK.${N} That must never happen."
  say "      Cancel it in the paper dashboard ($NEW_ID) and report this run with the output above."
  stop_walk
else
  explain_failure; stop_walk
fi
vw event "4. Once more, no permission" "AI pick ($VERDICT), new id" "buy $VERDICT" "refused: permission taken back" "no such order"

# ---- the record
say ""; say "  ${Y}▶ The record.${N} While you watched, EKKA wrote down every step on this computer: what the AI"
say "      was asked, what it picked, each permission you gave and took back, each order sent or stopped."
say "      Each entry is locked to the one before it, so no one can change one without it showing."
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
case "${ORDER_OUTCOME:-}" in submitted|accepted) GONE="Alpaca accepted it" ;; rejected) GONE="Alpaca turned it down" ;; *) GONE="${ORDER_OUTCOME:-it was not sent}" ;; esac
say "  1. The AI picked ${B}$PICK_NAME${N}. It had no permission, so ${B}EKKA stopped its order.${N}"
say "  2. You gave it permission for $PERMIT. The same order went through: $GONE."
say "  3. You cancelled the order (Alpaca: $CANCEL_RESULT) and took the permission back."
say "  4. The same order once more: ${B}EKKA stopped it.${N}"
say ""
if [ "$VERIFY_RC" = 0 ]; then
say "  ${B}Trust${N}      Every step was written down and signed on this computer, and the record checks out."
else
say "  ${B}Trust${N}      ${R}The record did not check out,${N} so this walk is not proven. See above."
fi
say "  ${B}Security${N}   The AI's order went through only while you allowed it."
say "             Before and after, EKKA stopped it."
say "  ${B}Privacy${N}    Your Alpaca keys stayed on this computer and went only to Alpaca."
say "             ${B}EKKA NEVER SAW YOUR KEYS OR YOUR ACCOUNT.${N} EKKA only allowed or refused."
say "             The AI is a third-party model, not EKKA. It saw only the rule, the prices, and whether"
say "             you own either stock. Never your keys, never your account."
say "             ${B}Want your own model instead?${N} Add its API to your catalog the same way this kit added"
say "             Alpaca, and your agent calls it from this computer. Your prompts never leave your"
say "             network, and EKKA still only says yes or no."
say ""
say "  ${B}Good to know:${N} taking the permission back stops new orders. An order already placed stays"
say "  until you cancel it. That is why step 3 cancels first."
say ""
say "  ${B}Next${N}"
say "    See everything on one page     ${C}open .view/view.html${N}"
say "    Change the AI's rule           edit ${C}bin/prompt${N}, then run ${C}./open.sh${N} again"
say "    How it works                   ${C}./open.sh why${N}"
say "    Every command it ran           ${C}./open.sh commands${N}"
say "    The code                       ${C}$KIT_DOC${N}"
say ""
[ "$VERIFY_RC" = 0 ] || return 1
}

recover() {
  head_ "Inspect the saved attempt; do not submit it again"
  say "  Saved client order id: $CLIENT_ID. Saved outcome: ${ORDER_OUTCOME:-not-recorded} (${ORDER_BY:-})."
  lookup "$CLIENT_ID"
  case "$LOOK" in
    found) RP=$(out_path); [ -n "$RP" ] && show_run "bin/show-order $RP --client=$CLIENT_ID" ;;
    absent) say "  This lookup returned no such order. Keep the id; this alone does not justify resubmission." ;;
    *) say "  The lookup is unresolved. Check the paper dashboard using the saved client order id." ;;
  esac
  say "  This recovery mode creates no grant and submits no order or cancellation."
  [ -n "${CAN_VER:-}" ] && { cmd "$EK plan run $CAN_VER"; note "Only if this is still your open order and write access remains."; }
  [ -n "${WRITE_GRANT_ID:-}" ] && cmd "$EK gate grant revoke $WRITE_GRANT_ID"
  [ -n "${WRITE_INTENT:-}" ] && note "A write grant may remain. Inspect the list below and revoke only this Kit's write grant."
  cmd "$EK gate grant list --agent $AGENT"
  say "  Preserve .demo-state. When the order is final and write access is gone, ./open.sh steps starts fresh."
}

# ⛔ AN UNRESOLVED ATTEMPT IS NEVER REPLAYED, AND A FINISHED ONE IS NOT A PRISON.
# `unresolved` means: a write grant may still exist, or an order was submitted and its fate is
# not known. In that state every mode inspects and nothing is sent again. Once the order reads
# final (or none was ever placed) and the write grant is gone, the attempt is CLOSED and the
# walk can run again, with a NEW client order id, because reusing the old one is how a
# duplicate is born.
unresolved_attempt() {
  [ -n "${WRITE_INTENT:-}" ] && return 0
  [ -n "${ORDER_OUTCOME:-}" ] && [ -z "${ORDER_RESOLVED:-}" ] && return 0
  return 1
}

case "$MODE" in steps|setup) take_lock; trace "walk starts: $MODE" ;; esac
if [ -f "$STATE" ]; then
  . "$STATE"
  case "$MODE" in
    why) why ;;
    commands) commands ;;
    schedule) schedule ;;
    view) vw render; say "  $VIEWD/view.html" ;;
    steps|setup)
      if unresolved_attempt; then recover; exit 0; fi
      if [ "$MODE" = steps ]; then
        CLIENT_ID=$(new_client_id); ORDER_ID=''; ORDER_OUTCOME=''; ORDER_RESOLVED=''; ORDER_BY=''; WALK_STARTED=''; VERDICT=''
        save_state
        steps; exit 0
      fi
      # ./open.sh with nothing left open: a new walk, from the first screen, like the first time.
      rm -f "$STATE" ;;
    *) stop "Unknown mode: $MODE" "Use steps, why, commands, schedule or view." ;;
  esac
  [ -f "$STATE" ] && exit 0
fi
if [ "$MODE" != setup ]; then stop "No saved Kit setup exists." "Run ./open.sh first."; fi

# ================================================================ setup
command -v "$EKKA" >/dev/null 2>&1 || stop "EKKA is not installed." "Install it with the line in your email, then: ekka login --email you@example.com"
command -v python3 >/dev/null 2>&1 || stop "This machine is missing python3." "The kit reads a run's saved answer with it. On Debian or Ubuntu: apt-get install -y python3"
# ⛔ 0.1.88, NOT 0.1.87. This kit catalogues API rows in the person's OWN organization, so the
# resources are `apis/<org>/alpaca-*`. An Enclave before 0.1.88 refuses an owner-prefixed name
# with API_NAME_INVALID before any call.
FLOOR=0.1.88; KIT_VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo dev)
HAVE=$(run --version 2>/dev/null | awk 'NR==1{print $2}')
[ "$(printf '%s\n%s\n' "$FLOOR" "$HAVE" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$FLOOR" ] || stop "This kit needs EKKA $FLOOR or later; you have ${HAVE:-an unknown version}." "Run the install line again, then open a new terminal window."
run secret list >/dev/null 2>&1 || stop "Your Enclave is not running." "In your other window: ekka enclave start <id>"
GATES=$(run gate list 2>/dev/null || true)
# ⛔ THIS MACHINE'S Enclave, never the first one listed. An org with a laptop and a server has
# two, and the first in the list sent a kit box's calls to somebody's laptop (measured 2026-09-24).
[ -n "$ENCLAVE" ] || ENCLAVE=$(run whoami 2>/dev/null | sed -n 's/^ *enclave id  *\([0-9a-f]\{8\}\).*/\1/p' | head -1)
[ -n "$ENCLAVE" ] || stop "This machine is not an Enclave of your organization." "Start one here first: ekka enclave create --name \"this machine\", then ekka enclave start <id>"
AINST="enclave${ENCLAVE}Api"
printf '%s\n' "$GATES" | grep -q "api/$AINST" || stop "This machine's Enclave ($ENCLAVE) offers no api gate yet." "Is it running? In your other window: ekka enclave start <id>"
# The hosted model gate: the llm gate that names a url, and serves the model.
LLM=${LLM:-$(printf '%s\n' "$GATES" | awk -v m="$MODEL" '/^  [a-z]+\//{n=""; u=0} /^  llm\//{n=$1; next} n && /url/{u=1} n && u && index($0, m){sub("llm/","",n); print n; exit}')}
# A gate exists in an org because its admin registered it, EKKA's hosted one included. A new
# org has none, so the kit registers EKKA's hosted model gateway, after asking, below.
GATEWAY=${GATEWAY:-https://gateway.ekka.ai}
NEED_LLM_REG=""; [ -n "$LLM" ] || NEED_LLM_REG=1
ORG=$(run whoami 2>/dev/null | sed -n 's/.*Signed in as [^,]*, *\([^ ]*\) (.*/\1/p; s/^ *organization  *\([^ ]*\) (.*/\1/p' | head -1)
[ -n "$ORG" ] || stop "Could not read your organization name." "Check: ekka whoami"
API_ROW="$ORG/$ROW"; DATA_ROW="$ORG/$DROW"

[ -t 1 ] && clear 2>/dev/null || true
head_ "Let an AI trade for you. You decide what it may do."
say "  An AI looks at Apple and the S&P 500 and decides which one to buy."
say "  You give it permission to trade, for as long as you choose, and its order goes through."
say "  Take the permission back whenever you want, and it stops."
say ""
say "  ${B}Trust${N}      Every action is recorded and signed, so you can prove what happened."
say "  ${B}Security${N}   The AI can do only what you allowed, and only for as long as you allowed it."
say "  ${B}Privacy${N}    Your broker keys stay on this computer and go only to Alpaca."
say "             ${B}EKKA NEVER SEES YOUR KEYS OR YOUR ACCOUNT.${N} EKKA only allows or refuses."
say "             The AI is a third-party model, not EKKA. It never sees them either."
say ""
say "  ${B}Safe to try${N}"
say "    · Paper money only: Alpaca's practice account. No bank, no real money."
say "    · Your keys stay on this computer, encrypted."
say "    · Nothing is bought unless you have given permission."
say "    · The buying rule is an example, not advice."
say ""
say "  ${B}You need${N} your free Alpaca paper keys:"
say "    ${C}$ALPACA_KEYS${N}  >  Profile  >  Manage Accounts  >  Paper Accounts  >  API Keys"
say ""
say "  ${D}What gets set up, in detail:  ./open.sh why        kit $KIT_VERSION, EKKA $HAVE${N}"
say ""
ask "Ready? [y/N]"
case "$REPLY" in y|Y|yes|YES) ;; *) say ""; say "  Nothing was changed."; say ""; exit 0 ;; esac

# Setup runs quietly: a stranger needs to know THAT it worked, not how. The commands are all in
# ./open.sh commands and ./open.sh why. On any failure the real output is printed, in red.
head_ "Setting up"

# ---- the hosted model gate, when the org has not registered it
if [ -n "$NEED_LLM_REG" ]; then
  quiet "$EK gate register $GATEWAY"
  [ "$RC" = 0 ] || { show_failure; stop "EKKA's AI could not be connected to your organization." "Check: ekka gate list"; }
  LLM=$(run gate list 2>/dev/null | awk -v m="$MODEL" '/^  [a-z]+\//{n=""; u=0} /^  llm\//{n=$1; next} n && /url/{u=1} n && u && index($0, m){sub("llm/","",n); print n; exit}')
  [ -n "$LLM" ] || stop "The gateway registered, but no gate serving $MODEL appeared." "Check: ekka gate list"
  ok "Connected EKKA's AI to your organization."
fi

# ---- the catalog rows
LIST=$(run api list 2>/dev/null || true)
for pair in "$ROW:$API_ROW" "$DROW:$DATA_ROW"; do
  r=${pair%%:*}; name=${pair#*:}
  if ! printf '%s\n' "$LIST" | grep -qE "^\s*$name(\s|@)"; then
    sed "s#\"ekka/$r\"#\"$name\"#" "$HERE/catalog/ekka-$r.json" > "$OUTF"
    ADD_OUT=$(run api create "$OUTF" 2>&1) || stop "Could not add $name to your catalog." "$(printf '%s\n' "$ADD_OUT" | grep -vE '^\s*$' | head -3)"
  fi
done
need_connect() { ! printf '%s\n' "$LIST" | grep -E "^\s*$1(\s|@)" | grep -q "connected here"; }
if need_connect "$API_ROW" || need_connect "$DATA_ROW"; then
  # ---------------- ⛔ THE ONLY BLOCK THAT TOUCHES YOUR KEYS ----------------
  say "  Paste your two Alpaca paper keys. They stay hidden while you paste."
  TRIES=0
  while :; do
    printf "  ${Y}Key ID (starts with PK):${N} "
    stty -echo 2>/dev/null || true; read -r KID <&3 || KID=""; stty echo 2>/dev/null || true; say ""
    KID=$(printf '%s' "$KID" | tr -d ' \r\t')
    case "$KID" in
      AK*) say "  ${R}That is a key for REAL money.${N} This kit only takes paper keys. Nothing was stored." ;;
      PK*) if printf '%s' "$KID" | grep -qE '^PK[A-Za-z0-9]{8,}$'; then break; fi; say "  ${R}That does not look like a key id.${N}" ;;
      *)   say "  ${R}That does not look like a paper key id (it starts with PK).${N}" ;;
    esac
    TRIES=$((TRIES+1)); [ "$TRIES" -ge 3 ] && stop "Three tries. Nothing was stored." "Get the paper keys from $ALPACA_KEYS and run ./open.sh again."
  done
  printf "  ${Y}Secret key:${N} "
  stty -echo 2>/dev/null || true; read -r KSEC <&3 || KSEC=""; stty echo 2>/dev/null || true; say ""
  KSEC=$(printf '%s' "$KSEC" | tr -d ' \r\t')
  printf '%s' "$KSEC" | grep -qE '^[A-Za-z0-9_/+=-]{20,}$' || { KSEC=""; stop "That does not look like a secret key. Nothing was stored." "Copy it from $ALPACA_KEYS and run ./open.sh again."; }
  for name in "$API_ROW" "$DATA_ROW"; do
    need_connect "$name" || continue
    printf '%s:%s' "$KID" "$KSEC" | run api connect "$name" --stdin >/dev/null 2>&1 || { KSEC=""; KID=""; stop "The Enclave did not store the keys for $name." "Run it by hand to see why: ekka api connect $name"; }
  done
  KSEC=""; KID=""
  # ---------------- end of the block that touches your keys ----------------
  ok "Your keys are stored on this computer, encrypted. The AI cannot see them."
  note "They are yours alone: never share them, even with a colleague running this kit."
else
  ok "Your keys are already stored on this computer."
fi

# ---- the agent, its plans as files, and its three standing grants
item_start "Created your AI agent"
AG_OUT=$(run agent create "$AGENT" --name "Trading Agent" 2>&1) || true
if printf '%s\n' "$AG_OUT" | grep -qiE "already|exists"; then
  # ⛔ AN OLD WRITE GRANT WOULD SPOIL MOMENT 2, and nothing else about an existing agent does.
  EXISTING_GRANTS=$(run gate grant list --agent "$AGENT" 2>&1) || stop \
    "Could not check this agent's existing grants." "Run ekka gate grant list --agent $AGENT and resolve the error before continuing."
  if printf '%s\n' "$EXISTING_GRANTS" | grep -F "apis/$API_ROW" | grep -q "api.write"; then
    stop "The agent ${AGENT} already holds write access on $API_ROW, so step 1's refusal would prove nothing." \
         "Revoke it (ekka gate grant list --agent $AGENT, then revoke its id), or run with AGENT=<a-new-name> ./open.sh."
  fi
  :
elif printf '%s\n' "$AG_OUT" | grep -q "✓"; then
  :
elif printf '%s\n' "$AG_OUT" | grep -qiE "waiting to be approved|org.agents: 0"; then
  stop "Your organization is not let in yet, so it cannot have an agent." "Reply to the email you were sent and say your organization name ($ORG). Then run ./open.sh again."
else
  stop "Could not create the agent $AGENT." "$(printf '%s\n' "$AG_OUT" | grep -vE '^\s*$' | head -3)"
fi

item_done
"$HERE/bin/write-plans" "$HERE" "$AGENT" "$AINST" "$LLM" "$API_ROW" "$DATA_ROW" "$MODEL" >/dev/null
item_start "Saved its plan: read prices";                         create_plan "$HERE/trade.market.json" trade.market; MKT_VER=$V; item_done
item_start "Saved its plan: read your paper account";             create_plan "$HERE/trade.account.json" trade.account; ACC_VER=$V; item_done
item_start "Saved its plan: see what you own";                    create_plan "$HERE/trade.positions.json" trade.positions; POS_VER=$V; item_done
item_start "Saved its plan: look up its own order";               create_plan "$HERE/trade.status.json" trade.status; STA_VER=$V; item_done
item_start "Saved its plan: pick what to buy, then buy it";       create_plan "$HERE/trade.decide.json" trade.decide; DEC_VER=$V; item_done
item_start "Saved its plan: send its pick again as an order";     create_plan "$HERE/trade.execute.json" trade.execute; EXE_VER=$V; item_done
item_start "Saved its plan: look and pick only, never buy";       create_plan "$HERE/trade.analyze.json" trade.analyze; ANA_VER=$V; item_done
CAN_VER=""   # written in moment 4, when there is an order to name

grant() {  # label type instance resource capability words
  item_start "$1"; shift
  quiet "$EK gate grant add --agent $AGENT --type $1 --instance $2 --resource $3 --capability $4${5:+ $5}"
  [ "$RC" = 0 ] || grep -qiE "already|exists" "$OUTF" || { spin_stop; show_failure; say "      ${R}The grant was not created.${N} The red lines above name the reason."; stop_walk; }
  item_done
}
grant "Allowed it to read prices"              api "$AINST" "apis/$DATA_ROW" api.read --no-fingerprint
grant "Allowed it to read your paper account"  api "$AINST" "apis/$API_ROW" api.read --no-fingerprint
grant "Allowed it to ask the AI"               llm "$LLM" "$MODEL" llm.infer ""
ok "Your AI agent is ready. It may NOT place an order. Only you can allow that, in step 2."

QTY=${QTY:-1}
printf '%s' "$QTY" | grep -qE '^[1-9][0-9]{0,3}$' || stop "QTY must be a whole number from 1 to 9999." "Run ./open.sh again."
CLIENT_ID=$(new_client_id)
LIMIT_AAPL=pending; LIMIT_SPY=pending
save_state
# The limit is about 10% under the last close, from the governed market read, so the order
# should sit open long enough to cancel. It may still fill; moment 4 reads what happened.
START=$(python3 -c 'import datetime;print((datetime.date.today()-datetime.timedelta(days=21)).isoformat())')
busy "Getting today's prices" "$EK plan run $MKT_VER --input start=$START"
if ! plan_completed; then
  show_failure
  # Two servers, one key pair. If prices are refused, ask the paper server, so the person is
  # told which of the two said no instead of being told their keys are wrong.
  if grep -qE "401|Authorization Required" "$OUTF"; then
    quiet "$EK plan run $ACC_VER"
    if plan_completed; then
      stop "The paper server accepted your keys and the market data server refused the same sign-in." \
           "Your keys are fine. Tell us (reply to your email): the market data row's sign-in needs a change on our side."
    fi
  fi
  explain_failure; stop_walk
fi
# Each symbol's limit is about 10% under its last close, so an order should sit open long enough
# to cancel. It may still fill; step 3 reads what happened.
lim() { python3 -c 'import json,sys;b=json.load(open(sys.argv[1]))["body"]["bars"][sys.argv[2]];print("%.2f"%(sorted(b,key=lambda x:x["t"])[-1]["c"]*0.9))' "$1" "$2" 2>/dev/null || true; }
BARS_FILE=$(out_path); LIMIT_AAPL=$(lim "$BARS_FILE" AAPL); LIMIT_SPY=$(lim "$BARS_FILE" SPY)
for v in "$LIMIT_AAPL" "$LIMIT_SPY"; do
  printf '%s' "$v" | grep -qE '^[0-9]+\.[0-9]{2}$' || stop "The market read did not give a price to set the limit from." "Check the output above, then run ./open.sh again."
done
ok "Prices are coming in. Whatever the AI picks, it will offer $QTY share,"
say "    about 10% under today's price."
save_state
steps
