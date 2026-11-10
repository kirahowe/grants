# grants

Short-lived credentials, issued to one task at a time, declared in an
application's config.

This project is still at the design stage and has no code yet.

- [`doc/design.md`](doc/design.md) describes how it works.
- [`doc/threat-model.md`](doc/threat-model.md) explains what it protects,
  where the trust boundaries are, and what it leaves exposed.
- [`doc/prior-art.md`](doc/prior-art.md) surveys what other products and
  providers do.

## The idea

[`secrets`](https://github.com/kirahowe/secrets) keeps an application's
secrets in an encrypted file that a single age key opens. That one key unlocks
everything, and any code running as the developer can get at it, including a
coding agent.

`grants` doesn't store any values. Instead, the repository holds
`grants.edn`, which describes the access each task may have. When a task
runs, it proves who it is, and the provider issues a credential that covers
only that task and expires soon afterward.

The application reads a credential through its config, using a `#grant`
reader literal, so no environment variable is involved. Production and CI use
the workload identity that their platform already provides. A laptop has no
such identity, so a small local issuer, with its keys in the Secure Enclave,
supplies one.

Some providers offer only long-lived API keys. For those, a local gateway
holds one bounded test-mode key and attaches it to requests, so the task never
receives the key.

`grants` is a working title.
