#!/bin/bash
# Ambient Mesh Workshop - Cleanup Script
# Removes workshop resources from the cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

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
# Configuration
#######################################

CONFIG_FILE=""
SKIP_CONFIRM=false
FULL_CLEANUP=false
DELETE_CLUSTER=false

usage() {
    echo "Usage: $0 [-c config_file] [-y|--yes] [--full] [--delete-cluster]"
    echo ""
    echo "Options:"
    echo "  -c, --config FILE   Load configuration from FILE"
    echo "  -y, --yes           Skip confirmation prompt"
    echo "  --full              Full cleanup including Istio (default: app only)"
    echo "  --delete-cluster    Delete the GKE cluster (requires CLUSTER and GKE_ZONE)"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Cleanup modes:"
    echo "  Default: Removes bookinfo namespace and workshop progress"
    echo "  --full:  Also removes Istio Gateway, Istio Ambient, and Gateway API CRDs"
    echo "  --delete-cluster: Deletes the entire GKE cluster (DESTRUCTIVE!)"
    exit 0
}

#######################################
# Parse Arguments
#######################################

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        --full)
            FULL_CLEANUP=true
            shift
            ;;
        --delete-cluster)
            DELETE_CLUSTER=true
            FULL_CLEANUP=true  # Deleting cluster implies full cleanup
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

#######################################
# Load Configuration
#######################################

if [[ -n "$CONFIG_FILE" ]]; then
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "Loaded config from: $CONFIG_FILE"
    fi
fi

#######################################
# Cleanup Functions
#######################################

cleanup_bookinfo() {
    log_info "Removing Bookinfo namespace..."

    kubectl delete ns bookinfo --ignore-not-found --wait=false
    log_success "Bookinfo namespace removed"
}

cleanup_gloo_gateway() {
    log_info "Removing Gloo Gateway (if installed)..."

    kubectl delete gateway gloo-gateway -n gloo-system --ignore-not-found 2>/dev/null || true
    helm uninstall gloo-gateway -n gloo-system 2>/dev/null || true
    helm uninstall gloo-gateway-crds -n gloo-system 2>/dev/null || true
    kubectl delete ns gloo-system --ignore-not-found --wait=false 2>/dev/null || true

    log_success "Gloo Gateway removed"
}

cleanup_istio_gateway() {
    log_info "Removing Istio Gateway..."

    kubectl delete gateway istio-ingressgateway -n istio-ingress --ignore-not-found 2>/dev/null || true
    helm uninstall istio-ingress -n istio-ingress 2>/dev/null || true
    kubectl delete ns istio-ingress --ignore-not-found --wait=false 2>/dev/null || true

    log_success "Istio Gateway removed"
}

cleanup_istio_ambient() {
    log_info "Removing Istio Ambient..."

    helm uninstall ztunnel -n istio-system 2>/dev/null || true
    helm uninstall istio-cni -n istio-system 2>/dev/null || true
    helm uninstall istiod -n istio-system 2>/dev/null || true
    helm uninstall istio-base -n istio-system 2>/dev/null || true
    kubectl delete ns istio-system --ignore-not-found --wait=false 2>/dev/null || true

    log_success "Istio Ambient removed"
}

cleanup_gateway_api() {
    log_info "Removing Gateway API CRDs..."

    kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml 2>/dev/null || true

    log_success "Gateway API CRDs removed"
}

cleanup_local() {
    log_info "Cleaning up local state..."

    # Clean up workshop progress file
    local PROGRESS_FILE="$REPO_ROOT/.workshop-progress"
    if [[ -f "$PROGRESS_FILE" ]]; then
        rm -f "$PROGRESS_FILE"
        log_info "Removed workshop progress file"
    fi

    # Clean up kubeconfig context if deleting cluster
    if [[ "$DELETE_CLUSTER" == "true" && -n "${CLUSTER:-}" ]]; then
        kubectl config delete-context "$CLUSTER" 2>/dev/null || true
        log_info "Removed kubeconfig context"
    fi

    log_success "Local state cleaned up"
}

delete_gke_cluster() {
    log_info "Deleting GKE cluster..."

    if [[ -z "${CLUSTER:-}" ]]; then
        log_error "CLUSTER variable required for cluster deletion"
        exit 1
    fi

    if [[ -z "${GKE_ZONE:-}" ]]; then
        log_error "GKE_ZONE variable required for cluster deletion"
        exit 1
    fi

    local PROJECT
    PROJECT="$(gcloud config get-value project 2>/dev/null)"

    if [[ -z "$PROJECT" ]]; then
        log_error "No active gcloud project set"
        exit 1
    fi

    log_info "Deleting GKE cluster: $CLUSTER (zone: $GKE_ZONE)"
    gcloud container clusters delete "$CLUSTER" \
        --zone "$GKE_ZONE" \
        --project "$PROJECT" \
        --quiet

    log_success "GKE cluster deleted"
}

#######################################
# Main
#######################################

main() {
    echo ""

    if [[ "$DELETE_CLUSTER" == "true" ]]; then
        log_warn "This will DELETE the GKE cluster: ${CLUSTER:-<not set>}"
        log_warn ""
        log_warn "This action is IRREVERSIBLE!"
        log_warn ""
        log_warn "All resources will be destroyed including:"
        log_warn "  - The entire Kubernetes cluster"
        log_warn "  - All namespaces and workloads"
        log_warn "  - All persistent volumes"
    elif [[ "$FULL_CLEANUP" == "true" ]]; then
        log_warn "This will REMOVE the following:"
        log_warn "  - Bookinfo application (bookinfo namespace)"
        log_warn "  - Gloo Gateway (if installed)"
        log_warn "  - Istio Gateway (istio-ingress namespace)"
        log_warn "  - Istio Ambient (istio-system namespace)"
        log_warn "  - Gateway API CRDs"
        log_warn "  - Workshop progress file"
    else
        log_warn "This will REMOVE the following:"
        log_warn "  - Bookinfo application (bookinfo namespace)"
        log_warn "  - Workshop progress file"
        log_warn ""
        log_info "For full cleanup including Istio, use: $0 --full"
    fi

    echo ""

    if [[ "$SKIP_CONFIRM" != "true" ]]; then
        read -p "Are you sure you want to continue? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cleanup cancelled"
            exit 0
        fi
    fi

    echo ""

    if [[ "$DELETE_CLUSTER" == "true" ]]; then
        # Delete the entire cluster
        delete_gke_cluster
        cleanup_local
    else
        # Always clean up bookinfo and local state
        cleanup_bookinfo
        cleanup_local

        # Full cleanup
        if [[ "$FULL_CLEANUP" == "true" ]]; then
            cleanup_gloo_gateway
            cleanup_istio_gateway
            cleanup_istio_ambient
            cleanup_gateway_api
        fi
    fi

    echo ""
    log_success "Cleanup complete!"

    if [[ "$FULL_CLEANUP" != "true" && "$DELETE_CLUSTER" != "true" ]]; then
        echo ""
        log_info "To run the workshop again: ./scripts/workshop.sh -c env.sh"
        log_info "To fully remove Istio: ./scripts/cleanup.sh --full -y"
    fi
}

main "$@"
