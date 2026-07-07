#!/bin/bash
# =============================================================================
# Script Name: acmdeploy.sh
# Description: RHACM (Red Hat Advanced Cluster Management) ハブの構築管理スクリプト
#              advanced-cluster-management Operator のインストールから
#              MultiClusterHub の作成までを行う。
# Usage:
#   ./script/acmdeploy.sh setup     - RHACM Operator インストール + MultiClusterHub 作成
#   ./script/acmdeploy.sh cleanup   - RHACM Operator + MultiClusterHub 削除
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - User is logged into OpenShift
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ACM_NAMESPACE="open-cluster-management"

# 色を変数に格納
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0 setup       RHACM Operator インストール + MultiClusterHub 作成"
    echo "  $0 cleanup     RHACM Operator + MultiClusterHub 削除"
}

# =============================================================================
# Step 1: コマンド検証（無効なら即終了）
# =============================================================================

case "$1" in
    setup|cleanup) ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        usage; exit 1
        ;;
esac

# =============================================================================
# Step 2: ロゴ表示・OCP 接続確認
# =============================================================================

figlet "acm"

oc status
oc version

# OpenShift にログインしているか確認
if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

# =============================================================================
# RHACM セットアップ / クリーンアップ
# =============================================================================

acm_setup() {
    echo "RHACM セットアップ開始..."

    # namespace の作成
    if ! oc get namespace "$ACM_NAMESPACE" >/dev/null 2>&1; then
        oc create namespace "$ACM_NAMESPACE"
    fi

    # OperatorGroup の作成
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${ACM_NAMESPACE}-group
  namespace: ${ACM_NAMESPACE}
spec:
  targetNamespaces:
    - ${ACM_NAMESPACE}
EOF

    # PackageManifest からチャンネル / 最新 CSV を動的解決
    echo -e "${BLUE}advanced-cluster-management の PackageManifest を確認中...${RESET}"
    ACM_CHANNEL=$(oc get packagemanifest advanced-cluster-management -n openshift-marketplace \
        -o jsonpath='{.status.defaultChannel}')
    if [ -z "$ACM_CHANNEL" ]; then
        echo -e "${RED}advanced-cluster-management の PackageManifest が見つかりません。CatalogSource を確認してください。${RESET}"
        return 1
    fi
    ACM_STARTING_CSV=$(oc get packagemanifest advanced-cluster-management -n openshift-marketplace \
        -o jsonpath="{.status.channels[?(@.name==\"${ACM_CHANNEL}\")].currentCSV}")
    echo -e "${GREEN}channel: ${ACM_CHANNEL} / currentCSV: ${ACM_STARTING_CSV}${RESET}"

    # Subscription の作成
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: ${ACM_NAMESPACE}
spec:
  channel: ${ACM_CHANNEL}
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: ${ACM_STARTING_CSV}
EOF

    # CSV が Succeeded になるまで待機
    echo -e "${BLUE}RHACM CSV の Succeeded を待っています...${RESET}"
    for i in $(seq 1 30); do
        MATCH=$(oc get csv -n "$ACM_NAMESPACE" -o json 2>/dev/null | \
            python3 -c "
import json, sys
try:
    items = json.load(sys.stdin).get('items', [])
except Exception:
    items = []
print(sum(1 for i in items if i['metadata']['name'].startswith('advanced-cluster-management.') and i.get('status', {}).get('phase') == 'Succeeded'))
")
        if [ "$MATCH" = "1" ]; then
            echo -e "${GREEN}RHACM CSV が Succeeded になりました。${RESET}"
            break
        fi
        if [ "$i" = "30" ]; then
            echo -e "${RED}タイムアウトしました。CSV の状態を確認してください: oc get csv -n ${ACM_NAMESPACE}${RESET}"
            return 1
        fi
        sleep 60
    done

    # MultiClusterHub の作成
    cat <<EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${ACM_NAMESPACE}
spec: {}
EOF

    # MultiClusterHub が Running になるまで待機
    echo -e "${BLUE}MultiClusterHub の Running を待っています（数分かかることがあります）...${RESET}"
    for i in $(seq 1 40); do
        PHASE=$(oc get multiclusterhub multiclusterhub -n "$ACM_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$PHASE" = "Running" ]; then
            echo -e "${GREEN}MultiClusterHub が Running になりました。${RESET}"
            echo -e "${GREEN}追加クラスタの import は './script/ocpdeploy.sh acm' から行えます。${RESET}"
            return 0
        fi
        if [ "$i" = "40" ]; then
            echo -e "${RED}タイムアウトしました。ステータスを確認してください: oc get multiclusterhub -n ${ACM_NAMESPACE}${RESET}"
            return 1
        fi
        sleep 30
    done
}

acm_cleanup() {
    echo "RHACM クリーンナップ開始..."

    oc delete multiclusterhub multiclusterhub -n "$ACM_NAMESPACE" --ignore-not-found=true

    for csv in $(oc get csv -n "$ACM_NAMESPACE" -o name 2>/dev/null); do
        oc delete "$csv" -n "$ACM_NAMESPACE" --ignore-not-found=true
    done

    oc delete subscription advanced-cluster-management -n "$ACM_NAMESPACE" --ignore-not-found=true

    read -p "本当に ${ACM_NAMESPACE} namespace を削除してもよろしいですか？(yes/no): " DELETE_CONFREM
    if [ "$DELETE_CONFREM" == "yes" ]; then
        oc delete namespace "$ACM_NAMESPACE" --ignore-not-found=true
    fi
}

# =============================================================================
# Step 3: ディスパッチ
# =============================================================================

case "$1" in
    setup)   acm_setup   ;;
    cleanup) acm_cleanup ;;
esac
