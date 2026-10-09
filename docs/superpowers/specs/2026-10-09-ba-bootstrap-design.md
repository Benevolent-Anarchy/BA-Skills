# ba-bootstrap: project foundation

Date: 2026-10-09

Status: proposed design for review. This document does not authorize implementation or create a project.

## Purpose and agreed scope

Cicely works across agents, worktrees and sessions. Earlier projects used textual queues and session handoffs, which became cumbersome and caused unnecessary PR churn. New projects should begin with the working process developed in De Recta Rerum Dispositione (DRRD): GitHub Issues coordinate unfinished work, permanent documentation holds the design canon and records of decisions and human judgements, and textual handoff is a minimal orientation map.

Version one creates the repository pair, the local private checkout, the documentation and agent contract, a working `tools/verify.ps1` documentation gate, issue labels, and local Obsidian setup. It also provides a way to apply the Obsidian setup to a fresh clone without creating repositories again.

The second step adds a selectable Godot starter, selected by default when available, and extends the same verification gate with GUT and the relevant Godot checks. Version one's documentation checks work without Godot; it supplies no runnable engine project, engine test suite or store configuration. Future Unreal, Unity, Tauri, Electron and web starters are possible extensions, not version-one work.

The skill's working name is `ba-bootstrap`. Instructions and helpers are shared across agents and do not require a particular AI's installed plugins or planning workflow.

## Inputs and identity

Collect these together when practical:

| Input | Meaning | Default |
| --- | --- | --- |
| Project name | Human-readable project title | Required |
| Description | Private repository description and opening README text | Required |
| Parent directory | Directory under which the private checkout is created | `C:\Users\cicel\Dev` |
| GitHub owner | Owner of both repositories | `Benevolent-Anarchy`; optional switch to `cicely-f` |

Trim surrounding whitespace and replace runs of whitespace in the project name with a hyphen, preserving capitalisation. Validate the result against both GitHub repository names and Windows directory names; reject unsupported names with a useful explanation instead of silently inventing another name.

For `Foo Bar Baz` with the defaults:

- Title: `Foo Bar Baz`.
- Private repository: `Benevolent-Anarchy/Foo-Bar-Baz`.
- Public repository: `Benevolent-Anarchy/Foo-Bar-Baz-release-notes`.
- Local checkout: `C:\Users\cicel\Dev\Foo-Bar-Baz`.
- Documentation vault: that checkout's `docs` directory.
- Obsidian nickname: `Foo Bar Baz`.
- Default branch: `main` in both repositories.

There is no local clone or path for the public repository. The title and repository name remain distinct values.

## Repository pair

The private repository contains the project foundation and enables Issues and PRs. Its initial GitHub description and README use the supplied description. Work proceeds in separate worktrees and ordinary reviewable PRs; bootstrap itself seeds the initial `main` branch directly.

The public repository initially contains exactly `README.md`. Its content is a heading identifying the project's release notes and one sentence: "This repository is the public record of release notes for Foo Bar Baz." Substitute the actual title. Do not copy the private description, documentation, code, licence, templates or workflows into this repository.

Disable Issues, pull requests, wiki, Discussions, Projects, Actions and other optional contribution or automation features exposed by GitHub. Leave the repository public and writable by Cicely's release tooling. Ordinary public GitHub affordances such as starring and forking are not contribution workflows on the original repository.

Use supported configuration APIs where available. GitHub documents disabling pull requests in Settings > General > Features; if that setting has no supported API, the invoking agent completes it through its authenticated browser tools. If a setting cannot be applied or verified, report the unfinished setting and retain a resumable partial result rather than claiming full completion.

The shared contract with the evolving `ba-release` skill is only the same-owner naming convention, public visibility, existing default branch and write access. Publication details and `release.json` integration will be reconciled as that skill and the Godot preset develop. Do not infer store IDs, release versions or credentials.

## Generated project files

```text
README.md
AGENTS.md
CLAUDE.md
.gitignore
tools/
  verify.ps1
  Documentation.psm1
docs/
  DESIGN.md
  design/
    .gitkeep
  DECISIONS.md
  decisions/
    .gitkeep
  JUDGEMENTS.md
  judgements/
    .gitkeep
  NEXT.md
  .obsidian/                 generated locally and ignored
```

Empty topical directories are retained with `.gitkeep`; remove a marker when that directory gains its first real note. The initial indexes contain useful authoring and navigation guidance but no invented project decisions, judgements or design claims. No `_project-meta` directory is required.

`AGENTS.md` is the canonical agent contract. `CLAUDE.md` is a short pointer to it, not a second copy. Other agents can read the same contract explicitly; do not promise universal automatic discovery or generate unrequested agent-specific settings.

Ignore `docs/.obsidian/` and an agreed local scratch directory, `.scratch/`. Required tool configuration belongs where its tool expects it. Transient plans, session diaries and generated agent material are not permanent project documentation.

## Extracted agent contract

The generated contract expresses these rules in concise, engine-neutral language:

1. Read `docs/NEXT.md` for orientation at session start and retrieve all open Issues, using pagination rather than accepting a tool's default truncated list. Labels and milestones show the kind of work and planned deliverables; dependencies and sub-issues stay with the Issues.
2. Select work within the human's current direction. Inspect linked Issues and PRs before duplicating work. Record discussion and unresolved questions in Issues rather than creating a second task queue in documentation.
3. Read `docs/DESIGN.md` and the relevant topical notes before changing intended behaviour or structure. Current intended state belongs in design notes; update those notes when it changes.
4. Search the decision and judgement indexes for relevant titles and terms before changing a topic. Read the related records and follow cross-links. Do not load the entire corpus on every session start.
5. Record significant reasoning and rejected alternatives in a topical decision file and index every entry. Preserve superseded entries, mark them in place with forward references, and say what survives.
6. Record verdicts that required a person in topical judgement files. An automated test or an agent's inspection is not evidence that Cicely performed a human check. Capture the actual verdict, date, coverage, applicable hardware and conditions requiring a recheck.
7. If a change calls a judgement into question, mark it provisional in place and create or update an Issue for the investigation. The Issue closes after a new human check is recorded, not merely after its suspected cause is explained.
8. Close an Issue when its resolution is recorded in code, design, a decision or a judgement. A resolving PR uses `Closes #N`; an independently closed Issue points to its durable resolution. A duplicate or declined Issue records why it was closed.
9. Prefix GitHub body text with the author's identity, such as `[Codex]`, `[Claude]`, `[Rool]`, the appropriate local agent name, or `[Cee]`. This covers Issue and PR descriptions, comments, review feedback and replies. Titles do not carry the prefix. Honour the current task's authorization for posting.
10. Keep `NEXT.md` a small map to relevant parts of the project. Update it only when its orientation changes; do not append session history, test totals or an Issue queue. Ending a session alone does not require a documentation change or a PR.
11. Use separate worktrees and small, reviewable changes. Verify repository root, branch, status and relationship to `main` before a new slice and after a reported merge. Use the host application's managed worktree/handoff facilities when it has them; do not leave a chat operating in a stale checkout while treating another path as its new workspace.
12. Preserve existing work. Do not discard, stash or relocate another person's or agent's changes merely to make a workflow convenient.
13. Before opening a PR, make the proposed project state ready for a fresh session to take over once review passes. Finish the implementation, record durable outcomes, link resolved or remaining Issues, and update orientation where needed. Run `tools/verify.ps1` against that finished state and require it to pass before opening the PR; earlier results do not cover subsequent changes. Do not rely on being able to make non-review-related changes after the review process starts.
14. Open completed changes for ordinary PR review; Cicely retains merge control. Include the result, relevant verification and known limitations. `tools/verify.ps1` is the project's single verification gate; extend it as project checks are added rather than substituting a partial check for its complete result.
15. Prefer small changes and clear code, introduce dependencies for a concrete reason, and keep logic deterministic and independently testable where practical. Add comments explaining purpose, contracts and non-obvious choices rather than restating syntax.
16. Verify behaviour changes meaningfully and re-read new claims against the finished project state before calling work ready. Pay particular attention to claims about bounds, uniqueness and constants which later edits can invalidate.
17. Keep temporary execution plans in ignored scratch space or the active conversation. Promote durable conclusions to design notes, decisions or judgements, unfinished work to Issues, and orientation to `NEXT.md`.

These preserve DRRD's working process without carrying over its game premise, LG terminology, premium-game restrictions, prohibited gameplay systems, particular platform decisions, existing test totals or code maps. Godot/GUT requirements, compiler warnings and GDScript-specific comment rules belong to the later Godot preset.

## Seeded documentation contents

### DESIGN.md

Start with the project title, purpose of the working design canon, and an explanation that this file indexes topical notes under `design/`. Include a small "Where information belongs" guide linking `[[DECISIONS]]`, `[[JUDGEMENTS]]` and `[[NEXT]]`; unresolved matters belong in Issues.

Each topical design note has one clear topic, a title and searchable headings. Its index entry points to the file, explains its scope and links its substantive subheadings to their locations in that file. Keep the index a reading guide rather than a second copy of the design. Current design states what the project is; the rationale for reaching it lives in decision records. The index and headings are checked in both directions by `tools/verify.ps1`.

The `## Index` section is initially empty. The README's supplied description is not elaborated into an invented design. Add actual notes as the project's design is discussed.

### DECISIONS.md

Explain its role and the distinction between current design, reasoning, human observations and unfinished work. Store entries in topical files under `decisions/` so related choices are encountered together.

Use DRRD's record shape: dated `## YYYY-MM-DD` sections and a unique `### Decision title` for each entry. Titles are durable citation keys. Explain the choice, why it was made, what was rejected, supporting evidence and any superseded record. The index groups entries by topic file and lists every title with a link to its heading and searchable terms, including terms not present in the title. A topic fitting several concerns is stored where a reader would look for it and cross-linked from related topics.

When a decision supersedes one, mark the old entry in place and link forward; do not erase history. Update current design in the same change when intended behaviour changes. `tools/verify.ps1` checks each entry against its indexed title and target file, and rejects duplicate citation keys. This index has an empty `## Index` section initially and records no decisions.

### JUDGEMENTS.md

Explain that this records checks only a person could settle, including appearance, interaction, perceived timing, clarity and difficulty. Group related entries in topical files under `judgements/`.

Each entry has a unique `### Judgement title` followed immediately by a single-line `Judged` statement containing the actual date and either applicable hardware or `Hardware not applicable`. Its body records what was exercised, the verdict and enduring properties accepted, what was not covered, the circumstances requiring a recheck, and links to evidence or the relevant Issue when useful. Device-sensitive judgements name the hardware; platform-independent observations explicitly say hardware was not applicable.

The index lists every title, links to the entry heading, reproduces its judgement date/hardware statement and supplies searchable terms. An incomplete historical record is labelled incomplete rather than represented as trusted acceptance; open a relevant investigation Issue if needed. Newly written checks never invent a missing date, device or verdict.

If a relevant change invalidates an acceptance, retain and mark the entry provisional and link the Issue that requests a new check. Preserve both the old evidence and the later result. `tools/verify.ps1` checks the entry/index relationship and the judgement date/hardware fields independently, including agreement between the indexed statement and the actual record. This index has an empty `## Index` section initially and records no judgements.

### NEXT.md and links

Seed `NEXT.md` with a short orientation: the README identifies the project; the three indexes route its permanent canon; Issues hold unfinished work; `AGENTS.md` defines collaboration; `tools/verify.ps1` is the required gate before a PR opens. The README documents how to run that script. There is no initial task list or speculative backlog. Add pointers into implementation only as it exists.

Use plain Markdown and Obsidian wikilinks. Links to topical records are vault-relative and can include a heading and readable alias, for example `[[decisions/interface#A descriptive decision title|A descriptive decision title]]`. Agent instructions explain that the vault root is `docs/`, `.md` is implicit and a heading identifies an entry within its topical file. Repeated headings which make citations ambiguous are avoided. Canon navigation does not depend on Dataview executing.

## Project verification gate

Seed a working, tracked `tools/verify.ps1` and its documentation-validation support module, `tools/Documentation.psm1`, in the private project. They run from a fresh checkout without depending on the globally installed skill, Godot, Obsidian, network access or GitHub authentication. The script resolves paths from its own repository location, reports actionable file/heading diagnostics, returns non-zero on failure and zero only when all applicable checks pass.

Version one validates:

- The three required indexes, their real `## Index` sections and corresponding topical directories exist and can be read. A missing or unreadable index is a failure, not an empty successful scan.
- Each topical design note is indexed, each indexed file exists, and its indexed title and substantive headings match the actual note. An entry under one topic cannot be satisfied by a similarly named heading in another file.
- Every decision and judgement entry is indexed under its actual topic file exactly once, every indexed title resolves to the corresponding entry, and citation keys are unique within each record corpus.
- Local Markdown links and wikilinks in the documentation resolve to the intended file and, where specified, an existing unambiguous heading. Follow the project's documented vault-relative wikilink and relative Markdown-link conventions, including aliases used as display text. External URLs are not fetched.
- Judgement records carry the required single-line statement immediately under the entry title. The date and hardware fields are validated independently; an invalid date, missing field, wrapped or duplicate statement, or different date/hardware text in the index fails the gate. Explicitly incomplete historical records remain visibly incomplete and are not reported as trusted acceptance; the validator does not invent missing evidence.
- Apparent headings and links inside code examples or HTML comments do not count as live index entries or targets. Parsing must preserve the relevant Markdown distinctions already covered by DRRD's record-check fixtures.

A correctly seeded project with no topical notes or historical records passes. Empty initial collections are intentional; missing structure, a removed `## Index` heading, or an index which omits a real record fails. `.gitkeep` is not a documentation record.

Keep the gate extensible: the second-step Godot preset adds its import/compile checks, GUT runs and other applicable tests to `tools/verify.ps1`, retaining documentation validation. Further project-specific checks join this entry point as they are introduced. No engine check is silently skipped for an engine-enabled project; the aggregate exit code reflects every required stage.

Passing this gate after the complete proposed change is a prerequisite for opening a PR. Subsequent review changes are checked through the same complete gate before declaring the revised PR ready. Passing verification establishes machine-checkable contracts; it does not replace a human judgement or authorize fabricating one.

## Standard issue labels

Seed the complete DRRD label set with its inspected names, descriptions and colours. Preserve names and colours; adapt description references to DRRD's former `Design Notes` name to the generated `DESIGN.md` so guidance points at a real file.

The snapshot contains:

- GitHub defaults: `bug`, `documentation`, `duplicate`, `enhancement`, `good first issue`, `help wanted`, `invalid`, `question`, `wontfix`.
- Working process: `build`, `design`, `judge in play`, `content`, `housekeeping`, `accessibility`, `needs hardware`, `needs players`, `review follow-up`.
- Tracks: `systems`, `visual`, `game design`, `production`, `non-blocking`.

Retain the chosen game-oriented vocabulary in version one; future project presets can adapt it. Do not generate project-specific Issues, milestones or design constraints from DRRD's current backlog. Issue templates are not needed for version one: the index guidance and AGENTS contract define what to record without adding another source of duplicated rules.

## Obsidian preset

Maintain a curated preset inside the canonical skill, extracted from DRRD's existing configuration. The preset is tracked in BA-Skills; generated `docs/.obsidian/` remains ignored in every project. It is a selected configuration recipe, not a runtime dependency on DRRD's checkout or an external stub.

Required community plugins, installed at their latest published community releases at setup time:

| Display name | Plugin ID |
| --- | --- |
| Vault Nickname | `vault-nickname` |
| Vault Inspector | `vault-inspector` |
| Dataview | `dataview` |
| Diagram Popup | `mermaid-popup` |

Additional plugins are installed manually as project needs arise. Do not vendor current installed plugin binaries into the preset or pin them to the versions found in DRRD.

Carry selected editor, appearance and core-plugin preferences, Dataview's saved preferences, Vault Inspector's scanner preferences, and Vault Nickname's vault-first title behaviour. DRRD currently has no additional Diagram Popup settings or custom appearance values. Set Vault Nickname's shared nickname to the new human-readable title rather than retaining `DRRD`.

Exclude workspace/window state, open tabs, scan snapshots/history, previously ignored scan findings and other project-derived state. Do not copy Sync/Publish account configuration or automatically set up those services. If a copied core preference enables their UI, it does not constitute configuring or verifying a remote service.

Where the official Obsidian CLI is available, it can install and enable plugins in the specifically identified vault. It requires the installed CLI integration and connects to the running application. Otherwise, acquire the published release files and prepare the local plugin/configuration folders. Separate verification of installed files from verification that Obsidian actually loaded and enabled the plugins; report any remaining first-use or enablement step truthfully.

On a fresh clone, the local-setup entry point derives project identity from its verified repository and README rather than creating GitHub repositories. It creates missing Obsidian configuration. If configuration already exists, retain local preferences and extra plugins; install missing standard plugins and provide a deliberate refresh operation rather than silently replacing settings or updating every plugin on every invocation.

## Helpers, installation and resumability

Use a concise `SKILL.md`, shared PowerShell 7.2+ helpers suited to this Windows environment, project-document templates, standalone project-verification files, the Obsidian preset and a DRRD label snapshot. Git and authenticated GitHub CLI are the repository prerequisites. Keep supporting references conditional and avoid copying generic manuals into the skill.

The existing BA-Skills installer pattern provides one canonical source with Windows directory junctions at:

```text
C:\Users\cicel\.agents\skills\ba-bootstrap
C:\Users\cicel\.claude\skills\ba-bootstrap
```

Both point to `C:\Users\cicel\Dev\BA-Skills\skills\ba-bootstrap` after integration. During development they can be validated against the isolated worktree without replacing existing links. Other agents can read the same entry point explicitly. Extend installation while preserving ba-release's current behaviour and unrelated skills; re-check its evolving implementation before making shared installer changes.

The helper exposes inspection/planning, creation, local Obsidian setup and status/resume operations. The normal user interaction is the name/description/parent/owner prompt and a clear report of resulting identities and progress. An invocation requesting project creation and supplying its inputs authorizes that repository pair; do not invent repeated approval prompts for routine steps already authorized.

Validate inputs and local/remote conflicts before creation. Keep a small local progress journal under the current Windows user's `LOCALAPPDATA/BA-Skills/ba-bootstrap/state/`, keyed by owner and repository. It records the resolved inputs, created repository IDs, paths, phases and installed plugin versions, without credentials. This is operational state, not project canon.

Record verified results after each phase. After an ambiguous API outcome, inspect the exact owner/name before retrying. Reuse a repository only when the journal and observed identity establish it belongs to this invocation; do not adopt, change visibility on, overwrite or delete an unrelated existing repository. A local directory is similarly resumed only when its journal, Git origin and expected generated files agree.

Before retrying a file write, compare the existing content: accept the expected content, preserve different content and report the conflict. Do not automatically delete partially created repositories or local work to roll back a failure. Resume the missing phases and keep completed work.

Completion reports distinguish repositories created, content seeded, labels configured, public settings verified, local checkout prepared and Obsidian installed/enabled. Network, permission or plugin failures leave explicit partial progress. Initial private and public visibility are chosen at creation, not changed after uploading content.

## Validation and bogus-project trial

Use disposable local fixtures and simulated GitHub responses to verify meaningful behaviour before the live trial: title-to-name conversion, correct private/public initial contents, labels, a genuinely ignored Obsidian directory, interruption/resume, collision preservation, and repeatable skill installation. Validate the finished skill's structure. Extend existing installer checks only where its behaviour changes.

Test the generated verification gate with both valid and deliberately invalid documentation fixtures. The fresh scaffold and correctly indexed populated records pass. Missing files/headings, entries indexed under the wrong file even when a matching title exists elsewhere, omitted or duplicate records, inconsistent judgement metadata, independently absent date/hardware fields and removed required index structure fail with useful diagnostics. Code/comment examples must not produce false failures or satisfy missing live entries. A fresh clone can run the same gate independently of the skill installation.

Then create a clearly named bogus project through the actual skill, for example `BA Bootstrap Smoke Test`, using the chosen owner and a description identifying it as disposable. If its name already exists, choose an unused test name explicitly rather than adopting that repository.

Verify the private checkout's `main`, remote owner, seeded files, labels and canon routing, and run its `tools/verify.ps1`. Temporarily introduce a wrong file/heading reference in the disposable project, confirm the gate fails, restore it and confirm the complete gate passes. Verify the public repository is public, initially contains only the stated README, has contribution/automation features disabled, and can be written by the release identity. Verify all four plugin versions against their published releases and check the Obsidian nickname plus Diagram Popup's full-screen/pan/zoom behaviour in the application where available.

Exercise resume without duplicated repositories or overwritten content, and exercise local Obsidian setup on a second fresh private clone. Record exactly what was verified and any step still requiring Cicely's inspection. This trial tests the repository contract with ba-release without claiming that an evolving release workflow is complete.

Cicely will tear down the bogus project. The skill does not delete either repository or the checkout automatically.

## Alternatives and implementation boundary

The selected approach is one shared skill with curated templates/presets and small deterministic helpers. A complete cloned stub would carry unrelated project and workspace state; instructions alone would require each agent to rediscover the same creation and resume mechanics. The selected design keeps the editable defaults with the workflow while giving new projects their own permanent canon.

The implementation plan is the next artifact after review of this design. No skill files, generated projects, repositories or user-level links have been created by preparing this document.

## Evidence and references

- DRRD: `AGENTS.md`, `documentation/NEXT.md`, `documentation/Design Notes.md`, the decision/judgement index guidance in `documentation/_project-meta/`, `tools/verify.ps1`, and the record/index tests and their fixtures under `test/`.
- DRRD's live GitHub labels and selected Obsidian settings, inspected on 2026-10-09. Repository owner: `Benevolent-Anarchy`; authenticated account: `cicely-f`.
- Existing BA-Skills installation guidance and inspected links for `ba-release`.
- [GitHub: disabling pull requests](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/disabling-pull-requests).
- [GitHub: repository configuration API](https://docs.github.com/en/rest/repos/repos).
- [Obsidian: manage vaults and transfer configuration](https://obsidian.md/help/Files%2Band%2Bfolders/Manage%2Bvaults).
- [Obsidian: CLI and plugin commands](https://obsidian.md/help/cli).
- [Obsidian: plugin release assets](https://docs.obsidian.md/Plugins/Releasing/Submit%20your%20plugin).
- [Vault Nickname: configuration and display names](https://community.obsidian.md/plugins/vault-nickname).
