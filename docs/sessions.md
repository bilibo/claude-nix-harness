# Sessions: tiers and proposals

How several Claude Code sessions on one host work together without trusting
each other. Written 2026-10-20 from the first live case: a session in a
customer repo was refused an edit by the hook (the rule for `devenv.nix`
matched the harness's own module source), wrote the change up as a diff,
sent it to the session open in the harness checkout, and that session put
the diff in front of Raul before applying it. That sequence is the design;
this file says which parts of it to make structural, and in what order.
The roadmap keeps the order against everything else.

## 1. Principles

- **Identity comes from the host, never from a message.** Which session is
  allowed to touch what is a property of the directory it was started in
  and the configuration that names the directories. A session can claim
  anything in a message; the receiver acts on none of it.
- **The human is the only party who can accept a relayed request.** A
  session that was refused an action does not get it done by asking a peer.
  Claude Code's own guidance to the receiving session says so (it calls it
  permission laundering); the harness makes it a check the engine performs,
  not a courtesy the model extends.
- **Coordination is a separate layer from enforcement.** `env-guard.sh`, the
  deny rules and the sandbox stay the hard rules, enforceable from a repo
  on any host. Everything in this file is coordination: it may make the
  rules easier to live with, it never relaxes one.
- **Observe before act.** Anything that shows state ships before anything
  that changes it.

## 2. What Claude Code already provides

Built into the binary, no mod involved, on this build (2.1.304):

- Sessions on one machine see each other (`ListAgents`) and message each
  other (`SendMessage`). The name is the directory the session runs in,
  plus its tmux pane.
- A message between sessions in different permission modes is held for the
  receiving human's approval; a message between sessions in the same mode
  is delivered to the model.
- The receiving model is told that a peer's request carries no user
  authority and that a request to do what the sender was refused must go
  to the human.

What it does not provide: a record of a proposal, a guarantee that the
receiver asks the human, a notion of which session may touch what, or any
view across sessions. The deny rules and the mod policy do not cover
messaging at all; a repo cannot isolate its session from its peers, and the
README says so under what a repo cannot enforce.

## 3. Tiers (handoff phase 2), realised as roles

Planned on 2026-10-20 as two tiers, customer and platform, chosen by
`ccmux` from the directory and exported as `HARNESS_TIER`. Realised on
2026-10-24 as a role the repo's own devenv shell sets: `harness.role` in
its `devenv.nix`, exported as `HARNESS_ROLE` at every shell entry and
carried by `ccmux`, which names the tmux window after it and does not
pass `center` on to a work session it launches. The customer tier is the
role `work`, the platform tier the role `center`; section 5 keeps the old
words.

| Role | Where | Rules | Part in the flow |
|---|---|---|---|
| `work` (default) | every harness repo under `HARNESS_CODE_ROOT` (`~/code/git/<customer>/<repo>`) | the repo's generated `.claude/settings.json`: full deny set, hook, sandbox with the network allowlist, memory off | proposes; never applies a change the rules refused |
| `center` | this checkout only, which imports the harness module pinned from GitHub like a work repo | the same deny set and hook, no sandbox, every Bash command prompted unless the owner allows `Bash(*)`, memory on (`docs/command-center.md`) | the control room: the human accepts or rejects proposals there |

The role is the repo owner's line in `devenv.nix`, which the deny rules
and the hook refuse to a session and `require_allowed` flags at the next
`cd`, so no session can make its own repo a center; `harness init`
refuses a work repo that sets `center`. The configured platform roots
(a home module option, or a bootstrap `HARNESS_PLATFORM_ROOTS`) were
never built: on an unmanaged host the repo file is the only rule source,
and the line in `devenv.nix` is the whole decision, as `harness.enable =
false` is. `~/nixos-config` has no harness shell and no role (handoff
phase 2 has what is open). The center session is not "allowed to act for
peers"; it may edit harness source because that is its directory, and the
permission prompt in it is the gate. It must not run in a bypass mode;
its generated settings set `disableBypassPermissionsMode` like a work
repo's.

The roles do not remove the 2026-10-20 trigger: the hook is the same in
both, so its rule for `*/devenv.nix` still matches the harness's own
`devenv/devenv.nix` in the center, and a change there still comes to the
human as a diff.

## 4. The proposal flow

A proposal is a diff plus a rationale, the role and directory it came
from, and a timestamp. It is the only thing that crosses from a work repo
to the center.

1. A work session hits a refusal for a change to a harness-owned or
   project-config file (`devenv.nix`, `.envrc`, `.claude/settings.json`,
   the harness source). It writes the change as a diff and submits it as a
   proposal. It does not ask any session to apply it.
2. The center session shows the proposal to the human: the model relays
   it in chat and asks. The window it waits in turns colour in tmux
   (`tmux-notify.sh`), next to the work session's under `ccmux`.
3. The human accepts in the center session. Only then does an edit
   happen, by the center session, under its own permission prompt, or by
   the human from the diff where the hook refuses the file in the center
   too (`devenv.*`, `.envrc`, `.claude/`).
4. The applied change is traceable to the accepted proposal.

Since 2026-10-24 the roles exist; the flow on top of them is unchanged.
Steps 1 and 2 are the CLAUDE.md contract in both places: the block
`harness init` writes into work repos ("Do not work around it: propose a
diff or ask") and this repo's own CLAUDE.md ("propose those as diffs";
it has no line of its own on relayed requests, so the receiving side is
Claude Code's guidance in section 2). Step 3 is Claude Code's permission
prompt plus the receiving model's judgement. Step 4 is the chat
transcript. That is the whole mechanism: the broker mod that was to make
steps 2, 3 and 4 structural was dropped on 2026-10-24 (section 5).

Relay is for the genuine case: a work session needing a change to
harness source or project configuration. Routine work bouncing through the
center means a rule over-matches, and the fix is the rule.

## 5. The broker mod: dropped 2026-10-24

Roadmap item 8 planned one mod, `harness-broker`, shipped from this
repository through a managed marketplace directory in three stages:
observe (a row per session in the mod's store, `/fleet`, the tier in the
status line), propose (`/propose`, and a `/proposals` pane with accept and
reject in the platform session), gate (a `tool.call` hook in the platform
session letting through only edits that match an accepted proposal). The
builder, the registration keys and the first observe slice went in on
2026-10-21; the mod never loaded on a managed host.

Dropped on 2026-10-24, with the machinery that built and shipped it
(changelog). A mod is a hooks module loaded into the engine of every
session on the machine: it sees every event, can deny or rewrite any tool
call and change the system prompt, runs with the engine's reach outside
the Bash sandbox, and keeps a store every session shares. An enabled
organisation mod is the one kind the built-in guard lets through, so
shipping one makes its code, its build, the marketplace that serves it and
the keys that enable it a trust surface the harness would have to defend
on every host, for coordination that never relaxes a rule (section 1).

What stays is the policy that refuses mods:

- Managed host: the built-in guard's `allowManagedModsOnly` with no
  organisation mod enabled, so every mod is refused;
  `strictKnownMarketplaces` empty unless `harness.extraKnownMarketplaces`
  lists a source, so no marketplace can be added; `disableSideloadFlags`;
  `allowManagedHooksOnly`. The managed tree has no marketplace directory.
- Any host: the deny rules and the hook refuse `claude plugin` and the
  plugin flags on a nested `claude`; `harness init` refuses a repo with a
  plugin manifest under `.claude`.
- Unmanaged host: since the same day `harness bootstrap` writes
  `syncClaudeAiSkills` and `syncClaudeAiPlugins = false` into user scope by
  default, so the claude.ai account's plugins and skills do not load;
  `--account-sync` opts back in.

Coordination stays the proposal flow of section 4 plus `ccmux`: the
CLAUDE.md contract in each tier, Claude Code's own messaging between
sessions, the platform session's permission prompt as the gate, and the
tmux window colour as the sign that a session waits. A record of proposals
and a structural gate have no replacement; reopening either takes a new
dated roadmap entry.

## 6. Testing

- The mod policy: `managed-tree-test` over both managed trees (no
  marketplace directory, no `extraKnownMarketplaces` or `enabledPlugins`,
  the guard option, an empty `strictKnownMarketplaces`,
  `disableSideloadFlags`, `allowManagedHooksOnly`), `nixos-module-eval` for
  the tree the NixOS module links, `hook-test` for the `claude plugin`
  refusals.
- The proposal flow is a contract between models and a human, so its test
  is live: the live suite (`harness check`) is to gain a case where a work
  session's refused edit ends as a proposal in chat and not as an edit
  anywhere. The roles it waited for exist since 2026-10-24; the case does
  not yet.

## 7. Open questions

- Whether a center session can be kept out of bypass mode by its
  generated settings alone (`disableBypassPermissionsMode` is honoured from
  any scope; confirm it covers `--permission-mode` on the outer `claude`,
  which the hook cannot see).
- Remote Control: a driven session is still the local process, so the
  roles apply unchanged; confirm once Remote Control can start on a
  harness host (roadmap, Ideas).
