#!/bin/sh
# EKKA wallet agent. Sets up one real AI agent in your own organization, then runs three steps in
# front of you and explains each one.
# It touches your key exactly once: reads it at a hidden prompt, checks the shape, hands it to the
# Enclave, forgets it. Everything else here is plans, grants and explanations. Read it first if you like.
set -eu

EKKA=${EKKA:-ekka}
EKKA_FLAG=${EKKA_FLAG:-}
AGENT=${AGENT:-wallet-agent}
KEY=${KEY:-SEPOLIA_WALLET_KEY}
ENCLAVE=${ENCLAVE:-}
ROW=eth-balance-sepolia                    # the one website, described in catalog/ekka-$ROW.json
NETNAME="Sepolia test network"
BALANCE_SITE=https://eth-sepolia.blockscout.com
FAUCET=https://cloud.google.com/application/web3/faucet/ethereum/sepolia
DOCS=https://docs.ekka.ai
KIT_DOC=$DOCS/kits/wallet-agent/
SIGN_PAGE=${SIGN_PAGE:-$DOCS/kits/wallet-agent/sign.html}   # the same file as sign.html here, hosted so the link is clickable
HERE=$(cd "$(dirname "$0")" && pwd)
STATE="$HERE/.demo-state"
MODE=${1:-setup}                # setup (default) | steps | commands | try | why

# ---------------------------------------------------------------- colors, only on a terminal
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$(printf '\033[1m'); D=$(printf '\033[2m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); C=$(printf '\033[36m'); N=$(printf '\033[0m')
else
  B=""; D=""; G=""; Y=""; R=""; C=""; N=""
fi
# Text rolls out one line at a time, so a change on screen is seen as it happens. ROLL=0 turns it off.
ROLL=${ROLL:-0.04}
say()   { printf '%s\n' "$*"; [ "$ROLL" = 0 ] || sleep "$ROLL"; }
head_() { say ""; say "  ${B}$1${N}"; say "  ${D}$(printf '%*s' "${#1}" '' | tr ' ' '-')${N}"; }
ok()    { say "  ${G}✔${N} $*"; }
note()  { say "      ${D}$*${N}"; }
cmd()   { say "      ${C}$*${N}"; }
learn() { say "      ${D}Learn more:${N} ${C}$*${N}"; }
stop()  { say ""; say "  ${R}✖ Stopped.${N} $1"; say "    $2"; say ""; exit 1; }
run()   { $EKKA $EKKA_FLAG "$@"; }
# Answers come from the terminal, opened once as fd 3. OPEN_SH_INPUT=<file> rehearses the
# script itself with canned answers.
if [ -n "${OPEN_SH_INPUT:-}" ]; then exec 3<"$OPEN_SH_INPUT"
elif ( : </dev/tty ) 2>/dev/null; then exec 3</dev/tty
else exec 3</dev/null; fi
ask()   { printf "  ${Y}%s${N} " "$1"; read -r REPLY <&3 || REPLY=""; }
wait_enter() { printf "  ${Y}%s${N} " "$1"; read -r REPLY <&3 || REPLY=q; case "$REPLY" in q|Q) say ""; say "  Stopped. Pick up again with: ./open.sh steps"; say ""; exit 0 ;; esac; }
OUTF=$(mktemp); trap 'rm -f "$OUTF" "$OUTF.rc"' EXIT

# Output streams to the screen as it happens (a run can take a while; a silent screen looks
# hung) and is kept in $OUTF for the explanation that follows.
show_run() {
  say ""
  say "      ${D}──── running ─────────────────────────────────────────────────────────────${N}"
  RC=0
  { sh -c "$1" 2>&1; echo "$?" >"$OUTF.rc"; } | tee "$OUTF" | while IFS= read -r line; do
    case "$line" in
      "") say "" ;;
      ✓*) say "      ${G}$line${N}" ;;
      *✗*|*refused*|*failed*|*denied*|*DENIED*|*ERROR*|*error*|*expired*) say "      ${R}$line${N}" ;;
      *) say "      $line" ;;
    esac
  done
  RC=$(cat "$OUTF.rc" 2>/dev/null || echo 0)
  say "      ${D}──── done ────────────────────────────────────────────────────────────────${N}"
  say ""
}

# When a run did not complete, say the next thing to do in plain words.
explain_failure() {
  say "      ${R}The plan did not run.${N}"
  if grep -q "session expired" "$OUTF"; then
    say "      Your sign-in on this machine expired (it renews itself; this time it could not). Sign in"
    say "      again, then come back:   ${C}ekka login --email <your email>${N}   then   ${C}./open.sh steps${N}"
  elif grep -q "credit_exhausted" "$OUTF"; then
    say "      Your organization has no EKKA credit yet. Reply to the email you were sent and name"
    say "      your organization (${B}$ORG${N}); it is one command on our side. Then ${C}./open.sh steps${N}"
  elif grep -qE "GOVERN_HTTP_ERROR|50[234]" "$OUTF"; then
    say "      EKKA's server did not answer in time. Nothing ran. Wait a minute and try again:"
    cmd "./open.sh steps"
  else
    say "      The red line above names the reason. Fix it, then run the steps again:  ${C}./open.sh steps${N}"
  fi
  say "      ${D}The attempt is on a signed record like everything else: ekka receipts list${N}"
}

# A grant, one field per line, each one explained. What runs is the one-line form; this is the reading form.
explain_grant() {  # type instance resource capability what-it-means [ttl]
  g() { printf "        ${C}%-13s %-40s${N} ${D}%s${N}\n" "$1" "$2" "$3"; [ "$ROLL" = 0 ] || sleep "$ROLL"; }
  say "      ${C}ekka gate grant add \\${N}"
  g "--agent"      "$AGENT" "who: the agent this permission belongs to"
  g "--type"       "$1"     "which kind of gate: $( [ "$1" = api ] && echo "a website call" || echo "the vault" )"
  g "--instance"   "$2"     "where: that gate on your Enclave, and no other machine"
  g "--resource"   "$3"     "what: $5"
  g "--capability" "$4"     "which action: $( [ "$4" = api.read ] && echo "read. Not write, not delete" || echo "sign 32 bytes. Not read, not export" )"
  [ -n "${6:-}" ] && g "--ttl" "$6" "for how long: $6 seconds, then it is gone by itself"
  g "--no-fingerprint" "" "do not pin this to one version of the resource's description; it is yours and read-only"
}

# A step: title, what is about to happen, the exact line. Enter runs it. s skips, q stops.
step() {
  say ""; say "  ${Y}▶ $1${N}"; shift
  while [ $# -gt 1 ]; do say "      $1"; shift; done
  cmd "$1"
  printf "  ${Y}Enter runs it. s skips it, q stops here.${N} "
  read -r REPLY <&3 || REPLY=q; printf "\r%60s\r" ""
  case "$REPLY" in q|Q) say ""; say "  Stopped. Pick up again with: ./open.sh steps"; say ""; exit 0 ;; s|S) return 1 ;; esac
  show_run "$1"
}

# The balance of one address, read straight from the public website (no agent, no EKKA). Prints
# the figure in ETH, "0" for an address the network has never seen, or "?" if the site is unreachable.
site_balance() {
  command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "?"; return; }
  curl -fsS -m 15 "$BALANCE_SITE/api/v2/addresses/$1" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin); raw = d.get("coin_balance")
    print("0" if raw is None else f"{int(raw) / 1e18:.6f}")
except Exception:
    print("?")' 2>/dev/null || echo "?"
}

faucet_help() {
  say "      Test ETH is free. One minute:"
  say "      1. Open ${C}$FAUCET${N}"
  say "      2. Sign in with a Google account, paste your address, click ${B}Receive 0.05 Sepolia ETH${N}."
  say "      3. Wait about a minute. MetaMask shows 0.05 SepoliaETH on that account."
  say "      ${D}If Google refuses (daily quota): https://www.alchemy.com/faucets/ethereum-sepolia${N}"
  learn "$KIT_DOC#test-eth"
}

# Pull a field out of a run's saved output file (the path `plan run` prints).
field_of() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null || true; }

why() {
head_ "Questions people ask at this point, and how to check the answer yourself"
say "  ${B}Where is my key?${N}  Encrypted, inside your Enclave, in ~/.ekka/vault. Look: the file names"
say "  are scrambled and the contents are unreadable. No command prints it back."
say ""
say "  ${B}What can the agent reach on the internet?${N}  One public website that reports wallet"
say "  balances, read only. See exactly what it offers: ${C}ekka api describe $API_ROW${N}"
say ""
say "  ${B}Can it read a different wallet?${N}  No. The plan names your wallet as a fixed value and has"
say "  no input for another. Read it: ${C}cat $HERE/wallet.balance.json${N}"
say ""
say "  ${B}Can the agent give itself permission?${N}  Only your signed-in session can grant. In this"
say "  walkthrough you type the agent's lines yourself; to see the agent locked out, run it as its"
say "  own user on this machine (What else to try, item 1). It cannot read your session."
say ""
say "  ${B}What does EKKA's server see?${N}  That a step ran, on which key or website, allowed or"
say "  refused, and a fingerprint of the result. Never your key, your balance or a signature."
say ""
say "  ${B}What if I edit a plan?${N}  A plan is a version, frozen when created. Editing makes a new"
say "  version, which starts with no grant."
say ""
learn "$KIT_DOC"
say ""
}

try_more() {
head_ "What else to try"
say "  1. Give the agent its own user and hand it the lines: ${C}sudo useradd -m agent${N}, then as agent"
say "     run ${C}./open.sh commands${N}. It cannot read your session: every grant attempt says not signed in."
say "  2. Turn wifi off, ${C}ekka receipts verify${N}: every record checks out with no server at all."
say "  3. Point the agent at another wallet: ${C}ekka plan run $BAL_VER --input address=0x…${N}"
say "     Your wallet comes back. The plan has no such input; read it: ${C}cat $HERE/wallet.balance.json${N}"
say "  4. Change one character in wallet.balance.json, ${C}ekka plan create $HERE/wallet.balance.json${N}:"
say "     a new version, with no grant. Refused until you allow it."
say "  5. Hand ${C}./open.sh commands${N} to your own AI and tell it to get the money. Read the trail:"
say "     ${C}ekka receipts list${N}"
say "  6. ${C}ekka secret list${N}, then ${C}ls ~/.ekka/vault${N}: the key's name, and scrambled files."
learn "$KIT_DOC#what-else-to-try"
say ""
}

yours() {
head_ "This agent is yours"
say "  ${B}$AGENT${N} lives in your organization. Its two plans are the files you just read."
say "  Add a third: copy wallet.balance.json, point it at any website with an API, create it."
say "  The new version starts with no grant. It is refused until you allow it, as in step 2."
say "  When it is good, ${C}ekka agent publish $AGENT${N} lets other organizations install it;"
say "  they see every permission it asks for before they say yes."
learn "$DOCS/connect/your-own-api/"
say ""
say "  ${D}Reprint: ./open.sh steps (run again)  ./open.sh try  ./open.sh why  ./open.sh commands${N}"
say ""
}

commands() {
head_ "The lines, to run by hand or hand to your AI"
cmd "$BAL_GRANT"
cmd "ekka plan run $BAL_VER"
cmd "$HERE/bin/show-balance"
cmd "ekka plan run $SIG_VER --input digest=<64 hex characters> --input alg=secp256k1"
cmd "ekka receipts verify"
say ""
say "  To move money, as the human (the grant lasts ten minutes):"
cmd "$SIG_GRANT"
cmd "$SIGN_PAGE?plan=$SIG_VER&address=$ADDRESS&to=$ADDRESS"
cmd "ekka gate grant list      then      ekka gate grant revoke <id>"
say ""
}

# ---------------------------------------------------------------- the three steps
steps() {
head_ "Three steps"
say "  Each one shows the exact line before it runs. ${B}This script runs it${N}, shows the real output,"
say "  then says what happened. ${D}s skips a step, q stops. In this walkthrough you type the agent's${N}"
say "  ${D}lines yourself; the permission check is the same either way.${N}"

# ---- 1 allow one read, the agent reads
say ""; say "  ${Y}▶ 1. You allow one thing. The agent reads the balance.${N}"
say "      A grant is one row with a few fields. Read this one field by field; it says:"
say "      ${B}$AGENT${N} may ${B}read${N} ${B}apis/$API_ROW${N}, on your Enclave. Nothing else."
explain_grant api "$AINST" "apis/$API_ROW" api.read "one website in your organization's catalog, the balance site"
printf "  ${Y}Enter runs it. s skips it, q stops here.${N} "
read -r REPLY <&3 || REPLY=q; printf "\r%60s\r" ""
case "$REPLY" in q|Q) say ""; say "  Stopped. Pick up again with: ./open.sh steps"; say ""; exit 0 ;; esac
if [ "$REPLY" != s ] && [ "$REPLY" != S ]; then
  show_run "$BAL_GRANT"
  say "      ${B}Allowed.${N} One row on EKKA's server. When ${B}$AGENT${N} asks for this one thing the"
  say "      answer is yes; for anything else it is still no."
  say ""
  say "      Now the agent runs its plan: read the balance of ${B}$SHORT${N} from the website."
  cmd "ekka plan run $BAL_VER"
  wait_enter "Enter runs it."
  show_run "ekka plan run $BAL_VER"
  OUT_PATH=$(grep -oE 'output is at .*' "$OUTF" | sed 's/output is at //' | head -1 || true)
  if grep -q "✓ Plan completed" "$OUTF"; then
    say "      ${B}The agent read your balance:${N}"
    show_run "$HERE/bin/show-balance ${OUT_PATH:-}"
    say "      ${B}What happened:${N} the agent asked to run the plan; EKKA's server checked the grant and"
    say "      said yes; the Enclave on this machine called the website; the answer was saved here, in"
    say "      the file named above. That is the whole run."
    say "      ${D}Privacy, separately: EKKA's server saw that the step ran, the website it used, and a${N}"
    say "      ${D}fingerprint of the answer (the Content hash line). The number itself stayed here.${N}"
  else
    explain_failure
  fi
  learn "$DOCS/how-governance-works/#what-happens-when-an-agent-acts"
fi

# ---- 2 sign refused
if step "2. The agent asks the Enclave to sign. Nobody has allowed this." \
  "The second plan asks the Enclave to sign with the key in your vault. There is no grant for it." \
  "Watch where it stops." \
  "ekka plan run $SIG_VER --input digest=7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069 --input alg=secp256k1"; then
  if grep -q RESOURCE_GRANT_DENIED "$OUTF"; then
    say "      ${B}Refused.${N} The part that matters in the red text: ${B}no Grant covers keys/$KEY (sign)${N}."
    say "      EKKA's server refused ${B}before${N} the request reached this machine. The Enclave never"
    say "      saw it; the key was never touched. The refusal itself is now on a signed record."
    say "      Notice it prints the exact grant line an admin would need. The agent can read that line;"
    say "      it cannot run it. Only your signed-in session can grant."
  else
    say "      ${R}Unexpected.${N} This should have been refused with RESOURCE_GRANT_DENIED. Check:"
    cmd "ekka gate grant list"
  fi
  learn "$DOCS/security/#how-does-ekka-stop-an-agent-before-it-acts"
fi

# ---- 3 the human moves money, then takes the permission back
say ""; say "  ${Y}▶ 3. You allow signing, sign once, take it back.${N}"
say ""
say "      This is the step that moves test ETH. Five small parts, each explained as it comes:"
say "      ${D}3a allow  ·  3b build the transaction on a web page  ·  3c the Enclave signs it${N}"
say "      ${D}3d send it  ·  3e take the permission back, check the records${N}"
say ""
say "  ${Y}3a. Allow signing, for ten minutes.${N}"
say "      The permission covers exactly one thing: sign with ${B}keys/$KEY${N}. It expires by itself."
explain_grant secret "$SINST" "keys/$KEY" secret.vault.sign "one named key in your vault; the key itself is never read" 600
wait_enter "Enter runs it. q stops here."
show_run "$SIG_GRANT"
SIG_GRANT_ID=$(grep -oE '[gG]rant [0-9a-f-]{8,}' "$OUTF" | head -1 | cut -d' ' -f2 || true)
if [ "$RC" != 0 ]; then
  say "      ${R}The grant was not created.${N} Read the red line above, then ${C}./open.sh steps${N}"
else
  say "      ${B}Allowed, for ten minutes.${N}"
  say ""
  say "  ${Y}3b. Build the transaction, on a web page.${N}"
  say ""
  say "      A transaction is a short note to the network: ${B}from${N} this address, ${B}to${N} that address,"
  say "      ${B}this much${N}, plus a fee. Unsigned, it is just a note; the network ignores it. The page builds"
  say "      the note for you. It uses only public information and never asks for a key."
  say ""
  say "      Open this link:"
  cmd "$SIGN_PAGE?plan=$SIG_VER&address=$ADDRESS&to=$ADDRESS"
  note "It is the same file as sign.html in this folder; open that one instead if you prefer to read it first."
  say ""
  say "      On the page, in order:"
  say "        1. ${B}Read balance${N}: your address is filled in; it shows the test ETH you have."
  say "        2. ${B}Build unsigned transaction${N}: it sends 0.001 test ETH to your own address, so nothing is"
  say "           lost but the fee. The black box shows the note, and on its last line a ${B}digest${N}."
  say ""
  say "      ${B}The digest${N} is a fingerprint of that note: from, to, amount, fee, network, boiled down to 64"
  say "      characters. Change one detail and the digest changes. It is what the Enclave will sign."
  say ""
  DIGEST=""
  while :; do
    ask "Paste the digest (the 64 characters on the line marked digest; empty skips):"
    DIGEST=$(printf '%s' "$REPLY" | tr -d ' \r\t'); case "$DIGEST" in 0x*|0X*) DIGEST=${DIGEST#??} ;; esac
    printf '%s' "$DIGEST" | grep -qE '^[0-9a-fA-F]{64}$' && break
    [ -z "$DIGEST" ] && { say "      Skipping the signing part."; break; }
    if printf '%s' "$DIGEST" | grep -qE '^[0-9a-fA-F]{40}$'; then
      say "      ${R}That is an address (40 characters).${N} The digest appears on the page only after you click"
      say "      ${B}Build unsigned transaction${N}: the last line of the black box, starting with ${B}digest${N}, 64 characters."
    else
      say "      ${R}Not a digest.${N} 64 hex characters, from the line marked digest on the page. Empty skips."
    fi
  done
  if [ -n "$DIGEST" ]; then
    SIGN_CMD="ekka plan run $SIG_VER --input digest=$DIGEST --input alg=secp256k1"
    say ""
    say "  ${Y}3c. The Enclave signs it.${N}"
    say ""
    say "      Signing means: take those 64 characters and your key, and produce a ${B}signature${N} that only"
    say "      that key could have made. The key stays inside the Enclave the whole time. The plan hands in"
    say "      the digest; the Enclave hands back the signature; nobody, including this script, sees the key."
    say ""
    say "      Same plan as step 2. This time a grant exists, for ten minutes."
    cmd "$SIGN_CMD"
    wait_enter "Enter runs it."
    show_run "$SIGN_CMD"
    OUT_PATH=$(grep -oE 'output is at .*' "$OUTF" | sed 's/output is at //' | head -1 || true)
    if grep -q "✓ Plan completed" "$OUTF" && [ -n "$OUT_PATH" ]; then
      SIG=$(field_of "$OUT_PATH" signature); RID=$(field_of "$OUT_PATH" recovery_id)
      say "      ${B}Signed inside the Enclave.${N} Two values came back:"
      say ""
      say "        signature    ${C}${SIG:-see $OUT_PATH}${N}"
      say "        recovery_id  ${C}${RID:-see $OUT_PATH}${N}"
      say ""
      say "      The ${B}signature${N} is the proof. The ${B}recovery_id${N} is one extra digit the network uses to work out"
      say "      which address signed. Neither one reveals the key."
      say ""
      say "  ${Y}3d. Send it.${N}"
      say ""
      say "      Back on the page: paste the two values into their boxes, then ${B}Assemble and broadcast${N}."
      say "      The page first checks that the signature really belongs to your address. Then it hands the"
      say "      signed note to the network. In about 15 seconds it shows ${B}confirmed${N} and a link you can open."
      say ""
      wait_enter "Press Enter when the page says confirmed (or to move on)."
      say ""
      say "      ${B}What just happened:${N} you allowed one verb on one key for ten minutes; the plan asked; the"
      say "      Enclave signed 64 characters and returned a signature; the page sent it. The key never left"
      say "      the Enclave. EKKA's server saw only: a sign step ran on keys/$KEY, and a fingerprint."
    else
      explain_failure
    fi
  fi
  say ""
  say "  ${Y}3e. Take the permission back, then check the records.${N}"
  say ""
  say "      The grant would expire on its own in ten minutes. Take it back now, so you see the switch:"
  REVOKE_CMD="ekka gate grant revoke ${SIG_GRANT_ID:-<id from: ekka gate grant list>}"
  cmd "$REVOKE_CMD"
  wait_enter "Enter runs it."
  show_run "$REVOKE_CMD"
  say "      Now the same sign request as before, one more time:"
  RERUN="ekka plan run $SIG_VER --input digest=${DIGEST:-7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069} --input alg=secp256k1"
  cmd "$RERUN"
  wait_enter "Enter runs it."
  show_run "$RERUN"
  if grep -q RESOURCE_GRANT_DENIED "$OUTF"; then
    say "      ${B}Refused again.${N} The permission was a switch, and you own it."
  fi
  say ""
  say "      Last thing. ${B}Turn wifi off now.${N} Every step you just took, allowed or refused, left a"
  say "      signed record on this machine. This checks all of them and asks EKKA nothing:"
  cmd "ekka receipts verify"
  wait_enter "Wifi off? Enter runs it."
  show_run "ekka receipts verify"
  if [ "$RC" = 0 ]; then
    say "      ${B}What happened:${N} each record is signed and points at the one before it. The ones signed by"
    say "      this machine's Enclave are the steps that ran here; the rest were signed by EKKA's server,"
    say "      the refusals among them. Change one, delete one, add one: the check fails. Wifi back on."
  fi
  learn "$DOCS/receipts/#how-do-i-verify-it-myself"
  say ""
  say "      ${B}One more thing: nobody wrote code for any of this.${N} The agent is a name. Its two plans are"
  say "      the two JSON files you read before step 1. Each permission was one row you added and one you"
  say "      took away. Every rule you watched hold was declared, not programmed, and every attempt to"
  say "      break it was refused by EKKA's server before it reached this machine. That is the product."
fi

try_more
yours
}

# ---------------------------------------------------------------- reprint on demand
if [ "$MODE" = steps ] || [ "$MODE" = why ] || [ "$MODE" = commands ] || [ "$MODE" = try ]; then
  [ -f "$STATE" ] || { say ""; say "  Run ./open.sh once first; there is nothing to show yet."; say ""; exit 1; }
  . "$STATE"
  API_ROW=${API_ROW:-your-org/$ROW}; ORG=${ORG:-${API_ROW%%/*}}
  case "$MODE" in why) why ;; commands) commands ;; try) try_more ;; steps) steps ;; esac
  exit 0
fi

# ---------------------------------------------------------------- checks before anything is touched
command -v "$EKKA" >/dev/null 2>&1 || stop "EKKA is not installed." "Install it with the line in your email, then: ekka login --email you@example.com"
# This kit version needs a runner that has the secret gate's sign op (0.1.87).
FLOOR=0.1.87; KIT_VERSION=$(cat "$HERE/VERSION" 2>/dev/null || echo dev)
HAVE=$(run --version 2>/dev/null | awk 'NR==1{print $2}')
[ "$(printf '%s\n%s\n' "$FLOOR" "$HAVE" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$FLOOR" ] || stop "This kit needs EKKA $FLOOR or later; you have ${HAVE:-an unknown version}." "Run the install line again, then open a new terminal window."
run secret list >/dev/null 2>&1 || stop "Your Enclave is not running." "In your other window: ekka enclave start <id>"
HAVE_KEY=0; run secret list 2>/dev/null | grep -q "$KEY" && HAVE_KEY=1

# which gates are ours
if [ -n "$ENCLAVE" ]; then AINST="enclave${ENCLAVE}Api"; SINST="enclave${ENCLAVE}Secret"
else
  AINST=$(run gate list 2>/dev/null | grep -oE 'enclave[0-9a-f]{8}Api' | head -1 || true)
  SINST=$(run gate list 2>/dev/null | grep -oE 'enclave[0-9a-f]{8}Secret' | head -1 || true)
  [ -z "$AINST" ] && stop "Could not find your Enclave's gates." "Rerun with ENCLAVE=<the 8-character id from: ekka enclave list>"
fi
SGATE="secret/$SINST"

# who you are, so every "check it yourself" line below names your real organization
# 0.1.87 prints "Signed in as <email>, <org> (owner)."; older builds print an "organization <org>" line.
ORG=$(run whoami 2>/dev/null | sed -n 's/.*Signed in as [^,]*, *\([^ ]*\) (.*/\1/p; s/^ *organization  *\([^ ]*\) (.*/\1/p' | head -1)
[ -n "$ORG" ] || stop "Could not read your organization name." "Check: ekka whoami"
API_ROW="$ORG/$ROW"

# ---------------------------------------------------------------- what this is
[ -t 1 ] && clear 2>/dev/null || true
say ""
say "  ${B}EKKA · Your wallet agent${N}"
say "  ${D}An AI agent gets your test wallet's key. Watch what it can do.${N}"
say ""
say "  1. You allow one thing: read the balance. The agent reads it."
say "  2. The agent asks to sign. Refused before it reaches this machine."
say "  3. You allow signing for ten minutes, sign once, take it back. Refused again."
say "  Every attempt, allowed or refused, lands in a signed record you check with wifi off."
head_ "Your key"
say "  Pasted once at a hidden prompt, encrypted inside the Enclave on this machine."
say "  ${B}No command prints it back. Not the agent's, not EKKA's, not yours.${N}"
say "  What leaves this machine: that a step ran, and a fingerprint of the result."
say "  Your key, your balance and every signature stay here."
say ""
say "  ${NETNAME} only. Test ETH from a faucet, nothing at stake. ${D}$KIT_DOC${N}"
say ""
ask "Continue? [y/N]"
case "$REPLY" in y|Y|yes|YES) ;; *) say ""; say "  Nothing was changed."; say ""; exit 0 ;; esac

head_ "Your wallet's private key goes into the vault"
if [ "$HAVE_KEY" = 1 ]; then
  ok "The vault already holds a key named ${B}$KEY${N}. You put it there earlier; nothing to do."
  say "      Only the name is visible, to you or anyone:  ${C}ekka secret list${N}"
else
  say "  Have the private key of your Sepolia test wallet ready (in MetaMask: the account's three dots,"
  say "  Account details, Show private key). A throwaway account, funded from a faucet, nothing at stake."
  say ""
  say "  ${B}What happens:${N} this script asks for the key at a prompt that shows nothing as you paste."
  say "  It checks only the shape (64 hex characters), hands it to the Enclave, and forgets it."
  say "  The Enclave encrypts it and stores it under the name ${B}$KEY${N}. From then on no command"
  say "  prints it back. Never written to disk in the clear, to shell history, or to a command line."
  say ""
  TRIES=0
  while :; do
    printf "  ${Y}Private key of your Sepolia test wallet (hidden as you paste):${N} "
    stty -echo 2>/dev/null || true; read -r K <&3 || K=""; stty echo 2>/dev/null || true; say ""
    K=$(printf '%s' "$K" | tr -d ' \r\t'); case "$K" in 0x*|0X*) K=${K#??} ;; esac
    if printf '%s' "$K" | grep -qE '^[0-9a-fA-F]{64}$'; then break; fi
    TRIES=$((TRIES+1))
    if printf '%s' "$K" | grep -qE '^[0-9a-fA-F]{40}$'; then
      say "  ${R}That is the wallet's address, the public half (40 characters).${N} The private key is 64"
      say "  characters. In MetaMask: the account's three dots, Account details, Show private key."
    else
      say "  ${R}Not a private key.${N} Expected 64 hex characters (0-9, a-f), with or without 0x in front."
    fi
    [ "$TRIES" -ge 3 ] && stop "Three tries. Nothing was stored." "Find the key in MetaMask (Account details, Show private key) and run ./open.sh again."
  done
  printf '%s' "$K" | run secret put "$KEY" --stdin >/dev/null || { K=""; stop "The Enclave did not store the key." "Is it running? In your other window: ekka enclave list"; }
  K=""
  ok "Stored. Check what is visible, the name and nothing else:"
  show_run "ekka secret list"
fi

say ""
say "  Now the ${B}public${N} half: the wallet's address, the string people send test ETH to."
say "  The plan will name it, so the agent reads that balance and no other."
ask "Your Sepolia wallet address (starts with 0x):"
ADDRESS=$(printf '%s' "$REPLY" | tr -d ' \r\t')
if printf '%s' "$ADDRESS" | grep -qE '^(0x)?[0-9a-fA-F]{64}$'; then
  stop "That is a PRIVATE key, and it was just shown on this screen. Treat that wallet as burned." "Make a new account in MetaMask, then run ./open.sh again and paste its ADDRESS here (0x and 40 characters)."
fi
printf '%s' "$ADDRESS" | grep -qE '^0x[0-9a-fA-F]{40}$' || stop "That does not look like a wallet address (0x followed by 40 hex characters)." "Copy it from MetaMask: the copy icon next to the account name. Nothing was changed."
SHORT="$(printf '%s' "$ADDRESS" | cut -c1-6)…$(printf '%s' "$ADDRESS" | rev | cut -c1-4 | rev)"

# ---------------------------------------------------------------- is there test ETH in it?
head_ "Is there test ETH in it?"
say "  Step 3 moves a little of it, so the wallet needs some first. Asking the public website"
say "  directly (no agent, no EKKA involved):"
while :; do
  BAL=$(site_balance "$ADDRESS")
  case "$BAL" in
    "?") say "  ${Y}Could not reach the website just now.${N} Continuing; step 1 will show the balance."; break ;;
    0|0.000000) say "  ${Y}$SHORT holds no test ETH yet.${N}"; faucet_help
       ask "Press Enter to check again, or s to continue with an empty wallet:"
       case "$REPLY" in s|S) break ;; esac ;;
    *) ok "$SHORT holds ${B}$BAL ETH${N} on the $NETNAME."; break ;;
  esac
done

head_ "Setting up"
say "  Three things change in your organization. Each one is a file or a row you can read afterwards."

# 1. the balance website: first the row in your catalog, then the connection on this machine
if run api list 2>/dev/null | grep -qE "^\s*$API_ROW(\s|@)"; then
  ok "Your organization already allows read access to the balance website (${B}$API_ROW${N})."
else
  sed "s#\"ekka/$ROW\"#\"$API_ROW\"#" "$HERE/catalog/ekka-$ROW.json" > "$OUTF"
  ADD_OUT=$(run api create "$OUTF" 2>&1) || stop "Could not add the balance website to your catalog." "$(printf '%s\n' "$ADD_OUT" | grep -vE '^\s*$' | head -3)"
  ok "Your organization now allows ${B}read${N} access to one website, as ${B}$API_ROW${N}. Private to you."
  say "      Exactly what was allowed:   ${C}ekka api describe $API_ROW${N}"
  say "      The file it came from:      ${C}cat $HERE/catalog/ekka-$ROW.json${N}"
fi
if run api list 2>/dev/null | grep -E "^\s*$API_ROW(\s|@)" | grep -q "connected here"; then
  ok "This machine can already reach that website ($NETNAME)."
else
  # The website is public and needs no key. EKKA still stores a placeholder, because
  # a connection with no credential at all is not something it allows yet.
  printf 'public' | run api connect "$API_ROW" --stdin >/dev/null 2>&1 || stop "Could not connect the balance website." "Run it by hand to see why: ekka api connect $API_ROW"
  ok "This machine can now reach that website, read only ($NETNAME). No login, no key of yours."
fi

# 2. the agent
AG_OUT=$(run agent create "$AGENT" --name "Wallet Agent" 2>&1) || true
if printf '%s\n' "$AG_OUT" | grep -qiE "✓|already|exists"; then
  ok "The agent ${B}$AGENT${N} exists. It holds no permission of any kind:  ${C}ekka gate grant list${N}"
elif printf '%s\n' "$AG_OUT" | grep -qiE "waiting to be approved|org.agents: 0"; then
  stop "Your organization is not let in yet, so it cannot have an agent." "Reply to the email you were sent and say your organization name ($ORG). It takes one command on our side. Then run ./open.sh again."
else
  stop "Could not create the agent $AGENT." "$(printf '%s\n' "$AG_OUT" | grep -vE '^\s*$' | head -3)"
fi

# 3. the two plans
cat > "$HERE/wallet.balance.json" <<EOF
{
  "plan": { "agent": "$AGENT", "code": "wallet.balance", "name": "wallet.balance" },
  "definition": {
    "schema_version": "ekka.plan.v2",
    "run_context": [],
    "inputs": {},
    "operations": [{
      "id": "balance",
      "display_name": "Read the balance of one wallet",
      "execution": { "allowed": [], "preferred": { "mode": "async", "runtime": "node" } },
      "steps": [{
        "id": "call",
        "action_ref": "ekka.gate.api.v1",
        "target": "$AINST",
        "op": "read",
        "call": "balance",
        "inputs": { "resource": "apis/$API_ROW", "address": "$ADDRESS" }
      }]
    }]
  }
}
EOF
rm -f "$HERE/wallet.sign.json"
run plan template "$HERE/wallet.sign.json" --gate "$SGATE" --op sign --resource "keys/$KEY" >/dev/null 2>&1 \
  || stop "This EKKA cannot sign yet." "You need version 0.1.87 or later. Check with: ekka --version"
awk -v a="$AGENT" '{ if ($0 ~ /"code": "/ && !d) { print "    \"agent\": \"" a "\","; d=1 } print }' "$HERE/wallet.sign.json" > "$HERE/wallet.sign.json.tmp" && mv "$HERE/wallet.sign.json.tmp" "$HERE/wallet.sign.json"
BAL_OUT=$(run plan create "$HERE/wallet.balance.json" 2>&1 || true)
SIG_OUT=$(run plan create "$HERE/wallet.sign.json" 2>&1 || true)
printf '%s\n' "$BAL_OUT" | grep -qE "✓|already" || stop "The balance plan was refused." "$(printf '%s\n' "$BAL_OUT" | grep -vE '^\s*$' | head -3)"
printf '%s\n' "$SIG_OUT" | grep -qE "✓|already" || stop "The sign plan was refused." "$(printf '%s\n' "$SIG_OUT" | grep -vE '^\s*$' | head -3)"
BAL_VER=$(printf '%s\n' "$BAL_OUT" | grep -oE 'ekka\.wallet\.balance@[0-9.]+' | head -1); BAL_VER=${BAL_VER:-ekka.wallet.balance@1.0.0}
SIG_VER=$(printf '%s\n' "$SIG_OUT" | grep -oE 'ekka\.wallet\.sign@[0-9.]+' | head -1); SIG_VER=${SIG_VER:-ekka.wallet.sign@1.0.0}
BAL_GRANT="ekka gate grant add --agent $AGENT --type api --instance $AINST --resource apis/$API_ROW --capability api.read --no-fingerprint"
# Ten minutes, on purpose: a sign grant means "sign anything with this key" while it exists.
SIG_GRANT="ekka gate grant add --agent $AGENT --type secret --instance $SINST --resource keys/$KEY --capability secret.vault.sign --ttl 600 --no-fingerprint"
cat > "$STATE" <<EOF
ADDRESS='$ADDRESS'
SHORT='$SHORT'
API_ROW='$API_ROW'
ORG='$ORG'
AGENT='$AGENT'
AINST='$AINST'
SINST='$SINST'
BAL_GRANT='$BAL_GRANT'
SIG_GRANT='$SIG_GRANT'
BAL_VER='$BAL_VER'
SIG_VER='$SIG_VER'
EOF
ok "Plan ${B}$BAL_VER${N} is written. It names one wallet, ${B}$SHORT${N}, and takes no other."
ok "Plan ${B}$SIG_VER${N} is written. It can ask the Enclave to sign with ${B}$KEY${N}."
say "    ${B}It cannot see the key. Nothing can. The key stays inside the Enclave.${N}"

head_ "What just happened"
say "  Your organization has an agent, ${B}$AGENT${N}, with two plans. ${B}Neither may run yet.${N}"
say "  Allowing a plan is a separate step, called a grant, and only you can do it. Every attempt from"
say "  now on, allowed or refused, is written to a signed record you can check with wifi off."
say ""
say "  ${B}Before you press Enter, check what was written.${N} Open another window; nothing runs until"
say "  you come back here:"
cmd "cat $HERE/wallet.balance.json           the plan: one wallet, one website, read"
cmd "cat $HERE/wallet.sign.json              the plan: sign with keys/$KEY, nothing else"
cmd "ekka api describe $API_ROW    exactly what the agent may call"
cmd "ekka gate grant list                          what it is allowed today: nothing"
say ""
say "  ${D}Questions people ask at this point, answered: ./open.sh why${N}"
printf "  ${Y}Press Enter to start step 1.${N} "; read -r _ <&3 || true; printf "\r%40s\r" ""
steps
