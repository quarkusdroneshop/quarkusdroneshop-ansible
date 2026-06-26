#!/bin/bash
# =============================================================================
# Script Name: openmetadata.sh
# Description: This script deploys OpenMetadata to OpenShift.
# Author: Noriaki Mushino
# Date Created: 2026-06-24
# Last Modified: 2026-06-24
# Version: 1.0
#
# Usage:
#   ./openmetadata.sh deploy    - Deploy OpenMetadata and its dependencies.
#   ./openmetadata.sh cleanup   - Uninstall OpenMetadata.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - helm is installed
#   - User is logged into OpenShift
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENMETADATASPACE="openmetadata"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# ログイン確認
if ! oc whoami &>/dev/null; then
    echo -e "${RED}エラー: OpenShift にログインしていません。${RESET}" >&2
    exit 1
fi
echo -e "${GREEN}OpenShift にログイン済み: $(oc whoami)${RESET}"

deploy() {
    echo -e "${BLUE}セットアップ開始...${RESET}"

    # プロジェクトの作成
    oc delete project "$OPENMETADATASPACE" --ignore-not-found=true || true
    oc new-project "$OPENMETADATASPACE"

    # シークレットの作成
    oc create secret generic mysql-secrets \
        --from-literal=openmetadata-mysql-password=openmetadata_password \
        -n "$OPENMETADATASPACE"
    oc create secret generic airflow-secrets \
        --from-literal=openmetadata-airflow-password=admin \
        -n "$OPENMETADATASPACE"
    oc create secret generic airflow-mysql-secrets \
        --from-literal=airflow-mysql-password=airflow_pass \
        -n "$OPENMETADATASPACE"

    # 既存 SA への SCC 付与（プロジェクト作成直後）
    for sa in airflow builder default deployer mysql openmetadata; do
        oc adm policy add-scc-to-user anyuid -z "$sa" -n "$OPENMETADATASPACE"
    done

    # OpenMetadata 依存 Pod のインストール
    echo -e "${BLUE}[1/3] openmetadata-dependencies をインストール中...${RESET}"
    helm repo add open-metadata https://helm.open-metadata.org 2>/dev/null || true
    helm repo update
    helm install openmetadata-dependencies open-metadata/openmetadata-dependencies \
        -n "$OPENMETADATASPACE" \
        -f "$SCRIPT_DIR/openshift/values-openmetadata-dependencies.yaml"

    # Helm が作成した Airflow ServiceAccount に anyuid を付与（SA は helm install 後に作られる）
    for sa in \
        openmetadata-dependencies-airflow-migrate-database-job \
        openmetadata-dependencies-airflow-create-user-job \
        openmetadata-dependencies-airflow-api-server \
        openmetadata-dependencies-airflow-dag-processor \
        openmetadata-dependencies-airflow-scheduler \
        openmetadata-dependencies-airflow-triggerer \
        openmetadata-dependencies-airflow-worker \
        openmetadata-dependencies-airflow-statsd; do
        oc adm policy add-scc-to-user anyuid -z "$sa" -n "$OPENMETADATASPACE"
    done
    echo -e "${GREEN}  → Airflow ServiceAccount に anyuid を付与しました${RESET}"

    # 既存 PVC を一度削除して再作成（storageClass 対応）
    echo -e "${BLUE}[2/3] PVC を再作成中...${RESET}"
    oc delete pvc openmetadata-dependencies-dags -n "$OPENMETADATASPACE" --ignore-not-found=true
    oc delete pvc openmetadata-dependencies-logs -n "$OPENMETADATASPACE" --ignore-not-found=true

    oc apply -f "$SCRIPT_DIR/openshift/openmetadata-dependencies-dags.yaml" -n "$OPENMETADATASPACE"
    oc apply -f "$SCRIPT_DIR/openshift/openmetadata-dependencies-logs.yaml" -n "$OPENMETADATASPACE"

    oc label pvc openmetadata-dependencies-dags app.kubernetes.io/managed-by=Helm -n "$OPENMETADATASPACE"
    oc annotate pvc openmetadata-dependencies-dags \
        meta.helm.sh/release-name=openmetadata-dependencies \
        meta.helm.sh/release-namespace=openmetadata \
        -n "$OPENMETADATASPACE"
    oc label pvc openmetadata-dependencies-logs app.kubernetes.io/managed-by=Helm -n "$OPENMETADATASPACE"
    oc annotate pvc openmetadata-dependencies-logs \
        meta.helm.sh/release-name=openmetadata-dependencies \
        meta.helm.sh/release-namespace=openmetadata \
        -n "$OPENMETADATASPACE"

    # OpenMetadata 本体のインストール
    echo -e "${BLUE}[3/3] openmetadata をインストール中...${RESET}"
    helm install openmetadata open-metadata/openmetadata \
        -n "$OPENMETADATASPACE" \
        -f "$SCRIPT_DIR/openshift/values-openmetadata.yaml"
    oc expose svc openmetadata -n "$OPENMETADATASPACE"

    echo -e "${GREEN}OpenMetadata のデプロイが完了しました。${RESET}"
    echo -e "${YELLOW}Pod の起動には数分かかります: oc get pod -n ${OPENMETADATASPACE} -w${RESET}"
}

cleanup() {
    echo -e "${BLUE}クリーンアップ開始...${RESET}"
    helm uninstall openmetadata -n "$OPENMETADATASPACE" 2>/dev/null || true
    helm uninstall openmetadata-dependencies -n "$OPENMETADATASPACE" 2>/dev/null || true

    read -rp "本当にプロジェクトを削除してもよろしいですか？(yes/no): " DELETE_CONFREM
    if [ "$DELETE_CONFREM" = "yes" ]; then
        oc delete project "$OPENMETADATASPACE" --force --grace-period=0 2>/dev/null || true
        echo -e "${GREEN}プロジェクト ${OPENMETADATASPACE} を削除しました。${RESET}"
    else
        echo -e "${YELLOW}プロジェクトの削除をスキップしました。${RESET}"
    fi
}

case "${1:-}" in
    deploy)
        deploy
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: ${1:-}${RESET}"
        echo -e "${RED}使用方法: $0 {deploy|cleanup}${RESET}"
        exit 1
        ;;
esac
