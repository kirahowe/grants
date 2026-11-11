# Prior art and provider support

Surveyed on 2026-11-10.

## How far to trust this

Three provider pages were read directly: Anthropic's workload identity
federation reference, OpenAI's federation guide, and Stripe's federation page.
In the tables below, rows marked "read" were read in full during the survey.
Rows marked "summary" come from search-result summaries and weren't checked
against the source, so treat them as leads to confirm.

A second pass on 2026-11-11 checked the providers and platforms that the
[use cases](use-cases.md) depend on. It read Anthropic's federation overview
and reference again, Fly's OpenID Connect page, GitHub's installation token
endpoint, and OpenRouter's key management page. Plaid, Cloudflare Workers,
and GitHub's device flow were checked only through search summaries.

## What products do with a static upstream key

Nearly every product follows the same pattern. The real key stays outside the
workload, which holds a placeholder instead, and a proxy swaps in the real key
on requests to allowlisted hosts.

| Product | Where the real key lives | How the caller is identified | Routing | Scope it enforces | Checked |
| --- | --- | --- | --- | --- | --- |
| Fly Tokenizer | The client carries the key sealed to the proxy's public key. The proxy's private key is an environment variable | A shared bearer token, or the Fly machine | The client uses the proxy over plain HTTP | Allowed hosts | read |
| Tailscale Aperture | Aperture's config | Tailnet identity: user, device, or tags | A base URL per connector | Per connector, with no path rules | read |
| Infisical Agent Vault and Agent Proxy | A local encrypted store, or Infisical | A token per agent | HTTPS proxy with its own CA | Host rules | read |
| Claude Code sandbox credentials | The developer's machine, outside the sandbox | The sandbox session | A local proxy that terminates TLS | Hosts where the value is substituted | read |
| Claude Managed Agents vaults | Anthropic's control plane, write-only | Workspace and session | Substitution at egress | Allowed hosts, header or body | read |
| Deno Sandbox | The control plane | The sandbox | Substitution at egress | Hosts | read |
| Vercel Sandbox | A firewall on the host | The sandbox, through a CA per sandbox | TLS termination for configured domains | Path, method, query, and headers | read |
| E2B | Its egress proxy | The sandbox | Egress proxy | Exact host, with no method matchers | summary |
| Cloudflare Sandboxes and AI Gateway | An outbound Worker, or Secrets Store | The container, or a Cloudflare token | Interception, or a base URL | Whatever the Worker's code does | summary |
| Docker Sandboxes | The host | The sandbox | A proxy on the host | Named hosts | summary |
| Aembit, Keycard | The vendor's cloud | Attested workload identity | An edge proxy or sidecar | The vendor's policy engine | summary |
| Octo STS | A GitHub App key inside the service | An OIDC token, checked against a policy file in the target repository | The token is returned to the caller | The permissions the policy lists | summary |

These products share three gaps:

- Scope is shallow. Most of them scope by host, and Vercel also matches path
  and method. Aperture's docs advise using read-only upstream keys, because
  every caller with a grant shares one credential.
- None of them offers request or spend budgets as a core feature.
- A compromised workload can still use the key for anything the key allows.
  The proxy stops the key from being stolen, but does nothing about misuse.

None of these products removes the stored key. Octo STS comes closest, for one
provider: it puts federation in front of GitHub, which doesn't federate on its
own, and keeps its policy in the repository it protects.

## Techniques that do not remove the stored key

- **Split keys and multi-party computation.** Products such as Privy and Lit
  use these for signing keys. A bearer API key has to be whole when it's sent,
  though, so whichever party reassembles it becomes the trusted holder.
- **Proof of possession added at a proxy.** DPoP, mTLS, and HTTP message
  signatures work only when the upstream checks the proof, and a provider with
  static keys doesn't. It's still possible to bind the hop between the task
  and a gateway.
- **Enclave custodians.** Turnkey and Privy keep signing keys in attested
  enclaves. The survey found no product that does this for arbitrary SaaS API
  keys.
- **Tokenization proxies from payments.** VGS can alias an API key and reveal
  it only on a route to an allowlisted host, and Evervault Relay is similar.
  Both are hosted services priced for payment data.
- **The Secure Enclave on a Mac.** It holds only P-256 keys. It can wrap other
  data with ECIES and require a fingerprint for each use, but a wrapped API key
  still has to be unwrapped into process memory before it can be sent.

## Detection

Decoy credentials catch a workload that goes looking for secrets. GitGuardian
and Tracebit sell this, and `canaryhook` and `agent-canary` are open-source
versions aimed at coding agents. A decoy reports a theft after it happens, but
can't prevent one.

GitHub's secret scanning partner program reports leaked keys to providers.
Whether to revoke a key is then up to the provider.

## What providers offer

### Providers that accept an outside identity token

| Provider | What was found | Checked |
| --- | --- | --- |
| Anthropic | A custom OIDC issuer can be registered with its public keys inline, so the issuer needs no public endpoint. ES256 and the RSA families are accepted, and the JWT header must carry a `kid`. The token lasts 60 seconds to 24 hours, and never more than twice the remaining life of the JWT it was exchanged for. Rules match on subject, audience, claims, or a CEL expression. A `jti` can be used once. The narrowest scope is `workspace:inference`, and nothing finer exists. The token is sent as `Authorization: Bearer`, where an API key uses `x-api-key`. The official SDKs do the exchange themselves from a token file, which they read again at every exchange. Creating issuers and rules takes an organization admin, through the Console or the Admin API with an OAuth login | read |
| OpenAI | Custom OIDC issuers, by discovery or with inline public keys, plus SPIFFE JWT tokens, and X.509 for the API. A mapping names a project and service account, and optional permissions narrow it. The page doesn't list accepted signing algorithms | read |
| Stripe | Private preview. The issuers are AWS and Google Cloud. The access token lasts one hour | read |
| Tailscale | Federation with a token-exchange endpoint | summary |
| PlanetScale | OIDC from GitHub Actions and Depot CI | summary |
| Datadog | AWS roles, and GitHub through a Datadog action | summary |
| Hugging Face | Token exchange for organization members | summary |

### Platforms that give a workload an identity

| Platform | What was found | Checked |
| --- | --- | --- |
| Fly.io | A machine requests an OIDC token over a Unix socket at `/.fly/api`, and can set the audience. The issuer is `https://oidc.fly.io/<org>`, and `sub` is `<org>:<app>:<machine>`. Every request returns a new token with its own `jti`. The page doesn't name the signing algorithm or the discovery path | read |
| Cloudflare Workers | No identity token for a Worker. A draft pull request in `workers-sdk`, opened on 2026-10-23, adds an identity binding behind a flag. Community projects run their own issuer as a second Worker | summary |
| GitHub Actions | An OIDC token from the Actions endpoint, according to Anthropic's federation page, which has a setup guide for it. GitHub's own page wasn't read | summary |

### Providers with an API for minting keys

| Provider | What was found | Checked |
| --- | --- | --- |
| GitHub Apps | Installation tokens last an hour and can be limited to named repositories and a subset of permissions, never beyond what the installation has. The caller authenticates with a JWT. The endpoint's page doesn't say who a commit made with the token is attributed to | read |
| GitHub Apps, user tokens | A user token from the device flow lasts about eight hours and comes with a refresh token that lasts six months. Refreshing is said to need only the client ID. The token endpoints don't allow cross-origin requests from a browser | summary |
| OpenRouter | A management key creates and deletes API keys, and can't make completions itself. A created key can carry a credit limit that resets on a schedule. The page describes no expiry for created keys | read |
| Cloudflare | Tokens are created by API, with policies per resource, an expiry, and an IP condition | summary |
| OpenAI | An admin key creates and deletes service accounts and project keys | summary |
| Vercel | Tokens are created by API, with an expiry, per account, team, or project | summary |
| PlanetScale | Service tokens with a TTL | summary |
| SendGrid, Resend, Neon, Supabase, Twilio | Keys are created by API, with some scoping and no expiry, so the minter has to delete them | summary |

### Providers with static keys only

| Provider | What was found | Checked |
| --- | --- | --- |
| Stripe, outside the preview | Restricted keys are created in the dashboard. Sandboxes have their own keys | summary |
| Plaid | A client ID and a secret, sent as the `PLAID-CLIENT-ID` and `PLAID-SECRET` headers or in the request body. The sandbox and production have different secrets and different hosts. Plaid has an OAuth token endpoint, but the summaries tie it to its dashboard tools and not to the product endpoints | summary |
| Postmark | Account and server tokens, with no expiry | summary |
| Sentry | Tokens are created in the UI | summary |
| Linear | Personal keys are created in the UI | summary |
| Hugging Face | Fine-grained tokens that don't expire, with no creation API | summary |

## Standards

Everything in this section comes from summaries.

- WIMSE, the IETF's workload identity work, has drafts but no RFCs.
- OAuth token exchange (RFC 8693) is stable, and OpenAI's exchange uses it.
- DPoP (RFC 9449) and HTTP message signatures (RFC 9421) are RFCs. The survey
  found no SaaS API that uses them in place of API keys.
- The identity assertion grant behind MCP's enterprise authorization is a
  draft. It needs a user session, so it doesn't cover unattended workloads.
- Fly uses macaroons in production, and Biscuit has a few production users.

## Sources

- Anthropic: https://platform.claude.com/docs/en/manage-claude/wif-reference
  and https://platform.claude.com/docs/en/manage-claude/workload-identity-federation
- Fly.io: https://docs.fly.io/security/openid-connect
- Cloudflare Workers identity binding: https://github.com/cloudflare/workers-sdk/pull/16455
- GitHub installation tokens: https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app
- OpenRouter: https://openrouter.ai/docs/features/provisioning-api-keys
- Plaid: https://plaid.com/docs/api/ and https://plaid.com/docs/api/oauth/
- OpenAI: https://developers.openai.com/api/docs/guides/workload-identity-federation
- Stripe: https://docs.stripe.com/workload-identity-federation
- Fly Tokenizer: https://github.com/superfly/tokenizer and
  https://fly.io/blog/tokenized-tokens/
- Tailscale Aperture: https://tailscale.com/docs/aperture/how-to/set-up-http-api-connector
- Infisical Agent Vault: https://github.com/Infisical/agent-vault
- Claude Code sandbox: https://code.claude.com/docs/en/sandboxing
- Claude Managed Agents vaults: https://platform.claude.com/docs/en/managed-agents/vaults
- Deno Sandbox: https://docs.deno.com/sandbox/
- Vercel Sandbox: https://vercel.com/blog/a-sandbox-without-a-network-boundary-is-only-half-a-sandbox
- E2B: https://e2b.dev/docs/sandbox/internet-access
- Cloudflare: https://developers.cloudflare.com/changelog/post/2026-04-13-sandbox-outbound-workers-tls-auth/
  and https://developers.cloudflare.com/ai-gateway/configuration/bring-your-own-keys/
- Docker Sandboxes: https://docs.docker.com/ai/sandboxes/configuration/credentials/
- Aembit: https://aembit.io/blog/securing-ai-agents-without-secrets/
- Keycard: https://docs.keycard.ai/guides/access-provider-apis/overview/
- Octo STS: https://edu.chainguard.dev/open-source/octo-sts/overview/
- VGS: https://docs.verygoodsecurity.com/vault/http-proxy/outbound-connection
- Evervault Relay: https://docs.evervault.com/relay
- Turnkey: https://docs.turnkey.com/solutions/key-management/overview
- GitGuardian on agents: https://blog.gitguardian.com/ai-coding-agents-credential-security/
- canaryhook: https://github.com/aiagentflow/canaryhook
- agent-canary: https://github.com/petrhromadka/agent-canary
- GitHub Apps: https://docs.github.com/en/rest/apps/apps
- Cloudflare tokens: https://developers.cloudflare.com/fundamentals/api/how-to/create-via-api/
- Vercel tokens: https://vercel.com/docs/rest-api/authentication/create-an-auth-token
- PlanetScale: https://planetscale.com/docs/api/oidc
- Datadog: https://docs.datadoghq.com/account_management/workload_identity_federation/
- Tailscale federation: https://tailscale.com/docs/features/workload-identity-federation
- SendGrid: https://www.twilio.com/docs/sendgrid/api-reference/api-keys/create-api-keys
- Resend: https://resend.com/docs/api-reference/api-keys/create-api-key
- Neon: https://neon.com/docs/manage/api-keys
- Twilio: https://www.twilio.com/docs/iam/api-keys/key-resource-v1
- Hugging Face: https://huggingface.co/docs/hub/en/oauth
