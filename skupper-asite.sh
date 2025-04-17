#!/bin/bash
# =============================================================================
# Script Name: deploy.sh
# Description: This script deploys the skupper to OpenShift and verifies the setup.
# Author: Noriaki Mushino
# Date Created: 2025-04-06
# Last Modified: 2025-04-07
# Version: 0.3
#
# Usage:
#   ./skupper-<<site>>.sh setup           - To setup the skupper.
#   ./skupper-<<site>>.sh cleanup         - To delete the skupper.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - skupper(innerconect2.0) is installed and configured
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

NAMESPACE="kafka-source"
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

deploy() {
        
    # Namespace（例: "skupper-a"）に切り替え or 作成
    #oc create namespace skupper-a --dry-run=client -o yaml | oc apply -f -
    oc project quarkuscoffeeshop-demo
    # Skupper 初期化（内部 TLS・ルーティング対応）
    
    #oc apply -f https://raw.githubusercontent.com/skupperproject/skupper/refs/heads/1.8/api/types/crds/skupper_cluster_policy_crd.yaml
    #oc apply -f openshift/skupper-policy.yaml
    
    oc apply -f openshift/skupper-operator.yaml -n quarkuscoffeeshop-demo
    #skupper site create --console-auth internal --console-user admin --console-password skupper
    #skupper site create asite --console-auth internal --console-user admin --console-password skupper --enable-link-access
    skupper site create skupper-asite
    skupper site update --enable-link-access -n quarkuscoffeeshop-demo 

    # 確認
    skupper site status

    # TOKEN/LINKの作成
    skupper token issue skupper-token-a.yaml

    # ラベル付与バグ回避
    oc label pod -n quarkuscoffeeshop-demo cafe-cluster-cafe-cluster-brokers-0 site.quarkuscoffeeshop/kafka-cluster=asite --overwrite
    oc label pod -n quarkuscoffeeshop-demo cafe-cluster-cafe-cluster-brokers-1 site.quarkuscoffeeshop/kafka-cluster=asite --overwrite
    oc label pod -n quarkuscoffeeshop-demo cafe-cluster-cafe-cluster-brokers-2 site.quarkuscoffeeshop/kafka-cluster=asite --overwrite
    oc label pod -n quarkuscoffeeshop-demo cafe-cluster-cafe-cluster-controllers-3 site.quarkuscoffeeshop/kafka-cluster=asite --overwrite
    oc label pod -n quarkuscoffeeshop-demo cafe-cluster-cafe-cluster-controllers-4 site.quarkuscoffeeshop/kafka-cluster=asite --overwrite
    oc label pod -n quarkuscoffeeshop-demo cafe-cluster-cafe-cluster-controllers-5 site.quarkuscoffeeshop/kafka-cluster=asite --overwrite
    oc label svc -n quarkuscoffeeshop-demo cafe-cluster-kafka-external-plain site.quarkuscoffeeshop/kafka-cluster=asite --overwrite
    
    read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
    if [ "$LINK_CONFREM" != "yes" ]; then
        echo -e "${YELLOW}処理を終了します。${RESET}"
        exit 1
    fi
    # Linkの作成
    oc delete accesstokens.skupper.io --all -n quarkuscoffeeshop-demo
    skupper token redeem skupper-token-b.yaml -n quarkuscoffeeshop-demo
    skupper listener create external-cafe-cluster-kafka-asite --host external-cafe-cluster-kafka-asite 9094 -n quarkuscoffeeshop-demo
    skupper connector create external-cafe-cluster-kafka-asite 9094 --selector site.quarkuscoffeeshop/kafka-cluster=asite -n quarkuscoffeeshop-demo
    skupper listener create external-cafe-cluster-kafka-bsite 9094 -n quarkuscoffeeshop-demo

    sleep 10
    skupper link status
    skupper listener status
    skupper connector status

    oc apply -f openshift/cafe-cluster-kafka-bootstrap-listeners.yaml -n quarkuscoffeeshop-demo
    #oc apply -f openshift/kafka-mm2-a-site.yaml
    #oc apply -f openshift/kafka-mm2-a-setting.yaml
}

cleanup() {
    oc delete kafkamirrormaker2 --all -n quarkuscoffeeshop-demo
    oc delete accesstokens.skupper.io --all -n quarkuscoffeeshop-demo
    skupper listener delete external-cafe-cluster-kafka-asite -n quarkuscoffeeshop-demo
    skupper listener delete external-cafe-cluster-kafka-bsite -n quarkuscoffeeshop-demo
    skupper connector delete external-cafe-cluster-kafka-asite -n quarkuscoffeeshop-demo
    skupper site delete skupper-asite
    
    ####
    skupper listener delete cafe-cluster-cafe-cluster-brokers-b-0 -n quarkuscoffeeshop-demo
    skupper listener delete cafe-cluster-cafe-cluster-brokers-b-1 -n quarkuscoffeeshop-demo
    skupper listener delete cafe-cluster-cafe-cluster-brokers-b-2 -n quarkuscoffeeshop-demo


    #あとで整理
    oc delete all -l skupper.io/component
    oc delete configmap -l skupper.io/component
    oc delete secret -l skupper.io/component
}

retoken() {
    skupper token issue skupper-token-a.yaml
    oc delete accesstokens.skupper.io --all -n quarkuscoffeeshop-demo
    skupper token redeem skupper-token-b.yaml -n quarkuscoffeeshop-demo
    skupper site status
    skupper link status
    skupper listener status
    skupper connector status
}

status() {
    skupper site status
    skupper link status
    skupper listener status
    skupper connector status
}

case "$1" in
    retoken)
        retoken
        ;;
    status)
        status
        ;;
    deploy)
        deploy
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {deploy|retoken|status|cleanup}${RESET}"
        exit 1
        ;;
esac