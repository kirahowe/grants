# What a fingerprint key allows

Live keys depend on an enclave key that needs a fingerprint. The review
tested everything about such a key that can be tested without a finger: one
can be created with no entitlement and no prompt, and a second program that
loads its stored form is refused with "user interaction is required". This
check finishes the job, and only the owner can run it.

`run.sh` builds two programs. `grants-issuer-test` plays the issuer and
creates the keys. `not-the-issuer` is a different program with a different
signature that loads those keys from disk and tries to use them. All values
are dummies, and the keys' stored forms are deleted at the end.

Run `./run.sh` in Terminal at the Mac. Read each prompt before you touch the
sensor. If you want to stop, cancel in the prompt. Don't kill the process
while a prompt is showing.

| Step | What to look for | What it means |
| --- | --- | --- |
| 1 | `SIGN ... OK, valid` and `UNSEAL ... DUMMY-LIVE-KEY-bio` | Any program that can read the stored key can use it, given a fingerprint. The fingerprint is the only obstacle in the unsigned build. It also confirms that a fingerprint key can unseal as well as sign |
| 1 | The text on the prompt | If it names `not-the-issuer`, the prompt shows the caller's name, and a program named `grants` would look like the issuer |
| 1 | How many prompts appear | Three means every operation on a fresh context asks again |
| 1 | An access error after a successful touch | Unexpected. It would mean these keys are tied to the program after all |
| 2 | An error for a cancelled prompt | A refusal is reported cleanly |
| 3 | One prompt for a signature and two unseals | One fingerprint can cover several operations, so a live task can open several keys with one touch. The design assumes this |
| 4 | The prompt offers a password | The `userPresence` setting accepts the login password, which software can type. Live keys should use the fingerprint-only setting |
