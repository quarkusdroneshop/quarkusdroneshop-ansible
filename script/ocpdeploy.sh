#!/bin/bash
# =============================================================================
# Script Name: ocpdeploy.sh
# Description: quarkusdroneshop の統合管理スクリプト
#              (ocpdeploy / piplines / skupper-and-kafkacluster を統合)
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2026-06-28
# Version: 2.0
#
# Usage:
#   ./script/ocpdeploy.sh setup                  - OCP 環境セットアップ（demo NS）
#   ./script/ocpdeploy.sh cleanup                - demo NS の全リソース削除
#
#   MCP Gateway (Red Hat Connectivity Link) は ./script/connectivitylink.sh を使用
#
#   ./script/ocpdeploy.sh pipeline setup         - Tekton Operator インストール
#   ./script/ocpdeploy.sh pipeline deploy        - Pipeline kustomize デプロイ
#   ./script/ocpdeploy.sh pipeline config        - Demo ConfigMap 設定
#   ./script/ocpdeploy.sh pipeline cleanup       - CICD NS 削除
#
#   ./script/ocpdeploy.sh skupper deploy         - Skupper + Kafka クラスター構築
#   ./script/ocpdeploy.sh skupper retoken        - Skupper トークン再作成
#   ./script/ocpdeploy.sh skupper status         - Skupper ステータス確認
#   ./script/ocpdeploy.sh skupper console        - Skupper コンソールデプロイ
#   ./script/ocpdeploy.sh skupper cleanup        - Skupper リソース削除
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - kustomize / tkn (tektoncd-cli) is installed (pipeline サブコマンド用)
#   - skupper (innerconnect 2.0) is installed (skupper サブコマンド用)
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# script/ から見たリポジトリルート（openshift/, source.env, Dockerfile, skupper-token-*.yaml はここ基準）
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NAMESPACE="quarkusdroneshop-demo"
CICD_NAMESPACE="quarkusdroneshop-cicd"
RHDH_NAMESPACE="quarkusdroneshop-rhdh"
ENV_FILE="source.env"

# 色を変数に格納
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0 setup                  OCP 環境セットアップ（demo NS）"
    echo "  $0 cleanup                demo NS の全リソース削除"
    echo ""
    echo "  $0 skupper deploy         Skupper + Kafka クラスター構築"
    echo "  $0 skupper retoken        Skupper トークン再作成"
    echo "  $0 skupper status         Skupper ステータス確認"
    echo "  $0 skupper console        Skupper コンソールデプロイ"
    echo "  $0 skupper cleanup        Skupper リソース削除"
    echo ""
    echo "  $0 pipeline deploy        Pipeline kustomize デプロイ"
    echo "  $0 pipeline config        Demo ConfigMap 設定"
    echo "  $0 pipeline cleanup       CICD NS 削除"
    echo ""
    echo "  $0 dataproducts setup     Flink Kubernetes Operator インストール + Trino Helm デプロイ"
    echo "  $0 dataproducts deploy    Flink Session Cluster 起動 + 全ジョブ投入 (依存順)"
    echo "  $0 dataproducts schemas   Apicurio へスキーマ登録 (Keycloak OIDC 認証)"
    echo "  $0 dataproducts cleanup   dataproducts 関連リソースの削除"
    echo ""
    echo "  MCP Gateway (Red Hat Connectivity Link) は ./script/connectivitylink.sh を使用"
    echo "    ./script/connectivitylink.sh setup|deploy|status|cleanup"

}

# =============================================================================
# Step 1: コマンド検証（無効なら即終了）
# =============================================================================

case "$1" in
    setup|cleanup) ;;
    pipeline)
        case "$2" in
            setup|deploy|config|cleanup) ;;
            *)
                echo -e "${RED}無効なサブコマンド: pipeline $2${RESET}"
                usage; exit 1
                ;;
        esac
        ;;
    skupper)
        case "$2" in
            deploy|retoken|status|console|cleanup) ;;
            *)
                echo -e "${RED}無効なサブコマンド: skupper $2${RESET}"
                usage; exit 1
                ;;
        esac
        ;;
    dataproducts)
        case "$2" in
            setup|deploy|schemas|cleanup) ;;
            *)
                echo -e "${RED}無効なサブコマンド: dataproducts $2${RESET}"
                usage; exit 1
                ;;
        esac
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        usage; exit 1
        ;;
esac

# =============================================================================
# Step 2: ロゴ表示・OCP 接続確認・ドメイン確認
# =============================================================================

figlet "droneshop"

oc status
oc version

# OpenShift にログインしているか確認
if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)
DOMAIN_TOKEN=$(oc whoami -t)

echo -e "${YELLOW}Domain Name: $DOMAIN_NAME${RESET}"
echo -e "${YELLOW}Domain Token: $DOMAIN_TOKEN${RESET}"
echo -e "-------------------------------------------"
read -p "指定されたドメインで間違いないですか？(yes/no): " DOMAIN_CONFREM
if [ "$DOMAIN_CONFREM" != "yes" ]; then
    echo -e "${RED}処理を中断します。${RESET}"
    exit 1
fi

# =============================================================================
# OCP セットアップ / クリーンアップ
# =============================================================================

ocp_setup() {
    echo "セットアップ開始..."

    # source.env の CLUSTER_DOMAIN_NAME と TOKEN を更新（行が無ければ追加する）
    if grep -q "^CLUSTER_DOMAIN_NAME=" "$REPO_ROOT/$ENV_FILE"; then
        sed -i '' "s/^CLUSTER_DOMAIN_NAME=.*$/CLUSTER_DOMAIN_NAME=$DOMAIN_NAME/" "$REPO_ROOT/$ENV_FILE"
    else
        echo "CLUSTER_DOMAIN_NAME=$DOMAIN_NAME" >> "$REPO_ROOT/$ENV_FILE"
    fi
    if grep -q "^TOKEN=" "$REPO_ROOT/$ENV_FILE"; then
        sed -i '' "s/^TOKEN=.*$/TOKEN=$DOMAIN_TOKEN/" "$REPO_ROOT/$ENV_FILE"
    else
        echo "TOKEN=$DOMAIN_TOKEN" >> "$REPO_ROOT/$ENV_FILE"
    fi

    # プロジェクトの作成
    oc new-project "$NAMESPACE"

    # default ServiceAccount へ権限の追加
    oc adm policy add-scc-to-user anyuid system:serviceaccount:"$NAMESPACE":default

    # Podman イメージの作成と Operator のインストール（ビルドコンテキストはリポジトリルート）
    podman build --no-cache -t "$NAMESPACE" "$REPO_ROOT"
    podman run --platform linux/amd64 -it --env-file="$REPO_ROOT/$ENV_FILE" "$NAMESPACE"

    # PostgreSQLCluster へ権限の追加
    oc adm policy add-scc-to-user anyuid -z droneshopdb-instance -n "$NAMESPACE"
    oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE"

    # Skupper Operator の準備（site作成等は引き続き `skupper deploy` で手動実行）
    skupper_operator_setup

    # Tekton Operator の準備（pipeline deploy 等は引き続き `pipeline deploy` で手動実行）
    pipeline_setup
}

ocp_cleanup() {
    echo "クリーンナップ開始..."

    oc delete subscription amq-streams --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete subscription crunchy-postgres-operator --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete operator --all -n openshift-operators --ignore-not-found=true
    oc delete operator --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete all --all -n "$NAMESPACE" --ignore-not-found=true --force --grace-period=0

    read -p "本当にプロジェクトを削除してもよろしいですか？(yes/no): " DELETE_CONFREM
    if [ "$DELETE_CONFREM" == "yes" ]; then
        for topic in $(oc get kafkatopics.kafka.strimzi.io -n "$NAMESPACE" -o name); do
            oc patch $topic -n "$NAMESPACE" --type=merge -p '{"metadata":{"finalizers":[]}}'
        done
        oc delete project "$NAMESPACE" --force --grace-period=0
    fi
}

# =============================================================================
# Pipeline サブコマンド
# =============================================================================

pipeline_setup() {
    # Tekton Operator のインストール
    if ! oc get project "$CICD_NAMESPACE" > /dev/null 2>&1; then
        oc new-project $CICD_NAMESPACE
    fi
    oc apply -f "$REPO_ROOT/openshift/openshift-pipline.yaml"
    sleep 30
    oc delete tektonconfig config -n $CICD_NAMESPACE
    oc apply -f "$REPO_ROOT/openshift/tektonconfig.yaml" -n $CICD_NAMESPACE

    # Tekton coschedule 無効化（複数 PVC の並列マウントを許可）
    echo -e "${BLUE}Tekton coschedule を無効化中...${RESET}"
    oc patch tektonconfig config \
        --type=merge \
        -p '{"spec":{"pipeline":{"coschedule":"disabled"}}}'
    sleep 5
    echo -e "${GREEN}coschedule: $(oc get configmap feature-flags -n openshift-pipelines -o jsonpath='{.data.coschedule}')${RESET}"
}

pipeline_deploy() {
    echo "デプロイの開始..."

    # Tekton coschedule 無効化（未設定の場合のみ）
    CURRENT_COSCHEDULE=$(oc get configmap feature-flags -n openshift-pipelines -o jsonpath='{.data.coschedule}' 2>/dev/null || echo "")
    if [ "$CURRENT_COSCHEDULE" != "disabled" ]; then
        echo -e "${BLUE}Tekton coschedule を無効化中...${RESET}"
        oc patch tektonconfig config \
            --type=merge \
            -p '{"spec":{"pipeline":{"coschedule":"disabled"}}}'
        sleep 5
        echo -e "${GREEN}coschedule: disabled${RESET}"
    fi

    if oc get project "$CICD_NAMESPACE" > /dev/null 2>&1; then
        read -p "Operator のインストールを先に実行してください。実行を続けますか？ (y/N): " answer
        if [[ "$answer" =~ ^[Nn]$ ]]; then
            echo -e "${RED}処理を中断します。${RESET}"
            exit 1
        fi
    else
        oc new-project $CICD_NAMESPACE
    fi

    oc apply -f "$REPO_ROOT/openshift/tekton-configmap.yaml" -n $CICD_NAMESPACE
    oc adm policy add-scc-to-user privileged -z pipeline -n $CICD_NAMESPACE

    cd "$REPO_ROOT/../tekton-pipelines"

    OPTIONS=(
        "qdca10" "qdca10pro" "counter" "web" "inventory"
        "reword" "homeofficebackend" "homeoffice-ui" "customermocker"
        "all" "cancel"
    )
    PS3="実行したい Pipeline を選択してください（番号）: "

    select opt in "${OPTIONS[@]}"; do
        case $opt in
            "qdca10"|"qdca10pro"|"counter"|"web"|"inventory"|"reword"|"homeofficebackend"|"homeoffice-ui"|"customermocker")
                echo "実行中: $opt"
                oc delete pipelinerun "build-and-push-quarkusdroneshop-$opt" \
                    -n "$CICD_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
                kustomize build "quarkusdroneshop-$opt" | oc apply -f -
                ;;
            "all")
                for d in qdca10 qdca10pro counter web inventory reword homeofficebackend homeoffice-ui customermocker; do
                    echo "実行中: $d"
                    oc delete pipelinerun "build-and-push-quarkusdroneshop-$d" \
                        -n "$CICD_NAMESPACE" --ignore-not-found=true 2>/dev/null || true
                    kustomize build "quarkusdroneshop-$d" | oc apply -f -
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

    if ! oc get project "$DEMO_NAMESPACE" > /dev/null 2>&1; then
        oc new-project "$NAMESPACE"
    fi
    oc policy add-role-to-user admin system:serviceaccount:$CICD_NAMESPACE:pipeline -n $NAMESPACE
}

pipeline_config() {
    oc apply -f "$REPO_ROOT/openshift/droneshop-configmap.yaml" -n $NAMESPACE
    oc policy add-role-to-user admin system:serviceaccount:$CICD_NAMESPACE:pipeline -n $NAMESPACE
}

pipeline_cleanup() {
    echo "クリーンナップ開始..."
    for pvc in $(oc get pvc -n "$CICD_NAMESPACE" -o name); do
        oc patch "$pvc" -n "$CICD_NAMESPACE" --type=merge -p '{"metadata":{"finalizers":[]}}'
    done
    oc delete task push-app -n $CICD_NAMESPACE --ignore-not-found=true
    oc delete task git-clone -n $CICD_NAMESPACE --ignore-not-found=true
    oc delete task maven -n $CICD_NAMESPACE --ignore-not-found=true
    oc delete project $CICD_NAMESPACE
}

# =============================================================================
# Skupper サブコマンド
# =============================================================================

# NAMESPACE(既定: quarkusdroneshop-demo) がクラスタ上に存在しない場合、
# RHDHのみをデプロイした環境（quarkusdroneshop-demo は作成していない）である
# 可能性が高い。その場合に無言で失敗させず、対象namespaceを対話式で確認する。
_resolve_skupper_namespace() {
    if oc get project "$NAMESPACE" &>/dev/null; then
        return 0
    fi

    echo -e "${YELLOW}⚠ namespace '${NAMESPACE}' が存在しません。${RESET}" >&2
    if oc get project "$RHDH_NAMESPACE" &>/dev/null; then
        echo -e "${YELLOW}  '${RHDH_NAMESPACE}' は存在するため、RHDHのみのデプロイ環境の可能性があります。${RESET}" >&2
    fi
    read -rp "Skupperの対象namespaceを入力してください (デフォルト: ${RHDH_NAMESPACE}): " _ns_input
    NAMESPACE="${_ns_input:-$RHDH_NAMESPACE}"

    if ! oc get project "$NAMESPACE" &>/dev/null; then
        echo -e "${RED}ERROR: namespace '${NAMESPACE}' も存在しません。処理を中止します。${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}  → namespace '${NAMESPACE}' を使用します${RESET}"
}

skupper_operator_setup() {
    _resolve_skupper_namespace
    oc project "$NAMESPACE"

    echo -e "${BLUE}Skupper Operator をインストール中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/skupper-operator.yaml"

    echo -e "${BLUE}Skupper CRD の準備を待っています...${RESET}"
    until oc get crd sites.skupper.io &>/dev/null; do sleep 5; done
    echo -e "${GREEN}  → Skupper CRD 準備完了${RESET}"
}

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

skupper_deploy() {
    skupper_operator_setup

    read -p "どのサイトを構築しますか？(A/B/C/DH): " SITE_CONFREM

    if [ "$SITE_CONFREM" = "A" ]; then
        skupper site create skupper-asite -n "$NAMESPACE"
        skupper site update --enable-link-access -n "$NAMESPACE"
        skupper site status
        skupper token issue "$REPO_ROOT/skupper-token-a.yaml" -r 3 -e 1h -n "$NAMESPACE"

        read -p "LINK を作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"; exit 1
        fi

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
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-asite.yaml" -n "$NAMESPACE"
        _patch_kafka_advertised_host
        # NOTE: kafka-mm2-*-site.yaml のファイル名は「ミラーの向き」を表す
        # (デプロイ先クラスタ名ではない)。asiteクラスタには
        # target=asite (b-site → a-site 向き) の kafka-mm2-b-site.yaml を適用する。
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-b-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "B" ]; then
        skupper site create skupper-bsite -n "$NAMESPACE"
        skupper site update --enable-link-access -n "$NAMESPACE"
        skupper site status
        skupper token issue "$REPO_ROOT/skupper-token-b.yaml" -r 3 -e 1h -n "$NAMESPACE"

        read -p "LINK を作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"; exit 1
        fi

        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite --host external-shop-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-kafka-bsite 9094 --selector app.kubernetes.io/part-of=strimzi-shop-cluster -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-postgres-bsite --host external-shop-cluster-postgres-bsite 5432 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-postgres-bsite 5432 --selector postgres-operator.crunchydata.com/cluster=droneshopdb -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-bsite.yaml" -n "$NAMESPACE"
        _patch_kafka_advertised_host
        # NOTE: kafka-mm2-*-site.yaml のファイル名は「ミラーの向き」を表す
        # (デプロイ先クラスタ名ではない)。bsiteクラスタには
        # target=bsite (a-site → b-site 向き) の kafka-mm2-a-site.yaml を適用する。
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-a-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "C" ]; then
        skupper site create skupper-csite -n "$NAMESPACE"
        skupper site update --enable-link-access -n "$NAMESPACE"
        skupper site status
        skupper token issue "$REPO_ROOT/skupper-token-c.yaml" -r 3 -e 1h -n "$NAMESPACE"

        read -p "LINK を作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"; exit 1
        fi

        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite --host external-shop-cluster-kafka-csite 9094 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-kafka-csite 9094 --selector app.kubernetes.io/part-of=strimzi-shop-cluster -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-postgres-csite --host external-shop-cluster-postgres-csite 5432 -n "$NAMESPACE"
        skupper connector create external-shop-cluster-postgres-csite 5432 --selector postgres-operator.crunchydata.com/cluster=droneshopdb -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-csite.yaml" -n "$NAMESPACE"
        _patch_kafka_advertised_host
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-c-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "DH" ]; then
        # DHサイトは quarkusdroneshop-rhdh namespace に構築する
        # ($NAMESPACE=quarkusdroneshop-demo とは別。-nを省略すると
        # 現在のカレントプロジェクトに作成されてしまうため明示する)
        if ! oc get project "$RHDH_NAMESPACE" > /dev/null 2>&1; then
            oc new-project "$RHDH_NAMESPACE"
        fi
        skupper site create skupper-rhdh -n "$RHDH_NAMESPACE"
        skupper site update --enable-link-access -n "$RHDH_NAMESPACE"
        skupper site status -n "$RHDH_NAMESPACE"
        skupper token issue "$REPO_ROOT/skupper-token-rhdh.yaml" -r 3 -e 1h -n "$RHDH_NAMESPACE"

        read -p "LINK を作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"; exit 1
        fi

        oc delete accesstokens.skupper.io --all -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite 9094 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite 9094 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-apicurio 8080 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-postgres-asite 5432 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-postgres-bsite 5432 -n "$RHDH_NAMESPACE"
        skupper listener create external-shop-cluster-postgres-csite 5432 -n "$RHDH_NAMESPACE"
    fi

    if [ "$SITE_CONFREM" = "DH" ]; then
        STATUS_NAMESPACE="$RHDH_NAMESPACE"
    else
        STATUS_NAMESPACE="$NAMESPACE"
    fi

    sleep 10
    skupper link status -n "$STATUS_NAMESPACE"
    skupper listener status -n "$STATUS_NAMESPACE"
    skupper connector status -n "$STATUS_NAMESPACE"
}

skupper_retoken() {
    _resolve_skupper_namespace
    read -p "どのサイトで LINK を再作成しますか？(A/B/C/DH): " SITE_CONFREM

    if [ "$SITE_CONFREM" = "A" ]; then
        skupper token issue "$REPO_ROOT/skupper-token-a.yaml" -r 3 -e 1h -n "$NAMESPACE"
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "B" ]; then
        skupper token issue "$REPO_ROOT/skupper-token-b.yaml" -r 3 -e 1h -n "$NAMESPACE"
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "C" ]; then
        skupper token issue "$REPO_ROOT/skupper-token-c.yaml" -r 3 -e 1h -n "$NAMESPACE"
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "DH" ]; then
        # DHサイトは quarkusdroneshop-rhdh namespace が対象
        skupper token issue "$REPO_ROOT/skupper-token-rhdh.yaml" -r 3 -e 1h -n "$RHDH_NAMESPACE"
        oc delete accesstokens.skupper.io --all -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$RHDH_NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$RHDH_NAMESPACE"

        for listener in \
            "external-shop-cluster-postgres-bsite:5432" \
            "external-shop-cluster-postgres-csite:5432"; do
            name="${listener%%:*}"
            port="${listener##*:}"
            # 既存でもスキップせず、いったん削除してから作り直す
            # (Connector側が未作成/Pendingのままの場合の再同期を試すため)
            if skupper listener status -n "$RHDH_NAMESPACE" 2>/dev/null | grep -q "^${name}"; then
                echo -e "${YELLOW}  Listener 再作成のため削除: ${name}${RESET}"
                skupper listener delete "${name}" -n "$RHDH_NAMESPACE"
            fi
            echo -e "${BLUE}  Listener 追加: ${name}:${port}${RESET}"
            skupper listener create "${name}" "${port}" -n "$RHDH_NAMESPACE"
        done
    fi

    if [ "$SITE_CONFREM" = "DH" ]; then
        STATUS_NAMESPACE="$RHDH_NAMESPACE"
    else
        STATUS_NAMESPACE="$NAMESPACE"
    fi

    sleep 5
    skupper site status -n "$STATUS_NAMESPACE"
    skupper link status -n "$STATUS_NAMESPACE"
    skupper listener status -n "$STATUS_NAMESPACE"
    skupper connector status -n "$STATUS_NAMESPACE"
}

skupper_status() {
    # -n を省略すると現在のカレントプロジェクトを見てしまい、site が
    # 実際にあるnamespaceと食い違って「site が見つからない」となるため、
    # deploy/retoken 同様どのサイトを見るか確認してから対象namespaceを決める
    _resolve_skupper_namespace
    read -p "どのサイトのステータスを確認しますか？(A/B/C/DH): " SITE_CONFREM
    if [ "$SITE_CONFREM" = "DH" ]; then
        STATUS_NAMESPACE="$RHDH_NAMESPACE"
    else
        STATUS_NAMESPACE="$NAMESPACE"
    fi

    skupper site status -n "$STATUS_NAMESPACE"
    skupper link status -n "$STATUS_NAMESPACE"
    skupper listener status -n "$STATUS_NAMESPACE"
    skupper connector status -n "$STATUS_NAMESPACE"
}

skupper_console() {
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

    # skupper-network-observer-tls は skupper-local-ca (サイトごとに固有の内部CA) が発行する
    # 自己署名証明書のため、Route(reencrypt)に destinationCACertificate を明示しないと
    # ルーターがバックエンド証明書を信頼できず 503 Service Unavailable になる
    echo -e "${BLUE}Route の TLS 設定 (destinationCACertificate) を追加中...${RESET}"
    CA_CERT_JSON=$(oc get secret skupper-local-ca -n "$TARGET_NAMESPACE" -o jsonpath='{.data.ca\.crt}' | base64 -d | jq -Rs .)
    oc patch route skupper-network-observer -n "$TARGET_NAMESPACE" --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/spec/tls/destinationCACertificate\",\"value\":${CA_CERT_JSON}}]"

    CONSOLE_URL=$(oc get route skupper-network-observer -n "$TARGET_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    echo -e "${GREEN}Skupper コンソール URL: https://${CONSOLE_URL}${RESET}"
}

skupper_cleanup() {
    _resolve_skupper_namespace
    oc delete kafkamirrormaker2 --all -n "$NAMESPACE"
    oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-kafka-asite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-kafka-bsite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-kafka-csite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-kafka-rhdh -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-apicurio -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-postgres-asite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-postgres-bsite -n "$NAMESPACE"
    skupper listener delete external-shop-cluster-postgres-csite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-kafka-asite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-kafka-bsite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-kafka-csite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-apicurio -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-postgres-asite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-postgres-bsite -n "$NAMESPACE"
    skupper connector delete external-shop-cluster-postgres-csite -n "$NAMESPACE"
    skupper site delete skupper-asite
    skupper site delete skupper-bsite
    skupper site delete skupper-csite
    skupper site delete skupper-rhdh
    oc delete all -l skupper.io/component
    oc delete configmap -l skupper.io/component
    oc delete secret -l skupper.io/component
}

# =============================================================================
# dataproducts サブコマンド
#
# データプロダクト基盤 (Flink / Iceberg / Trino) のうち、OperatorHub 上に
# Operator が存在するものは Subscription として、存在しないもの (Trino) は
# 公式 Helm チャートとして、いずれもこのスクリプトにまとめる。
# 認証情報は Keycloak (RHBK, 既存の共通コンポーネント) に一元化し、
# 個別サービスのユーザー/パスワードはハードコードしない。
# =============================================================================

dataproducts_setup() {
    oc project "$NAMESPACE"

    echo -e "${BLUE}Flink Kubernetes Operator をインストール中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/flink-operator.yaml"
    echo -e "${BLUE}Flink CRD の準備を待っています...${RESET}"
    until oc get crd flinkdeployments.flink.apache.org &>/dev/null; do sleep 5; done
    echo -e "${GREEN}  → Flink Operator 準備完了${RESET}"

    # Trino には OperatorHub 上の公式 Operator が存在しないため Helm で導入する。
    echo -e "${BLUE}Trino (Helm chart) をインストール中...${RESET}"
    helm repo add trino https://trinodb.github.io/charts >/dev/null 2>&1 || true
    helm repo update trino >/dev/null 2>&1

    if ! oc get secret trino-oidc -n "$NAMESPACE" &>/dev/null; then
        echo -e "${YELLOW}  ⚠ Secret 'trino-oidc' が未作成です。Keycloak に${RESET}"
        echo -e "${YELLOW}     サービスアカウントクライアント (trino-coordinator) を作成した上で、${RESET}"
        echo -e "${YELLOW}     KEYCLOAK_ISSUER_URL / TRINO_OIDC_CLIENT_ID / TRINO_OIDC_CLIENT_SECRET を${RESET}"
        echo -e "${YELLOW}     'oc create secret generic trino-oidc --from-literal=...' で作成してから${RESET}"
        echo -e "${YELLOW}     再実行してください。ここでは Trino のデプロイをスキップします。${RESET}"
    else
        oc apply -f "$REPO_ROOT/openshift/dataproducts/trino-access-control-rules.json" \
            -n "$NAMESPACE" 2>/dev/null || \
        oc create configmap trino-access-control \
            --from-file=rules.json="$REPO_ROOT/openshift/dataproducts/trino-access-control-rules.json" \
            -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

        helm upgrade --install trino trino/trino \
            -n "$NAMESPACE" \
            -f "$REPO_ROOT/openshift/dataproducts/trino-values.yaml"
        echo -e "${GREEN}  → Trino デプロイ完了${RESET}"
    fi
}

dataproducts_deploy() {
    oc project "$NAMESPACE"

    echo -e "${BLUE}Flink Session Cluster (dataproducts-flink) を起動中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/dataproducts/flink-session-cluster.yaml" -n "$NAMESPACE"

    echo -e "${BLUE}依存順(OrderEvents → 後続プロダクト)でジョブを投入中...${RESET}"
    NAMESPACE="$NAMESPACE" "$SCRIPT_DIR/submit-flink-jobs.sh"
    echo -e "${GREEN}  → dataproducts の Flink ジョブ投入完了${RESET}"
}

dataproducts_schemas() {
    if [ -z "${KEYCLOAK_TOKEN_URL:-}" ] || [ -z "${REGISTRY_CLIENT_ID:-}" ] \
        || [ -z "${REGISTRY_CLIENT_SECRET:-}" ] || [ -z "${APICURIO_REGISTRY_URL:-}" ]; then
        echo -e "${RED}KEYCLOAK_TOKEN_URL / REGISTRY_CLIENT_ID / REGISTRY_CLIENT_SECRET / APICURIO_REGISTRY_URL を${RESET}"
        echo -e "${RED}環境変数で指定してください(Keycloak にサービスアカウントクライアントを作成した上で都度設定)。${RESET}"
        exit 1
    fi
    "$SCRIPT_DIR/register-schemas.sh"
}

dataproducts_cleanup() {
    oc delete flinkdeployment dataproducts-flink -n "$NAMESPACE" --ignore-not-found=true
    oc delete job -l app=dataproducts -n "$NAMESPACE" --ignore-not-found=true
    helm uninstall trino -n "$NAMESPACE" 2>/dev/null || true
    oc delete configmap trino-access-control -n "$NAMESPACE" --ignore-not-found=true
}

# =============================================================================
# Step 3: ディスパッチ
# =============================================================================

case "$1" in
    setup)   ocp_setup    ;;
    cleanup) ocp_cleanup  ;;
    skupper)
        case "$2" in
            deploy)  skupper_deploy  ;;
            retoken) skupper_retoken ;;
            status)  skupper_status  ;;
            console) skupper_console ;;
            cleanup) skupper_cleanup ;;
        esac
        ;;
    pipeline)
        case "$2" in
            deploy)  pipeline_deploy  ;;
            config)  pipeline_config  ;;
            cleanup) pipeline_cleanup ;;
        esac
        ;;
    dataproducts)
        case "$2" in
            setup)   dataproducts_setup   ;;
            deploy)  dataproducts_deploy  ;;
            schemas) dataproducts_schemas ;;
            cleanup) dataproducts_cleanup ;;
        esac
        ;;

esac
