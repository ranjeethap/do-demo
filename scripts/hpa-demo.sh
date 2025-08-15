#!/usr/bin/env bash
set -euo pipefail
NS="dev"
LT=$(kubectl -n "$NS" get pod -l app=flagger-loadtester -o jsonpath='{.items[0].metadata.name}')
if [[ -z "${LT}" ]]; then echo "Loadtester not found in $NS"; exit 3; fi
echo "[hpa] 90s load (qps=20) to http://doks-flask.dev/"; kubectl -n "$NS" exec -it "$LT" -- hey -z 90s -q 20 http://doks-flask.dev/ &
kubectl -n "$NS" get hpa -w
