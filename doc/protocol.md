# Protocol

Status: draft, 2026-11-11. Nothing described here has been built yet.

The [design](design.md) says what grants does. This document pins down the
things that separate programs have to agree on:

1. [The file](#1-the-file): what `grants.edn` may contain and how it's hashed.
2. [The control socket](#2-the-control-socket): how a process becomes a task,
   and the owner's own operations.
3. [The gateway](#3-the-gateway): how a task uses a grant over HTTP.
4. [The identity token](#4-the-identity-token): what the issuer signs and
   what a provider is told to expect.
5. [What the issuer keeps on disk](#5-what-the-issuer-keeps-on-disk).

[vectors.md](vectors.md) has test cases for the first and third.

A build never ignores something it doesn't implement. A grant it can't serve
is refused when it's used, with `unsupported`, and the rest of the file keeps
working. In the unsigned build that covers every grant with `:bound :live`
and every `:provider :wrap` grant, and a task that lists a live grant can't
start.

## 1. The file

In the first version only the daemon reads `grants.edn`. The Clojure library
finds the file's directory and asks the daemon for everything else. A second
reader comes with production, where there is no daemon, and it has to pass
the same test cases.

### 1.1 Grammar

The file is read with a strict subset of EDN, by a reader written for it and
not by a general EDN reader.

- UTF-8, with no byte-order mark. At most 256 KiB. Nested at most 16 deep,
  counting the top-level map as 1.
- Whitespace is space, tab, line feed, carriage return, and comma. A `;`
  starts a comment that runs to the end of the line.
- The file is exactly one map, followed only by whitespace and comments.
- A value is a map, a vector, a string, or a keyword. Nothing else.
- A string may use the escapes `\"`, `\\`, `\n`, `\t`, `\r`, and `\uXXXX`.
  An escaped or raw lone surrogate is an error.
- A keyword is `:name` or `:namespace/name`, where each part matches
  `[a-z][a-z0-9-]{0,62}`.
- A map with the same key twice is an error.

Numbers, booleans, `nil`, symbols, sets, lists, characters, tagged values,
metadata, `#_`, and namespaced-map syntax are all errors.

The reason for a subset is that general readers change the meaning of a file
before any check on its data can run, and two readers don't change it the
same way. `clojure.edn` reads `010` as 8 and `"\101"` as `"A"`, drops
metadata, ignores a second top-level form, and accepts `:a:b`. The one Go EDN
library accepts a map with a duplicate key and keeps the last value, where
`clojure.edn` refuses it. A reviewer could read one `:host` while the daemon
enforced another. With the subset, a file means one thing or is refused.

### 1.2 Schema

A key that isn't listed here is an error.

Top level:

| Key             | Value                                              |
| --------------- | -------------------------------------------------- |
| `:app`          | A string matching `[a-z][a-z0-9-]{0,62}`. Required |
| `:grants`       | A map from grant name to grant. Required           |
| `:tasks`        | A map from task name to task. Required             |
| `:default-task` | A task name                                        |

A grant name is a keyword with or without a namespace. A task name and a slot
name are keywords without one.

Every grant has `:provider`. The rest depends on it:

| `:provider`  | Keys                                                 |
| ------------ | ---------------------------------------------------- |
| `:anthropic` | `:allow`, optional                                   |
| `:http`      | `:host`, `:bound`, `:attach`, `:allow`. All required |
| `:wrap`      | `:bound`. Required                                   |

- `:host` is a lowercase DNS name: at least two labels, each of 1 to 63
  letters, digits, and hyphens, 253 characters in all, with no trailing dot
  and a last label that isn't all digits. An IP address in any notation, and
  `localhost`, are errors.
- `:bound` is `:test`, `:capped`, `:read-only`, or `:live`.
- `:attach` is a map from a header name to a template. A header name is a
  string that is a valid HTTP token. Names are compared in lower case, and
  two that differ only by case are an error. `host`, `content-length`,
  `transfer-encoding`, `connection`, `upgrade`, `te`, `trailer`, `keep-alive`,
  `expect`, and any name starting with `proxy-` or `grants-` are errors. A
  template is a slot keyword, or a vector of strings and slot keywords that
  contains at least one slot.
- `:allow` is a vector of rules. A rule is a vector of a method keyword and a
  path pattern ([3.5](#35-what-allow-matches)). A rule with a third element
  is an error. That place is reserved for rules on request bodies.

A task has these keys:

| Key       | Value                                                                              |
| --------- | ---------------------------------------------------------------------------------- |
| `:grants` | A vector of grant names from this file. Required                                   |
| `:env`    | A map from a variable name to a grant in this task, or to a vector of such a grant and a path suffix such as `"/v1"` |
| `:egress` | A vector of host names, following the `:host` rule                                 |

A variable name matches `[A-Za-z_][A-Za-z0-9_]*` and may not start with
`GRANTS_`. A suffix follows the path grammar in
[3.4](#34-the-request-target).

A file that is refused is refused with a reason code and a line number.
[vectors.md](vectors.md) lists the codes.

### 1.3 Canonical form and hash

The issuer approves a file by the hash of its canonical form:

1. Parse and validate the file.
2. Write it as JSON. A keyword becomes a string without its colon, such as
   `"llm/claude"`. A slot inside an `:attach` template becomes
   `{"slot": "secret"}`, so a slot can't be confused with a literal string.
   Header names are kept as written.
3. Sort the vectors whose order has no meaning: a task's `:grants`, a task's
   `:egress`, and every `:allow`.
4. Serialise with RFC 8785, which fixes key order, spacing, and string
   escaping.
5. The hash is `g1:` followed by the base64url SHA-256 of those bytes.

Comments, whitespace, key order, and the order of rules don't affect the
hash. Built-in provider lists aren't expanded into it, so the canonical form
is a function of the file alone. A release of the issuer that changes a
built-in list changes what an approved file allows, and that is part of
trusting the issuer's releases.

## 2. The control socket

### 2.1 Transport

One Unix stream socket at
`~/Library/Application Support/grants/control.sock`, mode 0600, in a
directory with mode 0700. launchd creates it and starts the daemon on the
first connection. The daemon closes a connection whose peer runs as a
different user.

The socket is for becoming a task and for the owner's own commands.
Everything a task does with a grant goes through the gateway. A sandbox
never gets this path, and `grants run` never passes its connection on to the
command it starts.

### 2.2 Framing

Each message is one JSON object on one line, in UTF-8, ended by a line feed
and no longer than 1 MiB. An object with the same key twice is an error.

```
request   {"id": 1, "op": "declare", ...}
event     {"id": 1, "event": "waiting", "for": "fingerprint"}
reply     {"id": 1, "ok": {...}}
          {"id": 1, "error": {"code": "not_approved", "message": "..."}}
```

`id` is an integer the client chooses. A client sends one request and waits
for its reply before sending the next. A request gets exactly one reply.
Zero or more events may come before it. The unsigned build sends no events,
but every client has to accept them, because the signed build sends one
while it waits for a fingerprint.

The daemon refuses a request that has a key it doesn't know. A client
ignores a key it doesn't know in a reply or an event, so a newer daemon can
say more to an older client.

The first request on a connection is `hello`:

```
{"id": 0, "op": "hello", "protocol": 1, "client": "grants-clj 0.1.0"}
{"id": 0, "ok": {"protocol": 1, "daemon": "0.1.0", "build": "unsigned"}}
```

If the daemon doesn't speak the client's protocol number, it replies with
`unsupported_version` and closes. The number changes only when the meaning of
an existing message changes.

A client gives up on connecting after two seconds, and on `hello` or
`declare` after five, unless an event has said the daemon is waiting for the
owner.

### 2.3 Becoming a task

```
{"id": 1, "op": "declare",
 "dir": "/Users/kira/code/projects/finance-aggregator",
 "task": "dev",
 "token": "gt1k3..."}
```

`dir` is an absolute path. `task` is optional: without it the daemon uses the
file's `:default-task`, and fails with `no_task` if there isn't one. `token`
is made by the client ([3.2](#32-urls)).

On `declare` the daemon:

1. Reads `<dir>/grants.edn` itself. It never accepts the file's contents from
   a client, and it refuses a symbolic link.
2. Parses and validates it, and computes its hash.
3. Checks that the hash is the approved one for the file's `:app`.
4. Checks that the task exists. In the unsigned build it refuses a task that
   lists a live grant.
5. Creates the task and replies:

```
{"id": 1, "ok": {"app": "finance-aggregator", "task": "dev",
                 "url": "http://127.0.0.1:7465/t/gt1k3..."}}
```

The task exists for as long as this connection stays open. A connection holds
at most one task, and a second `declare` on it is an error. When the
connection closes for any reason, the task ends: the gateway refuses its
token, cancels its requests in flight, and drops whatever it was holding in
memory for it.

Whether each of the task's grants is ready to use isn't checked here. A grant
with a value that hasn't been sealed doesn't stop the task's other grants
from working. [3.3](#33-what-the-library-asks) says how readiness is
reported.

**Coming back.** Because the client makes the token, a holder can get the
same task back. When the daemon restarts, every connection closes. Each
holder notices at once, connects again, and declares with the same token, so
the task's URL doesn't change and nothing that copied it has to be told. If
the new `declare` is refused, the library reports the error at the next
deref, and `grants run` stops its command and exits with an error.

A `declare` whose token belongs to a task that is still held by another
connection fails with `token_in_use`.

**Sessions.** The launcher for a sandboxed harness adds `"session": true`.
The daemon then opens a loopback port for that task alone and returns a URL
on that port ([3.11](#311-session-ports)). When it comes back after a
restart, the launcher asks for the same port again with `"port": <n>`.

### 2.4 The owner's operations

These are sent by the `grants` command.

| Op         | What it does                                                                                   | Used by |
| ---------- | ---------------------------------------------------------------------------------------------- | ------- |
| `issuer`   | Returns the issuer's URL, its signing key's id, and its public key as a JWK                    | `init` |
| `register` | Stores the ids a provider's setup produced, for an application and a grant                     | `init` |
| `policy`   | Given a directory, returns the file's hash, whether it's the approved one, and the differences from the approved version | `approve`, `doctor` |
| `approve`  | Given a directory and a hash, makes that hash the approved one for the application. It fails if the file no longer has that hash, so what is approved is what was shown | `approve`, `init` |
| `seal`     | Given a directory and a grant, stores a value for each slot, bound as [3.10](#310-sealed-values) describes | `seal`, `init` |
| `test`     | Given a directory and a grant, tries the grant: an exchange for a federated one, an unseal for a sealed one. Returns what failed | `doctor` |
| `status`   | Returns the build, the running tasks, and for a directory each grant's readiness               | `doctor` |
| `log`      | Returns recent log entries                                                                      | `log` |

In the unsigned build, `grants approve` prints the differences and asks at
the terminal. `grants seal` prints what it's about to seal for (the host,
the header, and the bound), reads each value from the terminal without echo,
and sends it in the request. In the signed build both happen in the issuer's
own window: the requests carry no values, and the reply comes after the
owner has acted there.

### 2.5 Errors

```
{"code": "invalid_file", "message": "...", "reason": "duplicate_key", "line": 12}
```

`code` is stable. `message` is written for a person and says what to do
next. `reason` and `line` are present for `invalid_file`.

| Code                  | Meaning                                                              |
| --------------------- | -------------------------------------------------------------------- |
| `unsupported_version` | No protocol number in common                                         |
| `bad_request`         | A malformed message, an unknown key, or a second `declare`           |
| `no_file`             | No `grants.edn` in the directory, or it's a symbolic link            |
| `invalid_file`        | The file failed the grammar or the schema                            |
| `no_task`             | The task isn't in the file, or none was named and there's no default |
| `not_approved`        | The file's hash isn't the approved one. The message says to run `grants approve` |
| `unsupported`         | The task lists a live grant, and this is the unsigned build. The same code is a grant's reason for not being ready ([3.3](#33-what-the-library-asks)) |
| `token_in_use`        | Another connection holds a task with this token                      |
| `live_task_running`   | The application already has a live task running                      |
| `fingerprint_declined` | A fingerprint was needed and wasn't given                           |
| `internal`            | A bug                                                                |

## 3. The gateway

### 3.1 The listener

The gateway listens for HTTP/1.1 on `127.0.0.1:7465` and `[::1]:7465`.
launchd holds both, so no other process can bind the port while the agent is
registered. A URL the gateway hands out always uses `127.0.0.1`, never a
name: `localhost` resolves to `::1` first on this platform.

### 3.2 URLs

```
http://127.0.0.1:7465/t/<token>                       the task
http://127.0.0.1:7465/t/<token>/<segment>/<path>      a request for a grant
```

The token is `gt1` followed by 52 characters of lowercase base32, which
encode 32 bytes from a secure random source. The client makes it and sends it
in `declare`. The gateway keeps only a hash of it, compares in constant time,
and never writes it to its log.

A grant's segment is its name with the slash replaced by a dot, so
`:plaid/sandbox` is `plaid.sandbox`. A name can't contain a dot, so two
grants can't share a segment.

### 3.3 What the library asks

`GET /t/<token>` returns what the library needs to build references:

```json
{"app": "finance-aggregator", "task": "dev",
 "grants": [
  {"name": "llm/claude", "segment": "llm.claude", "kind": "http",
   "host": "api.anthropic.com",
   "headers": {"x-api-key": "grants-placeholder"},
   "ready": true},
  {"name": "plaid/sandbox", "segment": "plaid.sandbox", "kind": "http",
   "host": "sandbox.plaid.com", "bound": "test",
   "headers": {"PLAID-CLIENT-ID": "grants-placeholder",
               "PLAID-SECRET": "grants-placeholder"},
   "ready": false,
   "problem": {"code": "not_sealed",
               "message": "no value sealed for :plaid/sandbox on this machine. Run: grants seal :plaid/sandbox"}}]}
```

The library takes a task URL from `GRANTS_TASK_URL` or from `declare`, makes
this one request, and builds every reference from the answer. It uses the
same code inside a sandbox and outside one. A deref of a grant that isn't
ready fails with the problem's code and message. The library asks again when
it has to declare again.

A grant isn't ready when a slot has no sealed value (`not_sealed`), when a
sealed value was sealed for something else (`binding_mismatch`), when a
federated grant has no provider ids (`not_registered`), or when this build
can't serve it (`unsupported`). A request for such a grant gets the same
code from the gateway.

### 3.4 The request target

The gateway reads the target from the raw request line and never from a
decoded copy. It forwards exactly the bytes it matched, or it refuses the
request. It doesn't normalize.

Only the form `/path?query` is accepted. A full URL as the target and `*`
are refused with `bad_request_target`.

The path has to match this grammar:

```
path    = 1*( "/" segment )
segment = 1*pchar
pchar   = ALPHA / DIGIT / "-" / "." / "_" / "~" / "!" / "$" / "&" / "'"
        / "(" / ")" / "*" / "+" / "," / "=" / ":" / "@" / "%" HEXDIG HEXDIG
```

Then, for each segment:

1. A segment that is `.` or `..` is refused.
2. Each `%XX` is decoded. The segment is refused if a decoded byte is a
   control character, or is `/`, `\`, `%`, `;`, `?`, or `#`. It is also
   refused if its decoded form is `.` or `..`.
3. The decoded bytes have to be valid UTF-8.

That refuses empty segments (so `//` and a trailing slash), `;`, a raw
backslash, a fragment, raw bytes above ASCII, and every encoding of a dot
segment or a slash, including double encoding.

What follows the grant's segment is the upstream path. When nothing follows
it, the request matches no rule.

The query is forwarded byte for byte and plays no part in matching. It may
contain the `pchar` characters plus `/` and `?`, with no encoded control
characters. A parameter named `_method` is refused with
`bad_request_target`, because some frameworks treat it as the real method.

No client that was checked sends any refused form by accident. A request
that carries one is hand-built or hostile, so refusing it costs nothing and
leaves the gateway and the provider nothing to disagree about.

### 3.5 What `:allow` matches

A rule is `[<method> <pattern>]`. The method is one of `:get`, `:post`,
`:put`, `:patch`, `:delete`, and `:head`. The pattern is a path in the
grammar above, where a segment may also be `*`.

- `*` matches exactly one segment, whatever it contains. It never matches a
  slash, and a pattern segment can't mix it with other characters.
- Every other pattern segment matches only a segment with the same bytes.
  Matching is case-sensitive.
- The method has to be the same, in upper case on the wire. `:get` doesn't
  allow `HEAD`.
- A request is allowed if any rule matches. There are no deny rules, so
  order doesn't matter.

Any method outside those six is refused with `method_not_supported`. That
covers `OPTIONS`, `TRACE`, and, on the main port, `CONNECT`.

The built-in list for `:provider :anthropic` is:

```clojure
[[:post "/v1/messages"]
 [:post "/v1/messages/count_tokens"]
 [:get  "/v1/models"]
 [:get  "/v1/models/*"]
 [:post "/v1/messages/batches"]
 [:get  "/v1/messages/batches/*"]
 [:post "/v1/messages/batches/*/cancel"]
 [:get  "/v1/messages/batches/*/results"]]
```

If an `:anthropic` grant has its own `:allow`, a request has to match both
lists. The built-in list is as wide as the provider's own scope might be, and
the provider refuses what its scope doesn't cover.

### 3.6 Request headers

Every header the client sent is forwarded, except these, which are removed:

1. Hop-by-hop headers: `Connection` and the headers it names, `Keep-Alive`,
   `Proxy-Connection`, `TE`, `Transfer-Encoding`, `Expect`.
2. Credential headers, whatever the grant attaches: `Authorization`,
   `Proxy-Authorization`, `Cookie`, `X-Api-Key`, `Api-Key`.
3. Every header named in the `:attach` of any grant in the file.
4. `Forwarded`, `Via`, `X-Real-IP`, and every header starting with
   `X-Forwarded-` or `Grants-`.

Then the gateway sets `Host` to the grant's host and adds the grant's own
credential headers. A header the client sent twice, or in a different case,
is removed entirely before the grant's is added. The removal of hop-by-hop
headers happens first, so a client's `Connection: authorization` can't remove
the credential.

A request with `Upgrade`, `Trailer`, `X-HTTP-Method-Override`,
`X-HTTP-Method`, or `X-Method-Override` is refused with `bad_header`.
`Expect: 100-continue` is answered by the gateway after its checks, so a
refused request gets its error and never a `100`.

The value of a removed header is ignored. A placeholder is there only so
that an SDK which insists on a key has one.

### 3.7 Who may call

A request for a task or a grant is accepted only if its `Host` is
`127.0.0.1:<port>`, `localhost:<port>`, or `[::1]:<port>` for the port it
arrived on. A request
that carries `Origin`, or `Sec-Fetch-Site` with any value, is refused. The
gateway never sends an `Access-Control-` header and removes them from
responses.

Together these keep a web page away. A page whose name has been pointed at
loopback still sends its own name as `Host`, and a browser marks its requests
with one of the two headers. Node's `fetch` sends `Sec-Fetch-Mode` and
neither of those, so it isn't affected.

### 3.8 The order of checks, and what a request costs

A proxy request, which is a `CONNECT` or a request whose target is a full
URL, is handled apart from the rest. On the main port it's refused: a
`CONNECT` as a method the gateway doesn't support, and a full URL as a bad
target. On a session port it goes straight to the `:egress` rule in
[3.11](#311-session-ports) and none of the checks below apply to it.

For every other request the gateway checks in this order and stops at the
first failure:

1. The HTTP parser's own framing rules.
2. `Host`, `Origin`, and `Sec-Fetch-Site`.
3. The method.
4. The target's grammar, and the refused headers.
5. The token.
6. That the task lists the grant.
7. That the grant is ready.
8. `:allow`.

A request the parser itself refuses, such as two different `Content-Length`
headers, gets the parser's bare 400 or 501. Every later refusal is the
gateway's own ([3.9](#39-the-gateways-own-errors)).

Then:

- A request body is streamed to the provider and not buffered. A declared
  length over 32 MiB is refused before the body is read, and a body with no
  declared length is cut off at the same size.
- A response is streamed back as it arrives, and a server-sent event is
  flushed as it's written.
- The gateway never follows a redirect. It passes it back.
- These response headers are removed: hop-by-hop headers, `Set-Cookie`,
  every `Access-Control-` header, `Alt-Svc`, `Strict-Transport-Security`, and
  any header starting with `Grants-`, so a provider can't forge a gateway
  error.
- The gateway waits ten minutes for a response to start and five minutes
  between bytes of a body, with no limit on total time. When the client goes
  away, the request to the provider is cancelled.
- The gateway never retries.

### 3.9 The gateway's own errors

Every refusal by the gateway has the header `Grants-Error: <code>` and a
JSON body:

```json
{"type": "error",
 "error": {"type": "grants_gateway",
           "code": "operation_not_allowed",
           "message": "grants gateway: task dev may not POST /item/webhook/update on plaid/sandbox",
           "task": "dev", "grant": "plaid/sandbox"}}
```

The shape follows Anthropic's error body, and the message is where OpenAI's
SDKs look too, so it reaches the application's exception text. A response
from the provider passes through unchanged and never carries the header.

| Status | Code                     | When                                                   | SDK retries |
| ------ | ------------------------ | ------------------------------------------------------ | ----------- |
| 400    | `bad_request_target`     | [3.4](#34-the-request-target)                          | No          |
| 400    | `bad_header`             | [3.6](#36-request-headers)                             | No          |
| 401    | `task_token_invalid`     | Unknown token, or its task has ended                   | No          |
| 403    | `grant_not_in_task`      | The segment isn't a grant of this task                 | No          |
| 403    | `operation_not_allowed`  | No `:allow` rule matched                               | No          |
| 403    | `bad_host`               | [3.7](#37-who-may-call)                                | No          |
| 403    | `browser_request`        | [3.7](#37-who-may-call)                                | No          |
| 403    | `egress_not_allowed`     | [3.11](#311-session-ports)                             | No          |
| 405    | `method_not_supported`   | A method the gateway never forwards                    | No          |
| 409    | `not_sealed`, `binding_mismatch`, `not_registered`, `unsupported` | The grant isn't ready ([3.3](#33-what-the-library-asks)) | No |
| 413    | `body_too_large`         | [3.8](#38-the-order-of-checks-and-what-a-request-costs) | No         |
| 502    | `exchange_refused`       | The provider refused the exchange. Setup is wrong      | No          |
| 502    | `upstream_tls`           | The provider's certificate didn't verify               | No          |
| 502    | `upstream_unreachable`   | The provider couldn't be reached                       | Yes         |
| 503    | `credential_unavailable` | The exchange failed for a reason that may pass         | Yes         |
| 504    | `upstream_timeout`       | [3.8](#38-the-order-of-checks-and-what-a-request-costs) | Yes        |

Where the last column says no, the response also carries
`x-should-retry: false`, which Anthropic's and OpenAI's SDKs obey.

### 3.10 Sealed values

A sealed value is stored with a record of what it was sealed for:

```json
{"v": 1, "app": "finance-aggregator", "grant": "plaid/sandbox",
 "slot": "secret", "host": "sandbox.plaid.com", "bound": "test",
 "attach": [["PLAID-SECRET", {"slot": "secret"}]],
 "key": "<id of the enclave key>", "sealed": "<ciphertext>"}
```

`attach` lists every header the slot appears in, with its template, written
as in the canonical form. Every
field but the ciphertext is authenticated along with it, so a record can't
be edited to say something else. The value is encrypted to the issuer's
sealing key: an ephemeral P-256 key agreement with the enclave key, a key
derived with HKDF-SHA-256, and AES-256-GCM.

Before the gateway uses a value, it compares the record with the approved
file. If the host, the bound, or any header and template the slot appears in
has changed, the grant isn't ready, with `binding_mismatch`, and the owner
seals the value again.

To the provider the gateway speaks HTTPS on port 443, with normal certificate
checks and no way to turn them off. It ignores proxy settings in its own
environment. When it connects, it refuses an address that is loopback,
private, link-local, or an IPv6 form that embeds an IPv4 address, checked on
the address it's about to connect to and not on the DNS answer.

### 3.11 Session ports

For a sandboxed harness the daemon opens one more loopback port, chosen by
the system, and closes it when the task ends. The launcher gives that port to
the harness as its sandbox's HTTP proxy.

On a session port the gateway:

- Serves requests for `/t/<token>/...` exactly as on the main port, but only
  for the one task the port was opened for. Any other token is refused with
  `task_token_invalid`.
- Accepts `CONNECT <host>:443` when the host is in the task's `:egress`, and
  then relays bytes without reading them. The same address checks apply as
  for a provider. Any other host, any other port, and any plain-HTTP proxy
  request is refused with `egress_not_allowed`.

A sandboxed command can connect to this one port and to nothing else, so a
token for some other task, found in a file the sandbox can read, has nowhere
to be used.

### 3.12 Wrap

A wrap grant has two operations on its segment. This is part of the signed
build.

```
POST /t/<token>/<segment>/wrap     {"plaintext": "<base64>", "context": "<string>"}
                                   -> {"blob": "gw1:<key id>:<base64url>"}
POST /t/<token>/<segment>/unwrap   {"blob": "gw1:...", "context": "<string>"}
                                   -> {"plaintext": "<base64>"}
```

The blob is AES-256-GCM under the grant's wrapping key. `context` is
optional and is authenticated with the data, so an application can tie a blob
to the row it belongs to, and a blob moved to another row won't open. It
protects against a swap by someone who can edit the stored data. It hides
nothing from a task that holds the grant, which can pass any context.

## 4. The identity token

### 4.1 Format

A JWT signed with ES256. The signature is the raw 64-byte `r || s` form.

```
header  {"alg": "ES256", "typ": "JWT", "kid": "<thumbprint>"}
claims  {"iss": "<issuer URL>", "sub": "<app>:<task>", "aud": "<provider>",
         "iat": <now>, "exp": <now + 300>, "jti": "<random>"}
```

- `kid` is the RFC 7638 thumbprint of the signing key, so a second key or a
  second machine is another entry in a key set and not a new format.
- `iss` is chosen when the issuer is installed, one per machine, and never
  changes. Nothing fetches it. If a provider insists that it look like a
  public address, it's a URL under a domain the owner controls.
- `sub` is the application's name, a colon, and the task's name. Neither can
  contain a colon.
- A token is signed for one exchange and never reused.

`iss`, `sub`, and `kid` keep these forms after the first version, because
every provider's rule is written against them.

### 4.2 The exchange with Anthropic

```
POST https://api.anthropic.com/v1/oauth/token
{"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
 "assertion": "<the token>",
 "federation_rule_id": "fdrl_...", "organization_id": "...",
 "service_account_id": "svac_...", "workspace_id": "wrkspc_..."}
```

The four ids come from setup and are stored by `register`. All four are sent
every time. The reply carries an access token, which the gateway attaches as
`Authorization: Bearer`, and a lifetime. For a five-minute identity token the
lifetime is at most ten minutes.

The gateway keeps the access token in memory, for one task and one grant, and
uses it until two minutes before it expires. Then it exchanges again. If
several requests arrive with no token in hand, they share one exchange. If
the provider answers 401 to a request that carried a kept token, the gateway
drops the token so the next request starts with a fresh exchange. It doesn't
replay the request.

Anthropic answers every refused exchange with the same 401 and puts the
reason only in the Console's history. The gateway reports `exchange_refused`
with a message that says where to look. A network failure or a 5xx is
`credential_unavailable`.

Setup limits the registered issuer to identity tokens that last at most ten
minutes. Anthropic refuses one that claims a longer life or a start in the
future, so a token signed now can't be saved for later.

## 5. What the issuer keeps on disk

Everything is under `~/Library/Application Support/grants/`, mode 0700.

| Path | Holds |
| --- | --- |
| `control.sock` | The control socket, created by launchd |
| `keys/` | The stored forms of the enclave keys. They only work on this machine |
| `sealed/<app>/<segment>.<slot>.json` | One sealed record each |
| `state.json` | The issuer's URL, each application's approved hash and canonical form, and each grant's provider ids |
| `log.jsonl` | One JSON object per line. Rotated at 10 MiB, with one old file kept |

Files are mode 0600 and are replaced by writing a new file and renaming it.
The approved canonical form is kept whole, so `policy` can show what changed.

The agent's launchd description is in `~/Library/LaunchAgents`. It names the
binary, the control socket, and both loopback addresses.

In the unsigned build these are plain files, and code running as the
developer can change any of them. In the signed build the keys, the sealed
records, and the state are keychain items in the issuer's access group
instead.
