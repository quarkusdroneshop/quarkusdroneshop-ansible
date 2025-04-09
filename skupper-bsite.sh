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
#   - skupper is installed and configured
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
    #oc create namespace skupper-b --dry-run=client -o yaml | oc apply -f -
    oc project quarkuscoffeeshop-demo
    # Skupper 初期化（内部 TLS・ルーティング対応）
    skupper init --router-mode interior --enable-console --enable-flow-collector --console-auth internal --console-user admin --console-password skupper

    # 確認
    skupper status

    # TOKEN/LINKの作成
    skupper token create skupper-token-b.yaml
    read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
    if [ "$LINK_CONFREM" != "yes" ]; then
        echo -e "${YELLOW}処理を終了します。${RESET}"
        exit 1
    fi
    # Linkの作成
    skupper link create skupper-token-a.yaml --name quarkuscoffeeshop-bsite --platform kubernetes --cost 10
    skupper link status
    # KAFKA,PostgreSQLの公開
    skupper expose service cafe-cluster-kafka-bootstrap --port 9092 --protocol tcp --address external-kafka-cafe-b-bootstrap
    skupper expose service postgres --port 5432 --protocol tcp --address postgres-a-skupper
    oc apply -f openshift/kafka-mm2-b-site.yaml
    oc apply -f openshift/kafka-mm2-b-setting.yaml
}

topic() {
    oc get kafkatopics.kafka.strimzi.io -n quarkuscoffeeshop-demo

    for topic in $(oc get kafkatopics.kafka.strimzi.io -n quarkuscoffeeshop-demo -o name); do
     oc delete $topic -n quarkuscoffeeshop-demo
    done
}

cleanup() {
    oc delete kafkamirrormaker2 --all -n quarkuscoffeeshop-demo
    oc delete all -l skupper.io/component
    oc delete configmap -l skupper.io/component
    oc delete secret -l skupper.io/component
    oc delete svc skupper
    oc delete svc skupper-prometheus
    oc delete svc skupper-router
    oc delete svc skupper-router-local
    oc delete route skupper
    oc delete route skupper-edge
    oc delete route skupper-inter-router
    oc delete route claims
}

case "$1" in
    deploy)
        deploy
        ;;
    topic)
        topic
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {deploy|resettopic|cleanup}${RESET}"
        exit 1
        ;;
esac
