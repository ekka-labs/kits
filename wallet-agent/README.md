# Your wallet agent

**An AI agent can request a wallet signature without ever seeing the private key. Watch what it is
allowed to do, and what it is not.**

The wallet key stays inside your Enclave. The agent submits a digest. If EKKA authorizes the
request, the Enclave signs it and returns the signature.

1. You allow one thing: read the balance. The agent reads it.
2. The agent asks to sign. Refused before it reaches your machine.
3. You allow signing for ten minutes, sign once, take it back. Refused again.

Every attempt, allowed or refused, lands in a signed record you check with wifi off. About twenty
minutes, on the Sepolia test network: test ETH from a faucet, nothing at stake.

**The full story, what else to try, and where this stops: https://docs.ekka.ai/kits/wallet-agent/**

## Run it

You need EKKA 0.1.87 or later, signed in, with an Enclave running in another window (the email
you were sent has the four lines). Then:

```sh
./open.sh
```

It says what it will change and asks before each change. It asks for your test wallet's private
key at a hidden prompt (checks only the shape, hands it to the Enclave, forgets it), then the
wallet's address, then checks the wallet has test ETH. It writes two plans you can read, then runs
the three steps in front of you. `s` skips a step, `q` stops.

- `./open.sh steps` runs the three steps again
- `./open.sh try` what else to try
- `./open.sh why` questions people ask, and how to check the answer yourself
- `./open.sh commands` the plain lines, to type yourself or hand to your AI

## What is in this folder

| File | What |
|---|---|
| `open.sh` | The kit. Read it; the part that touches your key is one block, marked |
| `catalog/ekka-eth-balance-sepolia.json` | The one website the agent may read, 25 lines |
| `sign.html` | Builds the transaction in your browser, shows the digest, sends the signed result. Never sees the key |
| `bin/show-balance` | Prints the balance from a run's saved output |
| `NEEDS`, `VERSION` | The two capability codes this kit needs; the kit version |

After a run, `wallet.balance.json` and `wallet.sign.json` are the agent's two plans, exactly as created.

## Trying it in a container first

`Dockerfile.rehearsal` builds a clean Debian box with two users, `person` (you) and `agent` (an AI),
and no EKKA installed, so you can run the whole thing from the install line exactly as a new user would.

```sh
docker build -f Dockerfile.rehearsal -t ekka-kitbox .
docker run -it --name kitbox -v "$PWD":/kit ekka-kitbox bash     # window 1: the Enclave runs here
docker exec -it -u person kitbox bash                             # window 2: you work here
docker exec -it -u agent kitbox bash                            # window 3: the agent lives here
```

Inside the box the kit is at `/kit`. Run it with `cd /kit && ENCLAVE=<id> ./open.sh`.
