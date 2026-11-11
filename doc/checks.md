# What was checked

Status: 2026-11-11.

The [design](design.md) rests on claims about Apple's platform, two agent
harnesses, several providers, and the applications it has to serve. This
document lists each claim, what was found, and how carefully it was checked:

- **Tested** means it was run on the owner's machine on 2026-11-11: Apple
  silicon, macOS 27.2, Claude Code 2.1.322, Codex 0.167.1, Go 1.27.4,
  Swift 6.4.2.
- **Read** means a primary source was read: a vendor's documentation, or
  source code.
- **Open** means nobody has checked it.

Most of the testing was done by review agents working in parallel, each on
one area. Their findings were merged into the other documents.

## The Secure Enclave and code signing

| Claim | Result | How |
| --- | --- | --- |
| An enclave key can be used only by the signed program that created it | False. The enclave ties a key to the device. A second program with a different signature loaded the first one's stored key, signed with it, and unsealed with it | Tested with two ad-hoc-signed Swift programs, with the `swift` interpreter, and through Security.framework from C. Apple's engineers say the same on the developer forums (thread 804612) |
| A key kept in the data protection keychain is tied to its access group | True, and it needs a signing identity. An ad-hoc program gets a missing-entitlement error, and one that claims the entitlement is killed at launch | Tested. Apple's technotes TN3137 and TN3125 explain why: the entitlement has to be authorized by a provisioning profile |
| The data protection keychain works from a launchd agent in the user's session | Probably. Apple rules it out for daemons and ties it to a user context. Secretive's agent uses it as a login item | Read. Not tested for a plain launchd agent |
| An enclave key that needs a fingerprint can unseal data, not only sign | True. Both operations were refused without a fingerprint, and both are available on such a key | Tested up to the refusal. The path with a real fingerprint is open |
| A fingerprint key's stored form can be used by any program, given a fingerprint | True as far as tested: a second program got as far as "user interaction is required" | Tested. The owner-run script in `spike/touchid` finishes this check |
| One fingerprint can cover several enclave operations | Open | The same script, step 3 |
| A process can't attach to an issuer signed with the hardened runtime | True for an unprivileged process of the same user, and also true for a plain ad-hoc binary | Tested with `task_for_pid` |
| A plain ad-hoc binary resists code injection | False. It loaded a library named in `DYLD_INSERT_LIBRARIES`. The same binary signed with the hardened runtime ignored it | Tested. An ad-hoc signature can carry the hardened runtime flag |
| Go can reach the enclave | Yes, two ways. Through Security.framework it works, but restoring a key in a later process needs an attribute that isn't in the public headers. Through a small Swift library linked into the Go binary it uses CryptoKit's documented format | Both built and run. An ES256 signature made each way verified in OpenSSL |
| A key created "when unlocked" works for a background service | False. Creating one failed while the screen was locked. "After first unlock" worked | Tested, with the screen locked |
| Go and a native window can share a process | Yes. A window with a text view, a secure field, and a Touch ID view was built while the same process served HTTP | Built off screen. Not shown, and not driven by a person |
| A Touch ID prompt identifies who is asking | False. The prompt shows the calling program's name and a reason string that the caller supplies | Read, in the SDK headers |
| Existing Go libraries give a working enclave backend | Not for this. `sks` and smallstep's `mackms` make keychain keys that need entitlements, and neither can unseal | Read, in their source |

The signed build needs an Apple Developer Program membership (99 USD a
year), a Developer ID certificate, a provisioning profile that authorizes a
keychain access group, and notarization. The free tier's profiles expire
after seven days, which doesn't suit a daemon.

## Claude Code's command sandbox

Each test ran a headless session with generated settings, in a throwaway
project, against dummy files and servers.

| Claim | Result | How |
| --- | --- | --- |
| A denied path can't be read by a sandboxed command | True, for `cat`, Python, and Babashka | Tested |
| A read rule for the file tool is enforced only by the harness | False, in the useful direction. The same rule also became an operating-system denial for shell commands | Tested |
| Settings in the repository can't loosen settings passed at launch | True for the sandbox, once the launch settings forbid unsandboxed commands. Every loosening key in the repository was ignored | Tested |
| The repository can't run code outside the sandbox | False. Its session-start and tool hooks ran unsandboxed and read a denied file. It could also add its own MCP server to the allowed list | Tested. `--setting-sources user` stopped both |
| A loopback port listed as an allowed domain is reachable | Only for a client that sends loopback traffic through the proxy. The sandbox sets `no_proxy` for loopback, so `curl` connects directly and is blocked, and a JVM never uses the proxy | Tested |
| The gateway can be the sandbox's proxy | Yes. With a port set as the proxy, `curl`, `nc`, and a JVM all connected to it directly, and all three were refused on another local port. Other traffic arrived at that port as proxy requests | Tested |
| The setting that lets commands bind local ports is narrow | False. Its documentation says it lets commands connect to every local port | Read. Direct connections to one port were tested with it on |
| An unlisted Unix socket can't be reached | True | Tested |
| The login Keychain can't be reached from inside | False. A sandboxed `security` command read a dummy item. No setting denies it | Tested |
| SSH to a remote works inside the sandbox | False on macOS, by the documentation | Read |
| One macOS sandbox can start inside another | False. The inner one failed to apply | Tested with `sandbox-exec` |
| A copy-on-write clone makes a private dependency cache cheap | Yes. Cloning a 1.3 GB Maven repository took under three seconds | Tested |
| A second jj workspace is self-contained | False. Its store is a pointer into the main repository's directory. jj also keeps a repository's config under the home directory | Tested |

Open: what a sandboxed command can write among the project's own config
files, and whether the harness refuses a request to leave the sandbox. Both
were read in the documentation and not run.

## Codex's sandbox

Codex can run a command under its sandbox with no model call, so nearly all
of this was tested directly.

| Claim | Result | How |
| --- | --- | --- |
| A listed path can be denied | True, including files created later and links to a denied path | Tested |
| One loopback port can be allowed without the rest | False. The proxy drops the port from a rule, so allowing one port on an address allowed the others | Tested |
| The gateway can sit behind Codex's proxy | Yes over HTTP: given an upstream proxy, Codex's proxy forwarded allowed requests to it | Tested. HTTPS through that route is open, which is why the first version supports Claude Code only |
| A repository can't loosen the launcher's settings | False in a trusted project, where the repository's config merged into the profile and reopened denied paths. Marking the project untrusted for that launch fixed it | Tested |
| A custom profile protects `.git/hooks` and `.git/config` | False in this version, though the built-in profile does. Explicit entries closed them | Tested |
| The Keychain can't be reached from inside | False when the profile enables networking. Denying `~/Library/Keychains` blocked it | Tested |
| Codex can run against a local base URL with a placeholder key | Yes | Tested against a fake local server |

## Anthropic's federation

| Claim | Result | How |
| --- | --- | --- |
| It's available to an organization with one member | Nothing says otherwise. The only requirement stated is an admin or owner role | Read. The real answer is the owner-run check in `spike/anthropic-federation` |
| A public key can be registered inline, with no endpoint to fetch | Yes | Read. One table on the same page says the issuer URL needs a public host, which the hand check settles |
| ES256 is accepted, and the header needs a `kid` | Yes | Read |
| The setup endpoints refuse API keys | Yes. They need an admin's OAuth login | Read |
| A rule can require a fingerprint through a claim | Not safely. A rule sees a token's claims and not which key signed it | Read |
| An exchange needs only the token | False. It also needs the ids of the rule, the organization, and the service account, and the workspace's when a rule covers more than one. The issuer sends all four every time | Read |
| A signed identity token can be saved and used later | No, by the documentation. A token has to start now and may last no longer than the issuer's registration allows, which setup sets to ten minutes | Read. The hand check in `spike/anthropic-federation` tries an over-long token |
| A failed exchange says why | False. Every refusal is the same 401, and the reason is in the Console's history | Read, and tested with a made-up rule id |
| An inline key is refreshed | Never. Replacing one takes an admin login | Read |
| `workspace:inference` covers Message Batches | Unsupported. The scope lists Messages, token counting, and Models | Read. Open until tried |
| A workspace spend limit applies to federated credentials | Open. Usage is attributed to the workspace, and nothing says the limit applies. The default workspace can't have a limit | Read |
| The official SDKs accept a base URL with a path prefix over plain HTTP | Yes for Python, TypeScript, and Java | Read, in their source. Not run |
| Claude Code works against a local base URL with a placeholder credential | Yes. It posts to `/v1/messages?beta=true` and retries on a 401 | Tested against a fake local server |
| Doing that keeps the subscription | No. With a placeholder credential the session is billed to whoever owns the credential the gateway attaches | Read |
| Claude Code can federate by itself | Yes, from a rule's ids and a file holding an identity token | Read |
| The Anthropic CLI installs with `brew install ant` | False. That installs Apache Ant. The formula is `anthropics/tap/ant` | Tested with `brew info` |

## Other providers and platforms

| Claim | Result | How |
| --- | --- | --- |
| OpenAI accepts a custom issuer with an inline key | Partly. The route with an uploaded key set is documented for SPIFFE. For other issuers its guide says to contact support, and Codex's federation is a beta | Read |
| OpenAI accepts ES256 | Open. Only one example uses it | Read |
| Fly's identity is in a form Anthropic accepts | Yes. Its issuer serves a public discovery document and signs with RS256 | Tested by fetching it |
| Plaid takes its credentials as headers | The Java SDK sends both as headers and nothing in the body | Tested with plaid-java 35.0.0. Whether Plaid's servers accept headers on every endpoint is open |

## The gateway's building blocks

| Claim | Result | How |
| --- | --- | --- |
| Go's HTTP server normalizes a request path | False. It passes `..` through, and it shows `%2F` decoded in one field and raw in another | Tested with raw requests |
| Go's reverse proxy forwards only what it should | False for this purpose. A client's `x-api-key` and `Cookie` reached the upstream beside the attached credential, and so did a WebSocket upgrade | Tested |
| It streams server-sent events without buffering | True | Tested |
| Go's JSON decoder refuses a duplicate key | The original package keeps the last one and matches names without regard to case. `encoding/json/v2` refuses the duplicate | Tested |
| A general EDN reader is safe for a policy file | False. `clojure.edn` and the one Go library disagree on duplicate keys and unknown tags, and `clojure.edn` rewrites several inputs silently | Tested in Clojure, Babashka, and Go |
| A strict reader for the subset is small | Yes. One was written in about 300 lines of Go | Built, with a short fuzz run |
| A specific loopback bind can be taken by another process | Not on `127.0.0.1` while it's held. `::1` is separate and has to be held too. `localhost` resolves to `::1` first | Tested |
| Node's `fetch` sends `Origin` to a local server | No. It sends `Sec-Fetch-Mode` only | Tested |
| stripe-node accepts a base URL with a path | False. It takes a host, a port, and a protocol | Read |
| Babashka can open a Unix socket | Yes | Tested |

## The applications

| Claim | Result | How |
| --- | --- | --- |
| finance-aggregator has a separate production task | False. `bb dev` is the live instance | Read, in its config, tasks, and docs |
| Its Plaid calls are the eleven in the earlier use case | True | Read |
| Its Anthropic client reads the key for each request | False. It reads once per call and reuses it across retries | Read |
| website-admin's Worker already takes a base URL | False. Neither variable in the earlier use case exists in the code | Read |
| The owner's sessions run in a sandbox | False. No settings file enables one | Read |

## The home-directory experiment

Denying the whole home directory was tried on macOS with this profile, run as
`sandbox-exec -f nohome.sb <command>`:

```
(version 1)
(allow default)
(deny file-read* (subpath "/Users/kira"))
(allow file-read* (subpath "/Users/kira/code/projects/grants"))
(allow file-read-metadata (literal "/Users/kira") (literal "/Users/kira/code") (literal "/Users/kira/code/projects"))
```

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

Everything that broke was config or a dependency cache, which is why denying
the home directory is an optional tightening and not where an agent starts.

## What the testing itself broke

One test did damage, and it's recorded here because it bears on how the
signed build is developed.

A test of the older file-based keychain raised a system dialog. The test
process was killed while the dialog was pending, and `securityd`, the system
service that holds every keychain's unlock state, crashed at that moment. It
restarted with the login keychain locked. Every program that then read the
keychain queued an unlock prompt, the queue grew until the service crashed
again, and that repeated twelve times in half an hour until the machine was
restarted.

Three things follow:

- The issuer never uses the file-based keychain.
- Experiments with the keychain or with fingerprint prompts are written as
  scripts for the owner to run, or run in a virtual machine or a separate
  user account. `spike/touchid` is written that way.
- Many tools read their logins from the login keychain with the `security`
  command, Claude Code among them. Anything that leaves the keychain locked
  stops them all.
