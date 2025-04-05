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

CICD_NAMESPACE="quarkuscoffeeshop-cicd"
DEMO_NAMESPACE="quarkuscoffeeshop-demo"
DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)
DOMAIN_TOKEN=$(oc whoami -t)

# ロゴの表示
figlet "coffeeshop"

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
    # オペレータのインストール
    # プロジェクトが存在するか確認
    if oc get project "$CICD_NAMESPACE" > /dev/null 2>&1; then
      read -p "Operatorのインストールを実行しますか？ (y/N): " answer
      if [[ "$answer" =~ ^[Yy]$ ]]; then
          oc apply -f openshift/openshift-pipline.yaml
          sleep 30        
      fi
    else
      oc new-project $CICD_NAMESPACE
      oc apply -f openshift/openshift-pipline.yaml
      sleep 30
    fi

    # 共通設定
    oc apply -f openshift/buildah-clustertask.yaml
    oc apply -f openshift/openshift-client-clustertask.yaml
    oc adm policy add-scc-to-user privileged -z pipeline -n  $CICD_NAMESPACE
    
    # quarkuscoffeeshop-barista Pipline の設定
    cd ../tekton-pipelines
    kustomize build quarkuscoffeeshop-barista | oc create -f - 

    # プロジェクトが存在するか確認
    oc get project "$DEMO_NAMESPACE" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
      oc new-project "$DEMO_NAMESPACE"
      oc policy add-role-to-user admin system:serviceaccount:quarkuscoffeeshop-cicd:pipeline -n $DEMO_NAMESPACE
    fi
}

cleanup() {
    echo "クリーンナップ開始..."

    # quarkuscoffeeshop-barista-build
    oc delete pipeline quarkuscoffeeshop-barista-build
    oc delete pipelinerun quarkuscoffeeshop-barista-build-run

    # quarkuscoffeeshop-barista-build
    oc delete pvc quarkuscoffeeshop-barista-maven-settings-pvc --force --grace-period=0
    oc delete pvc quarkuscoffeeshop-barista-shared-workspace-pvc --force --grace-period=0
    oc patch pvc quarkuscoffeeshop-barista-maven-settings-pvc -n $CICD_NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc patch pvc quarkuscoffeeshop-barista-shared-workspace-pvc -n $CICD_NAMESPACE -p '{"metadata":{"finalizers":[]}}' --type=merge
    oc delete task git-clone
    oc delete task maven

    oc delete project $CICD_NAMESPACE
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