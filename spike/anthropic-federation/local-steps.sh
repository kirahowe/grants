#!/usr/bin/env bash
# Steps 1-3 of the runbook: everything that needs no login. Safe to rerun.
# usage: local-steps.sh WORKDIR     (WORKDIR is created; the key never leaves it)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:?usage: local-steps.sh WORKDIR}"
mkdir -p "$WORK"; cd "$WORK"; umask 077

ISS="${ISS:-https://issuer.grants.invalid/spike}"   # the claim value; nothing fetches it in inline mode
SUB="${SUB:-spike-app:agent}"
KID="${KID:-spike-$(date +%Y%m%d)-a}"

# 1. throwaway software P-256 key (not the Secure Enclave; that is a later spike)
[ -f key.pem ] || openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out key.pem
echo "key: $(openssl pkey -in key.pem -text -noout | sed -n '/ASN1 OID/p;/NIST CURVE/p' | tr -s ' ' | tr '\n' ' ')"

# 2. JWKS (full document for reading) and the bare keys array (what the issuer API's jwks.keys wants)
bb "$HERE/wif.bb" jwks key.pem "$KID" > jwks.json
bb "$HERE/wif.bb" keys key.pem "$KID" > keys.json
jq -e '.keys|length==1 and (.[0]|.kty=="EC" and .crv=="P-256" and .alg=="ES256" and (.kid|length>0))' jwks.json >/dev/null && echo "jwks ok, kid=$KID"

# 3. sign a 5-minute JWT, check it with openssl, and decode it
bb "$HERE/wif.bb" jwt key.pem "$KID" "$ISS" "$SUB" https://api.anthropic.com 300 > jwt.txt
bb "$HERE/wif.bb" verify key.pem "$(cat jwt.txt)"
bb "$HERE/wif.bb" decode "$(cat jwt.txt)" | jq -c '{alg:.header.alg,kid:.header.kid,iss:.claims.iss,sub:.claims.sub,aud:.claims.aud,life:(.claims.exp-.claims.iat),jti:(.claims.jti|length>0)}'
echo "local steps done in $WORK"
