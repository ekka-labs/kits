# Your wallet AI agent

**Let an AI move your crypto. It never sees your private key, and neither does EKKA.**

Your everyday wallet holds more than it needs. An AI checks it against your rule and decides whether
to move the extra to your savings wallet. You give it permission to sign, for as long as you choose,
and its transfer goes through. Take the permission back whenever you want, and it stops.

- **Trust.** Every action is recorded and signed, so you can prove what happened.
- **Security.** The AI can do only what you allowed, and only for as long as you allowed it.
- **Privacy.** Your wallet's private key stays in the Enclave on this computer, which signs with
  it. It never leaves: not to EKKA, not to the AI, a third-party model. They cannot see it; they
  can only ask your Enclave to sign with it, and only while you allow that. To decide yes or no, EKKA's
  control plane is sent the message to the AI, which names the amount and the savings wallet. When
  your Enclave signs, EKKA sees only a fingerprint of what is signed, never your key. Then the
  signed transfer, which is public once it is sent. The AI gate carries the message to the model, a third
  party, not EKKA.

The Sepolia test network only: test ETH is free and has no value. The rule is an example, not
advice: when your everyday wallet holds more than 0.01 test ETH, move the extra to your savings
wallet. Edit it in `bin/prompt` and it is your rule.

**The AI decides yes or no, never how much or where.** The kit works out the amount (everything
above the 0.01 you keep, less the most the network fee can be) and puts your savings address into
the transfer before the AI is asked. The AI's answer is one word, **transfer** or **hold**. EKKA lets
only those two words through, and only **transfer** leads to the signing step. No answer from the
AI can send more, or send it anywhere else.

## The four steps

The AI is asked **once**. Its recorded decision is then governed three times.

1. **The AI checks your wallet, decides, and tries to move the extra.** You have not given
   permission, so EKKA stops the signature before the Enclave signs anything. Your wallet's page on
   Blockscout shows nothing new.
2. **You give permission to sign, for as long as you choose** (10 minutes if you press Enter;
   `PERMIT_MINUTES=3` sets it). The same transfer is signed by the Enclave and sent. The AI is not
   asked again. Blockscout shows the transfer, and the kit says what the network fee was.
3. **Take the permission back.** A confirmed transfer is final, so there is nothing to cancel.
4. **The same transfer once more,** as a new one: EKKA stops it.

The savings wallet is a second account you make in MetaMask (**Add account**, one click). With no
second account, press Enter: the extra goes back to the same wallet, and only the network fee is
spent. Three authorities stay visible the whole time: **Sepolia, read**; **Sepolia, send** (only a
transfer that is already signed: it cannot make, change or sign one); and **sign with your wallet
key**, for the minutes you chose.

This runs as **you**. Your session can issue and revoke grants, so never hand it to an AI.
`./open.sh commands` shows how to give an AI a member session that can run plans and cannot grant.

## Run it

You need EKKA 0.1.88 or later, signed in, with an Enclave running in another window, python3, and
a test wallet you made for this, holding a little test ETH, and a second account in it for savings.
How to make both in MetaMask and fill the first from a faucet, two minutes:
[What you need](https://docs.ekka.ai/kits/wallet-agent/#what-you-need). The walk needs a little more
than 0.011 test ETH; a faucet gives 0.05. If the wallet holds no extra above the 0.01 it keeps, the
kit stops before the AI is asked and says how to put some back. A second walk meets exactly that,
because the first one moved the extra to savings: send some back to the everyday wallet in
MetaMask, then run the steps again.

```sh
./open.sh
```

It says what it will change and asks first. It asks for your test wallet's private key at a hidden
prompt, once, then its address and your savings address. It writes the agent's plans as files you can read, then runs the
four steps. `q` stops.

- `./open.sh steps` runs the steps again, or inspects an unfinished attempt without signing again
- `./open.sh view` renders the read-only evidence page, `.view/view.html`
- `./open.sh why` questions people ask, and how to check the answer yourself
- `./open.sh commands` the operator commands, with administration kept separate from execution

## What is in this folder

| File | What |
|---|---|
| `open.sh` | The kit. The part that touches your key is one block, marked |
| `catalog/ekka-eth-sepolia.json` | The Sepolia network through Blockscout: read one wallet, send a signed transfer |
| `bin/write-plans` | Writes every plan as a file before it is created. Read `wallet.decide.json` first |
| `bin/prompt` | The one message the AI is sent. The rule is here; edit it and it is yours. The amount and the address are not the AI's to choose |
| `bin/tx` | Builds the transfer and its 32-byte fingerprint, and assembles the signed transfer. Never sees a key. `bin/tx selftest` runs its published test vectors |
| `bin/show-verdict` | Names the decision EKKA recorded and branched on |
| `bin/wallet` | Reads one Blockscout answer from a run's saved output |
| `bin/view` | The evidence file and the read-only page rendered from it. No buttons |
| `NEEDS`, `VERSION` | The four capability codes this kit needs; the kit version |

## Where it stops

**The sign permission lets the agent sign ANY transfer with this key while it lasts, not only this
one.** The signing permission checks who may sign, with which key, on which computer, and for how
long. It does not restrict the transfer's destination or amount. EKKA's control plane did see both,
in the message to the AI, but the permission does not limit them: this kit sets them, before
anything is signed, and it never takes either from the AI. When the Enclave signs, EKKA sees only a
32-byte fingerprint of what is signed.
That is why you choose the minutes, and why step 3 takes the permission back.

Revoking permission prevents new signatures. It cannot invalidate a signature already created or
undo a confirmed transfer. A signed transfer
carries its transfer number, so the network takes it once: sending the same signed transfer again
can never move it twice, and the kit never signs a transfer again to retry a send. A decision is not
stable across runs; the kit asks the AI once and reuses that decision.

The Blockscout service is free and takes only a few sends every few minutes. When it is busy the
kit says so and sends the same signed transfer again when you press Enter.

## Trying it in a container first

`Dockerfile.rehearsal` builds a Debian box with the kit copied into a writable directory owned by
`person`. It contains no EKKA installation and no credentials.

```sh
docker build -f Dockerfile.rehearsal -t ekka-kitbox .
docker run -it --name kitbox ekka-kitbox bash     # window 1: the Enclave runs here
docker exec -it -u person kitbox bash                             # window 2: you work here
```

Inside the box, follow the install and Enclave startup lines in your invitation. Leave the Enclave
in window 1, then run `cd /kit && ENCLAVE=<id> ./open.sh` in window 2.

## What stays where

The private key is held by the Enclave's vault and never leaves it. EKKA and the AI cannot see it:
they can only ask your Enclave to sign with it, and only while you allow that. The Enclave signs and returns
the signature and the public key. To decide yes or no, EKKA's control plane is sent the plans and
their inputs: the message to the AI (your rule, your balance, your savings address and the amount),
the transfer's fingerprint, and the signed transfer when it is sent. A transfer is public on the network
once it is sent. The AI gate carries the message to the model, a third party, not EKKA.

Each governed step produces signed evidence binding the authorized scope to hashes of its input and
output. Offline verification checks the local chain and signatures but cannot prove that the chain
has not been truncated at the end; online verification can also check signing-key revocation.
