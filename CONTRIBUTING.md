# Working in this repository

This repository is **public**. Anybody can read every file, every commit message
and every author line.

## Before your first commit here

```sh
git config core.hooksPath .githooks
git config user.name  "EKKA"
git config user.email "<the ekka-ops bot>@users.noreply.github.com"
```

The first line turns on a hook that refuses a commit which would publish a person
or an outside address. **A fresh clone inherits your machine's global git
identity**, which is how somebody's own name reaches a public repository without
anybody deciding to put it there.

## Merging

Merge as the bot. A GitHub squash merge signs the commit as **whoever pressed
it**, so merging from your own account puts your name and GitHub handle on this
repository's history, where it cannot be taken back.

## What must never appear here

- a real person's name or email address, ours or a customer's
- the name of the company that operates EKKA, or any internal system
- a real customer's data, however anonymous it looks

Use `@example.com` in docs and fixtures. RFC 2606 reserves `example.com`,
`example.net` and `example.org` so they cannot belong to anybody. `ekka` and
`ekka.ai` are fine: this is EKKA's product.

## What enforces it

| | |
|---|---|
| `.githooks/pre-commit` | refuses the commit, on your machine, before it exists |
| `ci/nothing-here-names-a-person-or-a-company.sh` | refuses the push, in CI, including a clone with no hook |

Both work by **allow list**, not by naming what is private. Listing the names we
want to hide would publish them in this very repository, and would still miss the
first person nobody thought of. So they ask which identities a public EKKA
repository may contain and refuse everything else.

The CI check reads authors across **every branch**, because a branch that never
merged still publishes what it carries.
