# Handoff: starting the build

Written 2026-11-11, at the end of the session that reviewed the design.
Nothing has been built. These notes are for whoever picks the work up in a
fresh session: what state things are in, what to do first, and what the
other documents don't say.

## Where things stand

The design was tested against the owner's machine and the two real
applications, simplified, and read twice more by fresh reviewers. The
documents now agree with each other and with what was found.

Read in this order:

1. [plan.md](plan.md): what to build, in what order, and how to tell each
   step worked.
2. [design.md](design.md): how it works and why. Its Decisions section is the
   short version of the review.
3. [protocol.md](protocol.md) and [vectors.md](vectors.md): what the code has
   to do, exactly. Read these when you start on the part they cover.
4. [use-cases.md](use-cases.md): what each application needs changed.
5. [checks.md](checks.md) and [threat-model.md](threat-model.md) when a
   question comes up about what is known or what is protected.

The review changed the design in ways the owner has seen in summary and
hasn't read in full. If any of these turns out to be unwanted, say so before
building on it: profiles were dropped in favour of separately named grants,
every grant on a laptop goes through the gateway, the remote minter and
browser callers were set aside, and the first version is an unsigned build
with no fingerprints.

## What happens next

### 1. The owner runs the Anthropic check

[spike/anthropic-federation](../spike/anthropic-federation/) decides whether
the project goes ahead. It needs the owner's Console admin login, so an
agent can't run it. When it's done:

- Record each result in [checks.md](checks.md), replacing the rows marked
  open.
- If a result is one of those listed under "What could change the plan" in
  [plan.md](plan.md), make that change to the documents before any code.
- Keep the ids it produces only if the test workspace is kept. The real
  setup is done by `grants init` later.

### 2. Milestone 1, in a workable order

1. Lay out the repository as [plan.md](plan.md) describes.
2. Turn the tables in [vectors.md](vectors.md) into fixture files. They come
   first, because the reader and the gateway are done when the cases pass.
3. Write the strict reader and the schema check against the file cases.
4. Build the enclave library and its bridge, starting from
   [spike/enclave-go-swift](../spike/enclave-go-swift/). It has to create a
   key, restore it from its stored form in a later process, and sign. Write
   the software-key twin at the same time, so every other package can be
   tested without the enclave.
5. Sign an identity token and exchange it, against a registration made by
   hand as in the Anthropic check.
6. Build the gateway's request path with the built-in Anthropic rules, and
   run the gateway cases against the real listener.
7. Build the control socket, the launchd agent, and the `grants` command.
8. Write the Clojure library.
9. Make finance-aggregator's first-stage changes.

### 3. Decisions waiting on the owner

The table in [plan.md](plan.md) lists them with a recommendation for each.
The owner has said an Apple Developer Program membership isn't off the
table. Nothing else has been decided.

## Things the other documents don't say

Build details the review found by building small proofs:

- Go's linker signs its output with the identifier `a.out`. Sign again with
  `codesign -f -s - -o runtime -i <identifier>`, which also turns on the
  hardened runtime.
- Go refuses a Swift static library named on a `#cgo LDFLAGS` line. Pass it
  in the `CGO_LDFLAGS` variable from a build script.
- Reading the peer's user id on a Unix socket, and taking over launchd's
  sockets, both need cgo. Neither is in Go's `syscall` package.
- Create the ordinary enclave keys with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. With "when unlocked",
  nothing works while the screen is locked.
- When fingerprint keys arrive, use `.biometryCurrentSet`. `.userPresence`
  also accepts the login password.
- `encoding/json/v2` ships in Go 1.27.4 with no flag.
- The Anthropic CLI is `brew install anthropics/tap/ant`. Plain `ant` is
  Apache Ant.
- `plaid-java` prints a warning on every call when its base URL isn't one of
  Plaid's own. It still works.

Where finance-aggregator's first-stage changes land. Paths are under
`backend/`, and the line numbers are as of 2026-11-11:

| File | What changes |
| --- | --- |
| `src/finance_aggregator/sys.clj` (49-104) | Add `grant` and `grant/fake` to the reader map |
| `resources/system/base-system.edn` (61) | `:client #grant :llm/claude` in place of the Keychain item's name |
| `src/finance_aggregator/system.clj` (217-236) | Pass the reference through, with no Keychain |
| `src/finance_aggregator/statement/llm.clj` (526-531, 548-552, 564-620) | Deref on every attempt, and build every URL from `:base-url` |
| `src/finance_aggregator/web/pages/statements.clj` (458-461, 498-503) | Recognise the library's error for a missing grant |
| `evals/resources/evals/registry.edn` (93-109), and `registry.clj` (110-116) | The same reference, or the evaluation runs break when the Keychain item goes |
| `env/test/resources/config.edn` | Replace each `#grant` with a `#grant/fake` |
| `src/finance_aggregator/plaid/client.clj` (33-47, 471-477) | Milestone 2: build the client from a reference, and make the sandbox guard read `:bound` |
| `test_utils/plaid_sandbox.clj` (29, 52-60) | Milestone 2: use the real grant when an issuer is there, and skip when it isn't |

Three facts about that application that are easy to forget: `bb dev` is the
live instance, it reloads changed code on every request, and its database
allows one writer, so anything that opens the real database has to run with
the server stopped. Try changes in a JVM on a copy first.

## Working rules from this session

- **No keychain experiments in the owner's login session.** One crashed
  `securityd`, locked the login keychain, and took a restart to clear.
  [checks.md](checks.md) has the account. Anything that touches the keychain
  or raises a system prompt is a script the owner runs, or runs in a virtual
  machine or a separate account. Never kill a process while a system prompt
  it raised is showing.
- **Give review agents reading tasks.** The agents that ran experiments left
  two stray writes outside their scratch directories. The later reviewers
  were limited to reading files, and that worked well.
- **Count concepts.** The owner wants this simple in Rich Hickey's sense and
  easy to use. Each review round proposed more mechanism than the design
  kept. Before adding a guard, look for a concept to remove, and don't add
  one whose only job is to stop an attacker the threat model already
  concedes.
- **This is a jj repository.** Commit with `commitp`, by path, and run prose
  through the humanizer skill, as the project instructions say.

## Loose ends outside this repository

- `~/.claude-kira/settings.json` has become a plain file again and has
  drifted from the copy in `~/code/configs/claude`. That repository's README
  says what to do: copy the live file over the repository's copy, and link
  it back. On 2026-11-11 two `ask` rules for `jj tugp` were added to the live
  file, because the alias pushed without matching the rule for `jj git push`.
  The repository's copy doesn't have them until that sync is done.
- The first milestone installs a launchd agent and a command in the owner's
  home directory. Say what will be installed and where before doing it.
