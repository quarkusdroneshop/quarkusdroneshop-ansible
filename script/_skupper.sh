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

# Kafka の external(loadbalancer) リスナーの advertisedHost は、AWS ELB が
# 再作成されるたびにホスト名が変わる(ELBを削除・再作成すると新しいランダムな
# ホスト名が割り当てられる)ため、YAMLファイルに静的に書いた値はすぐに陳腐化し、
# MirrorMaker2やSkupper経由の外部クライアントが NoBrokersAvailable /
# UnknownHostException で接続できなくなる。
# droneshop-cluster-kafka-bootstrap-listeners-*site.yaml を適用した直後に
# 実際にプロビジョニングされたLBのホスト名を取得し、Kafka CRへ上書きパッチする。
_patch_kafka_advertised_host() {
    echo -e "${BLUE}  Load Balancer のホスト名を待機中...${RESET}"
    local elb_host=""
    for i in $(seq 1 60); do
        elb_host=$(oc get svc shop-cluster-kafka-external-bootstrap -n "$NAMESPACE" \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -n "$elb_host" ]; then
            break
        fi
        sleep 5
    done
    if [ -z "$elb_host" ]; then
        echo -e "${RED}  Load Balancer のホスト名取得に失敗しました。advertisedHost は手動で確認してください。${RESET}"
        return 1
    fi
    echo -e "${GREEN}  Load Balancer ホスト名: ${elb_host}${RESET}"
    oc patch kafka shop-cluster -n "$NAMESPACE" --type merge -p "$(cat <<PATCH
{
  "spec": {
    "kafka": {
      "listeners": [
        {"name": "plain", "port": 9092, "tls": false, "type": "internal"},
        {"name": "tls", "port": 9093, "tls": true, "type": "internal"},
        {
          "name": "external", "port": 9094, "tls": false, "type": "loadbalancer",
          "configuration": {
            "bootstrap": {},
            "brokers": [
              {"broker": 0, "advertisedHost": "${elb_host}", "advertisedPort": 9094},
              {"broker": 1, "advertisedHost": "${elb_host}", "advertisedPort": 9094},
              {"broker": 2, "advertisedHost": "${elb_host}", "advertisedPort": 9094}
            ]
          }
        }
      ]
    }
  }
}
PATCH
)"
}

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
        skupper site create skupper-asite -n "$NAMESPACE"
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
        skupper connector create external-shop-cluster-postgres-asite 5432 --selector postgres-operator.crunchydata.com/cluster=droneshopdb -n "$NAMESPACE"
        skupper connector create external-shop-cluster-apicurio 8080 --selector app=droneshop-apicurioregistry-kafkasql -n "$NAMESPACE"

        # KafkaClusterの再作成 (Skupper advertisedHost を asite の FQDN に設定)
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-asite.yaml" -n "$NAMESPACE"
        _patch_kafka_advertised_host

        # MirrorMakerの設定
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-a-site.yaml" -n "$NAMESPACE"


    elif [ "$SITE_CONFREM" = "B" ]; then

        # Siteの作成
        skupper site create skupper-bsite -n "$NAMESPACE"
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
        skupper connector create external-shop-cluster-postgres-bsite 5432 --selector postgres-operator.crunchydata.com/cluster=droneshopdb -n "$NAMESPACE"
        
        # KafkaClusterの再作成 (Skupper advertisedHost を bsite の FQDN に設定)
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-bsite.yaml" -n "$NAMESPACE"
        _patch_kafka_advertised_host

        # MirrorMakerの設定
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-b-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "C" ]; then

        # Siteの作成
        skupper site create skupper-csite -n "$NAMESPACE"
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
        skupper connector create external-shop-cluster-postgres-csite 5432 --selector postgres-operator.crunchydata.com/cluster=droneshopdb -n "$NAMESPACE"

        # KafkaClusterの再作成 (Skupper advertisedHost を csite の FQDN に設定)
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-csite.yaml" -n "$NAMESPACE"
        _patch_kafka_advertised_host

        # MirrorMakerの設定
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-c-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "DH" ]; then

        # DHサイトは quarkusdroneshop-rhdh namespace に構築する
        # ($NAMESPACE=quarkusdroneshop-demo とは別。-nを省略すると
        # 現在のカレントプロジェクトに作成されてしまうため明示する)
        if ! oc get project "$RHDH_NAMESPACE" > /dev/null 2>&1; then
            oc new-project "$RHDH_NAMESPACE"
        fi

        # Siteの作成
        skupper site create skupper-rhdh -n "$RHDH_NAMESPACE"
        skupper site update --enable-link-access -n "$RHDH_NAMESPACE"

        # Siteのステータス確認
        skupper site status -n "$RHDH_NAMESPACE"

        # TOKEN/LINKの作成
        skupper token issue "$REPO_ROOT/skupper-token-rhdh.yaml" -r 3 -n "$RHDH_NAMESPACE"

        # LINK作成の確認
        read -p "LINKを作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"
            exit 1
        fi

        # Linkの作成
        oc delete accesstokens.skupper.io --all -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$RHDH_NAMESPACE"

        # Kafka Listener (各サイトの Connector とルーティングキーで対応)
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite 9094 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite 9094 -n "$RHDH_NAMESPACE"

        # Apicurio Listener
        skupper listener create external-shop-cluster-apicurio 8080 -n "$RHDH_NAMESPACE"

        # PostgreSQL Listener — a/b/c 全サイト分を作成
        skupper listener create external-shop-cluster-postgres-asite 5432 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-postgres-bsite 5432 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-postgres-csite 5432 -n "$RHDH_NAMESPACE"

    fi

    if [ "$SITE_CONFREM" = "DH" ]; then
        STATUS_NAMESPACE="$RHDH_NAMESPACE"
    else
        STATUS_NAMESPACE="$NAMESPACE"
    fi

    # LINKとサービスのステータス確認
    sleep 10
    skupper link status -n "$STATUS_NAMESPACE"
    skupper listener status -n "$STATUS_NAMESPACE"
    skupper connector status -n "$STATUS_NAMESPACE"

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

        # DHサイトは quarkusdroneshop-rhdh namespace が対象
        # Tokenの作り直し
        skupper token issue "$REPO_ROOT/skupper-token-rhdh.yaml" -r 3 -n "$RHDH_NAMESPACE"
        oc delete accesstokens.skupper.io --all -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$RHDH_NAMESPACE"

        # postgres-bsite / postgres-csite Listener は既存でもスキップせず、
        # いったん削除してから作り直す(Connector側が未作成/Pendingのままの
        # 場合の再同期を試すため)
        for listener in \
            "external-shop-cluster-postgres-bsite:5432" \
            "external-shop-cluster-postgres-csite:5432"; do
            name="${listener%%:*}"
            port="${listener##*:}"
            if skupper listener status -n "$RHDH_NAMESPACE" 2>/dev/null | grep -q "^${name}"; then
                echo -e "${YELLOW}  Listener 再作成のため削除: ${name}${RESET}"
                skupper listener delete "${name}" -n "$RHDH_NAMESPACE"
            fi
            echo -e "${BLUE}  Listener 追加: ${name}:${port}${RESET}"
            skupper listener create "${name}" "${port}" -n "$RHDH_NAMESPACE"
        done

        # Tokenの作り直し後のステータス確認
        sleep 5
        skupper site status -n "$RHDH_NAMESPACE"
        skupper link status -n "$RHDH_NAMESPACE"
        skupper listener status -n "$RHDH_NAMESPACE"
        skupper connector status -n "$RHDH_NAMESPACE"

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

    # -n を省略すると現在のカレントプロジェクトを見てしまい、site が
    # 実際にあるnamespaceと食い違って「site が見つからない」となるため、
    # deploy/retoken 同様どのサイトを見るか確認してから対象namespaceを決める
    read -p "どのサイトのステータスを確認しますか？(A/B/C/DH): " SITE_CONFREM
    if [ "$SITE_CONFREM" = "DH" ]; then
        STATUS_NAMESPACE="$RHDH_NAMESPACE"
    else
        STATUS_NAMESPACE="$NAMESPACE"
    fi

    # 様々なステータス確認
    skupper site status -n "$STATUS_NAMESPACE"
    skupper link status -n "$STATUS_NAMESPACE"
    skupper listener status -n "$STATUS_NAMESPACE"
    skupper connector status -n "$STATUS_NAMESPACE"

}

console() {

    # skupper-network-observer.yaml は namespace: quarkusdroneshop-demo が
    # 全リソースにハードコードされており、oc apply -n だけでは上書きできない
    # (metadata.namespace が明示されたリソースはそちらが優先される)ため、
    # どのサイトのコンソールかを確認し、対象namespaceにsedで置換してから適用する
    read -p "どのサイトのコンソールをデプロイしますか？(A/B/C/DH): " SITE_CONFREM
    if [ "$SITE_CONFREM" = "DH" ]; then
        TARGET_NAMESPACE="$RHDH_NAMESPACE"
    else
        TARGET_NAMESPACE="$NAMESPACE"
    fi

    echo -e "${BLUE}Skupper Network Observer (コンソール) を ${TARGET_NAMESPACE} にデプロイ中...${RESET}"
    sed "s/quarkusdroneshop-demo/${TARGET_NAMESPACE}/g" "$REPO_ROOT/openshift/skupper-network-observer.yaml" \
        | oc apply -f - -n "$TARGET_NAMESPACE"

    echo -e "${BLUE}Pod の起動を待っています...${RESET}"
    oc rollout status deployment/skupper-network-observer -n "$TARGET_NAMESPACE" --timeout=120s
    oc rollout status deployment/skupper-prometheus -n "$TARGET_NAMESPACE" --timeout=120s

    CONSOLE_URL=$(oc get route skupper-network-observer -n "$TARGET_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
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
