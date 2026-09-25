# Your wallet AI agent

**Let an AI pay for you. You decide what it may do.**

An invoice arrives. An AI checks it against your rule and decides whether to pay. You give it
permission to sign, for as long as you choose, and its payment goes through. Take the permission
back whenever you want, and it stops.

- **Trust.** Every action is recorded and signed, so you can prove what happened.
- **Security.** The AI can do only what you allowed, and only for as long as you allowed it.
- **Privacy.** Your wallet's private key stays in the Enclave on this computer, which signs with
  it. EKKA never sees it, and neither does the AI, a third-party model, not EKKA. To decide yes or
  no, EKKA's control plane is sent the message to the AI and the payment's fingerprint, then the
  signed payment, which is public once it is sent. The AI gate carries the message to the model,
  a third party, not EKKA.

The Sepolia test network only: test ETH is free and has no value. The rule is an example, not
advice: pay only if the payee is on your approved list and at least 0.01 test ETH is left after
paying. Edit it in `bin/prompt` and it is your rule.

The AI's answer is one word, **pay** or **hold**. EKKA lets only those two words through, and only
**pay** leads to the signing step. Any other answer can never become a signature.

## The four steps

The AI is asked **once**. Its recorded decision is then governed three times.

1. **The AI reads the invoice, decides, and tries to pay.** You have not given permission, so EKKA
   stops the signature before the Enclave signs anything. Your wallet's page on Blockscout shows
   no new payment.
2. **You give permission to sign, for as long as you choose** (10 minutes if you press Enter;
   `PERMIT_MINUTES=3` sets it). The same payment is signed by the Enclave and sent. The AI is not
   asked again. Blockscout shows the payment, and the kit says what the network fee was.
3. **Take the permission back.** A confirmed payment is final, so there is nothing to cancel.
4. **The same payment once more,** as a new one: EKKA stops it.

By default the invoice pays **you back**, so only the network fee is spent. Three authorities stay
visible the whole time: **Sepolia, read**; **Sepolia, send** (only a payment that is already
signed: it cannot make, change or sign one); and **sign with your wallet key**, for the minutes you
chose.

This runs as **you**. Your session can issue and revoke grants, so never hand it to an AI.
`./open.sh commands` shows how to give an AI a member session that can run plans and cannot grant.

## Run it

You need EKKA 0.1.88 or later, signed in, with an Enclave running in another window, python3, and
a test wallet you made for this, holding a little test ETH. How to make one in MetaMask and fill
it from a faucet, two minutes: [What you need](https://docs.ekka.ai/kits/wallet-agent/#what-you-need).
The walk needs about 0.012 test ETH; a faucet gives 0.05. If the wallet holds less, the kit stops
before the AI is asked and says how to get more.

```sh
./open.sh
```

It says what it will change and asks first. It asks for your test wallet's private key at a hidden
prompt, once, then its address. It writes the agent's plans as files you can read, then runs the
four steps. `q` stops.

- `./open.sh steps` runs the steps again, or inspects an unfinished attempt without signing again
- `./open.sh view` renders the read-only evidence page, `.view/view.html`
- `./open.sh why` questions people ask, and how to check the answer yourself
- `./open.sh commands` the operator commands, with administration kept separate from execution

## What is in this folder

| File | What |
|---|---|
| `open.sh` | The kit. The part that touches your key is one block, marked |
| `catalog/ekka-eth-sepolia.json` | The Sepolia network through Blockscout: read one wallet, send a signed payment |
| `bin/write-plans` | Writes every plan as a file before it is created. Read `wallet.decide.json` first |
| `bin/prompt` | The one message the AI is sent. The rule is here; edit it and it is yours |
| `bin/tx` | Builds the payment and its 32-byte fingerprint, and assembles the signed payment. Never sees a key. `bin/tx selftest` runs its published test vectors |
| `bin/show-verdict` | Names the decision EKKA recorded and branched on |
| `bin/wallet` | Reads one Blockscout answer from a run's saved output |
| `bin/view` | The evidence file and the read-only page rendered from it. No buttons |
| `NEEDS`, `VERSION` | The four capability codes this kit needs; the kit version |

## Where it stops

**The sign permission lets the agent sign ANY payment with this key while it lasts, not only this
one.** The Enclave signs a 32-byte fingerprint, and EKKA sees that fingerprint, not the payee or
the amount. So EKKA checks who may sign, with which key, on which computer, and for how long. It
does not check who is paid or how much: your rule and this kit do that, before anything is signed.
That is why you choose the minutes, and why step 3 takes the permission back.

Taking the permission back stops new signatures. A payment already sent is final. A signed payment
carries its payment number, so the network takes it once: sending the same signed payment again
can never pay twice, and the kit never signs a payment again to retry a send. A decision is not
stable across runs; the kit asks the AI once and reuses that decision.

The Blockscout service is free and takes only a few sends every few minutes. When it is busy the
kit says so and sends the same signed payment again when you press Enter.

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

The private key is held by the Enclave's vault and never leaves it: the Enclave signs and returns
the signature and the public key. To decide yes or no, EKKA's control plane is sent the plans and
their inputs: the message to the AI (the invoice, your rule, your approved list, your balance), the
payment's fingerprint, and the signed payment when it is sent. A payment is public on the network
once it is sent. The AI gate carries the message to the model, a third party, not EKKA.

Each governed step produces signed evidence binding the authorized scope to hashes of its input and
output. Offline verification checks the local chain and signatures but cannot prove that the chain
has not been truncated at the end; online verification can also check signing-key revocation.
