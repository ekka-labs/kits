# Your financial AI agent

**Let an AI trade for you. You decide what it may do.**

An AI looks at Apple and the S&P 500 and decides which one to buy. You give it permission to trade,
for as long as you choose, and its order goes through. Take the permission back whenever you want,
and it stops.

- **Trust.** Every action is recorded and signed, so you can prove what happened.
- **Security.** The AI can do only what you allowed, and only for as long as you allowed it.
- **Privacy.** Your broker keys stay on this computer and go only to Alpaca. The AI and EKKA never
  see them.

Paper money only: an Alpaca practice account, no bank, no real money. The rule is an example, not
advice: buy whichever of Apple (AAPL) and the S&P 500 fund (SPY) did better over the last five
trading days. Edit it in `bin/prompt` and it is your rule.

The AI's answer is one word, **AAPL** or **SPY**. EKKA lets only those two words through, and each
leads only to the order for that one symbol. Any other answer can never become an order.

## The four steps

The AI is asked **once**. Its recorded pick is then governed three times.

1. **The AI picks what to buy, and tries to buy it.** It picks whichever of Apple (AAPL) and the S&P
   500 fund (SPY) did better over the last five trading days. You have not given permission, so EKKA
   stops the order before anything reaches Alpaca. The kit asks Alpaca to confirm.
2. **You give permission, for as long as you choose** (10 minutes if you press Enter;
   `PERMIT_MINUTES=3` sets it). The AI's pick goes to EKKA again as the same order, and goes through.
   The AI is not asked again.
3. **Cancel, then take the permission back.** The kit reads Alpaca until the order is final.
4. **The same order once more:** EKKA stops it.

Three authorities stay visible the whole time: **market data, read**; **paper orders, read**; and
**paper orders, write**: submit and cancel on this paper API, for the minutes you chose. It is not
scoped to a symbol, side, quantity, price, position, exposure or loss.

This runs as **you**. Your session can issue and revoke grants, so never hand it to an AI.
`./open.sh commands` shows how to give an AI a member session that can run plans and cannot grant.

The concepts the kit uses (grants, the Enclave, plans, signed records) are explained at
https://docs.ekka.ai. A write-up of one full run, with the video, is coming as a blog post.

## Run it

You need EKKA 0.1.88 or later, signed in, with an Enclave running in another window, python3, and
**your own** Alpaca account with paper trading turned on. Paper trading needs no bank, no funding
and no money at risk. Its keys are at [app.alpaca.markets](https://app.alpaca.markets/): Profile
Settings, Manage Accounts, Paper Accounts, API Keys, **Regenerate**. The secret is shown once.

⛔ **Your keys are yours. Never share them, not even with a colleague running this Kit.** Anyone
holding the pair can place paper orders in your account. If a key ever reaches somebody else,
click **Regenerate**, which retires the old pair immediately.

```sh
./open.sh
```

It says what it will change and asks first. It asks for your paper key id and secret at hidden
prompts, once, for both catalog rows. It writes the agent's plans as files you can read, then runs
the four steps. `q` stops.

- `./open.sh steps` runs the moments again, or inspects an unfinished attempt without resubmitting it
- `./open.sh view` renders the read-only evidence page, `.view/view.html`
- `./open.sh schedule` optional: analysis only, on a schedule, run once in front of you first
- `./open.sh why` questions people ask, and how to check the answer yourself
- `./open.sh commands` the operator commands, with administration kept separate from execution

## What is in this folder

| File | What |
|---|---|
| `open.sh` | The kit. The part that touches your keys is one block, marked |
| `catalog/ekka-alpaca-data.json` | Market data: one call, daily bars. Read only |
| `catalog/ekka-alpaca-paper.json` | Paper orders: account, positions, place a buy, look up, cancel |
| `bin/write-plans` | Writes every plan as a file before it is created. Read `trade.decide.json` first |
| `bin/market-inputs` | Computes the two 5-day returns on your machine from the market read |
| `bin/prompt` | The one message the AI is sent. The rule is here; edit it and it is yours |
| `bin/show-verdict` | Names the verdict EKKA recorded and branched on |
| `bin/view` | The evidence file and the read-only page rendered from it. No buttons |
| `bin/show-account`, `bin/show-order`, `bin/show-positions` | Print a broker answer from a run's saved output |
| `NEEDS`, `VERSION` | The three capability codes this kit needs; the kit version |

## Where it stops

Revoking stops the next attempt. It does not cancel an accepted order or close a position, which is
why the kit cancels first and revokes second. The write grant limits who, which gate, which server,
which action and how long. It does not limit symbol, side, quantity, price, order count, exposure
or loss, and the kit claims no limit it does not enforce. A verdict is not stable across runs;
nothing binds moment 2's verdict to moment 3's. The optional schedule has no order step at all.

## Trying it in a container first

`Dockerfile.rehearsal` builds a Debian box with the Kit copied into a writable directory
owned by `person`. It contains no EKKA installation and no credentials. There is a second user,
`agent`: an OS user by itself grants nothing, and it is there to hold the **member** session
described above, so an AI you point at it can run published plans and cannot grant anything.

```sh
docker build -f Dockerfile.rehearsal -t ekka-kitbox .
docker run -it --name kitbox ekka-kitbox bash     # window 1: the Enclave runs here
docker exec -it -u person kitbox bash                             # window 2: you work here
```

Inside the box, follow the install and Enclave startup lines in your invitation. Leave the
Enclave in window 1, then run `cd /kit && ENCLAVE=<id> ./open.sh` in window 2.
The container stores your session, vault and results until removed. Use `docker stop kitbox`
and `docker rm kitbox` after saving any records you want. Removing it does not revoke EKKA
grants or the Alpaca keys: complete [the cleanup](https://docs.ekka.ai/kits/financial-api-agent/#clean-up) first.

## What stays where

Broker credentials are held by the Enclave's connection store, injected only into the vetted
broker request, and are never plan or model inputs. EKKA receives the plans and their inputs,
including `prompt.txt` and the order details. The model runs on EKKA's hosted path, so that message
leaves this machine for the model provider. Broker answers are saved locally.

Each governed step produces signed evidence binding the authorized scope to hashes of its input
and output. The full model reply and provider answer remain local artifacts. Offline verification
checks the local chain and signatures but cannot prove that the chain has not been truncated at
the end; online verification can also check signing-key revocation.

## After the demonstration

Which API action would you want to put behind this boundary in your organization? Share the
permission scope and observed results with the person responsible for that system, then choose
one bounded evaluation together.
