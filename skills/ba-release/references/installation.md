# Shared installation and discovery

The repository owns one `skills/ba-release` directory. Do not copy the skill into
game repositories or maintain agent-specific workflow forks.

```bash
<BA-Skills>/install.sh --skill ba-release --check-only
<BA-Skills>/install.sh --skill ba-release
<skill>/scripts/verify-discovery.sh --directory "/path/to/game"
```

`--skill ba-release` installs only this skill; omitting `--skill` installs every
repository skill. `<skill>/scripts/install.sh` selects ba-release and forwards
`--home` and `--check-only`.

The installer links `~/.agents/skills/ba-release` (Codex) and
`~/.claude/skills/ba-release` (Claude Code) to the canonical source with symbolic
links. It checks every selected target before creating any, preserves other
skills, and refuses an existing wrong link, folder or file, leaving it in place.
It never edits agent settings or replaces skill directories. `--check-only`
creates nothing and reports `would-install` for a missing link. Both hosts
support linked skill folders:
[Codex documentation](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)
and [Claude Code documentation](https://code.claude.com/docs/en/skills#where-skills-live).
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
