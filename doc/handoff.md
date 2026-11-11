# Handoff: gaps to settle before building

Written 2026-11-11, at the end of a session that reviewed the
[threat model](threat-model.md). Nothing has been built. These notes list
what still has to be settled, in the order worth settling it, with what is
known about each item and how it was checked.

The gaps themselves are recorded in the docs. "Question" below means a
numbered entry under [Open questions](design.md#open-questions) in the
design, and "gap" means a numbered entry under
[Known gaps](threat-model.md#known-gaps) in the threat model. Where these
notes suggest an answer, the suggestion is a starting point from one reading
of the docs. None of them has been discussed or agreed.

## Before editing

Another session was changing the same four documents while this one ran.
Run `jj st` before the first edit, and commit by path
(`commitp -m "..." doc/design.md`) so that someone else's uncommitted work
stays out of the commit.

## What this session settled

A sandbox is optional. `grants run agent` starts the harness at its own
command sandbox with a deny list of credential files, and denying the whole
home directory is an optional tightening. The design records this under
"Sandbox levels" in its Decisions, and the threat model has a
[Sandbox levels](threat-model.md#sandbox-levels) section that lists what
each level leaves open.

## 1. Check before writing code

These three could change the design if they turn out wrong, and each is
cheap to check.

### 1.1 The code-signature boundary on macOS (question 7)

The threat model's second boundary says that only the issuer's signed binary
can use its enclave keys. Sealed keys, live keys, and wrapping keys all
depend on it.

What was found:

- Apple's page on signing a daemon with a restricted entitlement says a
  daemon is a standalone executable, so it can't embed a provisioning
  profile, and that the way around this is to wrap the daemon in an app-like
  bundle. This was read at the source.
- The keychain access group that would tie a key to the issuer is believed
  to be an entitlement of that kind on macOS. This is from memory and was
  not checked.
- A Secure Enclave key made through CryptoKit has a stored form that appears
  to be bound to the device and not to the application, so any process that
  can read the stored form could use the key. This comes from a search
  summary of forum threads and a pull request review, and no Apple statement
  was found.
- An Apple engineer wrote on the developer forums that the data protection
  keychain isn't supported from a `launchd` daemon. The design installs the
  issuer as a `launchd` agent in the user's session, which is a different
  case, and the thread doesn't cover agents.

If all of this holds, the issuer on macOS is an app-like bundle signed by
one Apple developer team with a provisioning profile, and a copy built from
source has no code-signature boundary. That affects how other people install
it, and it may affect the choice of Go for the macOS issuer, since the
approval window and Touch ID also want native code.

To settle it, build two binaries with different signatures. The first
creates an enclave key and seals a value. The second tries to use that key
and to unseal the value. The boundary exists only if the second one fails.
Run the same test with a key that requires a fingerprint. This belongs
before part 1 of the design's first spike.

Sources:

- https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement
- https://developer.apple.com/forums/thread/799625
- https://developer.apple.com/forums/thread/119315

### 1.2 Anthropic federation with one member

The design's claims to check include "Workload identity federation is
available to a Console organization with one member." Every use case starts
with an Anthropic grant, so this one decides whether a solo developer can
use the design at all. It hasn't been checked.

### 1.3 What the harness sandboxes can express

The design's claims to check have three entries about Claude Code and Codex.
The setting names below come from each product's documentation, read on
2026-11-11. Nothing was run against either harness.

Claude Code (https://code.claude.com/docs/en/sandboxing):

- The sandbox covers Bash commands and the processes they start. The file
  tools, web fetches, MCP servers, and hooks run outside it.
- Reads are allowed everywhere by default. `sandbox.filesystem.denyRead`
  blocks paths and `allowRead` reopens paths inside a denied one. Read
  permission rules are what restrict the file tools.
- Egress goes through a local proxy that checks `network.allowedDomains`,
  which starts empty. A loopback address has to be listed with its port,
  such as `127.0.0.1:3000`. `network.httpProxyPort` replaces the proxy with
  one you run.
- `network.allowLocalBinding` on macOS opens every localhost port.
  `network.allowUnixSockets` lists socket paths.
- `allowUnsandboxedCommands: false` stops a failed command from being run
  again outside the sandbox.
- Repository settings can loosen the sandbox. The documentation says they
  are ignored when managed settings set `allowUnsandboxedCommands` to false
  or `allowManagedDomainsOnly` to true. It doesn't say whether settings
  passed with `--settings` get the same treatment, and that is the second of
  the three claims.
- `sandbox.credentials` with `mode: mask` already does a form of injection:
  the command sees a placeholder and the proxy substitutes the real value.
  It needs `network.tlsTerminate`, which is marked experimental.

Codex (https://learn.chatgpt.com/docs/permissions.md, installed version
0.167.0):

- A permission profile under `[permissions.<name>]` sets `read`, `write`,
  or `deny` for each path. The older `sandbox_mode` settings document no way
  to deny a read.
- Network access is off by default. A domain allowlist needs
  `features.network_proxy = true`.
- The examples allow `localhost` and `127.0.0.1` as hosts, with no port.
  Whether one port can be allowed without the rest is the third claim.
- Unix sockets are allowed by path under `network.unix_sockets`.
- The documentation describes the sandbox in terms of spawned commands and
  doesn't mention MCP servers.

## 2. Holes in the design

Questions 8 to 11 are best settled together, because their answers define
the socket protocol.

### 2.1 `#grant` inside a sandbox (question 8)

The command sandbox keeps the issuer's socket out of reach, and the library
on a laptop resolves a reference over that socket. A Clojure process that a
sandboxed agent starts therefore can't resolve any grant.

Suggested answer: the launcher gives the harness one gateway URL that
contains the task token. The library builds an injected reference from that
URL alone, with the gateway as `:base-url` and placeholder headers, and
never opens the socket. By-reference grants and wrap grants are unavailable
inside a sandbox. The URL would travel in an environment variable, which the
design already accepts for clients in other languages because it carries no
credential.

### 2.2 A sealed key follows the file (question 11, gap 15)

A sealed key is filed under its application, grant, profile, and slot. The
host it's sent to comes from `grants.edn`. Someone who changes `:host` gets
the key sent to the new host after one approval in the issuer's window, and
the threat model already says that people approve prompts they expect.

Suggested answer: record the host when the key is sealed, and refuse to send
the key anywhere else until the owner seals it again.

### 2.3 The working copy leads into other tasks (gap 14)

A sandboxed agent edits code in the project. The owner later starts `:serve`
with a fingerprint, and the agent's code runs with the live Plaid key and
can unwrap every stored token. The sandbox section lists another task's REPL
port as a route to close, and this is a wider route to the same place that
no sandbox level closes.

No answer is suggested. Ideas that haven't been examined: the issuer refuses
a task on a live profile when the working copy has uncommitted changes, or
the presence prompt for a live task says what changed since that task last
started.

### 2.4 When a declared task ends (question 9)

A task token works only while its task is running, and a live key stays
unsealed until its task ends. A process that declared its own task has no
launcher watching it.

Suggested answer: the library holds one connection to the issuer for the
life of the process, and the task ends when that connection closes. Under
this answer, restarting a REPL that holds a live key means another
fingerprint.

### 2.5 Which file a process means (question 10)

A process that declares a task names its project. Worktrees, jj workspaces,
and branches give one application several `grants.edn` files at once, and an
agent working in a workspace may have edited its copy. A second repository
can also claim an existing `:app`, which would put it in line for that
application's sealed keys and its `sub` prefix at every provider.

Suggested starting point: approve file contents by hash, record the
directory an application was first approved from, and require presence
before a different directory can use the same `:app`.

### 2.6 The issuer's own records (gap 16)

The pinned `grants.edn`, the live-key opt-ins, and the software-key opt-in
are kept on disk. If they are plain files, code running as the developer can
edit them and skip the approval window.

Suggested answer: the issuer signs each record with an enclave key, or keeps
it as a keychain item in its own access group. Both depend on 1.1.

### 2.7 What an agent's own model calls run on (question 14)

The `:agent` task lists `:llm/claude`. If that covers the harness's own
model access, the harness moves from the developer's subscription login to
API billing in a Console organization, which is a real cost of trying the
tool. If it covers only the code the agent runs, the harness keeps its own
login, and that login is one the tool doesn't manage.

### 2.8 What the starting sandbox level has to allow (question 1)

Allowing egress only to the gateway stops dependency fetches, and `git` over
SSH doesn't go through an HTTP proxy at all. Each exception reopens a route.
An allowed host is a way out for data, and a cache the agent can write to is
a way into whatever task loads from it next. Part 2 of the first spike can't
run until the default exceptions are chosen.

## 3. Specs to write

- **The socket protocol.** The design calls it the boundary between the
  daemon and its clients. It has no messages, framing, errors, or version
  yet.
- **The schema of `grants.edn`.** The Go daemon reads the file on a laptop
  and the Clojure library reads it in production (question 13). Shared test
  files would keep the two in agreement.
- **What `:allow` matches** (question 12). The design doesn't say how the
  gateway treats `..` segments, percent-encoding, query strings, or a
  trailing slash. A path rule also can't narrow an API that puts the
  operation in the request body.

## 4. What can wait until after the spike

The remote minter, Windows and Linux, cloud agents, people in browsers,
recovery of wrapped data, and more than one machine.

## The home-directory experiment

The design's "Sandbox levels" decision rests on this. To repeat it, save the
profile below with the paths changed, and run a tool under it with
`sandbox-exec -f nohome.sb <command>`.

```
(version 1)
(allow default)
(deny file-read* (subpath "/Users/kira"))
(allow file-read* (subpath "/Users/kira/code/projects/grants"))
(allow file-read-metadata (literal "/Users/kira") (literal "/Users/kira/code") (literal "/Users/kira/code/projects"))
```

The profile denies reads only, and it isn't the profile that Claude Code or
Codex generates. Results on 2026-11-11:

| Command | Result |
| --- | --- |
| `git` (any command), `jj log` | Failed on `~/.gitconfig` |
| `jj config get user.name` | Returned nothing, with no error |
| `clojure` | Wouldn't start, at `~/.clojure` |
| `uv` | Couldn't open `~/.cache/uv` |
| `gh`, `docker` | Couldn't read their config files |
| `zsh -ic` | Started without the functions from `.zshrc` |
| `ssh -G`, `aws configure list`, `mise current` | Ran as if unconfigured |
| `java`, `bb`, `node`, `go version`, `python3` | Worked. All are installed outside the home directory |
