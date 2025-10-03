#!/usr/bin/env bash

NAMESPACE="${1:-glr-jobs}"
manifests=captured_job_pods.yaml

kubectl get pods -n "$NAMESPACE" -w | while read line; do
  if [[ "$line" =~ "runner-" && "$line" =~ "Running" ]]; then
    POD_NAME=$(echo "$line" | awk '{print $1}')
    echo " $(date -Is) ℹ️ Capture: $POD_NAME"
    echo '---' >> $manifests
    kubectl get pod "$POD_NAME" -n "$NAMESPACE" -o yaml >> $manifests
  fi
done
