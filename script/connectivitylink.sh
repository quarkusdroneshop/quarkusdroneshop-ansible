#!/bin/bash
# =============================================================================
# Script Name: connectivitylink.sh
# Description: Red Hat Connectivity Link (rhcl-operator) を MCP Gateway として
#              セットアップ・デプロイする。サイト(クラスタ)ごとに論理的に
#              まとまった MCP サーバー群の手前に Gateway/HTTPRoute/AuthPolicy/
#              RateLimitPolicy を適用する。
# Author: Noriaki Mushino
# Date Created: 2026-07-17
# Last Modified: 2026-07-17
# Version: 1.0
#
# Usage:
#   ./script/connectivitylink.sh setup     - rhcl-operator のインストール
#   ./script/connectivitylink.sh deploy    - Gateway/HTTPRoute/AuthPolicy/RateLimitPolicy デプロイ
#   ./script/connectivitylink.sh status    - MCP Gateway ステータス確認
#   ./script/connectivitylink.sh cleanup   - MCP Gateway 関連リソースの削除
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - User is logged into OpenShift
#   - OCP の Gateway API ネイティブサポート
#     (GatewayClass controllerName: openshift.io/gateway-controller/v1) を前提とする。
#     Istio/OSSM の個別インストールは不要。
#   - keycloak namespace に Keycloak (realm: drone-platform) がデプロイ済みであること
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="connectivitylink"
# mcp-server 本体(HTTPRoute の backendRef 先)は datamesh-ai-agent-platform の
# kustomize base (business-api/chat-ui と同じ) が対象とする ai-agent-platform
# namespace にデプロイされる。Gateway とは別 namespace のため、
# ReferenceGrant によるクロス namespace backendRef 許可が必要。
APP_NAMESPACE="ai-agent-platform"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# ロゴの表示
figlet "droneshop"

# ログイン確認
if ! oc whoami &>/dev/null; then
    echo -e "${RED}エラー: OpenShift にログインしていません。${RESET}" >&2
    exit 1
fi
echo -e "${GREEN}OpenShift にログイン済み: $(oc whoami)${RESET}"

DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)

setup() {
    oc new-project "$NAMESPACE"
    oc project "$NAMESPACE"

    echo -e "${BLUE}Red Hat Connectivity Link (rhcl-operator) をインストール中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/connectivitylink-operator.yaml"

    echo -e "${BLUE}Connectivity Link CRD の準備を待っています...${RESET}"
    until oc get crd authpolicies.kuadrant.io &>/dev/null; do sleep 5; done
    echo -e "${GREEN}  → Connectivity Link CRD 準備完了${RESET}"

    # kuadrant-operator は AuthPolicy/RateLimitPolicy を Accepted にはするが、
    # この Kuadrant CR (Authorino/Limitador を実際に起動するトップレベルリソース) が
    # 無いといつまでも Enforced=False (MissingResource: kuadrant is not installed) のまま。
    echo -e "${BLUE}Kuadrant 本体(Authorino/Limitador)を起動中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/kuadrant.yaml"

    echo -e "${BLUE}Kuadrant の準備を待っています...${RESET}"
    until [ "$(oc get kuadrant kuadrant -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; do
        sleep 10
    done
    echo -e "${GREEN}  → Kuadrant Ready${RESET}"
}

deploy() {
    oc project "$NAMESPACE"

    local keycloak_host
    keycloak_host=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -z "$keycloak_host" ]; then
        echo -e "${RED}  keycloak namespace の Route 'keycloak' が見つかりません。先に Keycloak をデプロイしてください。${RESET}"
        exit 1
    fi
    echo -e "${GREEN}  Keycloak Host: ${keycloak_host}${RESET}"
    echo -e "${GREEN}  Cluster Domain: ${DOMAIN_NAME}${RESET}"

    if ! oc get namespace "$APP_NAMESPACE" &>/dev/null; then
        echo -e "${RED}  namespace '$APP_NAMESPACE' が見つかりません。先に ./script/ocpdeploy.sh setup を実行してください。${RESET}"
        exit 1
    fi

    echo -e "${BLUE}MCP Gateway (GatewayClass/Gateway) を適用中...${RESET}"
    sed -e "s/__DOMAIN_NAME__/${DOMAIN_NAME}/g" -e "s/__NAMESPACE__/${NAMESPACE}/g" \
        "$REPO_ROOT/openshift/mcp-gateway.yaml" | oc apply -f -

    echo -e "${YELLOW}  ※ Gateway の TLS には Secret 'mcp-gateway-tls' (namespace: $NAMESPACE) が必要です。${RESET}"
    echo -e "${YELLOW}    未作成の場合は事前に certificate/Secret を用意してください (例: cert-manager 等)。${RESET}"

    echo -e "${BLUE}MCP HTTPRoute を適用中...${RESET}"
    sed -e "s/__DOMAIN_NAME__/${DOMAIN_NAME}/g" -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s/__APP_NAMESPACE__/${APP_NAMESPACE}/g" \
        "$REPO_ROOT/openshift/mcp-httproute.yaml" | oc apply -f -

    echo -e "${BLUE}ReferenceGrant (${APP_NAMESPACE} 側でクロス namespace backendRef を許可) を適用中...${RESET}"
    sed -e "s/__NAMESPACE__/${NAMESPACE}/g" -e "s/__APP_NAMESPACE__/${APP_NAMESPACE}/g" \
        "$REPO_ROOT/openshift/mcp-httproute-referencegrant.yaml" | oc apply -f -

    echo -e "${BLUE}AuthPolicy (Keycloak OIDC) を適用中...${RESET}"
    sed -e "s/__KEYCLOAK_HOST__/${keycloak_host}/g" -e "s/__NAMESPACE__/${NAMESPACE}/g" \
        "$REPO_ROOT/openshift/mcp-gateway-authpolicy.yaml" | oc apply -f -

    echo -e "${BLUE}RateLimitPolicy を適用中...${RESET}"
    sed "s/__NAMESPACE__/${NAMESPACE}/g" "$REPO_ROOT/openshift/mcp-gateway-ratelimitpolicy.yaml" | oc apply -f -

    echo -e "${GREEN}MCP Gateway のデプロイが完了しました。${RESET}"
}

status() {
    oc get kuadrant kuadrant -n openshift-operators
    oc get gatewayclass openshift-gateway
    oc get gateway mcp-gateway -n "$NAMESPACE"
    oc get httproute mcp-server -n "$NAMESPACE"
    oc get authpolicy mcp-gateway-auth -n "$NAMESPACE"
    oc get ratelimitpolicy mcp-gateway-ratelimit -n "$NAMESPACE"
}

cleanup() {
    oc delete ratelimitpolicy mcp-gateway-ratelimit -n "$NAMESPACE" --ignore-not-found=true
    oc delete authpolicy mcp-gateway-auth -n "$NAMESPACE" --ignore-not-found=true
    oc delete httproute mcp-server -n "$NAMESPACE" --ignore-not-found=true
    oc delete gateway mcp-gateway -n "$NAMESPACE" --ignore-not-found=true
    oc delete gatewayclass openshift-gateway --ignore-not-found=true
    oc delete referencegrant mcp-gateway-to-mcp-server -n "$APP_NAMESPACE" --ignore-not-found=true
    echo -e "${GREEN}MCP Gateway 関連リソースを削除しました(rhcl-operator 本体は削除していません)。${RESET}"
}

case "${1:-}" in
    setup)
        setup
        ;;
    deploy)
        deploy
        ;;
    status)
        status
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: ${1:-}${RESET}"
        echo -e "${RED}使用方法: $0 {setup|deploy|status|cleanup}${RESET}"
        exit 1
        ;;
esac
