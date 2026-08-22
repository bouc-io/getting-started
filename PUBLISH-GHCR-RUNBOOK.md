# Publish artifacts to ghcr.io — Runbook

Promotes the 13 container images and 13 Helm charts from the private GitLab registry to
`ghcr.io/bouc-io`. Script: [`publish-to-ghcr.sh`](publish-to-ghcr.sh).

This is **pure promotion**. The exact bytes CI built are the bytes that land on GHCR. Nothing is
rebuilt, nothing is repackaged. GitLab stays the source of truth and CI home.

All commands run from this directory.

> **Ordering:** this runs *after* the registry parameterization work, which points chart values and
> Flux manifests at `ghcr.io/bouc-io` by default. That is why the consumer smoke test in step 5
> needs no `--set` overrides.

## 0. Credentials

Two credentials. Both differ from the ones [`publish-to-github-oss.sh`](publish-to-github-oss.sh)
uses, so read this even if you have published source before.

### How this differs from the source-publish script

| | `publish-to-github-oss.sh` | `publish-to-ghcr.sh` |
|---|---|---|
| GitLab credential | **none** (reads local git repos only) | group deploy token, read-only |
| GitHub credential | PAT with `repo`, used by the git credential helper | classic PAT with `write:packages` |

A `repo`-scoped PAT **cannot** push to GHCR. Package writes need `write:packages`, which the
git-push token does not carry.

You *can* add `write:packages` to your existing classic PAT and use one token for both. Not
recommended: keeping a separate publish-only token means your everyday git credential stays narrow.

### GitLab: a group deploy token, not a PAT

GitLab personal access tokens have no granular package-registry scope, so a PAT able to download
Helm charts needs the broad `api` scope. Deploy tokens do have granular scopes, and a **group**
token covers the container registry and every chart project at once.

1. Go to `https://gitlab.com/groups/bouc-io` → Settings → Repository → **Deploy tokens**
2. **Name:** anything identifying the consumer, e.g. `ghcr-promotion-read`
3. **Expiration date:** optional
4. **Username:** whatever ends up here is your `GITLAB_TOKEN_USER`. Type one, or leave the
   field blank and GitLab generates `gitlab+deploy-token-<id>` for you.
5. **Scopes:** tick **`read_registry`** only
6. **Create deploy token**, then copy the username and the token immediately. The token is
   shown once.

`read_registry` covers the container registry, which holds both the images and the OCI charts, and
that is everything this script reads. `read_package_registry` is deliberately not needed: it covers
the per-project HTTP Helm registry, which CI no longer publishes to and this script no longer
consults.

> This is **not** the same token as the write-scoped `CHARTS_DEPLOY_TOKEN` used by chart CI. Do not
> reuse that one here; this path only ever needs read access.

Fallback if group deploy tokens are unavailable on your plan: a PAT with `read_registry` + `api`.
Broader than needed, so treat it as second choice.

### GitHub: a classic PAT

1. github.com → Settings → Developer settings → Personal access tokens → **Tokens (classic)**
2. Generate new token, tick **`write:packages`** only (it implies `read:packages`)
3. Do **not** grant `delete:packages` or `repo`

Fine-grained tokens are not recommended for org-level GHCR packages.

### Export them

```bash
export GITLAB_TOKEN_USER='<deploy token username>'
export GITLAB_TOKEN_PWD='<deploy token>'
export GHCR_USER='<github username>'
export GHCR_TOKEN='<classic PAT>'
```

Keep these in your shell profile or a password manager. Never in the repo, and never inline in a
command that lands in shell history. The script only ever reads them from the environment, passes
them on stdin, and writes credentials to a throwaway authfile that is deleted on exit. Your
`~/.docker/config.json` is never touched.

> **Why `GITLAB_TOKEN_PWD` and not `GITLAB_TOKEN`.** `flux bootstrap` reads `GITLAB_TOKEN` and
> expects a **personal access token with `api` scope** for Git access. This script needs the
> **group deploy token** above, which is a different credential entirely. Sharing the name meant the
> two silently clobbered each other in one shell, producing a `skopeo login` failure that looked like
> a bad deploy token. The rename removes the collision, so both can be exported side by side.

### Check the GitLab pair on its own

The preflight in step 1 needs all four variables, so it cannot tell you whether the GitLab half is
right before you have made the GitHub PAT. To check just that half:

```bash
printf '%s' "$GITLAB_TOKEN_PWD" | skopeo login registry.gitlab.com -u "$GITLAB_TOKEN_USER" --password-stdin && skopeo inspect --raw docker://registry.gitlab.com/bouc-io/application/agent/agent-api-server:latest >/dev/null && echo "read_registry OK"
```

A login that succeeds but an inspect that fails means the token authenticated without
`read_registry`. Recreate it with both scopes rather than adding them later, since deploy token
scopes cannot be edited after creation.

### Prerequisites

```bash
brew install skopeo
```

`helm` 3.8+ is also required for OCI support. Both are checked by the preflight.

## 1. Preflight (no writes)

```bash
DRY_RUN=1 ./publish-to-ghcr.sh
```

This validates both logins, resolves every source image, and reads every chart version. Expect:

- 13 images `READY` with `[amd64 arm64]` and their derived git-tag lists
- 13 charts `READY` at their current `Chart.yaml` versions
- `failed: 0`

Anything else:

- `MISSING` — the source image or chart version is not in GitLab. For charts this usually means CI
  has not published that version yet, so git and the registry have drifted.
- `SINGLEARCH` — the image lost its arm64 half. Do not promote it; the Pi/Jetson cluster needs it.

## 2. Package visibility

Every new package is created **private**, images and charts alike. No org setting changes this, and
linking a repository afterwards does not either. Flip them by hand in step 4.

One-time cost: once a package is public, later pushes to it stay public.

## 3. Pilot (one image)

```bash
RELEASE=0.1.0 MODE=images FILTER=apidocs-api-server ./publish-to-ghcr.sh
```

```bash
VERIFY_ONLY=1 RELEASE=0.1.0 FILTER=apidocs ./publish-to-ghcr.sh
```

It reports `PRIVATE`, as expected. The pilot is still worth running to prove the credentials and the
multi-arch copy on one artifact instead of twenty-six.

> The audit cannot tell `PRIVATE` from "not published yet". Both fail an anonymous inspect.

Confirm the multi-arch manifest survived the copy, and that a stranger can pull it:

```bash
docker buildx imagetools inspect ghcr.io/bouc-io/application/apidocs/apidocs-api-server:0.1.0
```

```bash
docker logout ghcr.io && docker pull ghcr.io/bouc-io/application/apidocs/apidocs-api-server:0.1.0
```

The first must list both `linux/amd64` and `linux/arm64`.

## 4. Full run

```bash
RELEASE=0.1.0 ./publish-to-ghcr.sh
```

Re-publishing an existing tag is refused by default. Use `FORCE=1` to overwrite:

```bash
FORCE=1 RELEASE=0.1.0 ./publish-to-ghcr.sh
FORCE=1 RELEASE=0.1.0 FILTER=agent ./publish-to-ghcr.sh
```

Then, if step 3 showed `PRIVATE`, flip each package at
`https://github.com/orgs/bouc-io/packages` → package → Package settings → Danger Zone →
Change visibility → Public.

> **Making a package public is irreversible.** GitHub's documentation states it twice: once public,
> it cannot be made private again. Be sure before you flip.

Re-check until everything reports public:

```bash
VERIFY_ONLY=1 RELEASE=0.1.0 ./publish-to-ghcr.sh
```

### Before you flip anything public

1. **Pin any unpinned third-party image.** An unpinned `latest` against an archive namespace is the
   worst thing a stranger can hit on first install.

## 5. Consumer smoke test

What a stranger runs. No overrides needed:

```bash
helm install agent oci://ghcr.io/bouc-io/charts/agent-api-chart --version 0.2.6
```

```bash
helm show chart oci://ghcr.io/bouc-io/charts/web-chart --version 0.1.1
```

Both must work with no GitHub login.

## What the script does

| Phase | Behaviour |
|---|---|
| Images | `skopeo copy --all` per tag, preserving the amd64+arm64 manifest list. Without `--all`, skopeo copies only the host architecture and silently drops the other. |
| Tags | Every tag git references, plus `$RELEASE`, plus `latest`. |
| Charts | Downloads the CI-built `.tgz` from the OCI charts registry and `helm push`es it. Never packages locally. |
| Visibility | Reports only. It cannot change visibility; there is no API for it. |

### Why tags are derived, not listed

ImageUpdateAutomation rewrites the pinned tags on every image build, so any hardcoded list would be
stale within days. The script collects the union of `tag:` values from each chart's
`base`/`lcl`/`snbx` values files and from all three Flux environment overlays.

Mirroring these matters: git carries tags like `1.0.2705444123` in the `$imagepolicy`-marked lines,
and without them a fresh cluster would render HelmReleases pointing at tags absent from ghcr and
stay degraded until its own automation caught up.

Tags that exist in git but not in GitLab (the `1.0.0` placeholders in the `base` manifests) are
reported as `ABSENT` and skipped. That is expected, not an error.

### Why `$RELEASE` is not what Flux picks

ImagePolicy's default range is `${IMAGE_TAG_RANGE:=x.x.x}`, which selects the highest semver.
`1.0.2705444123` always beats `0.1.0`, so Flux resolves the pipeline tag and never `$RELEASE`.

`$RELEASE` is a human-facing pin: one version that names a known-good stack in documentation. It is
not a Flux-level pin, and should not be mistaken for one.

### Why charts are downloaded rather than packaged

The `.tgz` in GitLab is the artifact CI built and FluxCD consumes. Re-pushing it is a true
promotion; repackaging locally produces a *different* artifact that merely resembles it. Local
packaging also silently depends on your working tree being in sync with what CI published, and any
chart with a `dependencies:` block re-resolves its constraints at package time.

`ALLOW_LOCAL_PACKAGE=1` overrides this per item, but a `MISSING` chart normally means git and the
registry have drifted, which is worth fixing rather than papering over.

### Why `ollama-chart` is not published

It contains no chart, only values files that FluxCD absorbs as a component and layers over the
upstream `ollama` chart from `helm.otwld.com`. Publishing them to GHCR would produce an artifact
nothing can install. They already ship publicly in the `bouc-io/ollama-chart` git repo.

## Known gaps

- **Third-party images still come from Docker Hub.** The charts pull `bitnamilegacy/postgresql`,
  `pgvector/pgvector`, `bitnami/redis`, and `ollama/ollama`. `bitnamilegacy` is Bitnami's archive
  namespace: it receives no security updates and has no published removal date, so treat it as a
  security-debt clock rather than a deadline.

  The consumer answer is cluster-level rewriting rather than chart edits. Either a Kyverno
  `replace-image-registry` policy, or containerd registry mirrors in the node config. Both relocate
  third-party pulls to a registry you control without touching any values file.

- **Packages are not linked to a repository.** Linking only adds the repo README, the Packages
  sidebar entry, and the contributors/issues links. It does not affect visibility and nothing
  functional depends on it. Done manually via **Connect Repository** on the package page. The
  Dockerfile `LABEL org.opencontainers.image.source` route is deliberately not used: it would put a
  GitHub URL inside the GitLab-side build.

- **The six UI images keep GitLab's `-mirror-ui` name** (`application/agent/agent-mirror-ui`) even
  though the GitHub repo and `package.json` say `monochrome-agent-ui`. The path must be identical on
  both registries for the single `IMAGE_REGISTRY` variable to work.

- **Flux-based consumption needs the OSS template repo.** The mirrored GitOps repo has its
  submodules stripped, so `clusters/components/` is empty there and it cannot be used as-is.

- **Keep model weights out of images.** Ollama pulling models at run time is correct.

## Optional follow-ups

- List the charts on [Artifact Hub](https://artifacthub.io/) for discoverability.
- Add a GitHub Pages chart repo via `helm/chart-releaser-action` for people who prefer
  `helm repo add` over `oci://`.
