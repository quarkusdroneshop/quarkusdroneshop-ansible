#!/bin/bash
# =============================================================================
# Script Name: skupper-and-kafkacluster.sh
# Description: This script deploys the skupper to OpenShift and verifies the setup.
# Author: Noriaki Mushino
# Date Created: 2025-04-06
# Last Modified: 2025-04-19
# Version: 1.0
#
# Usage:
#   ./skupper-<<site>>.sh setup           - To setup the skupper and kafkacluster.
#   ./skupper-<<site>>.sh deploy          - To deploy the skupper and kafkacluster.
#   ./skupper-<<site>>.sh retoken         - To retoken the skupper and kafkacluster.
#   ./skupper-<<site>>.sh status          - To status the skupper and kafkacluster.
#   ./skupper-<<site>>.sh cleanup         - To delete the skupper and kafkacluster.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - skupper(innerconect2.0) is installed and configured
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

NAMESPACE="quarkusdroneshop-demo"
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

    oc project "$NAMESPACE"

    # Skupper 初期化
    oc apply -f openshift/skupper-operator.yaml -n "$NAMESPACE"
    sleep 60
    
    read -p "どのサイトを構築しますか？(A/B/C): " SITE_CONFREM
    if [ "$SITE_CONFREM" = "A" ]; then

        # Site作成
        skupper site create skupper-asite
        skupper site update --enable-link-access -n "$NAMESPACE"

        # Siteのステータス確認
        skupper site status

        # TOKEN/LINKの作成
        skupper token issue skupper-token-a.yaml
        
        # LINK作成確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem skupper-token-b.yaml -n "$NAMESPACE"
        skupper token redeem skupper-token-c.yaml -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-asite --host external-cafe-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper connector create external-cafe-cluster-kafka-asite 9094 --selector app.kubernetes.io/part-of=strimzi-cafe-cluster -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-csite 9094 -n "$NAMESPACE"

        skupper listener create external-cafe-cluster-postgres-asite --host external-cafe-cluster-postgres-asite 5432 -n "$NAMESPACE"
        skupper connector create external-cafe-cluster-postgres-asite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"

        # KafkaClusterの再作成
        oc apply -f openshift/cafe-cluster-kafka-bootstrap-listeners.yaml -n "$NAMESPACE"

        # MirrorMakerの設定
        oc apply -f openshift/kafka-mm2-a-site.yaml -n "$NAMESPACE"


    elif [ "$SITE_CONFREM" = "B" ]; then

        # Siteの作成
        skupper site create skupper-bsite
        skupper site update --enable-link-access -n "$NAMESPACE"

        # Siteのステータス確認
        skupper site status

        # TOKEN/LINKの作成
        skupper token issue skupper-token-b.yaml
        
        # LINK作成の確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem skupper-token-a.yaml -n "$NAMESPACE"
        skupper token redeem skupper-token-c.yaml -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-bsite --host external-cafe-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper connector create external-cafe-cluster-kafka-bsite 9094 --selector app.kubernetes.io/part-of=strimzi-cafe-cluster -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-csite 9094 -n "$NAMESPACE"

        skupper listener create external-cafe-cluster-postgres-bsite --host external-cafe-cluster-postgres-bsite 5432 -n "$NAMESPACE"
        skupper connector create external-cafe-cluster-postgres-bsite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"
        
        # KafkaClusterの再作成
        oc apply -f openshift/cafe-cluster-kafka-bootstrap-listeners.yaml -n "$NAMESPACE"

        # MirrorMakerの設定
        oc apply -f openshift/kafka-mm2-b-site.yaml -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "C" ]; then

        # Siteの作成
        skupper site create skupper-csite
        skupper site update --enable-link-access -n "$NAMESPACE"

        # Siteのステータス確認
        skupper site status

        # TOKEN/LINKの作成
        skupper token issue skupper-token-c.yaml
        
        # LINK作成の確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem skupper-token-a.yaml -n "$NAMESPACE"
        skupper token redeem skupper-token-b.yaml -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-csite --host external-cafe-cluster-kafka-csite 9094 -n "$NAMESPACE"
        skupper connector create external-cafe-cluster-kafka-csite 9094 --selector app.kubernetes.io/part-of=strimzi-cafe-cluster -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-kafka-bsite 9094 -n "$NAMESPACE"
       
        skupper listener create external-cafe-cluster-postgres-csite --host external-cafe-cluster-postgres-csite 5432 -n "$NAMESPACE"
        skupper connector create external-cafe-cluster-postgres-csite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-postgres-asite 5432 -n "$NAMESPACE"
        skupper listener create external-cafe-cluster-postgres-bsite 5432 -n "$NAMESPACE"

                
        # KafkaClusterの再作成
        oc apply -f openshift/cafe-cluster-kafka-bootstrap-listeners.yaml -n "$NAMESPACE"

        # MirrorMakerの設定
        oc apply -f openshift/kafka-mm2-c-site.yaml -n "$NAMESPACE"

    fi

    # LINKとサービスのステータス確認
    sleep 10
    skupper link status
    skupper listener status
    skupper connector status

}

retoken() {
    read -p "どのサイトでLINKを再作成しますか？(A/B/C): " SITE_CONFREM
    if [ "$SITE_CONFREM" = "A" ]; then

        # Tokenの作り直し
        skupper token issue skupper-token-a.yaml
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem skupper-token-b.yaml -n "$NAMESPACE"
        skupper token redeem skupper-token-c.yaml -n "$NAMESPACE"
        # Tokenの作り直し後のステータス確認
        skupper site status
        skupper link status
        skupper listener status
        skupper connector status

    elif [ "$SITE_CONFREM" = "B" ]; then

        # Tokenの作り直し
        skupper token issue skupper-token-b.yaml
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem skupper-token-a.yaml -n "$NAMESPACE"
        skupper token redeem skupper-token-c.yaml -n "$NAMESPACE"
        # Tokenの作り直し後のステータス確認
        skupper site status
        skupper link status
        skupper listener status
        skupper connector status

    elif [ "$SITE_CONFREM" = "C" ]; then

        # Tokenの作り直し
        skupper token issue skupper-token-c.yaml
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem skupper-token-a.yaml -n "$NAMESPACE"
        skupper token redeem skupper-token-b.yaml -n "$NAMESPACE"
        # Tokenの作り直し後のステータス確認
        skupper site status
        skupper link status
        skupper listener status
        skupper connector status

    fi
}

cleanup() {

    # Site含む全部削除
    oc delete kafkamirrormaker2 --all -n "$NAMESPACE"
    oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
    skupper listener delete external-cafe-cluster-kafka-asite -n "$NAMESPACE"
    skupper listener delete external-cafe-cluster-kafka-bsite -n "$NAMESPACE"
    skupper listener delete external-cafe-cluster-kafka-csite -n "$NAMESPACE"
    skupper connector delete external-cafe-cluster-kafka-asite -n "$NAMESPACE"
    skupper connector delete external-cafe-cluster-kafka-bsite -n "$NAMESPACE"
    skupper connector delete external-cafe-cluster-kafka-csite -n "$NAMESPACE"

    skupper listener delete external-cafe-cluster-postgres-asite -n quarkusdroneshop-demo
    skupper connector delete external-cafe-cluster-postgres-asite -n quarkusdroneshop-demo
    skupper listener delete external-cafe-cluster-postgres-bsite -n quarkusdroneshop-demo
    skupper connector delete external-cafe-cluster-postgres-bsite -n quarkusdroneshop-demo
    skupper listener delete external-cafe-cluster-postgres-csite -n quarkusdroneshop-demo
    skupper connector delete external-cafe-cluster-postgres-csite -n quarkusdroneshop-demo

    skupper site delete skupper-asite
    skupper site delete skupper-bsite
    skupper site delete skupper-csite
    oc delete all -l skupper.io/component
    oc delete configmap -l skupper.io/component
    oc delete secret -l skupper.io/component
}

status() {

    # 様々なステータス確認
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