# Shared installation and discovery

The repository owns one `skills/ba-release` directory. Do not copy the skill into
game repositories or maintain agent-specific workflow forks.

```powershell
pwsh -NoProfile -File <BA-Skills>/install.ps1 -IncludeWsl -CheckOnly
pwsh -NoProfile -File <BA-Skills>/install.ps1 -IncludeWsl
pwsh -NoProfile -File <BA-Skills>/install.ps1 -IncludeWsl -CheckOnly
pwsh -NoProfile -File <BA-Skills>/skills/ba-release/scripts/verify-discovery.ps1
```

The installer detects executables on each environment's PATH and preflights all
selected links before making any. It preserves all other skills and refuses a
regular file/folder, wrong link, dangling link, or conflicting legacy Codex entry.
It never edits agent settings or replaces skill directories. Repeated execution
returns `already-linked`. `-CheckOnly` reads without creating anything.

| Runtime | User discovery directory | Link |
| --- | --- | --- |
| Native Windows Codex | Actual Windows user home `/.agents/skills/` | Directory junction |
| Native Windows Claude Code | `CLAUDE_CONFIG_DIR/skills/`, otherwise Windows user home `/.claude/skills/` | Directory junction |
| Linux/WSL Codex | Linux user home `/.agents/skills/` | Symbolic link |
| Linux/WSL Claude Code | Linux `CLAUDE_CONFIG_DIR/skills/`, otherwise `~/.claude/skills/` | Symbolic link |

Codex's current user-level discovery location is `.agents/skills`; `CODEX_HOME`
is checked only for a conflicting legacy skill. Both hosts support linked skill
folders: [Codex documentation](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)
and [Claude Code documentation](https://code.claude.com/docs/en/skills#where-skills-live).

`-IncludeWsl` enumerates registered distributions and probes each Linux user's
login environment. `-WslDistribution <name>` restricts it when combined with
`-IncludeWsl`. Windows paths are translated with that distribution's `wslpath`;
the link points to the same canonical source under `/mnt/...`. The installer
does not assume WSL's home equals Windows' home and does not treat an old skills
directory as proof an agent is installed. Distributions with no PATH-visible
agents get no new links. Run the same installer from Linux `pwsh` for a Linux
checkout; `-IncludeWsl` is only relevant from native Windows.

Use Linux `pwsh` and Linux Godot for a native WSL release workflow. If those are
absent, run the native Windows release scripts against the Windows checkout;
translate paths explicitly with `wslpath -w` when launching `pwsh.exe` from WSL.
Installation does not install runtimes, engines, Butler, or credentials.

Discovery verification queries the installed agents' own startup inventories
without sending a model prompt, executing a release or creating a chat. New
sessions can invoke `ba-release` after installation. If a currently running
agent's selector is stale, refresh skills or restart that session.

Browser completion uses the user's designated BA/work Chrome profile. Its browser
connection is separate from skill installation and the private Chrome profile's
connection. Verify the BA profile appears in the current agent's connected-browser
inventory before store-console work, then apply the shared
[Chrome account guard](../SKILL.md#chrome-account-guard). Every agent must verify
the signed-in email is `cicely@benevolentanarchy.com` before acting; a matching
profile name or device ID alone is insufficient.

## Browser connection verification

The designated BA Chrome profile is `benevolentanarchy.com`. Select it by the
current browser inventory's profile name and connection identity as a candidate,
then check its signed-in account before acting. Do not rely on an ephemeral
browser number. Each agent needs its own working browser connection;
installing this shared skill or verifying one agent does not connect the other.

Recorded on 2026-10-08:

| Environment | Verified state |
| --- | --- |
| Codex desktop | The BA profile appeared in connected-browser inventory and responded to a read-only tab listing. Its Steamworks, itch.io editor and Google Play Console tabs were visible. |
| Claude Code | The user supplied a preferred device-selection procedure under [For Claude Code](../SKILL.md#for-claude-code). The shared account guard applies here as it does to Codex. Live connection verification is still pending the user's report. |

The Codex check verified the profile connection; it did not verify the Google
account email, publication or every store's current permissions. All agents must
perform the shared account guard before console work. Update the Claude entry only when its actual setup and
verification are reported; keep the main release workflow shared.
