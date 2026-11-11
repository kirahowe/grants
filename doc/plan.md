# Plan

Status: 2026-11-11. Nothing has been built.

This document says what to build first, in what order, and how to tell each
step worked. It replaces the handoff notes, whose open items were settled by
a review on 2026-11-11. The [design](design.md) records the decisions, and
[checks.md](checks.md) records the evidence.

## Where things stand

The review tested the design's riskiest claims on the owner's machine and
read the two existing applications. Fresh reviewers then read the result for
what was still complicated, what a builder couldn't build from, and what was
still claimed too strongly. What all of that settled:

- The Secure Enclave ties a key to the device, not to a program. So the
  first build is unsigned and says what that means, and fingerprints and
  live keys wait for a signed build.
- Claude Code's sandbox can contain an agent's commands, and the gateway can
  be that sandbox's proxy. The sandbox doesn't close the Keychain, and it
  isn't turned on anywhere on this machine today.
- Go's standard library is enough for the daemon, with a small Swift library
  for the enclave. The pieces were built and run.
- Anthropic's federation is documented as open to any organization whose
  owner sets it up. Nobody has tried it with a one-person organization.
- finance-aggregator's `bb dev` is its live instance, so its move happens in
  two stages.

One thing decides whether the project is worth starting, and only the owner
can check it.

## Before any code

### The check that decides the project

Run [spike/anthropic-federation](../spike/anthropic-federation/). It takes
about half an hour and an admin login to the Console. It registers a
throwaway software key with Anthropic, exchanges a signed token for a
credential, and makes one request.

If it works, every use case has its first step. If a one-person organization
can't federate, no provider in the three applications does, and what remains
is a gateway in front of sealed keys. That would still keep keys out of the
application's reach, but other tools already do it, and the project should
be reconsidered before anything is built.

The same run answers four smaller questions: whether the issuer's URL has to
look like a public address, whether the inference scope covers the batch
endpoints, whether a workspace's spend limit counts these credentials, and
whether Anthropic refuses an identity token that claims too long a life.

### Two more, later

- [spike/touchid](../spike/touchid/) before the signed build. It shows what
  a fingerprint prompt displays and whether one touch can open several keys.
- An Apple Developer Program membership before the signed build. Enrolment
  can take days, so start it when the second milestone is under way.

## The first version

The first version is the unsigned build, and it's the first three milestones
below. It does three things:

1. Replaces an application's Anthropic key with a federated grant, so no
   long-lived key for Anthropic exists anywhere.
2. Keeps a provider's test key sealed and behind the gateway, where the
   application can use it and can't read it.
3. Lets a sandboxed agent session use its own task's grants and nothing
   else.

It doesn't touch live keys or stored bank credentials. After it,
finance-aggregator's age store still holds the live Plaid key and the
database key, exactly as exposed as today. That is the largest standing risk
in the three applications, and it's what the signed build is for.

Not in the first version: fingerprints, live keys, wrap grants, the issuer's
window, request budgets, rules on request bodies, production, Codex,
certificates, and everything in [later.md](later.md).

## Milestones

Each milestone ends with things the owner can see on their own machine.

### 1. Anthropic through the gateway

Build:

- The daemon as a launchd agent: an enclave signing key, identity tokens,
  and the Anthropic exchange.
- The gateway's whole request path, because the built-in Anthropic rules need
  all of it: the order of checks, the request-target rules, `:allow`, the
  header rules, the gateway's own errors, and each grant reporting whether
  it's ready.
- The control socket: `hello`, `declare`, `issuer`, `register`, `test`,
  `status`, and `log`. No approval yet. The daemon honours any valid file
  until milestone 3, because until a sandboxed session exists an approval
  protects nothing.
- The strict file reader.
- The `grants` command: `init` (install and register), `doctor` (from
  `status` and `test`), `log`, and `run`.
- The cases from [vectors.md](vectors.md) as fixtures, run against the real
  reader and the real listener.
- The Clojure library: `#grant`, `#grant/fake`, a check for whether an
  issuer is there, one connection per process, and coming back after the
  daemon restarts.
- finance-aggregator's first-stage changes for Anthropic
  ([use-cases.md](use-cases.md)).

It worked if:

- The cases in [vectors.md](vectors.md) pass, apart from those that need a
  sealed key, an approval, or a session port.
- `grants init` in finance-aggregator ends with `grants doctor` reporting
  `:llm/claude` ready, and `grants log` shows the test exchange.
- An extraction runs end to end, first in a JVM on a copy of the database
  that declares the `:dogfood` task, and then in `bb dev`.
- The Console's history shows exchanges for `finance-aggregator:dev`.
- With the Anthropic rule's credential lifetime set to one minute, an
  extraction that takes longer still succeeds.
- With the agent removed from launchd, an extraction fails within a few
  seconds with an error that names `:llm/claude`. It doesn't hang.
- While `bb dev` is running, restarting the daemon doesn't break it: the next
  extraction succeeds with no restart of the server, and `(reset)` in the
  REPL doesn't end the task.
- With the screen locked, an extraction still succeeds.
- The test suite passes with the agent removed.
- A second jj workspace can declare `:dev` with nothing done there.
- The control socket's file mode is 0600, and a connection from another user
  account is closed.
- The server no longer reads the Keychain item `finances-anthropic`. The
  item and the API key in the Console are deleted once the evaluation runs
  have moved too: now, if the inference scope covers the batch endpoints, or
  in milestone 2 with a capped key if it doesn't.

### 2. Sealed keys

Build:

- An enclave key for sealing, `grants seal`, and the sealed record with its
  binding.
- `:provider :http` in the gateway, and readiness for a sealed grant.
- `grants init` sealing whatever isn't sealed.
- finance-aggregator's Plaid client built from a reference.

It worked if:

- The cases in [vectors.md](vectors.md) about sealed values pass.
- The Plaid sandbox flow test passes through the gateway, from the test
  runner and from the REPL, and doesn't skip.
- A call to a path outside `:allow` gets a 403 from the gateway and never
  reaches Plaid.
- Changing the grant's `:host`, its header, or its bound in the file makes
  that grant refuse with `binding_mismatch` until the key is sealed again,
  while `:llm/claude` in the same task keeps working.
- On a machine where the Plaid key was never sealed, `:llm/claude` works and
  a deref of `:plaid/sandbox` says to run `grants seal :plaid/sandbox`.
- No file under the home directory or the repository holds the sandbox
  secret in the clear. The owner checks by searching for a fragment of it.

### 3. Agent sessions

This milestone turns on a sandbox that isn't on today, so part of it is
deciding how the owner's sessions should work under one.
[use-cases.md](use-cases.md#the-owners-agent-sessions) lists what breaks.

Settle first: how a sandboxed agent runs a dev server or an end-to-end test
(open question 2 in the design). If there's no good answer, this milestone
ships for sessions that don't need one, and says so.

Build:

- Approval: the canonical form and its hash, `policy`, `approve`,
  `grants approve`, and `grants init` approving the file it set up.
- Session ports, and `:egress`.
- `grants agent`: the generated settings, a private dependency cache for the
  session, and write access to the main repository's store when the session
  is in a second workspace.
- A wrapper so the owner's usual way of starting a session goes through it,
  including the resume command that the session manager types.

It worked if:

- The remaining cases in [vectors.md](vectors.md) pass: the hashes, the two
  about approval, and the session ports.
- A workspace with the approved file declares with no prompt. One with an
  edited copy is refused until `grants approve`, and going back to an older
  version is refused too.

And inside a session started with `grants agent`:

- The environment shows a loopback URL and no key.
- A request to Anthropic through the task's URL succeeds, and a direct one
  fails.
- The nREPL port of a running `bb dev`, the control socket, an SSH key, and
  the issuer's directory are all out of reach.
- A URL copied from another running task is refused.
- The session's URL stops working when the session ends.
- The owner's loop still works as far as was decided: a commit in a
  workspace, and the test gate.

What it knowingly leaves open: the Keychain, everything the harness does
outside a shell command, and sessions that don't start through the launcher.

### 4. The signed build

Needs the Apple Developer Program membership, and a decision about where
finance-aggregator's live instance runs.

Build:

- The bundle: signed with a Developer ID, notarized, with a keychain access
  group, and registered with launchd from inside the bundle. Whether launchd
  still holds the sockets for an agent registered that way hasn't been
  checked. If it doesn't, the issuer binds them itself.
- Keys, the approved file, and sealed values moved into the keychain access
  group.
- A third enclave key that needs a fingerprint.
- The issuer's window: approvals, sealing, and the prompt that starts a live
  task.
- `:bound :live`, one live task per application, the tie to a directory, and
  wrap grants.
- finance-aggregator's second stage, ending with its migration.

It worked if:

- A second program that reads the issuer's files can't use its keys. This is
  the review's two-program test, now failing.
- Starting the live task asks for one fingerprint, in a window that names
  the application, the task, the directory, and the program that asked.
- Declaring the live task from another directory is refused, and so is a
  second live task while one is running.
- A live task started from inside an agent session waits for a fingerprint
  the agent can't give.
- With the age files moved aside, the application starts, lists its
  connections, and syncs one.
- The dogfood task, given a copy of the database, can't open the bank
  credentials in it.
- The age store is deleted, and the Plaid secret and every SimpleFIN access
  URL have been rotated.

### 5. The other applications

- website-admin's development and eval tasks through `grants run`. Tag
  suggestions work in development, and its two Keychain items are deleted.
- horizon starts with a `grants.edn` and never has a secrets file.
- A production resolver, and with it a second reader of the file, when an
  application is about to deploy.

Milestones 3 and 4 don't depend on each other. The third costs nothing but
is a change to how every agent session works. The fourth removes the biggest
standing risk and needs the membership. A reasonable order is to start the
enrolment during the second milestone, do the third while waiting, and then
the fourth.

## How the code is laid out

```
daemon/                       one Go module with no third-party modules
  cmd/grants/                 the command, and the daemon as a subcommand
  internal/edn/               the strict reader
  internal/policy/            schema, canonical form, hash, differences
  internal/control/           the control socket
  internal/gateway/           listener, checks, :allow, headers, forwarding
  internal/issuer/            tasks, identity tokens, readiness
  internal/providers/anthropic/
  internal/seal/              sealed records
  internal/store/             what's kept on disk, and the log
  internal/launcher/          run, agent, the generated settings
  internal/keystore/          an interface, with a software key for tests
  internal/darwin/            the bridge to the Swift library, launchd sockets, peer checks
  native/                     Swift: enclave keys now; window, Touch ID, keychain later
  packaging/                  launchd description, build script
clj/                          the Clojure library: one namespace, grants.core
conformance/                  fixtures from vectors.md
doc/  spike/
```

Everything outside `internal/darwin` builds and tests on any machine with the
software key, behind a build tag, so most tests never touch the enclave.

The library depends on a JSON library and nothing else. It needs a JDK with
Unix-domain sockets, which the applications already have.

Rules for the build:

- The daemon uses Go's standard library only, and `encoding/json/v2` for all
  JSON. The older JSON package keeps the last of two duplicate keys.
- The gateway never lets a decoded path reach the `:allow` matcher.
- The build script signs the binary with the hardened runtime, even for the
  ad-hoc signature. That alone blocks code injection.
- The enclave keys that aren't behind a fingerprint are created "after first
  unlock", so a locked screen doesn't stop the gateway.
- The fixtures come first. A reader or matcher is done when the cases pass.
- The issuer never uses the file-based keychain.
- No experiment touches the keychain or raises a system prompt from an agent
  session. [spike/README.md](../spike/README.md) has the rules.

## Decisions waiting on the owner

| Decision | Needed by | Recommendation |
| --- | --- | --- |
| Whether the Anthropic check passes | Before milestone 1 | Run it first. Everything else depends on it |
| An Apple Developer Program membership | Milestone 4 | Enrol during milestone 2. Without it there are no fingerprints and the age store stays |
| What an agent session may still do outside its sandbox | Milestone 3 | As little as possible. Keep pushing and `gh` with the owner. A Codex review is the one worth weighing |
| Where finance-aggregator's live instance runs | Milestone 4 | A separate clone is the arrangement that holds. Staying in the main working copy keeps the REPL on real data and leaves a known hole |
| The name | Before anything is published | Open |

## What could change the plan

- **The Anthropic check fails.** See above.
- **A workspace's spend limit doesn't count federated credentials.** Then
  nothing caps what an agent can spend, and request budgets
  ([later.md](later.md)) move into the first version.
- **Anthropic accepts an identity token with a long life.** Then in the
  unsigned build a signed token could be saved and used later, and the
  design's claim about that build has to be weakened.
- **The inference scope excludes batch requests.** finance-aggregator's
  evaluation runs keep a capped API key behind the gateway.
- **The issuer's URL has to be a public address.** A design edit: the URL
  becomes one under a domain the owner controls. Nothing has to be served
  there.
- **Restoring or using an enclave key through the Swift bridge misbehaves.**
  The fallback is the route through Security.framework, which also worked.
- **No good answer for servers inside a sandbox.** Agent sessions that need
  to run one stay unsandboxed, and the third milestone covers fewer of them.
- **A local Worker can't reach loopback.** website-admin's development task
  needs another route, and that application moves later.

## A stopgap worth considering

finance-aggregator's age key is a plain file today, and the fourth milestone
is some way off. `age-plugin-se` can hold an age identity in the Secure
Enclave behind a fingerprint, and the `secrets` library decrypts by running
the `age` command, which loads plugins. Re-encrypting the store to such an
identity would make the key file useless off the machine and put a
fingerprint in front of every start.

Nobody has tried this with the `secrets` library, and its helper functions
may assume the ordinary key format. It's about an hour to find out, and it
would close most of the gap until live keys arrive.
