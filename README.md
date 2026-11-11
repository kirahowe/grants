# grants

Short-lived credentials, issued to one task at a time, declared in an
application's config.

This project is still at the design stage and has no code yet.

- [`doc/design.md`](doc/design.md) describes how it works.
- [`doc/plan.md`](doc/plan.md) says what to build first and how to tell it
  works.
- [`doc/protocol.md`](doc/protocol.md) specifies the file format, the control
  socket, and the gateway, with test cases in
  [`doc/vectors.md`](doc/vectors.md).
- [`doc/threat-model.md`](doc/threat-model.md) explains what it protects,
  where the trust boundaries are, and what it leaves exposed.
- [`doc/use-cases.md`](doc/use-cases.md) works the design through three real
  applications.
- [`doc/checks.md`](doc/checks.md) lists the claims the design rests on and
  how each was checked.
- [`doc/later.md`](doc/later.md) keeps the parts that aren't planned yet.
- [`doc/prior-art.md`](doc/prior-art.md) surveys what other products and
  providers do.
- [`spike/`](spike/) holds small checks to run before building.

## The idea

[`secrets`](https://github.com/kirahowe/secrets) keeps an application's
secrets in an encrypted file that a single age key opens. That one key unlocks
everything, and any code running as the developer can get at it, including a
coding agent.

`grants` doesn't store any values. Instead, the repository holds
`grants.edn`, which describes the access each task may have. When a task
runs, a small local issuer, with its keys in the Secure Enclave, proves to
the provider which task is asking, and the provider issues a credential that
covers only that task and expires within minutes.

The application reads a grant through its config, using a `#grant` reader
literal, so no environment variable carries a secret. On a laptop the
application never holds a credential at all: it sends its requests to a local
gateway, which attaches the credential and forwards them.

Some providers offer only long-lived API keys. For those, one bounded key is
sealed on the machine, and only the gateway can use it. The application's own
stored data, such as a bank token, is wrapped with a key that stays in the
issuer.

`grants` is a working title.
