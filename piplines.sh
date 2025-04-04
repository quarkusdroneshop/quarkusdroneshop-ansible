#!/bin/bash
# =============================================================================
# Script Name: pipline.sh
# Description: This script sets up the application pipeline.
# Author: Noriaki Mushino
# Date Created: 2025-03-30
# Last Modified: 2025-03-30
# Version: 0.9
#
# Usage:
#   ./deploy.sh setup           - To setup the environment.
#   ./deploy.sh cleanup         - To delete the application.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - The kustomize command is installed and configureds
#   - The tektoncd-cli command is installed and configureds
#   - figlet is installed and configured
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

NAMESPACE="quarkuscoffeeshop-cicd"
DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)
DOMAIN_TOKEN=$(oc whoami -t)

# ロゴの表示
figlet "piplines"

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

setup() {
    echo "セットアップ開始..."
    # Podman イメージの作成とOperatorのインストール
    cd ../tekton-pipelines
    oc new-project quarkuscoffeeshop-cicd
    oc adm policy add-scc-to-user privileged -z pipeline -n  quarkuscoffeeshop-cicd
    kustomize build quarkuscoffeeshop-barista | oc create -f - 
    oc policy add-role-to-user admin system:serviceaccount:quarkuscoffeeshop-cicd:pipeline -n quarkuscoffeeshop-demo  
}

cleanup() {
    echo "クリーンナップ開始..."

    # quarkuscoffeeshop-barista-build
    oc delete pipeline quarkuscoffeeshop-barista-build
    oc delete pipelinerun quarkuscoffeeshop-barista-build-run

    # quarkuscoffeeshop-barista-build
    oc delete pvc quarkuscoffeeshop-barista-maven-settings-pvc --force --grace-period=0
    oc delete pvc quarkuscoffeeshop-barista-shared-workspace-pvc --force --grace-period=0
    oc patch pvc quarkuscoffeeshop-barista-maven-settings-pvc -n quarkuscoffeeshop-cicd -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc patch pvc quarkuscoffeeshop-barista-shared-workspace-pvc -n quarkuscoffeeshop-cicd -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete task git-clone
    oc delete task maven

    oc delete project quarkuscoffeeshop-cicd
}

case "$1" in
    setup)
        setup
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {setup|cleanup}${RESET}"
        exit 1
        ;;
esac