#!/usr/bin/env bash
# publish-to-github-oss.sh
# Push a SINGLE parentless commit (no history) of each in-scope repo to its
# `github-oss` remote. GitLab history stays private/internal.
#
#   DRY_RUN=1 ./publish-to-github-oss.sh     # PREFLIGHT: validate remotes/URLs/reachability, no pushes
#                                             (still installs the local pre-push guard in each repo)
#   ./publish-to-github-oss.sh               # publish every READY repo
#   FORCE=1 ./publish-to-github-oss.sh        # force-push a re-snapshot over an existing main
#   REPOS_FILTER=agent-api-server ./publish-to-github-oss.sh   # subset by path substring
#   FORCE=1 RELEASE=0.1.0 ./publish-to-github-oss.sh           # re-snapshot AND tag it v0.1.0
#
# RELEASE (optional, MAJOR.MINOR.PATCH) tags each snapshot it publishes, mirroring
# publish-to-ghcr.sh. The tag is annotated, built with `git mktag` and pushed by object
# SHA, so NO local tag ref is ever created — nothing can later leak to the GitLab remote.
# A tag is pushed only for a repo whose snapshot push succeeded, so a plain
# `RELEASE=... ./publish-to-github-oss.sh` with every repo already published tags nothing;
# pair it with FORCE=1. TAG_PREFIX defaults to "v"; set TAG_PREFIX= for bare "0.1.0".
set -euo pipefail

ROOT="/Users/martincote/bouc_io-wksp/02-bouc_io-workspace"
REMOTE="github-oss"
BRANCH="main"
MSG="Public snapshot of bouc.io (internal history withheld)"

# 43 repos — boucio-design intentionally excluded (stays private).
REPOS=(
  fluxcd/fluxcdboucio
  infrastructure/cert-manager infrastructure/istio infrastructure/keycloak
  infrastructure/oauth2-proxy infrastructure/external-dns infrastructure/external-secrets
  infrastructure/metrics-server infrastructure/prometheus infrastructure/grafana
  infrastructure/opentelemetry infrastructure/kiali infrastructure/datadog
  inference/ollama-chart
  application/agent/agent-api-server application/agent/monochrome-agent-ui
  application/agent/agent-api-chart application/agent/agent-chart
  application/chatbot/chatbot-api-server application/chatbot/monochrome-chatbot-ui
  application/chatbot/chatbot-api-chart application/chatbot/chatbot-chart
  application/memory/memory-api-server application/memory/memory-distiller
  application/memory/monochrome-memory-ui application/memory/memory-api-chart
  application/memory/memory-distiller-chart application/memory/memory-chart
  application/admin/admin-api-server application/admin/monochrome-admin-ui
  application/admin/admin-api-chart application/admin/admin-chart
  application/portal/portal-api-server application/portal/monochrome-portal-ui
  application/portal/portal-api-chart application/portal/portal-chart
  application/web/web-chart application/web/monochrome-web-ui
  application/apidocs/apidocs-api-server application/apidocs/apidocs-api-chart
  application/cli/agent-cli
  documentation/getting-started documentation/postman-setup
)

DRY_RUN="${DRY_RUN:-0}"; FORCE="${FORCE:-0}"; REPOS_FILTER="${REPOS_FILTER:-}"
RELEASE="${RELEASE:-}"; TAG_PREFIX="${TAG_PREFIX-v}"
published=0; skipped=0; failed=0; tagged=0; tagfailed=0

# --- Release tag setup (optional) -------------------------------------------
TAG_NAME=""
if [ -n "$RELEASE" ]; then
  if ! [[ "$RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "RELEASE must be MAJOR.MINOR.PATCH (got '$RELEASE')" >&2; exit 1
  fi
  TAG_NAME="${TAG_PREFIX}${RELEASE}"
  TAGGER_NAME="$(git config user.name || true)"
  TAGGER_EMAIL="$(git config user.email || true)"
  if [ -z "$TAGGER_NAME" ] || [ -z "$TAGGER_EMAIL" ]; then
    echo "RELEASE needs a git identity: set user.name and user.email" >&2; exit 1
  fi
  TAG_STAMP="$(date +%s) $(date +%z)"
  echo "==== release tag: $TAG_NAME  (tagger: $TAGGER_NAME <$TAGGER_EMAIL>) ===="
fi

# Tag a published snapshot. Builds an annotated tag OBJECT and pushes it by SHA;
# `git tag` is deliberately avoided so no ref is left in the local repo, which also
# has a GitLab remote. The pre-push guard passes tags whose commit is parentless.
push_release_tag() {
  local path="$1" sha="$2" tagobj tagflag=()
  tagobj="$(printf 'object %s\ntype commit\ntag %s\ntagger %s <%s> %s\n\n%s\n' \
    "$sha" "$TAG_NAME" "$TAGGER_NAME" "$TAGGER_EMAIL" "$TAG_STAMP" \
    "bouc.io public snapshot $RELEASE" | git -C "$path" mktag)" || return 1
  [ "$FORCE" = "1" ] && tagflag=(--force)
  git -C "$path" push "${tagflag[@]}" "$REMOTE" "$tagobj:refs/tags/$TAG_NAME"
}

# Install the pre-push guard + hardening config into a repo (idempotent).
install_guard() {
  local path="$1" hook="$1/.git/hooks/pre-push"
  cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
[ "$1" = "github-oss" ] || exit 0
blocked=0
while read -r local_ref local_sha remote_ref remote_sha; do
  [ "$local_sha" = "0000000000000000000000000000000000000000" ] && continue
  if git rev-parse -q --verify "${local_sha}^" >/dev/null 2>&1; then
    echo "BLOCKED: '$local_ref' -> github-oss carries history (commit has parents)." >&2
    echo "         Only publish-to-github-oss.sh's parentless snapshot is allowed." >&2
    blocked=1
  fi
done
exit $blocked
HOOK
  chmod +x "$hook"
  # NOTE: tagOpt is a FETCH setting (no automatic tag following). It does not and
  # never did block pushes; the explicit release-tag refspec below is unaffected.
  git -C "$path" config remote.github-oss.tagOpt --no-tags
  # bare `git push` should default to the GitLab remote, never github-oss
  local gl
  gl="$(git -C "$path" remote -v | awk '/gitlab\.com/ {print $1; exit}')"
  [ -n "$gl" ] && git -C "$path" config remote.pushDefault "$gl"
}

# Build the snapshot tree for a repo. For fluxcdboucio, strip .gitmodules and all
# submodule gitlink entries via a TEMPORARY index — never touches the real index
# or working tree.
snapshot_tree() {
  local path="$1" strip_submodules="$2" tmpidx tree p
  if [ "$strip_submodules" != "1" ]; then
    git -C "$path" rev-parse "HEAD^{tree}"
    return
  fi
  tmpidx="$(mktemp)"
  GIT_INDEX_FILE="$tmpidx" git -C "$path" read-tree "HEAD^{tree}"
  GIT_INDEX_FILE="$tmpidx" git -C "$path" update-index --force-remove .gitmodules 2>/dev/null || true
  # remove every gitlink (mode 160000) entry — dangling without .gitmodules
  while IFS= read -r p; do
    GIT_INDEX_FILE="$tmpidx" git -C "$path" update-index --force-remove "$p"
  done < <(GIT_INDEX_FILE="$tmpidx" git -C "$path" ls-files -s | awk '$1=="160000" {print $4}')
  tree="$(GIT_INDEX_FILE="$tmpidx" git -C "$path" write-tree)"
  rm -f "$tmpidx"
  echo "$tree"
}

for rel in "${REPOS[@]}"; do
  [ -n "$REPOS_FILTER" ] && [[ "$rel" != *"$REPOS_FILTER"* ]] && continue
  path="$ROOT/$rel"
  if [ ! -d "$path/.git" ]; then echo "SKIP      no git repo: $rel"; skipped=$((skipped+1)); continue; fi

  # --- Preflight validation (always runs; the only thing done in DRY_RUN) ---
  url="$(git -C "$path" remote get-url "$REMOTE" 2>/dev/null || true)"
  if [ -z "$url" ]; then
    echo "NO REMOTE add '$REMOTE' by hand: $rel"; skipped=$((skipped+1)); continue
  fi
  if [[ "$url" != *github.com* ]]; then
    echo "BAD URL   '$REMOTE' -> $url (not github.com): $rel"; skipped=$((skipped+1)); continue
  fi
  # Install the local pre-push guard NOW (also in DRY_RUN) so manual pushes to
  # github-oss are blocked before any real publishing/testing happens.
  install_guard "$path"
  # reachability/empty check: list ALL remote branches, not just main — any
  # pre-existing branch means something was already pushed (needs review/FORCE=1)
  remote_has_main=0
  if heads="$(git -C "$path" ls-remote --heads "$REMOTE" 2>/dev/null)"; then
    if [ -n "$heads" ]; then
      names="$(printf '%s\n' "$heads" | awk '{sub("refs/heads/","",$2); print $2}' | paste -sd, -)"
      echo "READY*    $rel  ($url)  [remote NOT empty: $names -> review; re-snapshot of main needs FORCE=1]"
      remote_has_main=1
    else
      echo "READY     $rel  ($url)  [empty remote]"
    fi
  else
    echo "READY?    $rel  ($url)  [could not reach remote; offline or repo not created?]"
  fi
  if [ -n "$TAG_NAME" ] && git -C "$path" ls-remote --tags "$REMOTE" "refs/tags/$TAG_NAME" 2>/dev/null | grep -q .; then
    echo "          tag $TAG_NAME already on $REMOTE — moving it needs FORCE=1"
  fi
  [ "$DRY_RUN" = "1" ] && continue

  # Already published and no FORCE: skip instead of attempting a push that
  # would be rejected (non-fast-forward) — a re-snapshot requires FORCE=1.
  if [ "$remote_has_main" = "1" ] && [ "$FORCE" != "1" ]; then
    echo "SKIP      already published (FORCE=1 to re-snapshot): $rel"; skipped=$((skipped+1)); continue
  fi

  # --- Publish (parentless commit -> single commit, no history, tracked files only) ---
  strip=0; [ "$rel" = "fluxcd/fluxcdboucio" ] && strip=1   # drop .gitmodules + gitlinks
  tree="$(snapshot_tree "$path" "$strip")"
  sha="$(git -C "$path" commit-tree "$tree" -m "$MSG")"
  echo ">>        $rel  ->  $REMOTE/$BRANCH  (snapshot $sha)"
  pushflag=(); [ "$FORCE" = "1" ] && pushflag=(--force)
  # A failed push must not abort the whole run (set -e): report it and move on.
  if git -C "$path" push "${pushflag[@]}" "$REMOTE" "$sha:refs/heads/$BRANCH"; then
    published=$((published+1))
    # Tag only what actually landed, and never let a tag failure abort the run.
    if [ -n "$TAG_NAME" ]; then
      if push_release_tag "$path" "$sha"; then
        echo "TAG       $rel  ->  $REMOTE/$TAG_NAME"
        tagged=$((tagged+1))
      else
        echo "TAG FAIL  could not tag $rel as $TAG_NAME — continuing with the rest"
        tagfailed=$((tagfailed+1))
      fi
    fi
  else
    echo "FAILED    push rejected/errored for $rel — continuing with the rest"
    failed=$((failed+1))
  fi
done
echo "---- published: $published  skipped/not-ready: $skipped  failed: ${failed:-0} ----"
if [ -n "$TAG_NAME" ]; then
  echo "---- tagged $TAG_NAME: $tagged  tag failures: $tagfailed ----"
fi
