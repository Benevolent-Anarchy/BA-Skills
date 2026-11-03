# Commands and verification

Requirements: Bash, Python 3.10 or later, Git 2.38 or later (`merge-tree --write-tree`), and authenticated `gh`. Older `gh` releases, such as Ubuntu's 2.46, work: the scripts read a pull request's closing issues through GraphQL rather than a `pr view` field those releases lack, and ask `gh` for no other field 2.46 lacks. Every command emits one JSON result; exit 1 carries `error` and any partial progress. Read the result before retrying. Arguments are passed as literal arrays, including paths with spaces, Unicode or square brackets; filenames use NUL-delimited Git output.

Run from the skill directory. All six commands have `--help`. Values are separate arguments; quote paths and multiline commit messages.

| Entry point | Required options | Additional options and defaults |
| --- | --- | --- |
| `scripts/survey.sh` | `--repository` | `--base` (origin's symbolic HEAD, otherwise `origin/main`), `--pull-requests-json` (offline array of the existing survey records), `--github-cli` (`gh` on PATH) |
| `scripts/update.sh` | `--worktree --head --base --rehearsed` | `--message` (`Merge the integration base into this pull request`) |
| `scripts/land.sh` | `--worktree --pull-request --branch --approved-head --updated --base-branch --expected-base --rehearsed --message` | `--remote origin`, `--timeout-seconds 120`, `--poll-seconds 5`, `--github-cli` |
| `scripts/retarget.sh` | `--repository --branch --base-branch` | `--list` for a read-only plan; otherwise `--approved '1,2'` or `--approved none`; `--remote origin`, `--github-cli` |
| `scripts/delete-branch.sh` | `--repository --branch --merged-tip --base-branch` | `--remote origin`, `--github-cli` |
| `scripts/check-issues.sh` | `--repository --pull-request` | `--recent-seconds 120`, `--remote origin`, `--github-cli` |

`integrate.py` implements the operations: checked subprocesses, commit resolution/existence/ancestry, merges in the object store (`merge-tree --write-tree` and `commit-tree`, so no checkout's state can stop them), exact remote branch reads, separate gh output/error streams, credential redaction, GitHub URL parsing and destination validation, paginated dependent PR reads, and CLI discovery. The Bash wrappers select the operation; they contain no business logic.

The scripts recognize GitHub's documented `ssh://git@ssh.github.com:443/owner/repo.git` endpoint as the same repository as its HTTPS and standard SSH URLs. Other hosts and unrecognized ports remain refused. See [GitHub's SSH-over-HTTPS instructions](https://docs.github.com/en/authentication/troubleshooting-ssh/using-ssh-over-the-https-port).

The rehearsal and gate sequence is the one `SKILL.md` describes: merge each surveyed head into the scratch branch, resolve and commit, replay with `update.sh`, which leaves the rehearsal's checkout as it was, then run the project's gate at every step. Gate failure is a plan finding. The scripts never mark a PR ready or create a PR. Any follow-up PR created by an agent must use `gh pr create --draft` and remain a draft.

Run `bash tests/integrate-linux/run-tests.sh` from the BA-Skills root. It exercises actual temporary Git repositories and bare remotes. Test-only Git transport routes fetches, pushes and remote-ref reads to those local remotes; URL and configuration checks still use real Git without a rewrite. GitHub's service boundary is a fixture too, and like Ubuntu's `gh` 2.46 it refuses any `--json` field that release lacks, such as `closingIssuesReferences` in `pr view` and `stateReason` in `issue view`. It never writes real remote refs or a real home directory. `bash tools/verify.sh` runs the bootstrap, integration, release and cross-review suites, and fails if any suite fails.
