#!/usr/bin/env bash
set -euo pipefail

# eks-exec.sh — interactively exec into a pod's container on an EKS cluster
# Usage:
#   ./eks-exec.sh [--profile <profile>] [--region <region>] [--cluster <name>] \
#                 [--namespace <ns>] [--pod <pod>] [--container <name>] [--shell </bin/sh|/bin/bash>]
#
# Notes:
# - If any of --profile, --cluster, --namespace, --pod, --container are omitted,
#   you'll be prompted to select from what's available.
# - Updates your kubeconfig via `aws eks update-kubeconfig` using a context alias
#   scoped to the chosen profile so it won't clobber other contexts.
# - Requires: aws CLI v2, kubectl, jq. Optional: fzf for nicer selection.
#
# Exit codes:
#   1 - user/config error, 2 - dependency missing, 3 - AWS/kubectl call failed

err() { echo "ERROR: $*" >&2; }
die() {
  err "$@"
  exit 1
}

need_bin() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

# Defaults
PROFILE=""
REGION=""
CLUSTER=""
NAMESPACE=""
POD=""
CONTAINER=""
SHELL="/bin/bash"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
  --profile)
    PROFILE="${2:-}"
    shift 2
    ;;
  --region)
    REGION="${2:-}"
    shift 2
    ;;
  --cluster)
    CLUSTER="${2:-}"
    shift 2
    ;;
  --namespace | -n)
    NAMESPACE="${2:-}"
    shift 2
    ;;
  --pod)
    POD="${2:-}"
    shift 2
    ;;
  --container)
    CONTAINER="${2:-}"
    shift 2
    ;;
  --shell)
    SHELL="${2:-}"
    shift 2
    ;;
  -h | --help)
    sed -n '1,40p' "$0"
    exit 0
    ;;
  *)
    die "Unknown arg: $1"
    ;;
  esac
done

need_bin aws || {
  err "aws CLI v2 is required."
  exit 2
}
need_bin kubectl || {
  err "kubectl is required."
  exit 2
}
need_bin jq || {
  err "jq is required."
  exit 2
}

# Helper: choose from list with fzf if available, else numbered select
choose_item() {
  local prompt="$1"
  shift
  if need_bin fzf; then
    printf "%s\n" "$@" | fzf --prompt="$prompt> " --height=15 --border
  else
    local arr=("$@")
    PS3="$prompt (enter number): "
    select opt in "${arr[@]}"; do
      if [[ -n "${opt:-}" ]]; then
        echo "$opt"
        break
      else
        echo "Invalid selection." >&2
      fi
    done
  fi
}

# Resolve profile if not provided
if [[ -z "$PROFILE" ]]; then
  profiles=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && profiles+=("$line")
  done < <(aws configure list-profiles 2>/dev/null)
  [[ ${#profiles[@]} -gt 0 ]] || die "No AWS profiles found. Configure one with 'aws configure' or 'aws configure sso'."
  PROFILE="$(choose_item "Select profile" "${profiles[@]}")"
  [[ -n "$PROFILE" ]] || die "No profile selected."
fi

# If region not provided, read from profile config
if [[ -z "${REGION}" ]]; then
  REGION="$(aws configure get region --profile "$PROFILE" || true)"
fi
[[ -n "$REGION" ]] || die "No region set. Use --region or set region in the profile."

# Resolve cluster if not provided
if [[ -z "$CLUSTER" ]]; then
  echo "Discovering EKS clusters in ${REGION} for profile ${PROFILE}..."
  clusters=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && clusters+=("$line")
  done < <(aws eks list-clusters --region "$REGION" --profile "$PROFILE" --query 'clusters' --output json | jq -r '.[]')
  [[ ${#clusters[@]} -gt 0 ]] || die "No EKS clusters found in region ${REGION}."
  if [[ ${#clusters[@]} -eq 1 ]]; then
    CLUSTER="${clusters[0]}"
    echo "Using only cluster found: $CLUSTER"
  else
    CLUSTER="$(choose_item "Select cluster" "${clusters[@]}")"
    [[ -n "$CLUSTER" ]] || die "No cluster selected."
  fi
fi

# Update kubeconfig with a profile-scoped alias so it doesn't clobber existing contexts
CONTEXT_ALIAS="${PROFILE}-${CLUSTER}"
echo "Updating kubeconfig for cluster '$CLUSTER' as context '$CONTEXT_ALIAS'..."
aws eks update-kubeconfig \
  --name "$CLUSTER" \
  --region "$REGION" \
  --profile "$PROFILE" \
  --alias "$CONTEXT_ALIAS" >/dev/null || {
  err "Failed to update kubeconfig."
  exit 3
}

KCTL=(kubectl --context "$CONTEXT_ALIAS")

# Run kubectl, capture stdout; on failure, echo stderr and die so silent auth/RBAC
# errors don't masquerade as "no resources found".
kctl_capture() {
  local out err rc
  err="$(mktemp)"
  out="$("${KCTL[@]}" "$@" 2>"$err")" && rc=0 || rc=$?
  if [[ $rc -ne 0 ]]; then
    err "kubectl ${*} failed:"
    cat "$err" >&2
    rm -f "$err"
    exit 3
  fi
  rm -f "$err"
  printf "%s" "$out"
}

# Resolve namespace if not provided
if [[ -z "$NAMESPACE" ]]; then
  namespaces=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && namespaces+=("$line")
  done < <(kctl_capture get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
  [[ ${#namespaces[@]} -gt 0 ]] || die "No namespaces found (do you have RBAC to list namespaces?)."
  NAMESPACE="$(choose_item "Select namespace" "${namespaces[@]}")"
  [[ -n "$NAMESPACE" ]] || die "No namespace selected."
fi

# Resolve pod if not provided
if [[ -z "$POD" ]]; then
  echo "Discovering Running pods in namespace: $NAMESPACE"
  pods=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && pods+=("$line")
  done < <(kctl_capture get pods -n "$NAMESPACE" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
  if [[ ${#pods[@]} -eq 0 ]]; then
    err "No Running pods found in namespace '$NAMESPACE'. All pods (any phase):"
    "${KCTL[@]}" get pods -n "$NAMESPACE" -o wide >&2 || true
    exit 1
  fi
  if [[ ${#pods[@]} -eq 1 ]]; then
    POD="${pods[0]}"
    echo "Using only pod found: $POD"
  else
    POD="$(choose_item "Select pod" "${pods[@]}")"
    [[ -n "$POD" ]] || die "No pod selected."
  fi
fi

# Resolve container if not provided
if [[ -z "$CONTAINER" ]]; then
  containers=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] && containers+=("$line")
  done < <(kctl_capture get pod "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n')
  [[ ${#containers[@]} -gt 0 ]] || die "No containers found on pod '$POD'."
  if [[ ${#containers[@]} -eq 1 ]]; then
    CONTAINER="${containers[0]}"
    echo "Using only container found: $CONTAINER"
  else
    CONTAINER="$(choose_item "Select container" "${containers[@]}")"
    [[ -n "$CONTAINER" ]] || die "No container selected."
  fi
fi

# Info
echo "Profile  : $PROFILE"
echo "Region   : $REGION"
echo "Cluster  : $CLUSTER"
echo "Context  : $CONTEXT_ALIAS"
echo "Namespace: $NAMESPACE"
echo "Pod      : $POD"
echo "Container: $CONTAINER"
echo "Shell    : $SHELL"
echo

# Execute the command
set -x
"${KCTL[@]}" exec -it "$POD" \
  -n "$NAMESPACE" \
  -c "$CONTAINER" \
  -- "$SHELL"
