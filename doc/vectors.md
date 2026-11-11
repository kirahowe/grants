# Test vectors

Status: draft, 2026-11-11. Nothing described here has been built yet.

These cases pin down the places in [protocol.md](protocol.md) where a small
difference in reading would be a hole: reading `grants.edn`, and deciding
what a request to the gateway asks for. They are meant to become a fixture
directory, `conformance/`, that the daemon's tests run. A second reader of
the file, when production needs one, runs the same fixtures.

The tables give each case in brief. A fixture is a whole file or a whole
request, with the canonical JSON and hash for a file that is accepted.

The "Seen" columns record what a general-purpose tool did with the same input
when it was tried on 2026-11-11. They show why each case exists.
[checks.md](checks.md) says how those trials were run.

## Reading the file

A file is accepted, or refused with one of these reason codes: `bad_encoding`,
`too_large`, `too_deep`, `bad_whitespace`, `trailing_form`, `unknown_form`,
`bad_escape`, `bad_keyword`, `duplicate_key`, `unknown_key`, `missing_key`,
`wrong_type`, `bad_app`, `bad_host`, `bad_header`, `bad_template`,
`bad_slot`, `bad_pattern`, `bad_method`, `reserved`, `bad_variable`,
`bad_suffix`, `unknown_grant`, `unknown_task`.

| # | File | Expected | Seen |
| --- | --- | --- | --- |
| R1 | `{:app "a" :grants {} :tasks {}}` | Accepted | |
| R2 | `{:app "a" :app "b" :grants {} :tasks {}}` | `duplicate_key` | `clojure.edn` refuses. The Go EDN library keeps `"b"` |
| R3 | `{:app "a" :grants {} :tasks {}} {:app "b"}` | `trailing_form` | `clojure.edn/read-string` ignores the second map |
| R4 | A byte-order mark, then R1 | `bad_encoding` | `clojure.edn` reads the mark as a symbol |
| R5 | R1 with a no-break space between a key and its value | `bad_whitespace` | |
| R6 | `:app "\101"` | `bad_escape` | `clojure.edn` reads `"A"` |
| R7 | `:app "\uD800"` | `bad_escape` | `clojure.edn` accepts it |
| R8 | A value of `010`, `1`, `1.5`, `true`, or `nil` anywhere | `unknown_form` | `clojure.edn` reads `010` as 8 |
| R9 | A set, a list, a symbol, a character, `#_`, `^:x`, `#:ns{}`, or any tag | `unknown_form` | The Go EDN library accepts an unknown tag as data |
| R10 | A key `:a:b`, `:1abc`, `:a.b/c`, or `:A` | `bad_keyword` | `clojure.edn` accepts the first three |
| R11 | Maps nested 17 deep, counting the top one | `too_deep` | |
| R12 | A file of 257 KiB | `too_large` | |
| R13 | A top-level key `:minter`, or a task key `:command` | `unknown_key` | |
| R14 | `:app "My App"` | `bad_app` | |
| R15 | `:grants [...]` (a vector where a map belongs) | `wrong_type` | |
| R16 | A grant with `:provider :http` and no `:allow` | `missing_key` | |
| R17 | `:host "127.0.0.1"`, `"2130706433"`, `"localhost"`, `"Example.com"`, or `"example.com."` | `bad_host` | |
| R18 | `:attach {"Authorization" :key "authorization" :key}` | `duplicate_key` | |
| R19 | `:attach {"host" :key}` or `{"grants-x" :key}` | `bad_header` | |
| R20 | `:attach {"x-key" ["Bearer "]}`, a template with no slot | `bad_template` | |
| R21 | `:attach {"x-key" :ns/key}`, a slot with a namespace | `bad_slot` | |
| R22 | `:allow [[:post "/v1/msg_*"]]` | `bad_pattern` | |
| R23 | `:allow [[:post "/v1/messages/"]]` or `"/v1//x"` or `"/v1/../x"` | `bad_pattern` | |
| R24 | `:allow [[:post "/graphql" {:body {}}]]` | `reserved` | |
| R25 | `:allow [[:options "/x"]]` | `bad_method` | |
| R26 | A task that lists a grant the file doesn't define | `unknown_grant` | |
| R27 | `:env` naming a grant the task doesn't list | `unknown_grant` | |
| R28 | `:default-task` naming a task the file doesn't define | `unknown_task` | |
| R29 | `:env {"GRANTS_TASK_URL" :llm/claude}` | `bad_variable` | |
| R30 | `:env {"X_URL" [:llm/claude "v1"]}` or a suffix with a space | `bad_suffix` | |
| R31 | Grants `:plaid/api` and `:plaid-api` in one file | Accepted. Segments `plaid.api` and `plaid-api` | |
| R32 | A file with a `:bound :live` grant and a `:wrap` grant | Accepted, in both builds | |

Hashes:

| # | Two files | Expected |
| --- | --- | --- |
| C1 | The same file with its keys reordered and a comment added | The same hash |
| C2 | The same file with the rules of an `:allow` in another order | The same hash |
| C3 | The same file with a task's `:grants` in another order | The same hash |
| C4 | Templates `["a" :b]` and `[:a "b"]` | Different hashes |
| C5 | One rule added to an `:allow` | Different hashes |

## Tasks

| # | Case | Expected |
| --- | --- | --- |
| T1 | `declare` with no `task`, in a file with a `:default-task` | The default task |
| T2 | `declare` for a task that lists a live grant, in the unsigned build | `unsupported` |
| T3 | `declare` for another task of that same file | The task starts |
| T4 | A second `declare` on one connection | `bad_request` |
| T5 | `declare` with a token that another connection's task holds | `token_in_use` |
| T6 | The holder's connection closes | The token is refused at the gateway, and requests in flight are cancelled |
| T7 | After T6, a new connection declares with the same token | The same URL works again |
| T8 | A task with one grant whose value isn't sealed | The task starts. That grant reports `not_sealed`, and the task's other grants work |
| T9 | The file changes while a task is running | The running task is unaffected. A new `declare` reads the new file |
| T10 | A file whose hash isn't the approved one | `not_approved` |
| T11 | An older file that was approved before the current one | `not_approved` |

## Requests to the gateway

Unless a case says otherwise: the token `TOK` is valid for task `agent`, the
segment `g` is a ready grant with host `api.example.com`, the request's
`Host` is `127.0.0.1:7465`, and the grant's rules are:

```clojure
[[:post "/v1/messages"]
 [:get  "/v1/models/*"]
 [:head "/v1/ping"]]
```

`P` stands for `/t/TOK/g`.

### The target and the rules

| # | Request | Expected | Reason | Seen in Go |
| --- | --- | --- | --- | --- |
| G1 | `POST P/v1/messages` | Forward `POST /v1/messages` | Same bytes | |
| G2 | `GET P/v1/models/claude-x` | Forward | `*` matches one segment | |
| G3 | `GET P/v1/models` | 403 `operation_not_allowed` | `*` needs a segment | |
| G4 | `GET P/v1/models/a/b` | 403 | `*` never matches a slash | |
| G5 | `GET P/v1/models/` | 400 `bad_request_target` | Empty segment | |
| G6 | `POST P/v1/messages/` | 400 | A trailing slash is an empty segment | |
| G7 | `POST P/V1/messages` | 403 | Case-sensitive | |
| G8 | `post P/v1/messages` | 405 `method_not_supported` | Methods are upper case | The handler receives `post` |
| G9 | `GET P/v1/messages` | 403 | Wrong method | |
| G10 | `HEAD P/v1/models/x` | 403 | `:get` doesn't allow `HEAD` | |
| G11 | `HEAD P/v1/ping` | Forward | An explicit `:head` rule | |
| G12 | `OPTIONS P/v1/messages` | 405 | Never forwarded | |
| G13 | `CONNECT api.example.com:443` on the main port | 405 | No tunnels there | The handler receives it |
| G14 | `TRACE P/v1/messages` | 405 | | |
| G15 | `PRI * HTTP/2.0` | 405 | No cleartext HTTP/2 | The handler receives method `PRI` |
| G16 | `GET http://evil.example/t/TOK/g/v1/models/x` | 400 | A full URL as the target | `Host` becomes `evil.example` |
| G17 | `POST P/v1/../v1/messages` | 400 | Dot segment | Passed on unchanged |
| G18 | `POST P/v1/%2e%2E/v1/messages` | 400 | Encoded dot segment | Decoded in one field, raw in another |
| G19 | `POST P/v1/./messages` | 400 | Dot segment | |
| G20 | `GET P/v1/models/a%2Fb` | 400 | Encoded slash | Decoded to `a/b`, forwarded raw |
| G21 | `GET P/v1/models/a%2fb` | 400 | Lower-case hex too | |
| G22 | `GET P/v1/models/a%5cb` | 400 | Encoded backslash | |
| G23 | `GET P/v1\..\admin` | 400 | Raw backslash | Accepted |
| G24 | `GET P/v1/models/%252e%252e` | 400 | Decodes to text containing `%` | Decoded once |
| G25 | `GET P/v1/models/%ff%fe` | 400 | Not UTF-8 | Accepted |
| G26 | `GET P/v1/models/` then raw bytes `c3 a9` | 400 | Raw byte above ASCII | Accepted |
| G27 | `GET P/v1/models/%zz` | 400 | Bad encoding | 400 |
| G28 | `GET P/v1/models/a%00b` | 400 | Encoded NUL | Accepted |
| G29 | `POST P//v1/messages` | 400 | Empty segment | |
| G30 | `POST P/v1/messages;x=1` | 400 | `;` | Forwarded unchanged |
| G31 | `GET P/v1/models/a%3Bb` | 400 | Encoded `;` | |
| G32 | `POST P/v1/messages#f` | 400 | Fragment | Kept in the path, then encoded |
| G33 | `GET P/v1/models/x?limit=5&after=a%20b` | Forward, query unchanged | The query isn't matched | |
| G34 | `POST P/v1/messages?beta=true` | Forward, query unchanged | Claude Code and Anthropic's SDK send this | |
| G35 | `GET P/v1/models/x?a=%00` | 400 | Encoded control character in the query | |
| G36 | `POST P/v1/messages?_method=DELETE` | 400 `bad_request_target` | Method override | |
| G37 | `GET P/v1/models/%6dodel` | Forward as sent | `*` takes any valid segment | |
| G38 | `POST P/v1/%6dessages` | 403 | A literal segment compares raw bytes | |
| G39 | `POST /t/BAD/g/v1/messages` | 401 `task_token_invalid` | | |
| G40 | `POST /t/TOK/other/v1/messages` | 403 `grant_not_in_task` | | |
| G41 | `POST /t/TOK/g` | 403 `operation_not_allowed` | Nothing follows the segment, so no rule matches | |

### The order of checks

| # | Request | Expected | Reason |
| --- | --- | --- | --- |
| O1 | `OPTIONS P/v1/messages` with `Origin` | 403 `browser_request` | The caller is checked before the method |
| O2 | `POST /t/BAD/g/v1/../x` | 400 `bad_request_target` | The target is checked before the token |
| O3 | `DELETE /t/BAD/g/v1/messages` | 401 `task_token_invalid` | The token is checked before the rules |
| O4 | `POST P/v1/other` where the grant isn't sealed | 409 `not_sealed` | Readiness is checked before the rules |

### Headers and the caller

| # | Request | Expected | Reason | Seen in Go's reverse proxy |
| --- | --- | --- | --- | --- |
| H1 | `Host: attacker.example:7465` | 403 `bad_host` | A page pointed at loopback | Accepted |
| H2 | `Host: localhost:7465` | Forward | An allowed name | |
| H3 | `Host: 127.0.0.1:9999` | 403 `bad_host` | Wrong port | |
| H4 | HTTP/1.0 with no `Host` | 403 `bad_host` | | Accepted with an empty host |
| H5 | Two `Host` headers | The parser's 400 | | 400 |
| H6 | `Origin: https://evil.example` | 403 `browser_request` | | |
| H7 | `Sec-Fetch-Site: cross-site` | 403 `browser_request` | | |
| H8 | `Sec-Fetch-Mode: cors` alone | Forward | Node's `fetch` sends this | |
| H9 | `Authorization: Bearer X`, grant attaches `x-api-key` | Provider gets the real `x-api-key` and no `Authorization` | Credential headers are removed | Both forwarded |
| H10 | `x-api-key: X`, grant attaches `authorization` | Provider gets only the attached header | | `X-Api-Key` forwarded |
| H11 | `PLAID-SECRET: x` sent to a grant that isn't Plaid's | Removed | Named in another grant's `:attach` | |
| H12 | Two `Authorization` headers in different case | Both removed, one attached | | |
| H13 | `Connection: close, Authorization` | The attached header still reaches the provider | Hop-by-hop removal comes first | Holds when the header is set in `Rewrite` |
| H14 | `Cookie: a=b` | Removed | | Forwarded |
| H15 | `Forwarded`, `X-Forwarded-For` | Removed | | Removed |
| H16 | `Upgrade: websocket` | 400 `bad_header` | | Forwarded |
| H17 | `Trailer: Authorization` with a chunked body | 400 `bad_header` | Trailers are never forwarded | The trailer was announced upstream |
| H18 | `X-HTTP-Method-Override: DELETE` | 400 `bad_header` | | |
| H19 | `Expect: 100-continue`, refused by the rules | 403, and no `100` | Checks run before the body | |
| H20 | `Expect: 100-continue`, allowed | `100`, then forwarded without `Expect` | | `Expect` absent upstream |
| H21 | `Transfer-Encoding: chunked` with `Content-Length: 4` | Forwarded, framed again | The provider only sees framing the gateway wrote | Chunked wins |
| H22 | Two different `Content-Length` headers | The parser's 400 | | 400 |
| H23 | `Transfer-Encoding: gzip, chunked` | The parser's 501 | | 501 |
| H24 | `Content-Length` over 32 MiB | 413 `body_too_large` before the body is read | | |
| H25 | Response with `Set-Cookie`, `Access-Control-Allow-Origin`, and `Grants-Error` | All three removed | | |
| H26 | A server-sent event stream | Each event flushed as written | | Flushed |
| H27 | Response `302` with `Location` | Passed back, not followed | | |

### Readiness and the provider

| # | Case | Expected |
| --- | --- | --- |
| S1 | The grant's `:host` changed since its value was sealed | 409 `binding_mismatch`. The task's other grants work |
| S2 | The slot moved to a different header since sealing | 409 `binding_mismatch` |
| S3 | The grant's `:bound` changed since sealing | 409 `binding_mismatch` |
| S4 | A rule was added to `:allow` since sealing | The grant works, once the file is approved |
| S5 | A federated grant with no provider ids on this machine | 409 `not_registered` |
| S6 | The provider answers the exchange with 401 | 502 `exchange_refused`, with `x-should-retry: false` |
| S7 | The exchange can't reach the provider | 503 `credential_unavailable`, with no retry header |
| S8 | Ten requests arrive with no credential in hand | One exchange |
| S9 | The host resolves to `10.0.0.5` or `127.0.0.1` | 502 `upstream_unreachable` |
| S10 | The provider's certificate doesn't verify | 502 `upstream_tls` |

### Session ports

| # | Request on a session port | Expected |
| --- | --- | --- |
| P1 | `GET /t/TOK` with the session's own token | 200 |
| P2 | `POST /t/OTHER/g/v1/messages` with another running task's token | 401 `task_token_invalid` |
| P3 | `CONNECT repo.clojars.org:443`, listed in the task's `:egress` | Tunnel opened |
| P4 | `CONNECT github.com:443`, not listed | 403 `egress_not_allowed` |
| P5 | `CONNECT repo.clojars.org:22` | 403 `egress_not_allowed` |
| P6 | `GET http://repo.clojars.org/x`, a plain-HTTP proxy request | 403 `egress_not_allowed` |
| P7 | `CONNECT` to a listed host that resolves to a private address | 502 `upstream_unreachable` |
