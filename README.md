# grants

Short-lived credentials, issued to one task at a time, declared in an
application's config.

This project is at the design stage and has no code yet.

- [`doc/design.md`](doc/design.md) describes how it works.
- [`doc/threat-model.md`](doc/threat-model.md) says what it protects, where
  the trust boundaries are, and what it leaves exposed.
- [`doc/prior-art.md`](doc/prior-art.md) surveys what other products and
  providers do.

## The idea

[`secrets`](https://github.com/kirahowe/secrets) keeps an application's
secrets in an encrypted file that one age key opens. That key is a single
prize for any code running as the developer, a coding agent included.

`grants` keeps no store of values. The repository holds `grants.edn`, a
description of the access each task may have. When a task runs, it proves who
it is and the provider issues a credential that covers that task and expires
soon after.

The application reads a credential through its config, with a `#grant` reader
literal, and no environment variable is involved. Production and CI use the
workload identity their platform already provides. On a laptop, a small local
issuer with its keys in the Secure Enclave supplies the identity that is
otherwise missing there.

Some providers have only long-lived API keys. For those, a local gateway holds
one bounded test-mode key and attaches it to requests, so a task never
receives it.

`grants` is a working title.
