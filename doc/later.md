# Later

Status: notes, 2026-11-11. Nothing here is planned yet.

The [design](design.md) describes what grants does first. This document
keeps the parts of the earlier design that were set aside, so the thinking
isn't lost and so the first version doesn't close a door by accident. Each
section says what would bring it back.

## A remote minter

Some providers have an API for creating scoped keys, but creating one takes a
long-lived root. GitHub Apps and Cloudflare work this way. The earlier design
put the root in a small remote service, the minter, which would create a key
for a task and revoke it when the task ended. The minter would read its
policy from `grants.edn` on the protected main branch, as Octo STS does for
GitHub, so widening a minted grant would take a merged pull request.

A host for it has to meet two conditions:

- It can sign with a root and can't read it. A GitHub App's root is an RSA
  key, so this means a key service that signs on request and never releases
  the key.
- No login kept on a developer's laptop can deploy to it or change what it
  runs.

A Cloudflare Worker fails both. Code deployed to a Worker can read the
Worker's secrets, and `wrangler` keeps its deploy login in the home directory
of the laptop the root was meant to stay off.

The review added one more problem. "A merged pull request" is only as strong
as the owner's GitHub login, and a solo owner's laptop usually holds a login
that can push to main. A minter would have to accept only policy commits
signed with a key that needs a fingerprint, or rely on branch rules that the
laptop's login can't satisfy alone.

What would bring it back: a second application that needs a minted key, or a
decision that website-admin's publishing must stop using a personal access
token.

## People in browsers

A browser application can't hold an issuer key or read a config, and its user
is a person and not a task. website-admin stores a GitHub personal access
token in the browser on every device that uses it.

The earlier design put the minter behind an access proxy such as Cloudflare
Access. The proxy would handle the login and add a signed JWT to each
request, and the minter would check it and return a token that lasts an hour.
A task marked `:caller :person` would list the grants a logged-in person may
have.

For website-admin this had real costs: publishing would need the minter once
an hour as well as GitHub, a token request would go through Access where
GitHub calls skip it today, and a publish queued offline would need a live
token when it finally went out. GitHub's own user tokens could meet the need
outside this tool.

What would bring it back: the minter.

## Cloud agents

Giving a cloud agent access usually means pasting long-lived keys into the
platform's settings. The sketch for doing it without a pasted secret: the
sandbox generates a key pair when the session starts, the developer's issuer
signs a delegation that names the public key, the task, and an expiry, and
the sandbox then acts as that task.

It has two known limits. A provider that accepts a plain OIDC token accepts
it from whoever holds it, so the delegation has to be short. And renewing it
during a long session needs an issuer the sandbox can reach, which a laptop
isn't.

What would bring it back: an issuer that is reachable from outside the
laptop.

## Certificates

The issuer could sign short-lived X.509 certificates for providers that trust
a certificate authority, such as Postgres `cert` auth and SSH certificates.
None of the three applications uses Postgres, so this waits for one that
does.

A certificate is a credential the task has to hold, since the gateway only
speaks HTTP. That is the case where a reference would yield a real credential
on a laptop and the library would renew it. `psql` reads its certificate and
key from files, so it would need a file that lasts only as long as the task,
kept in a directory the issuer owns and a sandbox can't read.

The same machinery is the route to bringing the developer's own logins under
the issuer: SSH certificates in place of long-lived SSH keys, and credential
helpers for `git`, `aws`, and Docker. Secretive is the model for enclave-held
SSH keys on a Mac.

## Tools that need a real credential

A tool that reads a credential only from an environment variable, or only
from a file, can't use the gateway. `grants run <task> -- <command>` could
set a real credential for one child process. That puts the credential in the
environment of every descendant, where other processes of the same user may
read it, so it would be a named exception and say so each time it's used.

## Budgets and rules on request bodies

The gateway could count requests for each task and grant, and refuse when a
budget is spent. The review settled the details:

- A request is counted once it has passed every check, before it's forwarded.
- A spent budget is a 403 with a header that tells SDKs not to retry. A 429
  would be retried forever by some clients.
- Spend can't be budgeted from Anthropic's response headers, which report
  rate-limit state and not what a request cost. A token budget would mean
  parsing response bodies and streams for each provider.
- A budget only holds for a sandboxed task. Unsandboxed code can start a
  fresh task with a fresh budget.

The first version relies on a spend limit at the provider instead.

A path rule can't narrow an API that puts the operation in the request body,
such as GraphQL, and it can't keep an agent off an expensive model, because
the model's name is in the body. A narrow body rule would help there:
top-level keys of a JSON object, equality for strings, a maximum for numbers.
The `:allow` grammar reserves a third element for it, and the first version
refuses a file that uses one.

## Recovering wrapped data

An enclave key can't be exported, so wrapped data doesn't survive the loss of
the machine. With `:recovery "age1..."` on a wrap grant, the issuer would
also encrypt the wrapping key to that age public key when it creates it. The
private half would stay offline, and `grants recover` would rebuild the
wrapping key on a new machine.

The recovery key is a long-lived secret again, so the recipient has to be
fixed when the wrapping key is created, and changing it or using it has to
take a fingerprint.

## Production targets

Production differs from one platform to the next in whether the platform
gives a workload an identity and where it keeps secrets.

| Target             | Workload identity                                     | Federated grants                | Sealed grants                 |
| ------------------ | ----------------------------------------------------- | ------------------------------- | ----------------------------- |
| Fly.io             | An OIDC token, requested over a socket in the machine | The library exchanges the token | Fly secrets                   |
| AWS, Google Cloud  | The platform's own                                    | The library exchanges it        | The platform's secret manager |
| GitHub Actions     | An OIDC token                                         | The library exchanges the token | Actions secrets               |
| Cloudflare Workers | None yet                                              | Not available                   | Worker secrets                |

A grant that can't federate on its target reads the platform's secret store.
Each slot maps to one secret, named after the grant and the slot. A Worker
runs TypeScript and has no identity to federate with, so the library has no
part in it, and `grants.edn` would only list the secrets the Worker needs.

Three things the review settled for when this is built:

- The application chooses the production resolver explicitly. If the library
  detected its platform from environment variables, a file an agent wrote in
  the project could switch a laptop onto reading secrets from the
  environment.
- Where an issuer is installed, the library never reads a credential from
  the environment.
- A grant can't name its own secret. With a name override, a merged change
  could point one grant at another grant's secret and send it to a new host.

Fly's identity is already known to fit. Its issuer serves a public discovery
document and signs with RS256, which Anthropic accepts, and its subject has
the form `<org>:<app>:<machine>`.

## Requiring a fingerprint at a provider

A provider's rule can't see which key signed a token, so it can't require a
fingerprint through a claim. If a provider ever has to refuse a task unless the
owner gave a fingerprint, the fingerprint key is registered there as a second
issuer with its own `iss`, and the rule that needs a fingerprint trusts only
that issuer. Anthropic's rule model allows this as far as its documentation goes.
It hasn't been tried.

A federated grant that needed a fingerprint for every exchange would prompt
every few minutes, so this only suits rare actions, such as a migration.

## The agent's own model calls

Claude Code can authenticate by federation itself: given a rule's ids and a
file that holds a fresh identity token, it does the exchange and renews it.
The issuer would only have to keep that file fresh. It also works through the
gateway with a placeholder key.

Either way the harness moves from the developer's subscription to API billing
in a Console organization, and loses the features tied to its own login. That
is the reason it isn't the default. An identity token can be exchanged only
once, so the file would have to be rewritten before every renewal, and a
sandbox would have to be kept from reading it.

## Other platforms

The issuer is defined by the protections it provides, not by the Secure
Enclave. On Windows and Linux a TPM 2.0 or a security key can hold a signing
key that can't be exported, and Windows Hello or a security key's touch can
stand in for a fingerprint. Neither platform is known to have a way to tie a
key to one signed program, so both would start where the unsigned macOS
build is.

A machine with no hardware key store could run the issuer with a software
key, if the machine's own config opted in. Live keys would be refused there.

None of this has been checked, and nothing in the first version depends on
it. The Go core is what would carry over: only the package that talks to the
operating system's key store would be replaced.

## More than one machine

Each laptop registers its own key with every provider. Two laptops is a
list, and a team is a longer one. A shared issuer for a team would fix that
and hasn't been designed.

## Decoy credentials

A credential an agent finds in `.env` or `~/.aws` could be a planted decoy,
so any use of one would be a real alarm. That only works once no real secrets
are on disk, and tools such as `canaryhook` already cover the idea.

## Opening wrapped values at the gateway

A task that unwraps a stored credential holds it for as long as a request
takes. For a credential that travels in a header, the task could send the
wrapped blob and the gateway could swap in the real value on the way out. The
task would then never hold it.

SimpleFIN is the case where this is easy and worth most: its access URL is a
complete credential that never expires, and it travels as a Basic auth
header. For Plaid the access token is in a JSON body, which would mean
rewriting bodies for each provider.
