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

The skill's rehearsal and gate sequence is unchanged: merge each surveyed head into the scratch branch, resolve and commit, replay with `update.sh`, return to the scratch branch, then run the project's gate at every step. Gate failure is a plan finding. The scripts never mark a PR ready or create a PR. Any follow-up PR created by an agent must use `gh pr create --draft` and remain a draft.

Run `bash tests/integrate-linux/run-tests.sh` from the BA-Skills root. It exercises actual temporary Git repositories and bare remotes, and substitutes only GitHub's service boundary. It never writes real remote refs or a real home directory. `bash tools/verify.sh` runs the bootstrap, integration and release Linux suites and fails if any suite fails.
