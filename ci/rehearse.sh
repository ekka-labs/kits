#!/bin/sh
# Run one kit end to end against its own stand-in ekka, with canned answers, and check the
# screens that matter appeared. No server, no key, no network.
#
# ☠️ THIS SCRIPT KNOWS NO KIT BY NAME, AND THAT IS THE POINT. It used to hold a `case` per kit
# carrying each one's screens, answers and injected failures. Those lines describe a product:
# exporting ONE kit for the public repository shipped the OTHER kit's demonstration, its exact
# expected output and the name of the API vendor it integrates with — none of it a kit folder,
# so no folder check saw it. The knowledge now lives in the kit it belongs to:
#
#   <kit>/rehearsal/answers           the canned input for the main walk
#   <kit>/rehearsal/answers.injected  the input for an injected run, which stops earlier
#   <kit>/rehearsal/expect            one screen the walk must print, per line
#   <kit>/rehearsal/modes             one open.sh mode that must still run, per line
#   <kit>/rehearsal/injections        name, env var, must-see, must-not-run, must-not-see
#   <kit>/rehearsal/fake-ekka         that kit's stand-in, complete, never a fragment
#   <kit>/rehearsal/state/<id>/       artifacts the stand-in serves, where a kit needs them
#
# ⛔ AND IT REFUSES A KIT WITH NO `rehearsal/`, rather than passing it silently. A kit nobody
# rehearsed looks exactly like a kit that passed, and the old `*)` arm printed a message and
# exited 1 only because somebody remembered to write it.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=${1:?usage: rehearse.sh <kit>}
R="$HERE/../$KIT/rehearsal"

[ -d "$R" ] || { echo "no rehearsal for $KIT: expected $KIT/rehearsal/"; exit 1; }
for f in answers expect modes fake-ekka; do
  [ -f "$R/$f" ] || { echo "$KIT/rehearsal/$f is missing; a kit is not rehearsed until it says what it must print"; exit 1; }
done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# ⚠️ ITS OWN HOME. A kit's reader globs ~/.ekka/artifacts for the newest answer, so a rehearsal
# that keeps the caller's HOME reads whatever that machine last ran and calls it this run's output.
export HOME="$WORK/home"; mkdir -p "$HOME"
export REHEARSAL_STATE="$WORK/state"; mkdir -p "$REHEARSAL_STATE"
[ -d "$R/state" ] && cp -R "$R/state/." "$REHEARSAL_STATE/art/" 2>/dev/null || mkdir -p "$REHEARSAL_STATE/art"

mkdir -p "$WORK/bin"; cp "$R/fake-ekka" "$WORK/bin/ekka"; chmod +x "$WORK/bin/ekka"
cp -R "$HERE/../$KIT" "$WORK/kit"; rm -f "$WORK/kit/.demo-state"
cd "$WORK/kit"
ROLL=0 NO_COLOR=1 OPEN_SH_INPUT="$R/answers" PATH="$WORK/bin:$PATH" sh ./open.sh > "$WORK/out.txt" 2>&1 \
  || { echo "open.sh exited non-zero"; tail -20 "$WORK/out.txt"; exit 1; }
rc=0

# ── the screens this kit said it must print ──────────────────────────────────
while IFS= read -r must; do
  case "$must" in ''|\#*) continue ;; esac
  if grep -q "$must" "$WORK/out.txt"; then echo "  ok   saw: $must"; else echo "  MISSING: $must"; rc=1; fi
done < "$R/expect"

while IFS= read -r m; do
  case "$m" in ''|\#*) continue ;; esac
  printf 's\ns\n\n\n\n\n\n\n' > "$WORK/s"
  ROLL=0 NO_COLOR=1 OPEN_SH_INPUT="$WORK/s" PATH="$WORK/bin:$PATH" sh ./open.sh "$m" >/dev/null 2>&1 \
    && echo "  ok   ./open.sh $m" || { echo "  FAIL ./open.sh $m"; rc=1; }
done < "$R/modes"

# ── injected failures ────────────────────────────────────────────────────────
# Each gets a fresh state dir (a first run, so the answers are read the same way) and a call log,
# so the checks are about what the kit did NOT run afterwards, not about a heading.
# ⚠️ A FRESH COPY OF THE KIT EACH TIME. The walkthrough above leaves `.demo-state` behind, and a
# kit that finds one inspects the saved attempt instead of starting: the injected failure would
# never be reached and every assertion below would be about the wrong screen.
# A WALK UNDER A REAL TERMINAL. Code that runs only on a terminal (live progress, waiting lines)
# is invisible to every run above, which pipes the output. A pseudo-terminal walk must reach the
# end, exit 0, and show the kit's own "waiting" lines, pressing the keys a person would.
if command -v python3 >/dev/null 2>&1 && [ -f "$R/tty-expect" ]; then
  rm -rf "$WORK/ttykit" "$WORK/ttystate" "$WORK/ttyhome"; cp -R "$HERE/../$KIT" "$WORK/ttykit"; rm -f "$WORK/ttykit/.demo-state"
  mkdir -p "$WORK/ttystate" "$WORK/ttyhome"
  if ( cd "$WORK/ttykit" && REHEARSAL_STATE="$WORK/ttystate" HOME="$WORK/ttyhome" ROLL=0 PATH="$WORK/bin:$PATH" \
        python3 "$HERE/tty-walk.py" "$R/answers" ) > "$WORK/tty.txt" 2>&1
  then echo "  ok   a real-terminal walk exits 0"
  else echo "  FAIL a real-terminal walk did not finish: $(tail -2 "$WORK/tty.txt" | tr '\n' ' ')"; rc=1; fi
  while IFS= read -r must; do
    case "$must" in ''|\#*) continue ;; esac
    if grep -q "$must" "$WORK/tty.txt"; then echo "  ok   on a terminal, saw: $must"; else echo "  MISSING on a terminal: $must"; rc=1; fi
  done < "$R/tty-expect"
fi

[ -f "$R/injections" ] || exit $rc
INJ_IN="$R/answers.injected"; [ -f "$INJ_IN" ] || INJ_IN="$R/answers"
while IFS='	' read -r name var must notrun notsee; do
  case "$name" in ''|\#*) continue ;; esac
  mkdir -p "$WORK/$name"
  rm -rf "$WORK/${name}kit"; cp -R "$HERE/../$KIT" "$WORK/${name}kit"; rm -f "$WORK/${name}kit/.demo-state"
  if ( cd "$WORK/${name}kit" && env "$var=1" REHEARSAL_STATE="$WORK/$name" HOME="$WORK/${name}home" \
        ROLL=0 NO_COLOR=1 OPEN_SH_INPUT="$INJ_IN" PATH="$WORK/bin:$PATH" sh ./open.sh ) > "$WORK/$name.txt" 2>&1
  then echo "  FAIL $name: open.sh exited zero"; rc=1
  else echo "  ok   $name: exits non-zero"; fi
  grep -q "$must" "$WORK/$name.txt" && echo "  ok   $name: saw: $must" || { echo "  MISSING $name: $must"; rc=1; }
  grep -q "The walkthrough has stopped" "$WORK/$name.txt" && echo "  ok   $name: the walk said it stopped" \
    || { echo "  MISSING $name: the stop line"; rc=1; }
  if grep -qE "$notrun" "$WORK/$name/calls.log" 2>/dev/null
  then echo "  FAIL $name: ran afterwards: $(grep -E "$notrun" "$WORK/$name/calls.log" | head -1)"; rc=1
  else echo "  ok   $name: never ran: $notrun"; fi
  # ⚠️ An optional fifth column: the kit must fail, and must not guess at why.
  if [ -n "${notsee:-}" ]; then
    if grep -qE "$notsee" "$WORK/$name.txt"
    then echo "  FAIL $name: unsupported explanation printed"; rc=1
    else echo "  ok   $name: no unsupported explanation"; fi
  fi
done < "$R/injections"
exit $rc
