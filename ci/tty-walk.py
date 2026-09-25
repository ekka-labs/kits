#!/usr/bin/env python3
"""Run ./open.sh under a pseudo-terminal, as a person's shell does, and press its keys.

    tty-walk.py <answers file>

The answers file holds the lines a person types; each is sent when the kit asks. Prints the
screen, ANSI colour removed, and exits with the kit's own exit code. A kit silent for 60 seconds
is reported as frozen and fails."""
import os, pty, re, select, sys

answers = open(sys.argv[1]).read().split("\n")
pid, fd = pty.fork()
if pid == 0:
    os.execvp("sh", ["sh", "./open.sh"])
out, pending = [], ""
prompt = re.compile(r"(\[y/N\]|\[10\]|Enter[^.]*\.( \([^)]*\))?|to ask the AI\.|\[r/k\]|:)\s*$")
while True:
    r, _, _ = select.select([fd], [], [], 60)
    if not r:
        print("".join(out)); print("FROZEN: no output for 60s"); os.kill(pid, 9); sys.exit(1)
    try:
        d = os.read(fd, 4096).decode("utf8", "replace")
    except OSError:
        break
    if not d:
        break
    d = re.sub(r"\x1b\[[0-9;]*m", "", d)
    out.append(d); pending = (pending + d).split("\n")[-1].split("\r")[-1]
    if prompt.search(pending):
        os.write(fd, ((answers.pop(0) if answers else "") + "\n").encode()); pending = ""
_, status = os.waitpid(pid, 0)
print("".join(out))
sys.exit(os.waitstatus_to_exitcode(status))
