# opencode in GitHub Actions

`.github/workflows/opencode.yml` runs [opencode](https://opencode.ai/docs/github/) in the cloud,
so the owner can hand work to an AI agent from a phone (GitHub app or browser), without a PC.

## Setup (once)

1. **Secret.** Repository > Settings > Secrets and variables > Actions > Secrets >
   New repository secret. Name: `OPENCODE_API_KEY`. Value: the API key from
   <https://opencode.ai/auth>. Never paste the key anywhere else (chat, issues, commits).
2. **Model (optional).** Same page, tab Variables > New repository variable. Name:
   `OPENCODE_MODEL`. Value: a `provider/model` id. Default when unset:
   `opencode-go/deepseek-v4.1-flash` (OpenCode Go plan). On the pay-as-you-go Zen plan use
   `opencode/deepseek-v4.1-flash`. `opencode models` in a terminal lists the exact ids.
3. **Let Actions open pull requests.** Settings > Actions > General > Workflow permissions:
   check "Allow GitHub Actions to create and approve pull requests" and save. Without it the run
   pushes its branch but fails with "GitHub Actions is not permitted to create or approve pull
   requests".
4. **Protect `main` (recommended).** Settings > Rules > Rulesets > New branch ruleset, target
   the default branch, enable "Restrict deletions", "Block force pushes" and
   "Require a pull request before merging" (0 approvals is fine), add the owner as a bypass
   actor. The workflow already keeps the agent off `main`; this is the hard guarantee.

## Use

- **On an issue:** write a comment that starts with `/opencode` (or `/oc`) followed by the
  task. opencode creates a branch, makes the change, opens a pull request and replies.
- **On a pull request:** a comment starting with `/oc` asks for changes to that PR; opencode
  commits to the PR's branch. A comment on a code line also gets the file and line context.
- **Manual run:** Actions > opencode > Run workflow, write the task in `prompt`. The result is a
  new pull request.

opencode reads `AGENTS.md` automatically. Review and merge its pull requests yourself.

## Safety

- Only `nocturn444` can trigger it (checked on the comment author and the actor). Comments by
  anyone else do not start a run, so nobody else can spend the key.
- The action pushes only to a new branch or to the PR's branch, never to `main`, and never
  merges. The agent's own shell may not run `git push`, `git remote`, `git checkout main`,
  `git reset --hard`, `gh` or GitHub API calls with curl (`OPENCODE_PERMISSION` in the workflow).
- Sessions are not shared publicly (`share: false`).
- The action is pinned to a commit; to update it, change the SHA in the workflow.

## Costs and limits

- Each run uses GitHub Actions minutes (the repository is private) and API credits.
  `timeout-minutes: 60` caps a run.
- Pull requests opened with the workflow's `GITHUB_TOKEN` do not start other workflows, so the
  console build does not run by itself on them: start it from Actions > Console build >
  Run workflow and pick the PR's branch.
