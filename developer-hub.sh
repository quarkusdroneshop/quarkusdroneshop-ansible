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

    DOMAIN_URL=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    DOMAIN_APIURL=$(oc whoami --show-server)

    # シークレットの文字列を実行環境クラスタ名に置換
    sed -i '' -E "s|https://backstage-developer-hub-quarkusdroneshop-rhdh\.[^[:space:]\"]*|https://backstage-developer-hub-quarkusdroneshop-rhdh.${DOMAIN_URL}|g" openshift/secrets-rhdh.yaml
    sed -i '' -E "s|https://openshift-gitops-server-openshift-gitops\.[^[:space:]\"]*|https://openshift-gitops-server-openshift-gitops.${DOMAIN_URL}|g" openshift/secrets-rhdh.yaml
    sed -i '' -E "s|https://api\.cluster-[^:]+:6443|${DOMAIN_APIURL}|g" openshift/secrets-rhdh.yaml

    echo "デプロイの開始..."
    # 各種設定
    oc apply -f openshift/developer-hub.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/app-config-rhdh.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/secrets-rhdh.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/dynamic-plugins-rhdh.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/catalog-info.yaml -n quarkusdroneshop-rhdh
    oc apply -f openshift/k8-plugin-sa.yaml -n quarkusdroneshop-rhdh

}

custom() {
    #REGISTRY="image-registry-openshift-image-registry.apps.cluster-2x987.2x987.sandbox1936.opentlc.com"                                                                       ✘ 1 
    #PROJECT="quarkusdroneshop-rhdh"
    #IMAGE_NAME="developer-hub"
    #TAG="latest"
    
    #oc new-build --name=developer-hub --binary --strategy=docker -n quarkusdroneshop-rhdh
    #oc create route edge --service=image-registry -n openshift-image-registry
    #oc registry login
    #REGISTRY_HOST=$(oc get route -n openshift-image-registry image-registry -o jsonpath='{.spec.host}')
    #FULL_IMAGE="${REGISTRY_HOST}/quarkusdroneshop-rhdh/developer-hub:latest -n quarkusdroneshop-rhdh"
    #docker build -t "${FULL_IMAGE}" .
    #docker push "${FULL_IMAGE}"
    #podman build --no-cache -f Containerfile -t backstage-plugin . 
    #cd backstage
    #yarn tsc
    #yarn build
    #oc start-build developer-hub --from-dir=. --follow

}

setup() {
    
    # Piplineオペレータの作成
    oc new-project $RHDH_NAMESPACE
    sleep 40
    oc apply -f openshift/developer-hub-operator.yaml -n rhdh-operator

}

cleanup() {
    
    echo "クリーンナップ開始..."
    
    ## 共通タスクの削除
    oc delete -f openshift/developer-hub.yaml -n quarkusdroneshop-rhdh   
    oc delete -f openshift/app-config-rhdh.yaml -n quarkusdroneshop-rhdh
    oc delete -f openshift/secrets-rhdh.yaml -n quarkusdroneshop-rhdh
    oc delete -f openshift/dynamic-plugins-rhdh.yaml -n quarkusdroneshop-rhdh
    oc delete -f openshift/catalog-info.yaml -n quarkusdroneshop-rhdh
    oc delete -f openshift/k8s-plugin-sa.yaml -n quarkusdroneshop-rhdh
    
    ## CICDプロジェクトの削除
    oc delete project $RHDH_NAMESPACE

}

case "$1" in
    deploy)
        deploy
        ;;
    custom)
        custom
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {deploy|custom|cleanup}${RESET}"
        exit 1
        ;;
esac