# Suggestions

Ideas with a shape but no commitment, written 2026-10-24. Neither is a
roadmap item; the roadmap's "Ideas, not planned" points here. Both start
from one observation: the harness governs the Claude Code process on a
host, and two things now sit next to that process that it does not
govern on its own: agents built on the Agent SDK, and the cloud identity
the agent acts under.

## 1. Agents built on the Claude Agent SDK

The Agent SDK runs the same engine as the `claude` binary, from a
program: a Python or TypeScript process starts a session, sets tools,
permission mode, hooks and MCP servers in code, and reads the stream.
What the SDK documentation says about settings, read 2026-10-24
(`code.claude.com/docs/en/agent-sdk`, the `claude-code-features`,
`permissions` and `hosting` pages):

- With `settingSources` omitted, a session loads user, project and local
  settings, CLAUDE.md and the hooks in `settings.json`, as the CLI does;
  project settings and hooks come from `<cwd>/.claude/` with no
  parent-directory fallback. `settingSources: []` loads none of them.
- Managed settings load regardless of `settingSources`
  ("Agent SDK sessions load managed settings even when `settingSources`
  excludes the user, project, and local files"), and managed policy
  takes precedence over programmatic options.
- The program's own `settings` and `sandbox` options sit in the
  flag-settings layer, above project and local scope.
- `permissionMode` includes `bypassPermissions` (TypeScript also needs
  `allowDangerouslySkipPermissions`). `disableBypassPermissionsMode` is
  documented against the CLI flag and agent definitions; the SDK option
  is not named.
- Filesystem hooks and programmatic hooks run side by side; a
  `PreToolUse` hook gates "every tool call regardless of mode and rules".

So the picture, before any test: in a harness repo, an SDK program with
default options is governed exactly as a session is (`env-guard`, the
deny set, the sandbox, the preamble). A program that opts out
(`settingSources: []`, its own `sandbox`, bypass mode) escapes the repo
file on an unmanaged host, because the repo file is project scope and
the program's options rank above it. On a managed host the managed file
still loads; whether it also stops the program's bypass mode is the one
undocumented point, and it is the SDK form of the question
`docs/sessions.md` section 7 already asks about the CLI's
`--permission-mode`.

Two harness use cases fit the SDK, and three test cases come before
either:

- **The harness's own jobs.** `harness check` is fourteen `claude -p`
  sessions driven by a shell script and judged with `jq` over
  stream-json; roadmap item 6 (the limits suite) grows the same way. As
  an SDK program: a typed stream, the transcript already parsed, one
  process per case. Not the broker (dropped 2026-10-24): that was a hooks
  module inside the engine (`docs/sessions.md` section 5), not a client of
  it.
- **Headless agents on the managed host.** A scheduled job on the WSL
  host (a nightly `terraform plan` review, a dependency audit) is an SDK
  program under a systemd timer, as the same user, in a harness repo.

The test cases, each a `harness check`-style verdict on tool results:

1. Default options in a harness repo: `env-guard` refuses `git push`,
   `grep nonewprivs /proc/self/status` shows the sandbox, `DEVENV_ROOT`
   is set by the preamble. Expected to pass; the documentation says so.
2. The opt-out program on a managed host: `settingSources: []`,
   `sandbox: { enabled: false }`, `permissionMode: 'bypassPermissions'`
   with `allowDangerouslySkipPermissions`. Expected: the managed file's
   deny set and `env-guard` still apply (documented), the sandbox still
   runs (managed settings make it admin-required), and bypass mode is
   refused (not documented; the point of the test). On an unmanaged
   host the same program is expected to succeed, and the README's "what
   a repo cannot enforce on its own" gains the line: a program the user
   runs can opt out of the repo file; the managed layer is the answer,
   as it is for user-scope settings today.
3. `harness check` gains an SDK twin of cases 1, 3 and 7 and the case
   above, so a Claude Code release that changes SDK behaviour fails a
   check instead of a reader's assumption.

The limit to write down whichever way the tests go: the harness reaches
agents that run through Claude Code's engine. An agent framework that
calls the API directly, or another vendor's, runs on the host with the
user's credentials and sees none of the hook, the deny rules or the
sandbox. The reported Storm-0940 activity (a multi-agent pentest
framework driving compromised service-principal credentials across
tenants, per a 2026-10-24 briefing; not verified here) is that shape.
For it the only lever is the identity, which is section 2.

## 2. The agent's identity: Entra Agent ID and M365

The harness is the process half of agent control: what the process can
read, write, run and reach. Roadmap item 5 names the other half from the
process's side: "Reader-only service principal per customer. The one
control that holds against every client, including things the hook never
sees." The handoff's phase 3 already shapes it: `AZURE_CONFIG_DIR` under
`.git/devenv-base/azure-<actor>`, the actor `agent` or `human` from
`CLAUDECODE`, `agentAuth = user | sp` with `user` the default, `az login`
in the universal deny set so only the human logs either directory in, a
shell-entry tenant check, and a hook branch that compares the live
tenant with `ARM_*` before `az` and `terraform apply`.

What that design does not yet say is *who* the agent directory is logged
in as. With `agentAuth = user` it is the human's own identity in a
second token cache: the tenant's sign-in log cannot tell the agent's
calls from the human's, and no Conditional Access policy can target one
without the other. Microsoft's direction (Entra Agent ID; per the same
briefing, now task-scoped and time-bound permissions, agent risk,
Conditional Access for agent identities, and discovery that names
Claude Code as a local agent type) is the answer to exactly that: the
agent gets an identity of its own, so it gets its own log, its own
policy and its own blast radius. The harness's contribution is small
and already half built: the agent directory is where that identity is
consumed, and nothing else on the host is.

This belongs in a separate repository: a different audience (tenant and
security administrators), different artifacts (KQL hunts for
service-principal sign-ins and app-credential changes, Conditional Access
for workload identities as code, app-consent governance, a playbook),
usable by someone who never installs Nix. The harness must keep working
for non-Azure customers; it is cloud-agnostic apart from the `az` regex
and the network allowlist.

The seams, each already in the code or the handoff:

1. **Consumption.** A third `agentAuth` value for an identity minted in
   the tenant for this agent on this host: scoped reader, time-bound,
   under Conditional Access, logged into `azure-agent` by the human with
   a device code; no client secret on disk (the sandbox already denies
   `ARM_CLIENT_SECRET` and `AZURE_CLIENT_SECRET` and hides `.env`).
   `harness doctor` names the principal in each directory and warns when
   `azure-agent` and `azure-human` hold the same one.
2. **Detection.** The identity repo watches the tenant side; the harness
   has the host side (hook refusals, `harness check` transcripts, debug
   logs). The key is the agent identity's app id plus the host name. A
   documented pairing, no code.
3. **Attestation.** If tenant-side discovery inventories Claude Code
   installs, the managed tree (root-owned `/etc/claude-code`, a known
   settings body and hook) is the evidence that an install is governed.
   `harness doctor --json` emitting the settings hash, hook version and
   deny count is the hook for it. Not before a consumer exists.

Order: the hunting note first, it needs no harness change; the identity
repo second; the `agentAuth` value and the doctor line when phase 3
lands; the attestation output when something reads it. The README gains
one paragraph when the identity repo exists: the harness is the endpoint
half, the identity half lives in the tenant, with the link.
