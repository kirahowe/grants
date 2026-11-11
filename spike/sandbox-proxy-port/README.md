# The gateway as the sandbox's proxy

Claude Code's command sandbox blocks direct connections to loopback, and it
tells clients not to use its proxy for loopback addresses. A JVM never uses
the proxy at all. So a gateway on a loopback port, listed as an allowed
domain, can't be reached by the clients that matter. The setting that lets
them through opens every local port.

The sandbox has to let commands reach its own proxy, though. This check sets
a port we control as the proxy and asks whether a sandboxed command can then
connect to that port directly, and to nothing else.

It was run on 2026-11-11 with Claude Code 2.1.322, and
`result-2026-11-11.txt` is the output. Port 47821 stood in for the gateway,
and 47822 for some other local service.

| Client | Proxy port | The other port |
| --- | --- | --- |
| `curl` with proxies turned off | Reached | Refused |
| `nc` | Reached | Refused |
| Babashka, a JVM | Reached | Refused, `Operation not permitted` |
| `curl` to an outside host | Sent to the proxy port as a proxy request | |

So a session's gateway port can be the sandbox's proxy. A sandboxed process
reaches it at an ordinary base URL, no other local port opens, and every
other outbound request arrives at the gateway to be refused or allowed.

## Running it again

1. Check that ports 47821 and 47822 are free. Start a small HTTP server on
   each, serving a file named `index.html`, and note their process ids.
2. In an empty directory that holds `probe.sh`, run:

   ```bash
   claude -p "Use the Bash tool to run exactly: bash ./probe.sh  Then print its raw output." \
     --model haiku --permission-mode dontAsk --setting-sources user \
     --strict-mcp-config --settings /path/to/settings.json
   ```

3. Stop the two servers by the process ids you noted.

The session is an ordinary Claude Code run and spends a little usage.

## A starting point for the generated settings

This is what the review's tests suggest `grants agent` should generate for
Claude Code. It hasn't been run as a whole.

```
claude --setting-sources user --strict-mcp-config --settings <generated file>
```

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "autoAllowBashIfSandboxed": true,
    "filesystem": {
      "denyRead": [
        "~/Library/Application Support/grants",
        "~/.ssh", "~/.aws", "~/.netrc", "~/.git-credentials",
        "~/.config/gh/hosts.yml", "~/.docker/config.json", "~/.npmrc",
        "~/.m2/settings.xml", "~/.fly/config.yml", "~/.codex-kira/auth.json",
        "~/Library/Preferences/.wrangler/config",
        "~/.config/finance-aggregator/key.txt",
        "~/Library/Keychains"
      ],
      "allowWrite": ["<the session's own cache directory>"]
    },
    "network": {
      "httpProxyPort": 0,
      "allowLocalBinding": false,
      "allowAllUnixSockets": false,
      "allowUnixSockets": []
    }
  },
  "permissions": {
    "deny": ["Read(//Users/kira/.ssh/**)"],
    "blockWritesOutsideWorkingDirectories": true,
    "disableBypassPermissionsMode": "disable"
  }
}
```

`httpProxyPort` is the session's port from the issuer, and `permissions.deny`
gets one `Read(...)` rule for each path in `denyRead`.

| Setting | Why | Checked |
| --- | --- | --- |
| `--setting-sources user` | Without it, the repository's hooks and MCP servers run outside the sandbox. It also drops the project's own permission rules, so the generated file has to carry everything | Tested |
| `--strict-mcp-config` | The same, for MCP servers | Read |
| `allowUnsandboxedCommands: false`, passed with `--settings` | Makes the harness ignore every sandbox setting in the repository | Tested |
| `failIfUnavailable` | Without it, a sandbox that can't start fails open | Read |
| `denyRead` | Stops a sandboxed command and anything it starts | Tested |
| A `Read(...)` deny rule | Stops the Read tool, and also becomes a denial for shell commands | Tested |
| `httpProxyPort` | The one local port the session can reach | Tested, above |
| `allowLocalBinding: false` | Turning it on lets commands connect to every local port | Read |
| `allowUnixSockets: []` | An unlisted socket can't be reached. The control socket is never listed | Tested |
| `blockWritesOutsideWorkingDirectories` | Keeps the file tools from writing the harness's own settings files | Read |
| `disableBypassPermissionsMode` | That mode skips the protected-path checks | Read |

The deny list names where credentials were found on this machine. Two of the
developer's logins aren't files at all: `gh` and Claude Code keep theirs in
the login Keychain. Denying `~/Library/Keychains` stops a command from
reading the keychain's files, but not from asking the system for an item,
which the review showed a sandboxed command can do.
