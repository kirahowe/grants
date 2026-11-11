# Use cases

Status: draft, 2026-11-11. Nothing described here has been built yet.

The [design](design.md) is judged against three applications and against the
way their owner runs coding agents. Two of the applications exist and hold
real secrets today, and the third is about to start. This document takes each
one from what it does now to what it would do under grants.

The two existing applications were read in full on 2026-11-11, and this
version corrects an earlier one that had guessed at several details.
[checks.md](checks.md) records what was read and what is still unverified.

## finance-aggregator

A personal finance application in Clojure, built on Integrant. It has no
production other than the laptop.

### How it runs today

`bb dev` is the live instance. It starts one JVM from the main working copy
that does everything:

- serves the real database, `backend/data/dev.db`, on loopback, which
  `tailscale serve` exposes to the owner's other devices;
- runs the scheduled bank sync, once at startup and then daily for each
  connection;
- hosts the nREPL;
- reloads changed source files before every request.

It has to be one JVM, because the database allows a single writer. There is
no separate production task, alias, or config. Agents mostly work in sibling
jj workspaces under `finance-aggregator-ws/`, and landing a change on `main`
doesn't touch the main working copy's files.

Several other JVMs start alongside it: test shards, a continuous verify loop
in its own workspace, an end-to-end server, paid evaluation runs, and
`bb dogfood`, which boots a copy of the real database without the database
key so that an agent can exercise the application against real data without
being able to decrypt the bank credentials in it.

### What it holds today

| Secret | Where it lives | Who reads it |
| --- | --- | --- |
| Plaid client ID and secret, and which Plaid environment they're for | `secrets.edn.age`, opened by an age key in a plain file | The server at startup |
| A database encryption key | The same file | The server, for one attribute: each connection's stored secret |
| An optional OpenRouter key | The same file | Only with a non-default backend |
| An Anthropic API key | The login Keychain, item `finances-anthropic`, read with `security` | The server at first use, the evaluation runs, and dogfood |
| Plaid access tokens and SimpleFIN access URLs | The database, encrypted with the database key | Every sync |

The age key is a plain file, and `security` answers any process that runs as
the developer. An agent working in the repository can read all of them.

A SimpleFIN access URL deserves its own mention. It is a complete credential
that never expires, it works without any other secret, and the application
sends it straight to SimpleFIN's bridge. A Plaid access token is useless
without the Plaid secret.

### Under grants, in two stages

The first stage needs only the unsigned build. It moves the Anthropic key to
a federated grant and puts the Plaid sandbox credentials, which the tests
use, behind the gateway. The live Plaid key and the database key stay in the
age store.

The second stage needs the signed build. It moves the live Plaid key and the
stored bank credentials, and deletes the age store.

```clojure
;; grants.edn
{:app "finance-aggregator"

 :grants
 {:llm/claude
  {:provider :anthropic}

  :plaid/sandbox
  {:provider :http
   :host     "sandbox.plaid.com"
   :bound    :test
   :attach   {"PLAID-CLIENT-ID" :client-id
              "PLAID-SECRET"    :secret}
   :allow    [[:post "/link/token/create"]
              [:post "/item/public_token/exchange"]
              [:post "/item/get"]
              [:post "/item/remove"]
              [:post "/accounts/get"]
              [:post "/institutions/get_by_id"]
              [:post "/institutions/search"]
              [:post "/transactions/sync"]
              [:post "/investments/transactions/get"]
              [:post "/sandbox/public_token/create"]
              [:post "/sandbox/item/reset_login"]]}

  ;; second stage
  :plaid/live
  {:provider :http
   :host     "production.plaid.com"
   :bound    :live
   :attach   {"PLAID-CLIENT-ID" :client-id
              "PLAID-SECRET"    :secret}
   :allow    [[:post "/link/token/create"]
              [:post "/item/public_token/exchange"]
              [:post "/item/get"]
              [:post "/item/remove"]
              [:post "/accounts/get"]
              [:post "/institutions/get_by_id"]
              [:post "/institutions/search"]
              [:post "/transactions/sync"]
              [:post "/investments/transactions/get"]]}

  :connections/live
  {:provider :wrap
   :bound    :live}}

 :tasks
 {:dev     {:grants [:llm/claude :plaid/sandbox]}
  :dogfood {:grants [:llm/claude]}
  :agent   {:grants [:llm/claude]}
  ;; second stage
  :live    {:grants [:llm/claude :plaid/live :connections/live]}}

 :default-task :dev}
```

The eleven sandbox rules are exactly the Plaid calls the code makes. The live
grant leaves out the two that exist only on the sandbox host.

The whole file is valid in the unsigned build. The two live grants can't be
used there and the `:live` task can't start, and everything else works.

| Secret today | Stage | What replaces it | What is on the laptop |
| --- | --- | --- | --- |
| Anthropic API key | First | A federated grant | Nothing |
| Plaid sandbox credentials | First | A sealed grant, bound `:test` | A sealed test key |
| Plaid production credentials | Second | A sealed grant, bound `:live` | A sealed live key, opened with a fingerprint |
| Database encryption key | Second | A wrap grant, bound `:live` | A wrapping key that stays in the issuer |
| OpenRouter key, if used | Either | A sealed grant, bound `:capped` | A sealed key with a spend cap |

### What changes in the application, first stage

The application loads config with plain `edn/read-string` and its own map of
readers, so `#grant` and `#grant/fake` are two more entries in that map.

- The extraction settings take `:client #grant :llm/claude` in place of a
  Keychain item's name, and the component passes the reference through.
- `statement/llm.clj` derefs the reference on every attempt and builds every
  URL from its `:base-url`. Today it reads the key once per call and reuses
  it across retries that can each wait ten minutes, and its main call uses a
  separate full-URL setting. It keeps sending `anthropic-version`.
- The evaluation registry uses the same reference. It reads the Keychain item
  too, so deleting the item before this is done would break the evaluation
  runs and the gate that depends on them.
- The page that reports a missing key learns the library's error.
- The test config replaces each `#grant` with a `#grant/fake`. The
  full-system tests boot real config today and decrypt real test secrets.
  They have to run with no issuer, because a sandboxed agent that runs the
  test suite can't reach one.
- The Plaid client is built from a reference: the reference's base URL goes
  to the SDK, and its placeholder header values stand in for the credentials.
  The SDK sends both credentials as headers and keeps a path prefix in its
  base URL, which was tested. It prints a warning for each call to a base URL
  it doesn't recognise.
- A guard in the Plaid client refuses sandbox-only helpers unless the
  configured URL is the sandbox's. Behind the gateway that comparison always
  fails, so the guard reads the reference's `:bound` instead.
- The sandbox tests use the real `:plaid/sandbox` grant. They ask the library
  whether an issuer is there, and skip as they do today when it isn't. They
  run from the REPL as well as from the test runner, because both are the
  `:dev` task.

One question is open for the evaluation runs. They use Anthropic's batch
endpoints, and the scope a federated credential gets doesn't list those. If
it excludes them, the evaluations keep an API key, sealed with a spend cap
and limited by `:allow` to the calls they make, and the Keychain item stays
until that key is sealed.

### What the owner does once, first stage

1. Run `grants init` in the project. The first time on a machine it installs
   the agent and sets the machine up at Anthropic, which takes an
   organization admin login. For this application it adds one rule there,
   asks for the Plaid sandbox credentials and seals them, and approves the
   file.
2. Delete the Keychain item, and delete the Anthropic API key in the Console.

### A day of work, first stage

`bb dev` is unchanged. The JVM declares no task and gets `:dev`. Its first
extraction goes through the gateway on a credential that lasts minutes. An
editor's jack-in works the same way, and so does a test run.

Every workspace carries the same `grants.edn`, so none of them asks for
anything. A workspace whose copy an agent edited is refused until the owner
runs `grants approve` there and reads what changed.

Nothing prompts. The unsigned build has no fingerprints, and the live Plaid
key is still read from the age store as before. If the issuer is upgraded
while the server is running, the server reconnects and carries on.

### The second stage, and where live runs

The second stage starts with a decision about the application and not about
grants. Today `bb dev` is the live instance, it runs from the working copy,
and it reloads changed code on every request. Whatever is in that working
copy runs with the live key on the next page load, with no restart and no
prompt. A fingerprint at task start does nothing about code that changes
after the start.

Grants starts a live task only from the directory its keys were sealed for,
and never gives an agent session write access to that directory or to a
version-control store inside it. That leaves two ways to arrange things.

**Live moves to a separate clone.** A clone that no agent can write is
checked out at a commit the owner reviewed, with its own config, hot reload
off, data at absolute paths, and its own dependency cache. A deploy step
updates it and restarts the server, which takes a fingerprint. The owner
loses the REPL and hot reload on real data, and development runs against a
snapshot of the database with the Plaid sandbox. This is the arrangement
where a fingerprint means what it says: the code that runs with the live key
is code the owner chose.

**Live stays in the main working copy.** The live keys are sealed there, the
dev alias declares the `:live` task, and the owner keeps a REPL and hot
reload on real data. It's what exists today, and it's weaker in a way that
matters. Agents in other workspaces commit through the jj store that sits
inside the main working copy. If sessions are denied that store, agents
can't commit from their workspaces. If they're allowed it, a commit an agent
rewrote can arrive in the live directory with the owner's next `jj` command,
and hot reload runs it. The live JVM also loads from dependency caches that
agents may write.

The choice is the owner's. It has to be made before anything is wrapped,
because a wrapping key belongs to one grant and nothing re-wraps data from
one to another. Neither arrangement does anything about an unsandboxed
agent, which can write anywhere.

Either way, the second stage changes these parts of the application:

- The Plaid config holds a reference, and the application's own environment
  config says which grant it is.
- Storing and reading a connection's secret go through `grants/wrap` and
  `grants/unwrap`, with the connection's id as the context. The stored values
  have no such tie today, so one row's ciphertext opens in another row.
- The end-to-end server generates its own database key today. It needs a
  fake wrap.
- `bb dogfood` keeps working as it does now, for a different reason: its
  task doesn't list the wrap grant, so the copy's bank credentials stay
  closed to it. That holds for the dogfood code as written. Code that runs
  unsandboxed could try to declare the live task instead, and what stops it
  is the fingerprint and the rule that an application has one live task at a
  time.
- The secrets component, the Keychain helper, the age files, and the age key
  are deleted last.

### Migrating the stored credentials

This is the one step with no way back, so it goes in this order:

1. Ship code that reads both the old format and the new one, and writes the
   new one.
2. Seal the live Plaid key and approve the file, in the directory live will
   run from.
3. Stop the server, because the database allows one writer, and take a
   snapshot of the database.
4. Run a one-time migration under the `:live` task, with the old key still
   read from the age store. For each stored secret it decrypts, wraps with
   the connection's id, writes, and reads back to compare. It has to be safe
   to run twice.
5. Start the server and run one sync for each connection.
6. Rotate what the age store exposed: the Plaid secret, and every SimpleFIN
   access URL. The URLs work on their own, so wrapping them doesn't undo a
   past leak. Each one has to be revoked at the bridge and claimed again.
7. Only then delete the age files, the age key, and the snapshot.

Until step 7 the snapshot and the old code are the way back. After it there
is none. Losing the machine after that means linking every bank again, which
gives new connection ids that the application has to map onto its accounts.

### What stays exposed

After the first stage:

- An unsandboxed process can declare `:dev` and call Anthropic as this
  application. A spend limit on the workspace should cap that, if Anthropic
  applies the limit to these credentials, which isn't confirmed.
- The live Plaid key, the database key, and the stored bank credentials are
  exactly as exposed as today.

After the second stage:

- The running live task can make the allowed Plaid calls and unwrap any
  stored secret, and so can anything that evaluates code in it. The nREPL in
  the same JVM is such a route, and so is every device on the tailnet that
  can reach the application's pages, which have no login of their own.
- A SimpleFIN access URL is in the application's memory for as long as a sync
  takes. Open question 5 in the design is about removing that.
- After a restart the scheduled sync waits for a fingerprint at the laptop.

## website-admin

A phone and laptop PWA for drafting and publishing to a website, with one
Cloudflare Worker behind Cloudflare Access. The PWA and the Worker are
TypeScript, and the development tasks are Babashka. No part of it runs on the
JVM.

### What it holds today

| Secret | Where it lives |
| --- | --- |
| A GitHub fine-grained personal access token, with contents read and write on the drafts and content repositories | `localStorage` in the browser, on every device. The PWA sends it straight to GitHub, and the Worker never sees it |
| An Anthropic API key, for tag suggestions | A Worker secret in production. Development has no key, so suggestions work only in production |
| Anthropic and OpenRouter keys, for `bb eval-enrich` | The login Keychain, items `website-admin-anthropic` and `website-admin-openrouter` |
| The `gh` login that `bb releases` uses | The login Keychain. This is the developer's login, and grants leaves it alone |

### Under grants

```clojure
;; grants.edn
{:app "website-admin"

 :grants
 {:llm/claude
  {:provider :anthropic}

  :llm/openrouter
  {:provider :http
   :host     "openrouter.ai"
   :bound    :capped
   :attach   {"authorization" ["Bearer " :key]}
   :allow    [[:post "/api/v1/chat/completions"]
              [:get  "/api/v1/credits"]]}}

 :tasks
 {:dev  {:grants [:llm/claude]
         :env    {"ENRICH_BASE_URL" :llm/claude}}
  :eval {:grants [:llm/claude :llm/openrouter]
         :env    {"ANTHROPIC_BASE_URL"  :llm/claude
                  "OPENROUTER_BASE_URL" [:llm/openrouter "/api/v1"]}}}}
```

Both tasks use the unsigned build. Neither path exists in the code yet, so
each needs changes to the application.

### Tag suggestions in development

`grants run dev -- bb dev` starts the development task with
`ENRICH_BASE_URL` set to the gateway and Anthropic's key variable set to a
placeholder. For that to reach the Anthropic client inside the local Worker:

- `worker/src/provider.ts` gains a base URL setting and passes it to the
  client explicitly. The SDK's own environment fallback doesn't work inside a
  Worker, which has no process environment.
- The provider code refuses to start without an API key, so the placeholder
  has to arrive. `wrangler dev` forwards an environment variable that the
  Worker's config names as a required secret, which covers it.
- The base URL has to reach the Worker as a variable. Declaring it in the
  Worker's config and setting it in the environment keeps the task's token
  out of `wrangler`'s command line, where `ps` would show it. Whether the
  environment overrides a declared variable is unverified.

The SDK posts to `/v1/messages?beta=true` with an `anthropic-beta` header.
The gateway forwards the query and that header as they are.

Two things are unchecked and come first when this is built: whether a local
Worker can fetch a loopback address, and whether its outbound requests carry
a header that the gateway takes for a browser's.

If it works, tag suggestions work in development for the first time, and no
key exists on the laptop to make that happen.

### The eval script

The script builds both clients from Keychain values and reads neither
variable in the file above. It needs to take a placeholder when a base URL is
set, and to read an OpenRouter base URL in the two places that have the
address written in. With that done, `grants run eval -- bb eval-enrich` sends
its Anthropic calls through the gateway on a federated credential, and its OpenRouter calls use a sealed key
that carries a spend cap at OpenRouter, which is that provider's nearest
thing to a test key. The two Keychain items are deleted.

Both the Worker and the script also fetch the site's public tag list. That
isn't a grant and needs nothing outside a sandbox. An agent task that ran
either one would list the site's host under `:egress`.

### The Worker in production

Nothing changes. Workers has no workload identity, so the Anthropic key stays
a Worker secret.

### Publishing

The personal access token stays. It lives in the browser and goes straight to
GitHub, so nothing that runs on the laptop can replace it. Replacing it needs
a service that mints tokens for a logged-in person, and
[later.md](later.md) keeps that design and what it would cost this
application.

## horizon

A new application in Clojure. It will call language models and will probably
use Plaid. It has no repository yet.

It starts with the file in the [design](design.md#what-gets-committed), and
there is no secrets file and no Keychain item at any point. The owner runs
`grants init` once: it adds a rule at Anthropic for the new application,
asks for the Plaid sandbox credentials, and approves the file. On a machine
that is already set up, that is the whole of it. `bb dev` and an editor's
jack-in both work without a launcher, because the process declares the
default task.

Where it will run isn't decided. If it runs on Fly.io, the language model
grants need no secret there, because Fly gives each machine an identity that
Anthropic accepts, and Plaid's keys go in Fly's secret store.
[later.md](later.md) has what is known. If it runs on the laptop, it follows
finance-aggregator's second stage.

## The owner's agent sessions

`grants agent` has to fit how agents are started and what they do. On this
machine:

- The Claude Code sandbox isn't turned on anywhere. Every agent session
  today runs with the developer's full access.
- Nearly all sessions start as `claude` in a terminal, through a shell
  function. After a relaunch, the app that manages them types
  `claude --resume <id>` itself, and Claude Code's own background sessions
  are started by its daemon. A wrapper around the shell function reaches the
  first kind only.
- Subagents run inside the session that started them. A Codex review is a
  shell command the agent runs.

Turning the sandbox on changes what a session can do:

| What agents do today | Under the command sandbox | What can be done |
| --- | --- | --- |
| `jj` status, diff, log, and commits | Works in the main working copy. In a second workspace it fails, because the workspace's store lives in the main repository's directory | Give the session write access to the main repository's `.jj` and `.git` directories, found by following the workspace's pointer. Not possible when that repository is where live runs |
| `jj git push` and `fetch` | Fail. Every remote is SSH, and SSH doesn't work inside the sandbox on macOS | The owner pushes |
| Codex review | Fails. One macOS sandbox can't start inside another, which was tested | The owner runs the review, or the command is let out of the sandbox knowingly |
| `gh` | Fails | Leave it unavailable to a sandboxed agent |
| Dev servers, test servers, and REPLs the agent starts | Can't listen on a port. The one setting that allows it lets the session connect to every local port | Unsolved. It's open question 2 in the design |
| The review tool's local port | Blocked. The hook that reports review notes still works, because hooks run outside the sandbox, but commands the agent sends to the tool fail | Unsolved, for the same reason as the row above |
| Dependency fetches | Blocked, and the shared caches aren't writable | Give each session its own cache, seeded by a copy-on-write clone of the shared one. List a registry under `:egress` only for a task that needs to fetch |

Letting a command out of the sandbox is never a small exception. The command
runs with the developer's access, with arguments the agent chose, and it
obeys repository config that the agent can write. A push is the plainest
case. So the table offers few of those, and the owner decides each one.

The sandbox is a migration for this machine with its own cost, and it's
separate from removing stored keys. The first stage of every application
above is worth doing without it.

## What the cases asked of the design

| Need | Came from | Where the design answers it |
| --- | --- | --- |
| A provider with no preset, and a key split across two headers | Plaid, in two applications | [Describing an HTTP API](design.md#describing-an-http-api) |
| A key with no test mode | OpenRouter | [Bounds](design.md#bounds) |
| A sandbox key and a live key for one provider, with different rules | finance-aggregator | Two grants. [What gets committed](design.md#what-gets-committed) |
| A live key on a laptop that is also production | finance-aggregator | [Live keys and application data](design.md#live-keys-and-application-data) |
| A live process that reloads code from a working copy | finance-aggregator | [Where live runs](design.md#where-live-runs) |
| Encryption for stored tokens, with no key on disk | finance-aggregator, horizon | [Application data](design.md#application-data) |
| A copy of real data that an agent can run against but not decrypt | finance-aggregator's dogfood | A task without the wrap grant |
| A config that loads with no issuer, in tests and reloads | finance-aggregator | [Tests and machines with no issuer](design.md#tests-and-machines-with-no-issuer) |
| A guard in application code that knows what it's talking to | finance-aggregator's sandbox helpers | `:host` and `:bound` in [what a reference yields](design.md#what-a-reference-yields) |
| Calls that retry for longer than a credential lasts | finance-aggregator's extraction | The gateway holds the credential, so a retry never carries an expired one |
| Grants for a process that isn't Clojure | website-admin | [Processes that aren't Clojure](design.md#processes-that-arent-clojure) |
| An SDK whose base URL includes a path | OpenAI and OpenRouter clients | The suffix form of `:env` |
| An agent session that can still commit and run tests | The owner's workflow | Partly. [Agents](design.md#agents), the table above, and an open question |
| A task that survives an upgrade of the issuer | Every long-running process | [Tasks](design.md#tasks) |
| A credential for a person using a browser | website-admin's publishing | Not answered. [later.md](later.md) |
