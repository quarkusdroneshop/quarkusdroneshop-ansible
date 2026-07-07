#!/bin/bash
# =============================================================================
# Script Name: skupper.sh
# Description: This script deploys the skupper to OpenShift and verifies the setup.
# Author: Noriaki Mushino
# Date Created: 2025-04-06
# Last Modified: 2025-07-16
# Version: 1.3
#
# Usage:
#   ./skupper.sh setup           - To setup the skupper and kafkacluster.
#   ./skupper.sh deploy          - To deploy the skupper and kafkacluster.
#   ./skupper.sh retoken         - To retoken the skupper and kafkacluster.
#   ./skupper.sh status          - To status the skupper and kafkacluster.
#   ./skupper.sh cleanup         - To delete the skupper and kafkacluster.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - skupper(innerconect2.0) is installed and configured
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# quarkusdroneshop-demo が見つからない場合、確認の上 openmetadata にフォールバックする
if ! oc get project "$NAMESPACE" &>/dev/null; then
    echo -e "${YELLOW}名前空間 '${NAMESPACE}' が見つかりません。${RESET}"
    read -p "代わりに 'openmetadata' 名前空間を使用してよいですか？(yes/no): " NAMESPACE_FALLBACK_CONFIRM
    if [ "$NAMESPACE_FALLBACK_CONFIRM" = "yes" ]; then
        NAMESPACE="openmetadata"
        echo -e "${GREEN}名前空間を 'openmetadata' に切り替えました。${RESET}"
    else
        echo -e "${RED}処理を中断します。${RESET}" >&2
        exit 1
    fi
fi

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

    # Skupper Operator のインストール（AllNamespaces モード）
    echo -e "${BLUE}Skupper Operator をインストール中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/skupper-operator.yaml"

    # Skupper CRD の準備待ち
    echo -e "${BLUE}Skupper CRD の準備を待っています...${RESET}"
    until oc get crd sites.skupper.io &>/dev/null; do sleep 5; done
    echo -e "${GREEN}  → Skupper CRD 準備完了${RESET}"

    read -p "どのサイトを構築しますか？(A/B/C/DH): " SITE_CONFREM
    if [ "$SITE_CONFREM" = "A" ]; then

        # Site作成
        skupper site create skupper-asite
        skupper site update --enable-link-access -n "$NAMESPACE"

        # Siteのステータス確認
        skupper site status

        # TOKEN/LINKの作成
        skupper token issue "$REPO_ROOT/skupper-token-a.yaml" -r 3
        
        # LINK作成確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-asite --host external-shop-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-kafka-asite 9094 --selector app.kubernetes.io/part-of=strimzi-shop-cluster -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite 9094 -n "$NAMESPACE"

        skupper listener create external-shop-cluster-postgres-asite --host external-shop-cluster-postgres-asite 5432 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-postgres-asite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"
        skupper connector create external-shop-cluster-apicurio 8080 --selector app=droneshop-apicurioregistry-kafkasql -n "$NAMESPACE"

        # KafkaClusterの再作成 (Skupper advertisedHost を asite の FQDN に設定)
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-asite.yaml" -n "$NAMESPACE"

        # MirrorMakerの設定
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-a-site.yaml" -n "$NAMESPACE"


    elif [ "$SITE_CONFREM" = "B" ]; then

        # Siteの作成
        skupper site create skupper-bsite
        skupper site update --enable-link-access -n "$NAMESPACE"

        # Siteのステータス確認
        skupper site status

        # TOKEN/LINKの作成
        skupper token issue "$REPO_ROOT/skupper-token-b.yaml" -r 3
        
        # LINK作成の確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite --host external-shop-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-kafka-bsite 9094 --selector app.kubernetes.io/part-of=strimzi-shop-cluster -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite 9094 -n "$NAMESPACE"

        skupper listener create external-shop-cluster-postgres-bsite --host external-shop-cluster-postgres-bsite 5432 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-postgres-bsite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"
        
        # KafkaClusterの再作成 (Skupper advertisedHost を bsite の FQDN に設定)
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-bsite.yaml" -n "$NAMESPACE"

        # MirrorMakerの設定
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-b-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "C" ]; then

        # Siteの作成
        skupper site create skupper-csite
        skupper site update --enable-link-access -n "$NAMESPACE"

        # Siteのステータス確認
        skupper site status

        # TOKEN/LINKの作成
        skupper token issue "$REPO_ROOT/skupper-token-c.yaml" -r 3
        
        # LINK作成の確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite --host external-shop-cluster-kafka-csite 9094 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-kafka-csite 9094 --selector app.kubernetes.io/part-of=strimzi-shop-cluster -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite 9094 -n "$NAMESPACE"
       
        skupper listener create external-shop-cluster-postgres-csite --host external-shop-cluster-postgres-csite 5432 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-postgres-csite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"

        # KafkaClusterの再作成 (Skupper advertisedHost を csite の FQDN に設定)
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-csite.yaml" -n "$NAMESPACE"

        # MirrorMakerの設定
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-c-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "DH" ]; then

        # Siteの作成
        skupper site create skupper-rhdh
        skupper site update --enable-link-access -n "$NAMESPACE"

        # Siteのステータス確認
        skupper site status

        # TOKEN/LINKの作成
        skupper token issue "$REPO_ROOT/skupper-token-rhdh.yaml" -r 3

        # LINK作成の確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"

        # Kafka Listener (各サイトの Connector とルーティングキーで対応)
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite 9094 -n "$NAMESPACE"

        # Apicurio Listener
        skupper listener create external-shop-cluster-apicurio 8080 -n "$NAMESPACE"

        # PostgreSQL Listener — a/b/c 全サイト分を作成
        skupper listener create external-shop-cluster-postgres-asite 5432 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-postgres-bsite 5432 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-postgres-csite 5432 -n "$NAMESPACE"

    fi

    # LINKとサービスのステータス確認
    sleep 10
    skupper link status
    skupper listener status
    skupper connector status

}

retoken() {
    read -p "どのサイトでLINKを再作成しますか？(A/B/C/DH): " SITE_CONFREM
    if [ "$SITE_CONFREM" = "A" ]; then

        # Tokenの作り直し
        skupper token issue "$REPO_ROOT/skupper-token-a.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"
        # Tokenの作り直し後のステータス確認
        skupper site status
        skupper link status
        skupper listener status
        skupper connector status

    elif [ "$SITE_CONFREM" = "B" ]; then

        # Tokenの作り直し
        skupper token issue "$REPO_ROOT/skupper-token-b.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"
        # Tokenの作り直し後のステータス確認
        skupper site status
        skupper link status
        skupper listener status
        skupper connector status

    elif [ "$SITE_CONFREM" = "C" ]; then

        # Tokenの作り直し
        skupper token issue "$REPO_ROOT/skupper-token-c.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        # Tokenの作り直し後のステータス確認
        skupper site status
        skupper link status
        skupper listener status
        skupper connector status

    elif [ "$SITE_CONFREM" = "DH" ]; then

        # Tokenの作り直し
        skupper token issue "$REPO_ROOT/skupper-token-rhdh.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"

        # postgres-bsite / postgres-csite Listener が未作成の場合は追加
        for listener in \
            "external-shop-cluster-postgres-bsite:5432" \
            "external-shop-cluster-postgres-csite:5432"; do
            name="${listener%%:*}"
            port="${listener##*:}"
            if ! skupper listener status -n "$NAMESPACE" 2>/dev/null | grep -q "^${name}"; then
                echo -e "${BLUE}  Listener 追加: ${name}:${port}${RESET}"
                skupper listener create "${name}" "${port}" -n "$NAMESPACE"
            else
                echo -e "${YELLOW}  Listener 既存スキップ: ${name}${RESET}"
            fi
        done

        # Tokenの作り直し後のステータス確認
        sleep 5
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
    skupper listener delete external-shop-cluster-kafka-asite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-kafka-bsite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-kafka-csite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-kafka-rhdh -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-apicurio -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-postgres-asite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-kafka-asite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-kafka-bsite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-kafka-csite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-apicurio -n "$NAMESPACE"

    skupper listener delete external-shop-cluster-postgres-asite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-postgres-asite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-postgres-bsite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-postgres-bsite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-postgres-csite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-postgres-csite -n "$NAMESPACE"

    skupper site delete skupper-asite
    skupper site delete skupper-bsite
    skupper site delete skupper-csite
    skupper site delete skupper-rhdh
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

console() {

    echo -e "${BLUE}Skupper Network Observer (コンソール) をデプロイ中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/skupper-network-observer.yaml" -n "$NAMESPACE"

    echo -e "${BLUE}Pod の起動を待っています...${RESET}"
    oc rollout status deployment/skupper-network-observer -n "$NAMESPACE" --timeout=120s
    oc rollout status deployment/skupper-prometheus -n "$NAMESPACE" --timeout=120s

    CONSOLE_URL=$(oc get route skupper-network-observer -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    echo -e "${GREEN}Skupper コンソール URL: https://${CONSOLE_URL}${RESET}"

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
    console)
        console
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {deploy|retoken|status|console|cleanup}${RESET}"
        exit 1
        ;;
esac
