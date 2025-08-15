#!/usr/bin/env bash
# =============================================================================
# DOKS Cluster Lifecycle Helper (Interactive + Numeric Selection)
# -----------------------------------------------------------------------------
# Usage:
#   ./scripts/cluster.sh create     # prompt for name/region/size/count, create + set kube context
#   ./scripts/cluster.sh use        # pick an existing DO cluster (by number or name) and set kube context
#   ./scripts/cluster.sh status     # show cluster + pools + kube nodes (pick by number or name)
#   ./scripts/cluster.sh nodeup     # +1 node to default pool (pick by number or name)
#   ./scripts/cluster.sh nodedown   # -1 node from default pool (min 1)
#   ./scripts/cluster.sh delete     # delete the cluster (confirms by name)
#
# Env overrides (skip prompts): CLUSTER_NAME, REGION, SIZE, COUNT
# Requires: doctl, kubectl
# =============================================================================
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 2; }; }
need doctl
need kubectl

header(){ echo -e "\n=== $* ===\n"; }
prompt(){ local q="$1" d="${2:-}"; local a; read -r -p "${q} [${d}]: " a || true; echo "${a:-$d}"; }

# Return: selected cluster NAME (empty = cancel)
select_cluster() {
  # If provided via env, trust it
  if [[ -n "${CLUSTER_NAME:-}" ]]; then
    echo "$CLUSTER_NAME"
    return
  fi

  # Fetch names into an array
  mapfile -t names < <(doctl kubernetes cluster list --format Name --no-header 2>/dev/null || true)
  if (( ${#names[@]} == 0 )); then
    echo ""
    return
  fi

  # Show numbered list on stderr (so only the final selection is captured)
  echo "Available clusters:" >&2
  local i=1
  for n in "${names[@]}"; do
    printf "  %2d) %s\n" "$i" "$n" >&2
    ((i++))
  done

  read -r -p "Pick number or type cluster name (blank to cancel): " choice

  # If numeric, map to name
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local idx=$((choice-1))
    if (( idx >= 0 && idx < ${#names[@]} )); then
      echo "${names[$idx]}"
      return
    else
      echo ""
      return
    fi
  fi

  # If typed name, validate it exists
  for n in "${names[@]}"; do
    if [[ "$choice" == "$n" ]]; then
      echo "$choice"
      return
    fi
  done

  # Unknown or blank -> cancel
  echo ""
}

cluster_id(){ doctl kubernetes cluster get "$1" -o json 2>/dev/null | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n1; }
default_pool_id(){ doctl kubernetes node-pool list "$1" --format Name,ID --no-header | awk '/^default-pool/ {print $2; exit}'; }
default_pool_count(){ doctl kubernetes node-pool get "$1" "$2" --format Count --no-header | tr -d '[:space:]'; }

create() {
  header "Create DOKS cluster (interactive)"
  local name region size count
  name="$(prompt 'Cluster name' "${CLUSTER_NAME:-doks-saas-cluster}")"
  region="$(prompt 'Region (sfo2|nyc3|ams3|...)' "${REGION:-sfo2}")"
  size="$(prompt 'Node size' "${SIZE:-s-2vcpu-4gb}")"
  count="$(prompt 'Node count' "${COUNT:-2}")"

  if doctl kubernetes cluster get "$name" >/dev/null 2>&1; then
    echo "Cluster '$name' already exists. Skipping create."
  else
    doctl kubernetes cluster create "$name" \
      --region "$region" \
      --tag "doks-demo" \
      --node-pool "name=default-pool;size=${size};count=${count}"
  fi

  header "Saving kubeconfig & setting current context to '$name'"
  # With modern doctl, this sets current context by default
  doctl kubernetes cluster kubeconfig save "$name"
  kubectl config current-context
  kubectl get nodes -o wide || true
}

use_ctx() {
  header "Use an existing DOKS cluster"
  local name; name="$(select_cluster)"
  [[ -z "$name" ]] && { echo "No cluster selected."; exit 1; }
  doctl kubernetes cluster kubeconfig save "$name"
  kubectl config current-context
  kubectl get nodes -o wide || true
}

status() {
  header "Cluster status"
  local name="${CLUSTER_NAME:-}"

  # Prefer current kube context if it contains the cluster name
  if [[ -z "$name" ]]; then
    name="$(kubectl config current-context 2>/dev/null | sed -n 's/.*cluster\/\([^@]*\).*/\1/p')"
  fi
  # If still not determined, prompt (numeric or name)
  if [[ -z "$name" ]]; then
    name="$(select_cluster)"
  fi
  [[ -z "$name" ]] && { echo "No cluster selected."; exit 1; }

  echo "Cluster: $name"
  if ! doctl kubernetes cluster get "$name" >/dev/null 2>&1; then
    echo "Cluster not found in DO."; exit 1
  fi
  doctl kubernetes cluster get "$name"

  local cid; cid="$(cluster_id "$name")"
  if [[ -n "$cid" ]]; then
    echo
    doctl kubernetes node-pool list "$cid"
  fi

  echo
  kubectl get nodes -o wide || true
}

nodeup() {
  header "Scale up default-pool by +1"
  local name; name="${CLUSTER_NAME:-$(select_cluster)}"
  [[ -z "$name" ]] && { echo "No cluster selected."; exit 1; }
  local cid pid cur new
  cid="$(cluster_id "$name")"
  [[ -z "$cid" ]] && { echo "Could not resolve cluster id."; exit 1; }
  pid="$(default_pool_id "$cid")"
  cur="$(default_pool_count "$cid" "$pid")"
  new=$((cur+1))
  echo "Cluster: $name (id: $cid), Pool: $pid, Current: $cur -> New: $new"
  doctl kubernetes node-pool update "$cid" "$pid" --count "$new"
  kubectl get nodes -o wide || true
}

nodedown() {
  header "Scale down default-pool by -1"
  local name; name="${CLUSTER_NAME:-$(select_cluster)}"
  [[ -z "$name" ]] && { echo "No cluster selected."; exit 1; }
  local cid pid cur new
  cid="$(cluster_id "$name")"
  [[ -z "$cid" ]] && { echo "Could not resolve cluster id."; exit 1; }
  pid="$(default_pool_id "$cid")"
  cur="$(default_pool_count "$cid" "$pid")"
  if [[ "$cur" -le 1 ]]; then echo "Refusing to scale below 1 node."; exit 1; fi
  new=$((cur-1))
  echo "Cluster: $name (id: $cid), Pool: $pid, Current: $cur -> New: $new"
  doctl kubernetes node-pool update "$cid" "$pid" --count "$new"
  kubectl get nodes -o wide || true
}

delete_cluster() {
  header "Delete DOKS cluster (DANGEROUS)"
  local name; name="${CLUSTER_NAME:-$(select_cluster)}"
  [[ -z "$name" ]] && { echo "No cluster selected."; exit 1; }

  read -r -p "Really delete cluster '$name'? Type the name to confirm: " confirm
  if [[ "$confirm" != "$name" ]]; then
    echo "Cluster name mismatch. Aborting."
    exit 1
  fi

  doctl kubernetes cluster delete "$name" --force
}

cmd="${1:-}"
case "$cmd" in
  create)   create ;;
  use)      use_ctx ;;
  status)   status ;;
  nodeup)   nodeup ;;
  nodedown) nodedown ;;
  delete)   delete_cluster ;;
  *) echo "Usage: $0 {create|use|status|nodeup|nodedown|delete}"; exit 1 ;;
esac

