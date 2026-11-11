# Prove the Anthropic exchange by hand

Every use case starts with an Anthropic grant: the issuer signs a short
token, and Anthropic exchanges it for a credential that lasts minutes. If a
one-person Console organization can't do that, the design has no first step.
This check answers the question in about half an hour, with a throwaway
software key and no code from the project.

Run it in your own terminal, outside any agent session. Steps marked
**admin** need your Console login.

- `local-steps.sh` makes the key, the key set, and a signed token, and
  verifies the signature. It passes here (run on 2026-11-11).
- `wif.bb` builds and checks tokens. OpenSSL does the cryptography and
  Babashka does the JSON and encoding.

Everything from step 2 on has never been run. The request bodies were built
and checked for shape only.

## 0. Before you start

```bash
command -v openssl bb jq curl
brew install anthropics/tap/ant        # not `brew install ant`, which is Apache Ant
export WORK=$HOME/tmp/grants-wif-spike # the throwaway key lives here
export API=https://api.anthropic.com
export AV=2026-10-21
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
R=$(pwd)                               # this directory
```

## 1. Key, key set, token

```bash
$R/local-steps.sh $WORK
```

It prints `signature OK` and the token's claims, with `sub` set to
`spike-app:agent`. It leaves `key.pem`, `jwks.json`, `keys.json`, and
`jwt.txt` in `$WORK`. A failure here says nothing about Anthropic.

## 2. A test workspace (admin, in the Console)

1. Create a workspace named `grants-spike` and give it a spend limit of a few
   dollars. The default workspace can't have one.
2. Copy the workspace id and the organization id.

```bash
export WSID=wrkspc_...  ORG=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**The premise fails if** a one-person organization can't create the
workspace or set the limit.

## 3. An admin token (admin, in a browser)

```bash
ant auth login --profile admin --scope "org:admin"
export ANTHROPIC_AUTH_TOKEN=$(ant auth print-credentials --profile admin --access-token)
curl -sS --fail-with-body $API/v1/organizations/service_accounts \
  -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: $AV"
```

Expect a 200 with a list. The token is short-lived, so repeat the `export`
line if a later step answers 401.

**The premise fails if** the login refuses the admin scope for the sole
owner, or the request answers 403 or names a plan.

The Console's "Connect workload" wizard is an alternative to steps 3 and 4.

## 4. Service account, issuer, rule (admin token)

```bash
H=(-H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" -H "anthropic-version: $AV" -H "content-type: application/json")
ISS=https://issuer.grants.invalid/spike
KIDA=$(jq -r '.keys[0].kid' $WORK/jwks.json)

SA=$(curl -sS --fail-with-body $API/v1/organizations/service_accounts "${H[@]}" \
  -d '{"name":"grants-spike","organization_role":"developer"}' | jq -r .id); echo $SA

curl -sS --fail-with-body $API/v1/organizations/service_accounts/$SA/workspaces "${H[@]}" \
  -d "{\"workspace_id\":\"$WSID\",\"workspace_role\":\"workspace_developer\"}"

ISSID=$(jq -n --arg iss "$ISS" --slurpfile k $WORK/keys.json \
  '{name:"grants-spike-a",issuer_url:$iss,jwks:{type:"inline",keys:$k[0]},max_jwt_lifetime_seconds:600}' \
 | curl -sS --fail-with-body $API/v1/organizations/federation_issuers "${H[@]}" -d @- | jq -r .id); echo $ISSID

RULE=$(jq -n --arg i "$ISSID" --arg s "$SA" --arg w "$WSID" \
  '{name:"grants-spike-inference",issuer_id:$i,
    match:{subject_prefix:"spike-app:*",audience:"https://api.anthropic.com"},
    target:{type:"service_account",service_account_id:$s},
    workspace_id:$w,oauth_scope:"workspace:inference",token_lifetime_seconds:600}' \
 | curl -sS --fail-with-body $API/v1/organizations/federation_rules "${H[@]}" -d @- | jq -r .id); echo $RULE
```

**The premise fails if** the issuer or rule request answers 403 or names a
plan.

**A design change, not a failure:** a 400 about `issuer_url`. The
documentation says an inline issuer's URL is only compared as text, but one
table lists it as needing a public host. If it's refused, try
`ISS=https://example.com/grants-spike`. If that works, the issuer's URL has
to look like a public address.

## 5. The exchange

A token can be exchanged once, so make a new one each time.

```bash
mint() { bb $R/wif.bb jwt $WORK/key.pem "$KIDA" "${1:-$ISS}" "${2:-spike-app:agent}" https://api.anthropic.com "${3:-300}"; }
exchange() {
  jq -n --arg a "$1" --arg r "$RULE" --arg o "$ORG" --arg s "$SA" --arg w "$WSID" \
   '{grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",assertion:$a,federation_rule_id:$r,organization_id:$o,service_account_id:$s,workspace_id:$w}' \
  | curl -sS -i $API/v1/oauth/token -H 'content-type: application/json' --data @-
}
exchange "$(mint)" | tee $WORK/exchange.txt | sed -n '1p;/^{/p'
export TOK=$(sed -n '/^{/p' $WORK/exchange.txt | jq -r .access_token)
```

Expect a 200, an `access_token`, a `scope` of `workspace:inference`, and an
`expires_in` of at most 600.

Anthropic answers every refusal with the same 401. The reason is on the
Console's workload identity page, under history. **The premise fails if**
the reason is about the signature or the key when the key is right.

## 6. A real request

```bash
export MODEL=claude-haiku-5-5
curl -sS -i $API/v1/messages -H "authorization: Bearer $TOK" -H "anthropic-version: $AV" -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say ok\"}]}" \
  | sed -n '1p;/anthropic-workspace-id/Ip;/^{/p'
```

Expect a 200, and a response header naming the test workspace.

**The premise fails if** this answers 403.

## 7. What the scope covers

finance-aggregator's evaluations use the batch endpoints, and the scope's
documentation doesn't list them.

```bash
for spec in "GET /v1/models" "POST /v1/messages/count_tokens" "POST /v1/messages/batches"; do
  set -- $spec
  code=$(curl -s -o /tmp/p.json -w '%{http_code}' -X $1 $API$2 -H "authorization: Bearer $TOK" -H "anthropic-version: $AV" -H 'content-type: application/json' \
    -d '{"model":"'$MODEL'","messages":[{"role":"user","content":"."}],"requests":[]}')
  echo "$spec -> $code $(head -c 120 /tmp/p.json)"
done
```

A 400 on batches means the scope let the request through and the body was
wrong. A 403 means the scope excludes batches. Either answer settles open
question 4 in the design.

## 8. What should be refused

Each of these should answer 401.

```bash
JW=$(mint); exchange "$JW" | sed -n 1p; exchange "$JW" | sed -n 1p   # 200, then 401: used twice
exchange "$(mint $ISS other-app:x)" | sed -n 1p                      # wrong subject
exchange "$(mint $ISS spike-app:agent 7200)" | sed -n 1p             # lifetime over the issuer's limit
exchange "$(mint https://elsewhere.example/ spike-app:agent)" | sed -n 1p   # wrong issuer
```

**The premise fails if** any of them answers 200 after the first.

## 9. Check the spend limit

Look at the test workspace's usage in the Console. The request from step 6
should be counted there. The documentation doesn't say that a workspace's
spend limit applies to credentials from an exchange, and the design relies on
it, so note what you see.

## 10. Clean up (admin)

```bash
curl -sS -X POST $API/v1/organizations/federation_rules/$RULE/archive "${H[@]}"
curl -sS -X POST $API/v1/organizations/federation_issuers/$ISSID/archive "${H[@]}"
curl -sS -X POST $API/v1/organizations/service_accounts/$SA/archive "${H[@]}"
ant auth logout --profile admin; unset ANTHROPIC_AUTH_TOKEN TOK
rm -rf $WORK
```

Archive the rule first. Then archive the workspace in the Console.

## What each result means

| Step | Result | Meaning |
| --- | --- | --- |
| 3 or 4 | Refused for the plan or the role | Federation isn't open to a one-person organization. The design has no first step |
| 4 | The issuer URL is refused | The URL has to look public. A design edit |
| 5 | A signature or key reason, with a correct key | ES256 with an inline key doesn't work |
| 6 | 403 | The scope doesn't cover inference |
| 7 | 403 on batches | Evaluation runs need a wider rule or a capped key |
| 8 | A 200 that should be a 401 | Rules don't bind the subject, or a token can be reused |
| 9 | The request isn't counted in the workspace | The spend limit can't be relied on, and request budgets move up the plan |
