#!/bin/bash
# =============================================================================
# Script Name: openmetadata.sh
# Description: This script deploys OpenMetadata to OpenShift.
# Author: Noriaki Mushino
# Date Created: 2026-06-24
# Last Modified: 2026-07-18
# Version: 1.1
#
# Usage:
#   ./script/openmetadata.sh deploy    - Deploy OpenMetadata and its dependencies.
#   ./script/openmetadata.sh cleanup   - Uninstall OpenMetadata.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - helm is installed
#   - User is logged into OpenShift
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPENMETADATASPACE="openmetadata"

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0 deploy                 OpenMetadata と依存関係をデプロイ"
    echo "  $0 cleanup                OpenMetadata をアンインストール"
}

# =============================================================================
# Step 1: コマンド検証（無効なら即終了）
# =============================================================================

case "${1:-}" in
    deploy|cleanup) ;;
    *)
        echo -e "${RED}無効なコマンドです: ${1:-}${RESET}"
        usage; exit 1
        ;;
esac

# =============================================================================
# Step 2: ロゴ表示・OCP 接続確認
# =============================================================================

figlet "droneshop"

oc status
oc version

if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

deploy() {
    echo -e "${BLUE}セットアップ開始...${RESET}"

    # プロジェクトの作成
    oc delete project "$OPENMETADATASPACE" --ignore-not-found=true || true
    oc new-project "$OPENMETADATASPACE"

    # シークレットの作成
    # (airflow-secrets / airflow-mysql-secrets は Airflow 無効化に伴い不要になったため作成しない)
    oc create secret generic mysql-secrets \
        --from-literal=openmetadata-mysql-password=openmetadata_password \
        -n "$OPENMETADATASPACE"

    # 既存 SA への SCC 付与（プロジェクト作成直後）
    for sa in builder default deployer mysql openmetadata; do
        oc adm policy add-scc-to-user anyuid -z "$sa" -n "$OPENMETADATASPACE"
    done

    # OpenMetadata 依存 Pod のインストール
    # Airflow は values-openmetadata-dependencies.yaml で無効化している。
    # openmetadata本体 (values-openmetadata.yaml) の pipelineServiceClientConfig.type: "k8s"
    # により、メタデータ収集パイプラインの実行は OpenShift ネイティブの Job に任せる設計のため、
    # Airflow自体はOpenMetadataの動作に不要（バージョンによりOpenShift上で不安定になることがある）
    echo -e "${BLUE}[1/2] openmetadata-dependencies (MySQL / OpenSearch) をインストール中...${RESET}"
    helm repo add open-metadata https://helm.open-metadata.org 2>/dev/null || true
    helm repo update
    helm install openmetadata-dependencies open-metadata/openmetadata-dependencies \
        -n "$OPENMETADATASPACE" \
        -f "$REPO_ROOT/openshift/values-openmetadata-dependencies.yaml"

    # OpenMetadata 本体のインストール
    echo -e "${BLUE}[2/2] openmetadata をインストール中...${RESET}"
    helm install openmetadata open-metadata/openmetadata \
        -n "$OPENMETADATASPACE" \
        -f "$REPO_ROOT/openshift/values-openmetadata.yaml"
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

# =============================================================================
# Step 3: ディスパッチ
# =============================================================================

case "$1" in
    deploy)  deploy  ;;
    cleanup) cleanup ;;
esac
