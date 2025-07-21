#!/bin/bash
# =============================================================================
# Script Name: pipline.sh
# Description: This script sets up the application pipeline.
# Author: Noriaki Mushino
# Date Created: 2025-03-30
# Last Modified: 2025-07-21
# Version: 1.2
#
# Usage:
#   ./deploy.sh setup           - To setup the environment.
#   ./deploy.sh cleanup         - To delete the application.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

RHDH_NAMESPACE="quarkusdroneshop-rhdh"
DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)
DOMAIN_TOKEN=$(oc whoami -t)

# ロゴの表示
figlet "droneshop"

# 前処理
oc status
oc version

# 色を変数に格納
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

# OpenShift にログインしているか確認
if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

# OpenShift にログインしているか確認
echo -e "${YELLOW}Domain Name: $DOMAIN_NAME${RESET}"
echo -e "${YELLOW}Domain Token: $DOMAIN_TOKEN${RESET}"
echo -e "-------------------------------------------"
read -p "指定されたドメインで間違いないですか？(yes/no): " DOMAIN_CONFREM
if [ "$DOMAIN_CONFREM" != "yes" ]; then
    echo -e "${RED}処理を中断します。${RESET}"
    exit 1
fi

deploy() {

    echo "デプロイの開始..."
    # 共通設定）
    oc apply -f openshift/developer-hub.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/app-config-rhdh.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/secrets-rhdh.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/dynamic-plugins-rhdh.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/catalog-info.yaml -n quarkusdroneshop-rhdh

}

setup() {
    
    # Piplineオペレータの作成
    oc new-project $RHDH_NAMESPACE
    oc apply -f openshift/developer-hub-operator.yaml -n rhdh-operator
    sleep 40

}

cleanup() {
    
    echo "クリーンナップ開始..."
    
    ## 共通タスクの削除
    oc delete -f openshift/developer-hub.yaml -n quarkusdroneshop-rhdh   
    oc delete -f openshift/app-config-rhdh.yaml -n quarkusdroneshop-rhdh
    oc delete -f openshift/secrets-rhdh.yaml -n quarkusdroneshop-rhdh
    oc delete -f openshift/dynamic-plugins-rhdh.yaml -n quarkusdroneshop-rhdh
    oc delete -f openshift/catalog-info.yaml -n quarkusdroneshop-rhdh
    
    ## CICDプロジェクトの削除
    oc delete project $RHDH_NAMESPACE

}

case "$1" in
    setup)
        setup
        ;;
    deploy)
        deploy
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {setup|deploy|cleanup}${RESET}"
        exit 1
        ;;
esac