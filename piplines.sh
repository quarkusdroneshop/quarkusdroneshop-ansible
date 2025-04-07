#!/bin/bash
# =============================================================================
# Script Name: pipline.sh
# Description: This script sets up the application pipeline.
# Author: Noriaki Mushino
# Date Created: 2025-03-30
# Last Modified: 2025-04-06
# Version: 1.1
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
    
    cd ../tekton-pipelines
    # quarkuscoffeeshop-barista Pipline の設定
    #kustomize build quarkuscoffeeshop-barista | oc create -f - 
    # quarkuscoffeeshop-kitchen Pipline の設定
    #kustomize build quarkuscoffeeshop-kitchen | oc create -f - 
    # quarkuscoffeeshop-counter Pipline の設定
    #kustomize build quarkuscoffeeshop-counter | oc create -f - 
    # quarkuscoffeeshop-web Pipline の設定
    #kustomize build quarkuscoffeeshop-web | oc create -f - 
    # quarkuscoffeeshop-inventory Pipline の設定
    #kustomize build quarkuscoffeeshop-inventory | oc create -f - 
    # quarkuscoffeeshop-homeofficebackend Pipline の設定
    #kustomize build quarkuscoffeeshop-homeofficebackend | oc create -f - 
    # quarkuscoffeeshop-homeoffice-ui Pipline の設定
    #kustomize build quarkuscoffeeshop-homeoffice-ui | oc create -f - 
    # quarkuscoffeeshop-customermocker Pipline の設定
    #kustomize build quarkuscoffeeshop-customermocker | oc create -f - 
    
    OPTIONS=(
    "barista"
    "kitchen"
    "counter"
    "web"
    "inventory"
    "homeofficebackend"
    "homeoffice-ui"
    "customermocker"
    "all"
    "cancel"
    )

    PS3="実行したい Pipeline を選択してください（番号）: "

    select opt in "${OPTIONS[@]}"; do
        case $opt in
            "barista"|"kitchen"|"counter"|"web"|"inventory"|"homeofficebackend"|"homeoffice-ui"|"customermocker")
                echo "🔧 実行中: $opt"
                kustomize build "quarkuscoffeeshop-$opt" | oc create -f -
                ;;
            "all")
                for d in barista kitchen counter web inventory homeofficebackend homeoffice-ui customermocker; do
                    echo "🔁 実行中: $d"
                    kustomize build "quarkuscoffeeshop-$d" | oc create -f -
                done
                ;;
            "cancel")
                echo "終了します"
                break
                ;;
            *)
                echo "無効な選択です。コマンドを確認してください。"
                ;;
        esac
    done

    # プロジェクトが存在するか確認
    oc get project "$DEMO_NAMESPACE" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
      oc new-project "$DEMO_NAMESPACE"
    fi
    oc policy add-role-to-user admin system:serviceaccount:quarkuscoffeeshop-cicd:pipeline -n $DEMO_NAMESPACE
}

setupdemo() {
    oc apply -f openshift/coffeeshop-configmap.yaml
    oc apply -f openshift/coffeeshop-sub-configmap.yaml
    oc policy add-role-to-user admin system:serviceaccount:quarkuscoffeeshop-cicd:pipeline
}

cleanup() {
    echo "クリーンナップ開始..."
    for pvc in $(oc get pvc -n "$CICD_NAMESPACE" -o name); do
        oc patch "$pvc" -n "$CICD_NAMESPACE" --type=merge -p '{"metadata":{"finalizers":[]}}'
    done
    oc delete task push-app    
    oc delete task git-clone
    oc delete task maven
    oc delete project $CICD_NAMESPACE
}

case "$1" in
    setup)
        setup
        ;;
    setupdemo)
        setupdemo
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