# Hand checks

These are small checks to run before or alongside the first build. Each one
answers a question the [plan](../doc/plan.md) depends on. None of them is
product code.

| Directory | Question | State |
| --- | --- | --- |
| [anthropic-federation](anthropic-federation/) | Will Anthropic exchange a token signed by a key on this laptop, in a one-person organization? | The local steps pass. The rest needs the owner's admin login and hasn't been run |
| [touchid](touchid/) | What does a fingerprint key allow, and what does its prompt show? | Not run. It prompts, so the owner runs it |
| [enclave-go-swift](enclave-go-swift/) | Can a Go binary use the Secure Enclave through CryptoKit? | Built and run once on 2026-11-11, during the review |
| [sandbox-proxy-port](sandbox-proxy-port/) | Can the gateway be the sandbox's proxy? | Run on 2026-11-11. It can. The output is kept |

## Rules for these and any later check

A keychain experiment during the review crashed `securityd` and left the
login keychain locked ([checks.md](../doc/checks.md) has the account). So:

- A check that touches the keychain or raises a system prompt is a script the
  owner runs at the keyboard, never something an agent runs.
- If a prompt appears, answer or cancel it in the prompt. Don't kill the
  process that raised it.
- A check that needs the file-based keychain, or that might disturb the
  login session, runs in a virtual machine or a separate user account.
- Every check uses dummy values.
