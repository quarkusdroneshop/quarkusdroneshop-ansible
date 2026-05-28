#!/bin/bash
# =============================================================================
# Script Name: developer-hub.sh
# Description: This script sets up the developer-hub image and application skeleton.
# Author: Noriaki Mushino
# Date Created: 2025-03-30
# Last Modified: 2026-03-07
# Version: 1.5
#
# Usage:
#   ./developer-hub.sh setup           - To setup the environment.
#   ./developer-hub.sh cleanup         - To delete the application.
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

    oc project $RHDH_NAMESPACE

    DOMAIN_URL=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    DOMAIN_APIURL=$(oc whoami --show-server)

    # シークレットの文字列を実行環境クラスタ名に置換
    sed -i '' -E "s|https://backstage-developer-hub-quarkusdroneshop-rhdh\.[^[:space:]\"]*|https://backstage-developer-hub-quarkusdroneshop-rhdh.${DOMAIN_URL}|g" openshift/secrets-rhdh.yaml
    sed -i '' -E "s|https://openshift-gitops-server-openshift-gitops\.[^[:space:]\"]*|https://openshift-gitops-server-openshift-gitops.${DOMAIN_URL}|g" openshift/secrets-rhdh.yaml
    sed -i '' -E "s|https://api\.cluster-[^:]+:6443|${DOMAIN_APIURL}|g" openshift/secrets-rhdh.yaml

    echo "デプロイの開始..."
    # 各種設定
    oc apply -f openshift/developer-hub.yaml -n $RHDH_NAMESPACE
    oc apply -f openshift/app-config-rhdh.yaml -n $RHDH_NAMESPACE
    oc apply -f openshift/secrets-rhdh.yaml -n $RHDH_NAMESPACE
    oc apply -f openshift/dynamic-plugins-rhdh.yaml -n $RHDH_NAMESPACE
    oc apply -f openshift/catalog-info.yaml -n $RHDH_NAMESPACE
    oc apply -f openshift/k8-plugin-sa.yaml -n $RHDH_NAMESPACE

    # CICD設定
    # oc apply -f openshift/developer-hub-cicd.yaml -n quarkusdroneshop-cicd
    # oc expose svc el-reward-listener -n quarkusdroneshop-cicd
    
    oc adm policy add-cluster-role-to-user edit \
    -z rhdh-k8s-plugin \
    -n $RHDH_NAMESPACE

    oc adm policy add-cluster-role-to-user view \
    -z rhdh-k8s-plugin \
    -n $RHDH_NAMESPACE

}

customimage() {
    #REGISTRY="image-registry-openshift-image-registry.apps.cluster-2x987.2x987.sandbox1936.opentlc.com"                                                                       ✘ 1 
    #PROJECT="quarkusdroneshop-rhdh"
    #IMAGE_NAME="developer-hub"
    #TAG="latest"

    oc project $RHDH_NAMESPACE

    # OpenShift上の古いリソースを削除
    oc delete buildconfig rhdh-hub-custom --ignore-not-found
    oc delete imagestream rhdh-hub-custom --ignore-not-found
    # oc delete secret redhat-pull-secret --ignore-not-found
    # oc delete secret dynamic-plugins-registry-auth -n $RHDH_NAMESPACE

    # Scopioの認証情報をセットする
    oc create secret generic redhat-pull-secret \
    --from-file=.dockerconfigjson=$HOME/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson \
    -n $RHDH_NAMESPACE \
    --dry-run=client -o yaml | oc apply -f -

    # oc create secret generic dynamic-plugins-registry-auth \
    # --from-file=config.json=$HOME/.docker/config.json \
    # --type=kubernetes.io/dockerconfigjson \
    # -n $RHDH_NAMESPACE

    # Podに認証情報をリンクする
    oc secrets link default redhat-pull-secret --for=pull
    oc secrets link builder redhat-pull-secret --for=pull

    oc policy add-role-to-user edit \
        system:serviceaccount:quarkusdroneshop-rhdh:$(oc get deploy backstage-developer-hub -n quarkusdroneshop-rhdh -o jsonpath='{.spec.template.spec.serviceAccountName}') \
        -n quarkusdroneshop-cicd

    # RHDHのイメージを取得する
    oc get is rhdh-hub-rhel9 >/dev/null 2>&1 || \
    oc import-image rhdh-hub-rhel9:1.9 \
    --from=registry.redhat.io/rhdh/rhdh-hub-rhel9:1.9 \
    --confirm

    # 新規ビルド設定
    oc new-build \
        --name=rhdh-hub-custom \
        --binary \
        --strategy=docker \
        --to=rhdh-hub-custom:latest

    # ビルドファイルを指定
    oc patch bc rhdh-hub-custom \
    -p '{"spec":{"strategy":{"dockerStrategy":{"dockerfilePath":"dockerfile-rhdh","noCache":true}}}}'

    # ビルド開始
    cd ../developerhub-skeleton/developerhub
    oc start-build rhdh-hub-custom --from-dir=. --follow

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
    oc delete -f openshift/developer-hub.yaml -n $RHDH_NAMESPACE  
    oc delete -f openshift/app-config-rhdh.yaml -n $RHDH_NAMESPACE
    oc delete -f openshift/secrets-rhdh.yaml -n $RHDH_NAMESPACE
    oc delete -f openshift/dynamic-plugins-rhdh.yaml -n $RHDH_NAMESPACE
    oc delete -f openshift/catalog-info.yaml -n $RHDH_NAMESPACE
    oc delete -f openshift/k8s-plugin-sa.yaml -n $RHDH_NAMESPACE
    
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
    customimage)
        customimage
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {setup|deploy|customimage|cleanup}${RESET}"
        exit 1
        ;;
esac