#!/bin/bash
# =============================================================================
# Script Name: submit-flink-jobs.sh
# Description: datamesh-dataproducts/*/flink/*.sql を dataproducts-flink Session Cluster
#              (openshift/dataproducts/flink-session-cluster.yaml) に SQL Client
#              経由で投入する。依存順(OrderEvents が先)に投入する。
#
# Usage:
#   ./script/submit-flink-jobs.sh [product-dir ...]
#   引数なしの場合は依存順に全ジョブを投入する。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATAPRODUCTS_DIR="$(cd "${REPO_ROOT}/../datamesh-dataproducts" && pwd)"
NAMESPACE="${NAMESPACE:-quarkusdroneshop-demo}"
FLINK_DEPLOYMENT="dataproducts-flink"

# 依存順: OrderEvents をハブとして先に投入し、それに依存するプロダクトを後段で投入する。
DEFAULT_ORDER=(
    "order-events"
    "real-time-sales-trends"
    "drone-component-stock"
    "inventory-analytics"
    "assembly-lead-time-qdca10"
    "assembly-lead-time-qdca10pro"
    "customer-360"
)

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
    TARGETS=("${DEFAULT_ORDER[@]}")
fi

echo "Flink Session Cluster (${FLINK_DEPLOYMENT}) の Rest Service を待機中..."
until oc get flinkdeployment "${FLINK_DEPLOYMENT}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.jobManagerDeploymentStatus}' 2>/dev/null | grep -q "READY"; do
    sleep 5
done

for product in "${TARGETS[@]}"; do
    for sql in "${DATAPRODUCTS_DIR}/${product}"/flink/*.sql; do
        [ -e "$sql" ] || continue
        job_name="dataproducts-$(basename "$sql" .sql)"
        echo "投入中: ${product}/$(basename "$sql")"

        oc create configmap "${job_name}-sql" \
            --from-file="job.sql=${sql}" \
            -n "${NAMESPACE}" \
            --dry-run=client -o yaml | oc apply -f -

        oc run "${job_name}" \
            --image=apache/flink:1.19-java17 \
            --restart=Never \
            --namespace="${NAMESPACE}" \
            --overrides="
{
  \"spec\": {
    \"containers\": [{
      \"name\": \"${job_name}\",
      \"image\": \"apache/flink:1.19-java17\",
      \"command\": [\"/opt/flink/bin/sql-client.sh\", \"-f\", \"/etc/flink-sql/job.sql\"],
      \"env\": [{\"name\": \"FLINK_REST_HOST\", \"value\": \"${FLINK_DEPLOYMENT}-rest.${NAMESPACE}.svc\"}],
      \"volumeMounts\": [{\"name\": \"sql\", \"mountPath\": \"/etc/flink-sql\"}]
    }],
    \"volumes\": [{\"name\": \"sql\", \"configMap\": {\"name\": \"${job_name}-sql\"}}]
  }
}" \
            --dry-run=client -o yaml | oc apply -f -
    done
done

echo "全ジョブの投入完了(投入順: ${TARGETS[*]})"
