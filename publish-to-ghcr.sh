#!/usr/bin/env bash
# publish-to-ghcr.sh
# Promote bouc.io container images and Helm charts from the private GitLab
# registry to ghcr.io. Pure promotion: the exact bytes CI built are the bytes
# that land on GHCR. Nothing is rebuilt or repackaged.
#
#   DRY_RUN=1 ./publish-to-ghcr.sh                     # PREFLIGHT: validate, resolve, no writes
#   RELEASE=0.1.0 ./publish-to-ghcr.sh                 # publish images + charts
#   RELEASE=0.1.0 MODE=images ./publish-to-ghcr.sh     # images only (or MODE=charts)
#   RELEASE=0.1.0 FILTER=apidocs ./publish-to-ghcr.sh  # subset by path substring
#   RELEASE=0.1.0 FORCE=1 ./publish-to-ghcr.sh         # overwrite existing destination tags
#   VERIFY_ONLY=1 ./publish-to-ghcr.sh                 # anonymous PUBLIC/PRIVATE audit
#
# Credentials (all four required except in VERIFY_ONLY mode):
#   GITLAB_TOKEN_USER / GITLAB_TOKEN_PWD   bouc-io GROUP DEPLOY TOKEN
#                                      scope: read_registry
#   GHCR_USER / GHCR_TOKEN             GitHub CLASSIC PAT, scope: write:packages
#
# See PUBLISH-GHCR-RUNBOOK.md. This script never changes package visibility;
# that is a manual, irreversible step in the GitHub UI.
set -euo pipefail

# --- 1. Configuration -------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"   # -> 02-bouc_io-workspace

SRC_REGISTRY="registry.gitlab.com"
SRC_ORG="bouc-io"
DST_REGISTRY="ghcr.io"
DST_ORG="bouc-io"                             # constant: never derived from input
CHART_NS="charts"                             # oci://ghcr.io/bouc-io/charts
SRC_CHART_OCI="oci://${SRC_REGISTRY}/${SRC_ORG}/${CHART_NS}"
DST_CHART_OCI="oci://${DST_REGISTRY}/${DST_ORG}/${CHART_NS}"

# The allowlist. One row per publishable unit:
#   <chart dir under application/>|<image path>
# Image paths are IDENTICAL on both registries (plan 1's single IMAGE_REGISTRY
# variable requires it), so no renaming happens anywhere in this script.
UNITS=(
  "agent/agent-api-chart|application/agent/agent-api-server"
  "agent/agent-chart|application/agent/agent-mirror-ui"
  "memory/memory-api-chart|application/memory/memory-api-server"
  "memory/memory-chart|application/memory/memory-mirror-ui"
  "memory/memory-distiller-chart|application/memory/memory-distiller"
  "admin/admin-api-chart|application/admin/admin-api-server"
  "admin/admin-chart|application/admin/admin-mirror-ui"
  "portal/portal-api-chart|application/portal/portal-api-server"
  "portal/portal-chart|application/portal/portal-mirror-ui"
  "chatbot/chatbot-api-chart|application/chatbot/chatbot-api-server"
  "chatbot/chatbot-chart|application/chatbot/chatbot-mirror-ui"
  "apidocs/apidocs-api-chart|application/apidocs/apidocs-api-server"
  "web/web-chart|application/web/web-mirror-ui"
)

# Retired artifacts that must never be promoted, plus the buildcache tag that
# four pipelines push. Asserted against the table below, not merely documented.
DENY_SUBSTRINGS=(
  "application/examples/"
  "api-example"
  "api-java-example"
  "static-web-example"
  "txn-web-example"
  "buildcache"
)

# --- 2. Options -------------------------------------------------------------

DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"
FILTER="${FILTER:-}"
MODE="${MODE:-all}"
RELEASE="${RELEASE:-}"
VERIFY_ONLY="${VERIFY_ONLY:-0}"
ALLOW_LOCAL_PACKAGE="${ALLOW_LOCAL_PACKAGE:-0}"

published=0; skipped=0; failed=0
declare -a SUMMARY=()

log()      { printf '%-9s %s\n' "$1" "$2"; }
log_info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
log_ok()   { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()      { echo -e "\033[1;31m[FATAL]\033[0m $1" >&2; exit 1; }

# --- 3. Preflight -----------------------------------------------------------

case "$MODE" in images|charts|all) ;; *) die "MODE must be images, charts, or all (got '$MODE')" ;; esac

if [ "$VERIFY_ONLY" != "1" ] && [ "$DRY_RUN" != "1" ]; then
  [ -n "$RELEASE" ] || die "RELEASE is required (e.g. RELEASE=0.1.0). Use DRY_RUN=1 to preflight."
fi
if [ -n "$RELEASE" ] && ! [[ "$RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "RELEASE must be MAJOR.MINOR.PATCH (got '$RELEASE')"
fi

command -v skopeo >/dev/null 2>&1 || die "skopeo not found. Install it: brew install skopeo"
command -v helm   >/dev/null 2>&1 || die "helm not found. Install it: brew install helm"
helm push --help  >/dev/null 2>&1 || die "this helm has no 'push' subcommand; OCI support required (helm 3.8+)"
helm registry login --help >/dev/null 2>&1 || die "this helm has no 'registry login' subcommand"

# Guardrail: the table itself must be clean. Fail closed, before any network I/O.
for unit in "${UNITS[@]}"; do
  for bad in "${DENY_SUBSTRINGS[@]}"; do
    case "$unit" in *"$bad"*) die "DENY-LIST VIOLATION: '$bad' appears in table row '$unit'" ;; esac
  done
done
[ "${#UNITS[@]}" -eq 13 ] || log_warn "expected 13 units, table has ${#UNITS[@]}"

need_creds=1
[ "$VERIFY_ONLY" = "1" ] && need_creds=0
if [ "$need_creds" = "1" ]; then
  for v in GITLAB_TOKEN_USER GITLAB_TOKEN_PWD GHCR_USER GHCR_TOKEN; do
    [ -n "${!v:-}" ] || die "environment variable $v is not set (see PUBLISH-GHCR-RUNBOOK.md step 0)"
  done
fi

# --- 4. Credential isolation ------------------------------------------------
# Credentials go to a throwaway authfile, never ~/.docker/config.json, and are
# only ever passed on stdin so they cannot be read out of `ps`.

WORKDIR="$(mktemp -d)"
export REGISTRY_AUTH_FILE="${WORKDIR}/auth.json"

cleanup() {
  helm registry logout "$DST_REGISTRY" >/dev/null 2>&1 || true
  helm registry logout "$SRC_REGISTRY" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [ "$need_creds" = "1" ]; then
  printf '%s' "$GITLAB_TOKEN_PWD" | skopeo login "$SRC_REGISTRY" -u "$GITLAB_TOKEN_USER" --password-stdin >/dev/null \
    || die "skopeo login to $SRC_REGISTRY failed (check GITLAB_TOKEN_USER/GITLAB_TOKEN_PWD and read_registry scope)"
  printf '%s' "$GHCR_TOKEN"   | skopeo login "$DST_REGISTRY" -u "$GHCR_USER" --password-stdin >/dev/null \
    || die "skopeo login to $DST_REGISTRY failed (check GHCR_USER/GHCR_TOKEN and write:packages scope)"
  log_ok "authenticated to $SRC_REGISTRY (read) and $DST_REGISTRY (write)"

  if [ "$MODE" != "images" ]; then
    printf '%s' "$GITLAB_TOKEN_PWD" | helm registry login "$SRC_REGISTRY" -u "$GITLAB_TOKEN_USER" --password-stdin >/dev/null 2>&1 \
      || die "helm registry login to $SRC_REGISTRY failed; charts come only from the OCI registry now, so none could be pulled (check GITLAB_TOKEN_USER/GITLAB_TOKEN_PWD and read_registry scope)"
    printf '%s' "$GHCR_TOKEN"   | helm registry login "$DST_REGISTRY" -u "$GHCR_USER" --password-stdin >/dev/null \
      || die "helm registry login to $DST_REGISTRY failed"
  fi
fi

# --- 5. Helpers -------------------------------------------------------------

chart_name_of() { grep -E '^name:'    "$1/Chart.yaml" | head -1 | awk '{print $2}'; }
chart_ver_of()  { grep -E '^version:' "$1/Chart.yaml" | head -1 | awk '{print $2}'; }

# Every tag this image is referenced by anywhere in git. Derived, never frozen:
# ImageUpdateAutomation rewrites these continuously, so a hardcoded list would
# be stale within days. Sources are the three chart values files and the three
# Flux environment overlays.
derive_tags() {
  local chart_dir="$1" chart_name="$2" f t
  {
    for f in "$chart_dir"/base.values.yaml "$chart_dir"/lcl.values.yaml "$chart_dir"/snbx.values.yaml; do
      [ -f "$f" ] || continue
      awk '
        /^image:/{inb=1; next}
        inb && /^[^ \t]/{inb=0}
        inb && /^[ \t]+tag:/{gsub(/"/,"",$2); print $2}
      ' "$f"
    done
    for env in base local sandbox; do
      f="$ROOT/fluxcd/fluxcdboucio/clusters/$env/apps/examples/fluxcd-${chart_name}.yaml"
      [ -f "$f" ] || continue
      grep -E '^[ \t]+tag:' "$f" | sed 's/.*tag: *"\{0,1\}\([^"#]*\)"\{0,1\}.*/\1/' | tr -d ' '
    done
  } | awk 'NF && $0 != "latest"' | sort -V -u
}

image_exists() { skopeo inspect --raw "docker://$1" >/dev/null 2>&1; }

# Charts are OCI artifacts, so existence is an ordinary manifest lookup. Do NOT
# use `helm show chart` for this: against an absent or private OCI chart it
# retries indefinitely (measured >2min), while skopeo answers in ~0.3s.
chart_ref()          { echo "${DST_REGISTRY}/${DST_ORG}/${CHART_NS}/$1:$2"; }
chart_exists()       { skopeo inspect --raw "docker://$(chart_ref "$1" "$2")" >/dev/null 2>&1; }
chart_is_public()    { skopeo inspect --no-creds --raw "docker://$(chart_ref "$1" "$2")" >/dev/null 2>&1; }

# Report the platforms in a manifest list. Empty output means single-arch.
image_arches() {
  skopeo inspect --raw "docker://$1" 2>/dev/null \
    | tr ',' '\n' | grep -oE '"architecture"[ ]*:[ ]*"[a-z0-9]+"' \
    | sed 's/.*"\([a-z0-9]*\)"$/\1/' \
    | grep -v '^unknown$' | sort -u | paste -sd' ' -
    # "unknown" is the buildkit attestation manifest, not a real platform.
}

matches_filter() { [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# --- 6. Images --------------------------------------------------------------

do_images() {
  echo
  log_info "=== IMAGES -> ${DST_REGISTRY}/${DST_ORG} ==="
  local unit chart_rel img chart_dir chart_name src dst tags t arches copied primary

  for unit in "${UNITS[@]}"; do
    IFS='|' read -r chart_rel img <<< "$unit"
    matches_filter "$img" || continue

    chart_dir="$ROOT/application/$chart_rel"
    chart_name="$(chart_name_of "$chart_dir" 2>/dev/null || basename "$chart_rel")"
    # Identical path on both registries: bouc-io/application/<domain>/<service>
    src="${SRC_REGISTRY}/${SRC_ORG}/${img}"
    dst="${DST_REGISTRY}/${DST_ORG}/${img}"

    # Destination tag list: every git-referenced tag, plus RELEASE, plus latest.
    tags="$(derive_tags "$chart_dir" "$chart_name" || true)"

    if ! image_exists "${src}:latest"; then
      log "MISSING" "$img  (source ${src}:latest not reachable)"
      failed=$((failed+1)); continue
    fi

    arches="$(image_arches "${src}:latest")"
    case "$arches" in
      *arm64*) : ;;
      *) log "SINGLEARCH" "$img  [$arches] -- the Pi/Jetson cluster needs arm64"
         failed=$((failed+1)); continue ;;
    esac

    log "READY" "$img  [$arches]  git-tags: $(echo $tags | tr '\n' ' ')"
    [ "$DRY_RUN" = "1" ] && continue

    # Mirror each git-referenced tag verbatim so committed manifests resolve on
    # a fresh ghcr cluster without waiting for ImageUpdateAutomation.
    copied=0; primary=""
    for t in $tags; do
      if ! image_exists "${src}:${t}"; then
        log "ABSENT" "  ${img}:${t} not in GitLab (placeholder tag); skipping"
        continue
      fi
      if image_exists "${dst}:${t}" && [ "$FORCE" != "1" ]; then
        log "SKIP" "  ${img}:${t} already published (FORCE=1 to overwrite)"
        primary="$t"   # tags arrive version-sorted, so the last wins = newest
        continue
      fi
      if skopeo copy --all --digestfile "${WORKDIR}/d" \
           "docker://${src}:${t}" "docker://${dst}:${t}" >/dev/null; then
        log ">>" "  ${img}:${t}  $(cat "${WORKDIR}/d" 2>/dev/null)"
        SUMMARY+=("image ${img}:${t} $(cat "${WORKDIR}/d" 2>/dev/null)")
        copied=$((copied+1)); primary="$t"
      else
        log "FAILED" "  ${img}:${t} copy rejected -- continuing"
        failed=$((failed+1))
      fi
    done

    # RELEASE and latest track the newest git-referenced tag so the whole stack
    # is coherent; fall back to GitLab latest when no pinned tag exists.
    local base_ref="${src}:latest"
    [ -n "$primary" ] && base_ref="${dst}:${primary}"
    for t in ${RELEASE:+$RELEASE} latest; do
      if image_exists "${dst}:${t}" && [ "$FORCE" != "1" ]; then
        log "SKIP" "  ${img}:${t} already published (FORCE=1 to overwrite)"
        continue
      fi
      if skopeo copy --all --digestfile "${WORKDIR}/d" \
           "docker://${base_ref}" "docker://${dst}:${t}" >/dev/null; then
        log ">>" "  ${img}:${t}  $(cat "${WORKDIR}/d" 2>/dev/null)"
        SUMMARY+=("image ${img}:${t} $(cat "${WORKDIR}/d" 2>/dev/null)")
        copied=$((copied+1))
      else
        log "FAILED" "  ${img}:${t} copy rejected -- continuing"
        failed=$((failed+1))
      fi
    done

    if [ "$copied" -gt 0 ]; then published=$((published+1)); else skipped=$((skipped+1)); fi
  done
}

# --- 7. Charts --------------------------------------------------------------
# Charts are downloaded, never packaged locally. The .tgz in GitLab is the
# artifact CI built and FluxCD consumes; re-pushing it is a true promotion,
# while repackaging would produce a different artifact that merely resembles it.

do_charts() {
  echo
  log_info "=== CHARTS -> ${DST_CHART_OCI} ==="
  local unit chart_rel img chart_dir name ver tgz got

  for unit in "${UNITS[@]}"; do
    IFS='|' read -r chart_rel img <<< "$unit"
    matches_filter "$chart_rel" || continue

    chart_dir="$ROOT/application/$chart_rel"
    if [ ! -f "$chart_dir/Chart.yaml" ]; then
      log "SKIP" "$chart_rel  (no Chart.yaml)"; skipped=$((skipped+1)); continue
    fi
    name="$(chart_name_of "$chart_dir")"
    ver="$(chart_ver_of "$chart_dir")"
    [ -n "$name" ] && [ -n "$ver" ] || { log "FAILED" "$chart_rel  cannot read name/version"; failed=$((failed+1)); continue; }

    if [ "$DRY_RUN" = "1" ]; then
      log "READY" "$name  $ver"
      continue
    fi

    if chart_exists "$name" "$ver" && [ "$FORCE" != "1" ]; then
      log "SKIP" "$name $ver already published (FORCE=1 to overwrite)"; skipped=$((skipped+1)); continue
    fi

    # 1. The GitLab OCI namespace is the only source. The per-project HTTP
    #    package registry is no longer published to by CI, so it is not consulted.
    got=""
    if helm pull "${SRC_CHART_OCI}/${name}" --version "$ver" --destination "$WORKDIR" >/dev/null 2>&1; then
      got="oci"
    fi

    # 2. Not there. A miss means git and the registry have drifted, which
    #    is worth surfacing rather than papering over with a local rebuild.
    if [ -z "$got" ] && [ "$ALLOW_LOCAL_PACKAGE" = "1" ]; then
      log_warn "$name $ver not in any registry; ALLOW_LOCAL_PACKAGE=1 -> packaging locally"
      helm dependency update "$chart_dir" >/dev/null 2>&1 || true
      helm package "$chart_dir" --destination "$WORKDIR" >/dev/null 2>&1 && got="local"
    fi
    if [ -z "$got" ]; then
      log "MISSING" "$name $ver not published by CI (not in the OCI charts registry)"
      failed=$((failed+1)); continue
    fi

    tgz="${WORKDIR}/${name}-${ver}.tgz"
    [ -f "$tgz" ] || { log "FAILED" "$name  expected $tgz after pull"; failed=$((failed+1)); continue; }

    if helm push "$tgz" "$DST_CHART_OCI" >/dev/null 2>&1; then
      log ">>" "$name $ver  (source: $got)  -> ${DST_CHART_OCI}/${name}:${ver}"
      SUMMARY+=("chart ${name}:${ver} sha256:$(shasum -a 256 "$tgz" | awk '{print $1}') source=$got")
      published=$((published+1))
    else
      log "FAILED" "$name $ver push rejected -- continuing"
      failed=$((failed+1))
    fi
  done
}

# --- 8. Visibility audit ----------------------------------------------------
# GHCR packages are created private and there is NO REST API to change that.
# The flip is a manual, IRREVERSIBLE step in the GitHub UI. This only reports.

do_verify() {
  echo
  log_info "=== VISIBILITY AUDIT (anonymous) ==="
  local unit chart_rel img chart_dir name ver tag pub=0 priv=0

  tag="${RELEASE:-latest}"
  for unit in "${UNITS[@]}"; do
    IFS='|' read -r chart_rel img <<< "$unit"
    matches_filter "$img" || continue
    if skopeo inspect --no-creds --raw "docker://${DST_REGISTRY}/${DST_ORG}/${img}:${tag}" >/dev/null 2>&1; then
      log "PUBLIC" "image ${img}:${tag}"; pub=$((pub+1))
    else
      log "PRIVATE" "image ${img}:${tag}  (flip in GitHub UI -- IRREVERSIBLE)"; priv=$((priv+1))
    fi
  done
  for unit in "${UNITS[@]}"; do
    IFS='|' read -r chart_rel img <<< "$unit"
    matches_filter "$chart_rel" || continue
    chart_dir="$ROOT/application/$chart_rel"
    [ -f "$chart_dir/Chart.yaml" ] || continue
    name="$(chart_name_of "$chart_dir")"; ver="$(chart_ver_of "$chart_dir")"
    if chart_is_public "$name" "$ver"; then
      log "PUBLIC" "chart ${name}:${ver}"; pub=$((pub+1))
    else
      log "PRIVATE" "chart ${name}:${ver}  (flip in GitHub UI -- IRREVERSIBLE)"; priv=$((priv+1))
    fi
  done
  echo
  log_info "visibility: ${pub} public, ${priv} private, $((pub+priv)) total"
  [ "$priv" -eq 0 ] || log_warn "flip the private packages at https://github.com/orgs/${DST_ORG}/packages"
}

# --- 9. Run -----------------------------------------------------------------

if [ "$VERIFY_ONLY" = "1" ]; then
  do_verify
  exit 0
fi

[ "$DRY_RUN" = "1" ] && log_info "DRY RUN: validating and resolving only, nothing will be written"
[ -n "$RELEASE" ] && log_info "release tag: $RELEASE"

case "$MODE" in
  images) do_images ;;
  charts) do_charts ;;
  all)    do_images; do_charts ;;
esac

if [ "${#SUMMARY[@]}" -gt 0 ]; then
  echo
  log_info "=== PUBLISHED ARTIFACTS ==="
  printf '%s\n' "${SUMMARY[@]}"
  echo
  log_info "Redirect this output if you want a durable record; GHCR holds the"
  log_info "authoritative digests and can be re-queried with skopeo inspect."
fi

echo
echo "---- published: $published  skipped: $skipped  failed: $failed ----"
if [ "$DRY_RUN" != "1" ] && [ "$failed" -eq 0 ] && [ "$published" -gt 0 ]; then
  echo
  log_warn "Packages are PRIVATE until flipped in the GitHub UI. That change is IRREVERSIBLE."
  log_warn "Then re-check with: VERIFY_ONLY=1 RELEASE=${RELEASE:-latest} ./publish-to-ghcr.sh"
fi
[ "$failed" -eq 0 ]
