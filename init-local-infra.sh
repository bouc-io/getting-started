#!/bin/bash

# Bouc.io Local Infrastructure Setup Script
# This script installs necessary tools and sets up the entire project structure.

set -e # Exit on error

# --- Helper Functions ---

log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}

ensure_dir() {
    if [ ! -d "$1" ]; then
        log_info "Creating directory: $1"
        mkdir -p "$1"
    fi
}

clone_repo() {
    local dir="$1"
    local repo_url="$2"
    local target_dir="$3"

    ensure_dir "$dir"
    
    if [ -d "$dir/$target_dir/.git" ]; then
        log_info "Repository $target_dir already exists in $dir. Skipping clone."
    else
        log_info "Cloning $target_dir into $dir..."
        git -C "$dir" clone "$repo_url" "$target_dir"
    fi
}

install_brew_package() {
    local package="$1"
    if brew list --formula "$package" >/dev/null 2>&1 || brew list --cask "$package" >/dev/null 2>&1; then
        log_info "$package is already installed."
    else
        log_info "Installing $package..."
        brew install "$package"
    fi
}

# --- 1. Tool Installation ---

log_info "Starting Tool Installation..."

if ! command -v brew &> /dev/null; then
    echo "Homebrew is not installed. Please install it first: https://brew.sh/"
    exit 1
fi

# Core Tools
CORE_TOOLS=(
    "git"
    "git-flow"
    "git-lfs"
    "bash"
    "tree"
    "jq"
    "wget"
)

# Kubernetes & Cloud
K8S_CLOUD_TOOLS=(
    "kubernetes-cli"
    "helm"
    "k9s"
    "kubectx"
    "kustomize"
    "flux"
    "google-cloud-sdk"
    "tfenv"
    "skopeo"
)

# Languages & Runtimes
LANG_runtimes=(
    "node"
    "go"
    "python"
    "openjdk"
    "maven"
    "gradle"
    "spring-boot"
    "pyenv"
)

# Utilities
UTILITIES=(
    "direnv"
    "ffmpeg"
    "ripgrep"
    "certbot"
    "cfssl"
)

ALL_TOOLS=("${CORE_TOOLS[@]}" "${K8S_CLOUD_TOOLS[@]}" "${LANG_runtimes[@]}" "${UTILITIES[@]}")

for tool in "${ALL_TOOLS[@]}"; do
    install_brew_package "$tool"
done

log_success "All tools installed successfully."

# --- 2. Directory Structure Setup ---

log_info "Setting up Directory Structure..."

WORKSPACE_ROOT=$(pwd) # Assumes script is run from workspace root or handle relative paths
# If script is inside documentation/getting-started, move up to root
if [[ "$(basename $(pwd))" == "getting-started" ]]; then
    WORKSPACE_ROOT="../.."
fi

log_info "Workspace Root: $WORKSPACE_ROOT"

ensure_dir "$WORKSPACE_ROOT/infrastructure"
ensure_dir "$WORKSPACE_ROOT/application"
ensure_dir "$WORKSPACE_ROOT/fluxcd"
ensure_dir "$WORKSPACE_ROOT/ai-models" # Created but not cloned

# Create sub-paths for applications
ensure_dir "$WORKSPACE_ROOT/application/examples"
ensure_dir "$WORKSPACE_ROOT/application/examples/api-example"
ensure_dir "$WORKSPACE_ROOT/application/examples/api-sprngbt-example"
ensure_dir "$WORKSPACE_ROOT/application/examples/chatbot-example"
ensure_dir "$WORKSPACE_ROOT/application/examples/static-website"
ensure_dir "$WORKSPACE_ROOT/application/examples/txn-web-example"

# Create infrastructure sub-paths
ensure_dir "$WORKSPACE_ROOT/infrastructure/raspberry-pi-kubernetes-cluster"
ensure_dir "$WORKSPACE_ROOT/infrastructure/gcp" # Created but not cloned

log_success "Directory structure verification complete."

# --- 3. Repository Cloning ---

log_info "Cloning Repositories..."

# FluxCD
clone_repo "$WORKSPACE_ROOT/fluxcd" "https://gitlab.com/bouc-io/fluxcd/fluxcdboucio.git" "fluxcdboucio"

# Infrastructure Components
INFRA_REPOS=(
    "cert-manager"
    "datadog"
    "external-dns"
    "istio"
    "k8s-dashboard"
    "keycloak"
    "metrics-server"
    "oauth2-proxy"
    "opentelemetry"
    "prometheus"
    "grafana"
    "kiali"
)

for repo in "${INFRA_REPOS[@]}"; do
    clone_repo "$WORKSPACE_ROOT/infrastructure" "git@gitlab.com:bouc-io/infrastructure/${repo}.git" "$repo"
done

# Infrastructure: Raspberry Pi Cluster
clone_repo "$WORKSPACE_ROOT/infrastructure/raspberry-pi-kubernetes-cluster" "git@gitlab.com:bouc-io/infrastructure/raspberry-pi-kubernetes-cluster/pi-k8s-cluster.git" "pi-k8s-cluster"

# Applications

# API Example (Node)
clone_repo "$WORKSPACE_ROOT/application/examples/api-example" "git@gitlab.com:bouc-io/application/examples/api-example/api-example.git" "api-example"
clone_repo "$WORKSPACE_ROOT/application/examples/api-example" "git@gitlab.com:bouc-io/application/examples/api-example/api-chart.git" "api-chart"

# API SpringBoot Example
clone_repo "$WORKSPACE_ROOT/application/examples/api-sprngbt-example" "git@gitlab.com:bouc-io/application/examples/api-sprngbt-example/api-java-example.git" "api-java-example"
clone_repo "$WORKSPACE_ROOT/application/examples/api-sprngbt-example" "git@gitlab.com:bouc-io/application/examples/api-sprngbt-example/api-java-chart.git" "api-java-chart"

# Chatbot Example
clone_repo "$WORKSPACE_ROOT/application/examples/chatbot-example" "https://github.com/MartinCote1978/monochrome-chatbot-ui.git" "monochrome-chatbot-ui" # GitHub Repo
clone_repo "$WORKSPACE_ROOT/application/examples/chatbot-example" "git@gitlab.com:bouc-io/application/examples/chatbot-example/chatbot-api-server.git" "chatbot-api-server"
clone_repo "$WORKSPACE_ROOT/application/examples/chatbot-example" "git@gitlab.com:bouc-io/application/examples/chatbot-example/chatbot-chart.git" "chatbot-chart"
clone_repo "$WORKSPACE_ROOT/application/examples/chatbot-example" "git@gitlab.com:bouc-io/application/examples/chatbot-example/chatbot-api-chart.git" "chatbot-api-chart"
clone_repo "$WORKSPACE_ROOT/application/examples/chatbot-example" "git@gitlab.com:bouc-io/application/examples/chatbot-example/ollama-chart.git" "ollama-chart"

# Static Website
clone_repo "$WORKSPACE_ROOT/application/examples/static-website" "git@gitlab.com:bouc-io/application/examples/static-website/static-web-example.git" "static-web-example"
clone_repo "$WORKSPACE_ROOT/application/examples/static-website" "git@gitlab.com:bouc-io/application/examples/static-website/static-web-chart.git" "static-web-chart"

# Transaction Web Example
clone_repo "$WORKSPACE_ROOT/application/examples/txn-web-example" "git@gitlab.com:bouc-io/application/examples/txn-web-example/txn-web-example.git" "txn-web-example"
clone_repo "$WORKSPACE_ROOT/application/examples/txn-web-example" "git@gitlab.com:bouc-io/application/examples/txn-web-example/txn-web-chart.git" "txn-web-chart"

log_success "All repositories processed."
log_success "Bouc.io Local Infrastructure Setup Complete!"