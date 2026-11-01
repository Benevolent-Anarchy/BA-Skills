# Linux integration commands

Requirements: Bash, Python 3.10 or later, Git 2.38 or later (`merge-tree --write-tree`), and authenticated `gh`. Every command emits one JSON result; exit 1 carries `error` and any partial progress. Read the result before retrying. Arguments are passed as literal arrays, including paths with spaces, Unicode or square brackets; filenames use NUL-delimited Git output. No native command invokes PowerShell.

Run from the skill directory. All six commands have `--help`. Linux option names correspond to the PowerShell names below. Values are separate arguments; quote paths and multiline commit messages.

| Entry point | Required options | Additional options and defaults |
| --- | --- | --- |
| `scripts/survey.sh` | `--repository` | `--base` (origin's symbolic HEAD, otherwise `origin/main`), `--pull-requests-json` (offline array of the existing survey records), `--github-cli` (`gh` on PATH) |
| `scripts/update.sh` | `--worktree --head --base --rehearsed` | `--message` (`Merge the integration base into this pull request`) |
| `scripts/land.sh` | `--worktree --pull-request --branch --approved-head --updated --base-branch --expected-base --rehearsed --message` | `--remote origin`, `--timeout-seconds 120`, `--poll-seconds 5`, `--github-cli` |
| `scripts/retarget.sh` | `--repository --branch --base-branch` | `--list` for a read-only plan; otherwise `--approved '1,2'` or `--approved none`; `--remote origin`, `--github-cli` |
| `scripts/delete-branch.sh` | `--repository --branch --merged-tip --base-branch` | `--remote origin`, `--github-cli` |
| `scripts/check-issues.sh` | `--repository --pull-request` | `--recent-seconds 120`, `--remote origin`, `--github-cli` |

The PowerShell spelling is PascalCase with one hyphen (`-ApprovedHead`); Linux uses the corresponding double-hyphen kebab case (`--approved-head`). `-PullRequestsJson`, `-GitHubCli`, `-RecentSeconds`, `-TimeoutSeconds`, `-PollSeconds` map to `--pull-requests-json`, `--github-cli`, `--recent-seconds`, `--timeout-seconds`, `--poll-seconds`. Switches `-List` and `-CheckOnly` become `--list` and `--check-only`.

`integrate.py` implements the shared `Integrate.psm1` operations: checked subprocesses, commit resolution/existence/ancestry, exact remote branch reads, tracked dirty/merge detection, separate gh output/error streams, credential redaction, GitHub URL parsing and destination validation, paginated dependent PR reads, and CLI discovery. The Bash wrappers select the operation; they contain no business logic.

Both implementations recognize GitHub's documented `ssh://git@ssh.github.com:443/owner/repo.git` endpoint as the same repository as its HTTPS and standard SSH URLs. Other hosts and unrecognized ports remain refused. See [GitHub's SSH-over-HTTPS instructions](https://docs.github.com/en/authentication/troubleshooting-ssh/using-ssh-over-the-https-port).

The skill's rehearsal and gate sequence is unchanged: merge each surveyed head into the scratch branch, resolve and commit, replay with `update.sh`, return to the scratch branch, then run the project's gate at every step. Gate failure is a plan finding. The scripts never mark a PR ready or create a PR. Any follow-up PR created by an agent must use `gh pr create --draft` and remain a draft.

Run `bash tests/integrate-linux/run-tests.sh` from the BA-Skills root. It exercises actual temporary Git repositories and bare remotes. Test-only Git transport routes fetches, pushes and remote-ref reads to those local remotes; URL and configuration checks still use real Git without a rewrite. GitHub's service boundary is a fixture too. It never writes real remote refs or a real home directory. `bash tools/verify.sh` runs the bootstrap, integration and release Linux suites and fails if any suite fails.

The Linux gate neither parses nor exercises `.ps1` or `.psm1` sources. Windows support requires the separate Windows gate, `pwsh -NoProfile -File tools/verify.ps1`; a Linux pass alone does not verify the PowerShell implementation.

## BA-Skills Windows gate for a rehearsal

BA-Skills' Windows workflow checks every PR, without path filters. Its checked tree must match the actual rehearsal before that run can stand in for a Windows gate at an integration step. Record the checked commit and run URL in the plan. For other projects, use their own recorded Windows gate.

The workflow configures a fixture Git identity and long-path support, installs a digest-pinned official Godot 4.7 release, and imports a digest-pinned Canonical Ubuntu image into WSL1. The WSL path tests run against a usable default distribution rather than only the preinstalled `wsl.exe` launcher.

Push the candidate only to a dedicated verification branch, keeping PR and base updates subject to the integration plan's approval:

```bash
git push origin <rehearsed-commit>:refs/heads/codex/windows-verify/<run>
gh run list --repo <owner>/<repo> --branch codex/windows-verify/<run> --workflow verify-windows.yml
gh run watch <run-id> --repo <owner>/<repo> --exit-status
```

Once the workflow exists on the default branch, it can also be dispatched for an already-pushed candidate:

```bash
gh workflow run verify-windows.yml --repo <owner>/<repo> --ref main -f revision=<pushed-candidate-sha>
```

[GitHub requires a manually dispatched workflow to exist on the default branch](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch). Before then, the push trigger works only if the pushed commit contains the workflow file. If an earlier candidate lacks it, create a temporary descendant in a separate verification worktree: add the reviewed workflow, set its checkout `ref` to the literal candidate SHA, and push that descendant to the dedicated verification branch. GitHub reads the workflow from the descendant but checks out and tests the exact candidate. Record both SHAs; keep this CI-only commit off PR and base branches.

Each run prints `git rev-parse HEAD` before running the gate. Require that printed SHA to identify the intended candidate. A queued, running or failed check does not count as a gate pass.
