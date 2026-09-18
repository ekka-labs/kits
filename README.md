# EKKA Kits

**A governed AI agent in a box.**

A kit is a folder you run inside your own EKKA organization. It sets up one real AI agent for one
real use, runs a few steps in front of you, explains each one, and leaves the agent yours to extend.

A kit contains no EKKA code: a shell script that calls the public `ekka` command, the JSON files the
agent's plans and permissions are made of, sometimes a web page. Read the script before you run it;
that is the point of publishing it.

| Kit | The claim | Time |
|---|---|---|
| [`wallet-agent`](wallet-agent/) | An AI agent can request a signature from your test wallet without ever seeing the private key. It is allowed to read the balance. It is not allowed to sign, until you grant that authority for ten minutes, and you can take it back. | 20 min, Sepolia test network |

One kit today. The next ones are chosen by what people build with this one.

## Run a kit

You need EKKA installed and signed in (private beta: the email you were sent has the lines), and
an Enclave running in another window. Then, in the kit's folder:

```sh
./open.sh
```

Every kit says what it will change and asks before each change, then runs its steps in front of
you and explains what happened. Each kit's page on docs.ekka.ai has the full story:
https://docs.ekka.ai/kits/

## Versions

Each kit carries a `VERSION` and the minimum runner it needs (`kits.txt`). A kit version is tagged
(`wallet-agent/1.0.0`) only after a fresh-box walk on the public runner. `ci/check-kit.sh` confirms
the capability codes a kit needs are on the edition every new organization gets.

## License

Apache-2.0. Copy it, change it, build your own kit on it.
