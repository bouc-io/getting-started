# Publish to GitHub OSS — Runbook

Pushes a **single parentless commit** (no history) of each in-scope repo to its `github-oss`
remote. GitLab history never leaves. Script: [`publish-to-github-oss.sh`](publish-to-github-oss.sh).

All commands run from this directory.

## 1. Preflight (no pushes; installs the local guard)

```bash
DRY_RUN=1 ./publish-to-github-oss.sh
```

Besides validating, this **installs the pre-push guard hook** in every wired repo — run it before
any manual push experiments. Expect **43× `READY … [empty remote]`** (already-published repos
show `READY*` instead). Anything else:
- `NO REMOTE` — add the `github-oss` remote in that repo.
- `BAD URL` — the remote doesn't point at github.com; fix with `git remote set-url github-oss …`.
- `READY*` — the remote already has branches (listed); review them — a re-snapshot of `main`
  requires `FORCE=1`, and any *other* branch means something was pushed by hand (clean it up).
- `READY?` — remote unreachable (offline, or GitHub repo not created).

## 2. Guard test (after preflight — must be BLOCKED)

The hook only exists after step 1. Use the repo's **actual** local branch (some repos use
`master`, not `main`):

```bash
cd ../../inference/ollama-chart
git push github-oss "$(git branch --show-current)"   # expect: BLOCKED by pre-push hook
cd -
```

If this push *succeeds*, STOP — the guard isn't in place; re-run step 1 and investigate.

## 3. Pilot (one low-risk repo)

```bash
REPOS_FILTER=ollama-chart ./publish-to-github-oss.sh
```

Then verify on https://github.com/bouc-io/ollama-chart:
- Exactly **one commit** ("Initial public snapshot of bouc.io (internal history withheld)") on
  branch `main` (the script always publishes to remote `main`, whatever the local branch is called).
- Committed files only — no `.env`, no `node_modules`.
- `git clone https://github.com/bouc-io/ollama-chart.git /tmp/pilot-check` works standalone.

## 4. Full run

```bash
./publish-to-github-oss.sh
```

Already-published repos show `READY*` and need `FORCE=1` to re-snapshot:
```bash
FORCE=1 ./publish-to-github-oss.sh                      # re-publish everything
FORCE=1 REPOS_FILTER=agent-api-server ./publish-to-github-oss.sh   # or one repo
```

## 5. Post-checks

- Spot-check one repo per area (backend, UI, chart, infra, docs): single root commit, no history.
- **fluxcdboucio:** the GitHub copy must have **no `.gitmodules` and no `clusters/components/*`
  entries** (the script strips both; your local repo keeps them untouched). Verify:
  ```bash
  git clone https://github.com/bouc-io/fluxcdboucio.git /tmp/flux-check
  ls /tmp/flux-check/.gitmodules /tmp/flux-check/clusters/components 2>&1   # both should not exist
  ```
- Note: `gitlab.com` URLs still appear in file *contents* (`.gitlab-ci.yml`, READMEs, the
  `fluxcd-*.yaml` Helm/Git source manifests pointing at the GitLab package registry). Only
  `.gitmodules` is stripped, per decision. Review with:
  ```bash
  grep -r gitlab.com /tmp/flux-check | less
  ```

## What the script does per repo

1. Validates the `github-oss` remote (exists, github.com URL, reachable/empty — all branches checked).
2. Installs a **pre-push hook** blocking any history-bearing push to `github-oss` (in DRY_RUN too),
   sets `remote.github-oss.tagOpt --no-tags`, and points `remote.pushDefault` at the GitLab remote.
3. Creates a **parentless commit** from `HEAD`'s tree (`git commit-tree`) — for `fluxcdboucio`,
   through a temporary index that drops `.gitmodules` + all submodule gitlinks first.
4. Pushes that one commit to `github-oss main`. Working tree, index, branches, and the
   `origin`/`gitlab` remotes are never touched.

Auth note: remotes are HTTPS — the first push needs a GitHub PAT via your git credential helper.
If the pilot prompts, complete it once; the rest reuse it.
