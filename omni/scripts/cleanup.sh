#!/bin/bash
set -e

# Omni Demo Environment Cleanup Script
# Deletes GKE clusters and cleans up local state
#
# Usage:
#   ./cleanup.sh -c /path/to/env.sh      # delete clusters
#   ./cleanup.sh -c /path/to/env.sh -y   # skip confirmation
#
# Required variables (from config file or environment):
#   CLUSTER1, CLUSTER2, GKE_ZONE1, GKE_ZONE2

#######################################
# Logging
#######################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

#######################################
# Functions
#######################################

usage() {
    echo "Usage: $0 [-c config_file] [-y|--yes]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE   Load configuration from FILE"
    echo "  -y, --yes           Skip confirmation prompt"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Required variables (from config file or environment):"
    echo "  CLUSTER1, CLUSTER2, GKE_ZONE1, GKE_ZONE2"
    exit 0
}

load_config() {
    local config_file=$1

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    source "$config_file"
    log_info "Loaded config from: $config_file"
}

validate_environment() {
    local missing=()

    [[ -z "${CLUSTER1:-}" ]] && missing+=("CLUSTER1")
    [[ -z "${CLUSTER2:-}" ]] && missing+=("CLUSTER2")
    [[ -z "${GKE_ZONE1:-}" ]] && missing+=("GKE_ZONE1")
    [[ -z "${GKE_ZONE2:-}" ]] && missing+=("GKE_ZONE2")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"
        log_error "Use -c to specify a config file or source your env.sh first"
        exit 1
    fi

    log_info "Configuration:"
    log_info "  CLUSTER1: $CLUSTER1 (zone: $GKE_ZONE1)"
    log_info "  CLUSTER2: $CLUSTER2 (zone: $GKE_ZONE2)"
}

delete_gke_cluster() {
    local cluster_name=$1
    local zone=$2
    local project
    project=$(gcloud config get-value project 2>/dev/null)

    if [[ -z "$project" ]]; then
        log_error "No active gcloud project set"
        return 1
    fi

    log_info "Deleting GKE cluster: $cluster_name (zone: $zone)"
    gcloud container clusters delete "$cluster_name" \
        --zone "$zone" \
        --project "$project" \
        --quiet &
}

cleanup_local() {
    log_info "Cleaning up kubeconfig contexts..."

    kubectl config delete-context "$CLUSTER1" 2>/dev/null || true
    kubectl config delete-context "$CLUSTER2" 2>/dev/null || true

    # Clean up workshop progress file
    local SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local REPO_ROOT="$(dirname "$SCRIPT_DIR")"
    local PROGRESS_FILE="$REPO_ROOT/.workshop-progress"
    if [[ -f "$PROGRESS_FILE" ]]; then
        log_info "Removing workshop progress file..."
        rm -f "$PROGRESS_FILE"
    fi

    log_success "Local state cleaned up"
}

#######################################
# Main
#######################################

main() {
    local config_file=""
    local skip_confirm=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                config_file="$2"
                shift 2
                ;;
            -y|--yes)
                skip_confirm=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Load config file if specified
    if [[ -n "$config_file" ]]; then
        load_config "$config_file"
    fi

    validate_environment

    echo ""
    log_warn "This will DELETE the following GKE clusters:"
    log_warn "  - $CLUSTER1 (zone: $GKE_ZONE1)"
    log_warn "  - $CLUSTER2 (zone: $GKE_ZONE2)"
    log_warn ""
    log_warn "This action is IRREVERSIBLE!"
    echo ""

    if [[ "$skip_confirm" != "true" ]]; then
        read -p "Are you sure you want to continue? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cleanup cancelled"
            exit 0
        fi
    fi

    # Delete clusters in parallel
    delete_gke_cluster "$CLUSTER1" "$GKE_ZONE1"
    delete_gke_cluster "$CLUSTER2" "$GKE_ZONE2"

    log_info "Waiting for cluster deletions to complete..."
    wait

    cleanup_local

    echo ""
    log_success "Cleanup complete! GKE clusters deleted and local state cleaned up."
}

main "$@"
