# grants

Short-lived credentials, issued to one task at a time, declared in an
application's config.

This project is at the design stage and has no code yet. The design is in
[`doc/design.md`](doc/design.md).

## The idea

[`secrets`](https://github.com/kirahowe/secrets) keeps an application's
secrets in an encrypted file that one age key opens. That key is a single
prize for any code running as the developer, a coding agent included.

`grants` keeps no secret values. The repository holds `grants.edn`, a
description of the access each task may have. When a task runs, it proves who
it is and the provider issues a credential that covers that task and expires
soon after.

The application reads a credential through its config, with a `#grant` reader
literal, and no environment variable is involved. Production and CI use the
workload identity their platform already provides. On a laptop, a small local
issuer with its keys in the Secure Enclave supplies the identity that is
otherwise missing there.

`grants` is a working title.
