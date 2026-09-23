#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
# NOTHING HERE NAMES A PERSON OR A COMPANY.
#
# This repository is PUBLIC. Anybody can read every file, every commit message
# and every author line. What belongs here is the product. What does not belong
# here is who we are, where we work, or anybody's address.
#
# ⛔ AN ALLOW LIST, AND THAT IS THE WHOLE DESIGN.
#
# The first version of this check carried a DENY list: the company name and the
# surnames of everybody working on it, written down in a file, in this public
# repository. It would have published the exact thing it existed to hide. A deny
# list also cannot work: it knows only the names somebody thought to add, so the
# first customer, contractor or colleague it has never heard of walks past it.
#
# So it asks the opposite question. Not "is this one of our private names" but
# "is this one of the few identities a public EKKA repository may contain".
# Everything else fails, including names nobody predicted.
#
# ☠️ WHY IT EXISTS. A git identity is easy to get wrong and impossible to take
# back: a fresh clone inherits the machine's global one, and a squash merge signs
# as whoever pressed it. The CI step beside this one checks the author NAME, which
# is the half nobody gets wrong. This one checks the ADDRESS.
set -euo pipefail

# ⚠️ `--files-only` EXISTS BECAUSE OF WHERE THIS RUNS. The release exporter checks
# the tree it just produced, and that tree has no git of its own: `git log` walks
# up to whatever repository contains the staging directory, which is the PRIVATE
# development repo whose history legitimately carries real names. Checking
# identities there answers a question nobody asked and fails every export.
#
# So the identity checks belong to the PUBLIC repository's CI, where the history
# being checked is the history being published. The file checks belong to both.
FILES_ONLY=0
[ "${1:-}" = "--files-only" ] && FILES_ONLY=1

fail=0
say() { printf '  %s\n' "$*"; }

# The only email domains a public EKKA repository may contain.
#   example.com/.net/.org     RFC 2606 reserves them, so they cannot be anybody's
#   ekka.ai                   the product's own domain
#   users.noreply.github.com  GitHub's own, which is what the bot commits as
#   noreply@github.com        GitHub itself, the COMMITTER on a squash merge.
#                             Not a person, and not something we choose.
ALLOWED_MAIL='(@(example\.(com|net|org)|ekka\.ai|users\.noreply\.github\.com)$|^noreply@github\.com$)'
# The only names a commit here may carry. `GitHub` for the same reason as above:
# it signs the squash merge it performs. The AUTHOR is the half that leaks.
ALLOWED_NAME='^(EKKA|ekka-ops\[bot\]|GitHub)$'

# ── 1. every email address in every file ─────────────────────────
MAILS=$(grep -rhoiE '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' . \
          --exclude-dir=.git --exclude-dir=node_modules \
          --exclude="$(basename "$0")" 2>/dev/null \
        | grep -viE "$ALLOWED_MAIL" | sort -u || true)
if [ -n "$MAILS" ]; then
  say "FAIL  an address that is not ours and not reserved appears in a file:"
  printf '%s\n' "$MAILS" | head -10 | sed 's/^/        /'
  say "      use an @example.com address: RFC 2606 reserves it so it cannot be anybody's."
  fail=1
fi

if [ "$FILES_ONLY" = "1" ]; then
  if [ "$fail" -ne 0 ]; then say "nothing-here-names-a-person-or-a-company: FAILED"; exit 1; fi
  echo "nothing-here-names-a-person-or-a-company: files clean (no outside addresses)"
  exit 0
fi

# ── 2. every author and committer, on every branch ───────────────
# `--all`, because a branch that never merged still publishes what it carries.
IDENTS=$(git log --all --format='%ae%n%ce' 2>/dev/null | sort -u || true)
BADID=$(printf '%s\n' "$IDENTS" | grep -viE "$ALLOWED_MAIL" || true)
if [ -n "$BADID" ]; then
  say "FAIL  a commit is authored by an address a public repo may not carry:"
  printf '%s\n' "$BADID" | sed 's/^/        /'
  fail=1
fi

# ── 3. the names on those commits ────────────────────────────────
# A GitHub squash merge attributes the commit to whoever pressed it, so a merge
# pressed by a person publishes that person. That is what this catches.
NAMES=$(git log --all --format='%an%n%cn' 2>/dev/null | sort -u || true)
BADNAME=$(printf '%s\n' "$NAMES" | grep -vE "$ALLOWED_NAME" || true)
if [ -n "$BADNAME" ]; then
  say "FAIL  a commit is authored by a name that is not EKKA:"
  printf '%s\n' "$BADNAME" | sed 's/^/        /'
  say "      a squash merge signs as the person who pressed it. Merge as the bot,"
  say "      or rewrite: git commit --amend --reset-author"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  say "nothing-here-names-a-person-or-a-company: FAILED"
  exit 1
fi
echo "nothing-here-names-a-person-or-a-company: clean ($(printf '%s\n' "$IDENTS" | wc -l | tr -d ' ') identities, no outside addresses)"
