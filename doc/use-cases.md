# Use cases

Status: draft, 2026-11-11. Nothing described here has been built yet.

The [design](design.md) is judged against three applications. Two exist and
hold real secrets today, and the third is about to start. This document
takes each one from what it does now to what it would do under grants, and
says what the application has to change, what its owner sets up once, and
what stays exposed.

The details of the two existing applications were read from their
repositories on 2026-11-11.

## finance-aggregator

A personal finance application in Clojure, built on Integrant. It has no
production other than the laptop: the server binds to loopback, and other
devices reach it through `tailscale serve`.

### What it holds today

| Secret                                       | Where it lives                                                       |
| -------------------------------------------- | -------------------------------------------------------------------- |
| Plaid client ID and secret                   | `secrets.edn.age`, opened by an age key in `~/.config/finance-aggregator/key.txt` |
| A database encryption key                    | The same file                                                        |
| An optional OpenRouter key                   | The same file                                                        |
| An Anthropic API key                         | The login Keychain, item `finances-anthropic`, read with `security`  |
| Plaid access tokens and SimpleFIN access URLs | The database, encrypted with the database encryption key            |

The age key is a plain file, and `security` answers any process that runs
as the developer. An agent working in the repository can read all five.

### Under grants

```clojure
;; grants.edn
{:app "finance-aggregator"

 :grants
 {:llm/claude
  {:provider :anthropic
   :scope    :inference
   :ttl      "10m"}

  :plaid/api
  {:provider :http
   :source   :static
   :host     #profile {:dev  "sandbox.plaid.com"
                       :live "production.plaid.com"}
   :bound    #profile {:dev :test :live :live}
   :attach   {:headers {"PLAID-CLIENT-ID" :client-id
                        "PLAID-SECRET"    :secret}}
   :allow    [[:post "/link/token/create"]
              [:post "/item/public_token/exchange"]
              [:post "/item/get"]
              [:post "/item/remove"]
              [:post "/accounts/get"]
              [:post "/institutions/get_by_id"]
              [:post "/institutions/search"]
              [:post "/transactions/sync"]
              [:post "/investments/transactions/get"]
              ;; these two exist only on the sandbox host
              [:post "/sandbox/public_token/create"]
              [:post "/sandbox/item/reset_login"]]}

  :connections/at-rest
  {:provider :wrap}}

 :default-task :dev

 :tasks
 {:dev   {:profile :dev
          :grants  [:llm/claude :plaid/api :connections/at-rest]}
  :serve {:profile :live
          :grants  [:llm/claude :plaid/api :connections/at-rest]}
  :agent {:grants  [:llm/claude]
          :deliver :inject}}}
```

The `:allow` list is the eleven Plaid calls that `plaid/client.clj` makes.

| Secret today                 | Source   | Delivery     | What is on the laptop                         |
| ---------------------------- | -------- | ------------ | --------------------------------------------- |
| Anthropic API key            | Federate | By reference | Nothing                                       |
| Plaid sandbox credentials    | Static   | Injection    | A sealed test key                             |
| Plaid production credentials | Static   | Injection    | A sealed live key, opened with a fingerprint  |
| Database encryption key      | Wrap     | An operation | A wrapping key that stays in the issuer       |
| OpenRouter key, if used      | Static   | Injection    | A sealed key with a spend cap                 |

### What changes in the application

The config names grants where it named a secrets component and a Keychain
item:

```clojure
;; resources/system/base-system.edn
:finance-aggregator.statement/extraction-settings
{:backend :anthropic
 :model   "claude-sonnet-5-5"
 :client  #grant :llm/claude}

:finance-aggregator.plaid/config
{:client      #grant :plaid/api
 :link-config #ig/ref :finance-aggregator.plaid/link-config}

:finance-aggregator.db/connection-secrets
#grant :connections/at-rest
```

Four pieces of code change:

- `statement/llm.clj` builds its request from the reference. It takes the
  URL from `:base-url` and merges `:headers`, where it now sets `x-api-key`
  from a function that reads the Keychain. The federated token arrives as an
  `authorization` header, and the code doesn't need to know that.
- `plaid/client.clj` gives the Plaid SDK the reference's base URL and header
  values. The SDK already takes a URL for its environment. Under injection
  the two header values are placeholders, and the gateway replaces them.
- The connection secrets go through `grants/wrap` and `grants/unwrap` in
  place of `lib/encryption.clj`. A one-time migration reads each stored
  secret with the old key, wraps it, and writes it back.
- `lib/keychain.clj`, `lib/secrets.clj`, the `bb secrets` task, the `.age`
  files, and `key.txt` are deleted.

Tests and the e2e server pass a fake resolver. The e2e server already boots
with no secrets and a fake extraction backend, so its fake grants have
nothing to stand in for.

### What the owner does once

1. Install the issuer.
2. Run `grants init` and apply the Anthropic setup it writes: a workspace
   for this application, a service account, the issuer, and one rule for
   `finance-aggregator:*`. This takes an organization admin login.
3. Seal the Plaid credentials for each profile, with
   `grants seal :plaid/api --profile dev` and again with `--profile live`.
4. Run `grants allow-live` for `:plaid/api`, and approve it with Touch ID.
5. Approve `grants.edn` in the issuer's window.
6. Run the migration that wraps the stored connection secrets.
7. Delete the Keychain item, the age files, and the age key, and delete the
   Anthropic API key in the Console. The Plaid secret in the age file has
   been readable for as long as the file existed, so rotate it and seal the
   new one.

### A day of work

`bb dev` is unchanged. It starts one JVM that serves the application and an
nREPL. The JVM connects to the issuer, declares no task, and gets `:dev`,
which means the Plaid sandbox.

For real bank data, the application starts under the `:serve` task, through
a `deps.edn` alias that sets `-Dgrants.task=serve`. The first Plaid call
asks for a fingerprint, and the issuer's window says which application and
which key it's for. After that the scheduled sync runs without asking.

An agent working in the repository runs under `:agent`. It can call
Anthropic through the gateway. It has no route to Plaid and none to the
wrapped tokens, and there is no key file or Keychain item for it to read.

### Deploying

Nothing is deployed. If the application later moves to a server, the file
stays the same and the `:live` profile resolves there: Anthropic through
the platform's identity, and Plaid from the platform's secret store. The
wrapped data doesn't move with it unless `:connections/at-rest` names a
recovery recipient, so without one the banks are linked again.

### What stays exposed

- The running application holds an Anthropic token that lasts ten minutes.
- It can make the allowed Plaid calls and unwrap any stored token, and so
  can anything that evaluates code in it. The nREPL in the same JVM is such
  a route.
- A Plaid access token is in the application's memory for as long as a sync
  takes. Open question 3 in the design is about removing that.
- An unsandboxed agent can declare `:dev` and use the sandbox. It can't
  start `:serve`, because that takes a fingerprint, but it can reach into a
  `:serve` process that's already running.

## website-admin

A phone and laptop PWA for drafting and publishing to a website, with one
Cloudflare Worker behind Cloudflare Access. The PWA is TypeScript, the
Worker is TypeScript, and the development tasks are Babashka. No part of it
runs on the JVM.

### What it holds today

| Secret                                 | Where it lives                                               |
| -------------------------------------- | ------------------------------------------------------------ |
| A GitHub fine-grained personal access token, with contents read and write on the drafts and content repositories | `localStorage` in the browser, on every device |
| An Anthropic API key, for tag suggestions | A Worker secret in production. Development has no key, so suggestions work only in production |
| Anthropic and OpenRouter keys, for `bb eval-enrich` | The login Keychain, items `website-admin-anthropic` and `website-admin-openrouter` |
| The `gh` login that `bb releases` uses | `gh`'s own store. This is the developer's login, and grants leaves it alone |

### Under grants

```clojure
;; grants.edn
{:app    "website-admin"
 :minter "https://minter.example.dev"

 :grants
 {:llm/claude
  {:provider :anthropic
   :scope    :inference
   :ttl      "10m"
   :budget   {:requests 200}}

  :llm/openrouter
  {:provider :http
   :source   :static
   :host     "openrouter.ai"
   :bound    :capped
   :attach   {:headers {"authorization" ["Bearer " :key]}}
   :allow    [[:post "/api/v1/chat/completions"]
              [:get  "/api/v1/credits"]]}

  :content/write
  {:provider    :github
   :repos       ["kirahowe/kirahowe-drafts" "kirahowe/kirahowe-content"]
   :permissions {:contents :write}
   :ttl         "1h"}}

 :tasks
 {:dev     {:grants  [:llm/claude]
            :command ["bb" "dev"]
            :env     {"ENRICH_BASE_URL" :llm/claude}}
  :eval    {:grants  [:llm/claude :llm/openrouter]
            :command ["bb" "eval-enrich"]
            :env     {"ANTHROPIC_BASE_URL"  :llm/claude
                      "OPENROUTER_BASE_URL" :llm/openrouter}}
  :publish {:caller :person
            :grants [:content/write]}}}
```

The four secrets fare differently, so each has its own section.

### Tag suggestions in development

`grants run dev` starts `bb dev` with `ENRICH_BASE_URL` set to the gateway.
`dev/launch.clj` passes the value to `wrangler dev` as a variable, and
`worker/src/provider.ts` gives it to the Anthropic client as its base URL
when it's set. The Worker running locally then calls Anthropic through the
gateway, under the task's request budget.

Suggest tags works in development for the first time, and no key exists on
the laptop to make that happen.

### The eval script

`grants run eval` starts `bb eval-enrich` with both base URLs set. The
script stops reading the Keychain. Its Anthropic calls go through the
gateway on a federated token. Its OpenRouter calls use a sealed key that
carries a spend cap at OpenRouter, which is that provider's nearest thing
to a test key. The two Keychain items are deleted.

### The Worker in production

Nothing changes. Workers has no workload identity, so the Anthropic key
stays a Worker secret, which is where `wrangler.jsonc` already requires it.
`grants init --target workers` lists it, and that list is the only thing
grants adds. If Workers ships its identity binding, the key can go.

### Publishing without a personal access token

This is the one place where the design needs the remote minter, and where
the application has something to give up.

With the minter:

1. A GitHub App is installed on the drafts and content repositories, with
   contents read and write. Its private key is a secret in the minter.
2. The PWA asks its own origin for the `:content/write` grant. The request
   passes through Cloudflare Access, which the application already uses,
   and the application's Worker hands it to the minter.
3. The minter checks the Access JWT, reads `grants.edn` at main, and returns
   an installation token for those two repositories that lasts an hour.
4. The PWA uses that token where it uses the personal access token now, and
   asks again when it expires.

No device holds a long-lived GitHub credential after that. A lost phone
holds an Access session, which can be revoked in one place, and a token
with at most an hour left.

It costs the application four things, and they're its own to weigh:

- Its specification promises that publishing needs nothing but GitHub. With
  the minter, publishing needs the minter once an hour as well.
- Its README says Cloudflare never holds a GitHub credential. The minter is
  a Worker, and it holds the App's key.
- GitHub calls skip Access today, so drafting never waits on a login. A
  token request would go through Access, and an expired session would stop
  a sync until the next login.
- A publish queued offline needs a live token when it finally goes out, as
  well as a connection.

Until the minter is built, the personal access token stays.

### What the owner does once

1. For development and the eval: apply the Anthropic setup from
   `grants init`, seal the OpenRouter key, and delete the two Keychain
   items.
2. For publishing, later: deploy the minter, create the GitHub App and
   install it on three repositories, and store its key in the minter.

## horizon

A new application in Clojure. It will call language models and will
probably use Plaid. It has no repository yet, so this section describes how
it starts.

It begins where finance-aggregator ends up, without the migration. There is
no secrets file and no Keychain item at any point:

```clojure
;; grants.edn
{:app "horizon"

 :grants
 {:llm/claude {:provider :anthropic :scope :inference :ttl "10m"}
  :llm/openai {:provider :openai    :ttl "10m"}

  :plaid/api
  {:provider :http
   :source   :static
   :host     #profile {:dev  "sandbox.plaid.com"
                       :prod "production.plaid.com"}
   :bound    #profile {:dev :test :prod :live}
   :attach   {:headers {"PLAID-CLIENT-ID" :client-id
                        "PLAID-SECRET"    :secret}}
   :allow    [[:post "/link/token/create"]
              [:post "/item/public_token/exchange"]
              [:post "/transactions/sync"]]}

  :connections/at-rest {:provider :wrap}}

 :default-task :dev

 :tasks
 {:dev   {:grants [:llm/claude :llm/openai :plaid/api :connections/at-rest]}
  :agent {:grants [:llm/claude] :deliver :inject}}}
```

### Starting out

The owner applies the provider setup from `grants init` and seals the Plaid
sandbox credentials. From then on a new clone needs the issuer and nothing
else. `bb dev` and an editor's jack-in both work without a launcher, because
the process declares the default task.

### Deploying

Where horizon will run isn't decided. Two targets are likely, and the file
is the same for both.

**Fly.io, where the website runs.** A Fly machine can ask for an OIDC token,
so the language model grants need no secret:

- `grants init --target fly --profile prod` writes an Anthropic issuer for
  `https://oidc.fly.io/<org>` and a rule for the subject prefix
  `<org>:horizon:`. OpenAI gets the equivalent.
- The same command prints `fly secrets set PLAID_API_CLIENT_ID=...
  PLAID_API_SECRET=... CONNECTIONS_AT_REST_KEY=...`, with the values for
  the owner to fill in.
- The deploy is `fly deploy`, as it is for any Fly application.

In production the library asks the machine for a token, exchanges it, and
renews it. The application code is the code that ran on the laptop.

**The laptop, like finance-aggregator.** A `:serve` task names the `:prod`
profile, and the local issuer serves it. The live Plaid key is sealed, and
the owner opts in on that machine.

## What the three cases asked of the design

| Need                                                        | Came from                         | Where the design answers it                                   |
| ----------------------------------------------------------- | --------------------------------- | ------------------------------------------------------------- |
| A provider with no preset, and a key split across two headers | Plaid, in two applications        | [Describing an HTTP API](design.md#describing-an-http-api)    |
| A key with no test mode                                     | OpenRouter                        | [Bounds](design.md#bounds)                                    |
| A live key on a laptop that is also production              | finance-aggregator                | [Live keys](design.md#live-keys)                              |
| Encryption for stored tokens, with no key on disk           | finance-aggregator, horizon       | [Application data](design.md#application-data)                |
| One code path for an API key and a federated token          | finance-aggregator                | [What a reference yields](design.md#what-a-reference-yields)  |
| Grants for a process that isn't Clojure                     | website-admin                     | [Clients in other languages](design.md#clients-in-other-languages) |
| A config that loads with no issuer                          | finance-aggregator's tests        | [Tests and machines with no issuer](design.md#tests-and-machines-with-no-issuer) |
| Production on a platform with no workload identity          | website-admin's Worker            | [Production targets](design.md#production-targets)            |
| A credential for a person using a browser                   | website-admin's publishing        | [People in browsers](design.md#people-in-browsers)            |
