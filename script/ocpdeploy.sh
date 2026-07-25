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
    echo "  $0 dataproducts deploy [--site asite|bsite|csite] [product...]"
    echo "                            Flink Session Cluster 起動 + Lakekeeper + スキーマ登録 + ジョブ投入 (依存順、未指定時は全プロダクト)"
    echo "                            --site は order-events のソーストピック選択に使用 (未指定時は接続中クラスターから自動判定)"
    echo "  $0 dataproducts schemas   Apicurio へスキーマ登録 (Keycloak OIDC 認証)"
    echo "  $0 dataproducts lakekeeper Lakekeeper OSS (Iceberg REST Catalog) をこのサイトに構築"
    echo "  $0 dataproducts debezium  inventory Outbox 用 Kafka Connect (Debezium) のビルド + コネクタ登録"
    echo "  $0 dataproducts cleanup   dataproducts 関連リソースの削除"
    echo ""
    echo "  $0 ai-agent mm2-tokens    A/B/Cサイトの Kafka書き込み用トークンを対話入力し、"
    echo "                            provision-site-mm2-tokens.sh で ai-agent-platform に反映"
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
            setup|deploy|schemas|lakekeeper|debezium|cleanup) ;;
            *)
                echo -e "${RED}無効なサブコマンド: dataproducts $2${RESET}"
                usage; exit 1
                ;;
        esac
        ;;
    ai-agent)
        case "$2" in
            mm2-tokens) ;;
            *)
                echo -e "${RED}無効なサブコマンド: ai-agent $2${RESET}"
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
    oc adm policy add-scc-to-user anyuid -z droneshopdb-instance -n "$NAMESPACE"
    oc adm policy add-scc-to-user anyuid -z droneshopdb-pgbackrest -n "$NAMESPACE"
    oc adm policy add-scc-to-user anyuid -z droneshopdb-repohost -n "$NAMESPACE"

    # Skupper Operator の準備（site作成等は引き続き `skupper deploy` で手動実行）
    skupper_operator_setup

    # Tekton Operator の準備（pipeline deploy 等は引き続き `pipeline deploy` で手動実行）
    pipeline_setup

    # データプロダクト基盤 (Flink Operator / MinIO / Keycloak クライアント / Trino)
    # の準備（Flink Job 投入は引き続き `dataproducts deploy` で手動実行）。
    # Iceberg REST Catalog (Lakekeeper OSS) は Data Mesh のドメイン分散原則に
    # 基づき、サイトごとに `dataproducts lakekeeper` で個別に構築する
    # (`dataproducts setup` には含まれない)。
    dataproducts_setup
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
#
# 旧 provision-dataproducts-keycloak.sh / submit-flink-jobs.sh /
# register-schemas.sh はここに統合済み (このファイル単体で完結する)。
# =============================================================================

DATAPRODUCTS_DIR="$(cd "$REPO_ROOT/../datamesh-dataproducts" && pwd)"

# ファイル名からの機械的な artifactId 導出 (<basename>-value) では
# 各 flink/*.sql が参照する value.avro-confluent.subject と一致しないものが
# あるため、明示的にマッピングする。
dataproducts_artifact_id_for() {
    case "$(basename "$1")" in
        component-stock-event.avsc) echo "component-stock-events-value" ;;
        sales-trend.avsc)           echo "sales-trends-value" ;;
        *)                          echo "$(basename "$1" .avsc)-value" ;;
    esac
}

# ---------------------------------------------------------------------------
# Keycloak (既存の RHBK) に dataproducts 用サービスアカウントクライアントを
# 作成 (既存なら再利用) し、Trino OIDC / Apicurio スキーマ登録に必要な
# Secret (dataproducts-flink-auth / trino-oidc) を生成する。
# ---------------------------------------------------------------------------
dataproducts_provision_keycloak() {
    local keycloak_namespace="${KEYCLOAK_NAMESPACE:-keycloak}"
    local realm="${KEYCLOAK_REALM:-sso}"

    if ! oc get keycloakrealmimport "${realm}" -n "${keycloak_namespace}" &>/dev/null \
        && ! oc get secret keycloak-initial-admin -n "${keycloak_namespace}" &>/dev/null; then
        echo -e "${RED}Keycloak realm '${realm}' または Secret 'keycloak-initial-admin' が ${keycloak_namespace} に見つかりません。${RESET}" >&2
        exit 1
    fi

    local kc_host kc_base keycloak_issuer_url keycloak_token_url
    kc_host="$(oc get route keycloak -n "${keycloak_namespace}" -o jsonpath='{.spec.host}')"
    kc_base="https://${kc_host}"
    keycloak_issuer_url="${kc_base}/realms/${realm}"
    keycloak_token_url="${keycloak_issuer_url}/protocol/openid-connect/token"

    echo -e "${BLUE}Keycloak (${kc_base}) の管理者トークンを取得中...${RESET}"
    local kc_admin_user kc_admin_pass admin_token
    kc_admin_user="$(oc get secret keycloak-initial-admin -n "${keycloak_namespace}" -o jsonpath='{.data.username}' | base64 -d)"
    kc_admin_pass="$(oc get secret keycloak-initial-admin -n "${keycloak_namespace}" -o jsonpath='{.data.password}' | base64 -d)"
    admin_token="$(curl -sk -X POST "${kc_base}/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=admin-cli&username=${kc_admin_user}&password=${kc_admin_pass}" \
        | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])')"

    if [ -z "${admin_token}" ]; then
        echo -e "${RED}Keycloak 管理者トークンの取得に失敗しました。${RESET}" >&2
        exit 1
    fi

    # Keycloak クライアントを作成 (既存なら再利用) し、client secret を標準出力に返す。
    _dataproducts_ensure_kc_client() {
        local client_id="$1"
        local standard_flow="$2"   # true/false: ブラウザログインを許可するか

        local existing uuid
        existing="$(curl -sk "${kc_base}/admin/realms/${realm}/clients?clientId=${client_id}" \
            -H "Authorization: Bearer ${admin_token}")"
        uuid="$(echo "${existing}" | python3 -c 'import sys,json; a=json.load(sys.stdin); print(a[0]["id"] if a else "")')"

        if [ -z "${uuid}" ]; then
            echo -e "${BLUE}  Keycloak client '${client_id}' を作成中...${RESET}" >&2
            curl -sk -X POST "${kc_base}/admin/realms/${realm}/clients" \
                -H "Authorization: Bearer ${admin_token}" \
                -H "Content-Type: application/json" \
                -d "{\"clientId\":\"${client_id}\",\"protocol\":\"openid-connect\",\"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":${standard_flow},\"directAccessGrantsEnabled\":false,\"redirectUris\":[\"*\"]}" \
                >&2
            existing="$(curl -sk "${kc_base}/admin/realms/${realm}/clients?clientId=${client_id}" \
                -H "Authorization: Bearer ${admin_token}")"
            uuid="$(echo "${existing}" | python3 -c 'import sys,json; a=json.load(sys.stdin); print(a[0]["id"] if a else "")')"
        else
            echo -e "${YELLOW}  Keycloak client '${client_id}' は既に存在します。再利用します。${RESET}" >&2
        fi

        curl -sk "${kc_base}/admin/realms/${realm}/clients/${uuid}/client-secret" \
            -H "Authorization: Bearer ${admin_token}" \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["value"])'
    }

    echo -e "${BLUE}dataproducts-registry (Apicurio スキーマ登録用) クライアントを準備中...${RESET}"
    local registry_client_secret
    registry_client_secret="$(_dataproducts_ensure_kc_client "dataproducts-registry" "false")"

    echo -e "${BLUE}trino-coordinator (Trino OIDC 用) クライアントを準備中...${RESET}"
    local trino_oidc_client_secret
    trino_oidc_client_secret="$(_dataproducts_ensure_kc_client "trino-coordinator" "true")"

    local apicurio_route apicurio_registry_url
    apicurio_route="$(oc get route -n "$NAMESPACE" -l app=droneshop-apicurioregistry -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
    if [ -z "${apicurio_route}" ]; then
        apicurio_route="$(oc get route -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' | grep -i apicurio | head -1)"
    fi
    apicurio_registry_url="http://${apicurio_route}"

    echo -e "${BLUE}Secret 'dataproducts-flink-auth' を作成中...${RESET}"
    oc create secret generic dataproducts-flink-auth -n "$NAMESPACE" \
        --from-literal=KAFKA_BOOTSTRAP_URLS="shop-cluster-kafka-bootstrap:9092" \
        --from-literal=APICURIO_REGISTRY_URL="${apicurio_registry_url}" \
        --from-literal=KEYCLOAK_TOKEN_URL="${keycloak_token_url}" \
        --from-literal=REGISTRY_CLIENT_ID="dataproducts-registry" \
        --from-literal=REGISTRY_CLIENT_SECRET="${registry_client_secret}" \
        --dry-run=client -o yaml | oc apply -f -

    # coordinator/worker 間の内部通信認証用シェアードシークレット。
    # 既存の Secret があれば使い回し、新規作成時のみ生成する
    # (helm upgrade のたびに変わるとローリング時に不整合が起きるため)。
    local internal_shared_secret
    if oc get secret trino-oidc -n "$NAMESPACE" &>/dev/null; then
        internal_shared_secret="$(oc get secret trino-oidc -n "$NAMESPACE" -o jsonpath='{.data.INTERNAL_SHARED_SECRET}' 2>/dev/null | base64 -d || true)"
    fi
    if [ -z "${internal_shared_secret:-}" ]; then
        internal_shared_secret="$(openssl rand -hex 32)"
    fi

    echo -e "${BLUE}Secret 'trino-oidc' を作成中...${RESET}"
    oc create secret generic trino-oidc -n "$NAMESPACE" \
        --from-literal=KEYCLOAK_ISSUER_URL="${keycloak_issuer_url}" \
        --from-literal=TRINO_OIDC_CLIENT_ID="trino-coordinator" \
        --from-literal=TRINO_OIDC_CLIENT_SECRET="${trino_oidc_client_secret}" \
        --from-literal=ICEBERG_REST_CATALOG_URL="http://dataproducts-lakekeeper:8181/catalog" \
        --from-literal=INTERNAL_SHARED_SECRET="${internal_shared_secret}" \
        --dry-run=client -o yaml | oc apply -f -

    echo -e "${GREEN}Keycloak クライアント / Secret のプロビジョニング完了${RESET}"
    echo "  APICURIO_REGISTRY_URL=${apicurio_registry_url}"
    echo "  KEYCLOAK_TOKEN_URL=${keycloak_token_url}"
}

dataproducts_setup() {
    oc project "$NAMESPACE"

    echo -e "${BLUE}Flink Kubernetes Operator をインストール中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/flink-operator.yaml"
    echo -e "${BLUE}Flink CRD の準備を待っています...${RESET}"
    until oc get crd flinkdeployments.flink.apache.org &>/dev/null; do sleep 5; done
    echo -e "${GREEN}  → Flink Operator 準備完了${RESET}"

    echo -e "${BLUE}Flink 用 ServiceAccount / RBAC を作成中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/dataproducts/flink-rbac.yaml" -n "$NAMESPACE"

    # ---------------------------------------------------------------
    # MinIO (Iceberg 用オブジェクトストレージ) + バケット初期化
    # 公式 Helm チャート (minio/minio) で導入する。
    # ---------------------------------------------------------------
    echo -e "${BLUE}MinIO (Iceberg 用オブジェクトストレージ) をデプロイ中...${RESET}"
    if ! oc get secret dataproducts-minio-auth -n "$NAMESPACE" &>/dev/null; then
        # rootUser / rootPassword は minio/minio チャートの existingSecret が
        # 要求するキー名。Iceberg REST Catalog もこのキー名を参照する。
        oc create secret generic dataproducts-minio-auth -n "$NAMESPACE" \
            --from-literal=rootUser=dataproducts \
            --from-literal=rootPassword="$(openssl rand -hex 16)"
    fi
    helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
    helm repo update minio >/dev/null 2>&1
    # チャートは runAsUser/fsGroup: 1000 を使うため、OpenShift の
    # restricted-v2 デフォレンジと衝突する。専用 SA (minio-sa, チャートが
    # 生成) に anyuid SCC を付与する必要がある。
    oc adm policy add-scc-to-user anyuid -z minio-sa -n "$NAMESPACE" 2>/dev/null || true
    helm upgrade --install minio minio/minio \
        -n "$NAMESPACE" \
        -f "$REPO_ROOT/openshift/dataproducts/minio-values.yaml"
    echo -e "${BLUE}  MinIO の起動を待っています...${RESET}"
    oc rollout status deployment/dataproducts-minio -n "$NAMESPACE" --timeout=180s

    echo -e "${BLUE}  Iceberg 用バケットを初期化中...${RESET}"
    oc delete job dataproducts-minio-init-bucket -n "$NAMESPACE" --ignore-not-found=true
    oc apply -f "$REPO_ROOT/openshift/dataproducts/minio-init-bucket-job.yaml" -n "$NAMESPACE"
    oc wait --for=condition=complete job/dataproducts-minio-init-bucket -n "$NAMESPACE" --timeout=180s
    echo -e "${GREEN}  → MinIO 準備完了${RESET}"

    # Iceberg REST Catalog (Lakekeeper OSS) は `dataproducts lakekeeper` で
    # サイトごとに個別デプロイする (Data Mesh のドメイン分散原則に基づき、
    # 単一の共有カタログではなくサイトごとに自己完結させる)。

    # ---------------------------------------------------------------
    # Keycloak (既存) にサービスアカウントクライアントを作成し、
    # Trino OIDC / Apicurio スキーマ登録に必要な Secret を自動生成する。
    # ---------------------------------------------------------------
    echo -e "${BLUE}Keycloak クライアント (dataproducts-registry / trino-coordinator) をプロビジョニング中...${RESET}"
    dataproducts_provision_keycloak

    dataproducts_trino_setup

    echo -e "${GREEN}dataproducts setup 完了 (Flink Operator / MinIO / Keycloak クライアント / Trino)${RESET}"
    echo -e "${YELLOW}  ※ Iceberg REST Catalog (Lakekeeper) は対象外。必要なら './script/ocpdeploy.sh dataproducts lakekeeper' を実行${RESET}"
}

# Trino (Helm chart) — OperatorHub に公式 Operator が存在しないため Helm で導入する。
# dataproducts_setup / dataproducts_deploy の両方から呼ばれる。
dataproducts_trino_setup() {
    echo -e "${BLUE}Trino (Helm chart) をインストール中...${RESET}"
    helm repo add trino https://trinodb.github.io/charts >/dev/null 2>&1 || true
    helm repo update trino >/dev/null 2>&1

    # File-based access control のルールはチャート組み込みの accessControl 設定
    # (trino-values.yaml) から Helm が configmap を自動生成するため、
    # ここで手動 configmap を作る必要はない。

    helm upgrade --install trino trino/trino \
        -n "$NAMESPACE" \
        -f "$REPO_ROOT/openshift/dataproducts/trino-values.yaml"
    echo -e "${GREEN}  → Trino デプロイ完了${RESET}"
}

# サイトごとの投入対象 (依存順: OrderEvents をハブとして先に投入し、
# それに依存するプロダクトを後段で投入する)。
# dataproduct-order-events は asite (一次発行元) と bsite (意図的に独立稼働、
# 2026-07-22 に明示的に追加) の両方に投入する。
# dataproduct-inventory-event は asite/bsite 双方で独立稼働させる
# (2026-07-22 の site 再配置決定)。
# dataproduct-assembly-line-qdca10 / qdca10pro は Flink ジョブを持たない
# (schema-only, スキーマ登録のみ実施される) が、bsite の投入対象として
# 明示的にリストしておく。
DATAPRODUCTS_ASITE_ORDER=(
    "dataproduct-order-events"
    "dataproduct-inventory-event"
)
DATAPRODUCTS_BSITE_ORDER=(
    "dataproduct-order-events"
    "dataproduct-assembly-line-qdca10"
    "dataproduct-assembly-line-qdca10pro"
    "dataproduct-customer-360"
    "dataproduct-inventory-event"
)
DATAPRODUCTS_CSITE_ORDER=(
    "dataproduct-real-time-sales-trends"
    "dataproduct-inventory-analytics"
    "dataproduct-assembly-lead-time-qdca10"
    "dataproduct-assembly-lead-time-qdca10pro"
)

# datamesh-dataproducts/*/flink/*.sql を dataproducts-flink Session Cluster に
# SQL Client 経由で投入する。引数を指定するとそのプロダクトのみ投入する。
dataproducts_submit_flink_jobs() {
    local targets=("$@")
    if [ ${#targets[@]} -eq 0 ]; then
        case "${DATAPRODUCTS_SITE:-csite}" in
            asite) targets=("${DATAPRODUCTS_ASITE_ORDER[@]}") ;;
            bsite) targets=("${DATAPRODUCTS_BSITE_ORDER[@]}") ;;
            csite) targets=("${DATAPRODUCTS_CSITE_ORDER[@]}") ;;
        esac
    fi
    local flink_deployment="dataproducts-flink"

    # order-events は 3 サイト分の生トピックを横断参照するため、投入先サイト
    # (DATAPRODUCTS_SITE: asite|bsite|csite, 未指定時は接続中クラスターから自動判定) によって
    # 「自サイト発行 (無 prefix)」と「MirrorMaker2 でミラーされたトピック
    # (shop-<site>. prefix)」の組み合わせが変わる。
    local orders_in_topic orders_up_topic eighty_six_topic
    case "${DATAPRODUCTS_SITE:-csite}" in
        asite)
            orders_in_topic="orders-in"
            orders_up_topic="shop-bsite.orders-up"
            eighty_six_topic="shop-bsite.eighty-six"
            ;;
        bsite)
            orders_in_topic="shop-asite.orders-in"
            orders_up_topic="orders-up"
            eighty_six_topic="eighty-six"
            ;;
        csite)
            orders_in_topic="shop-asite.orders-in"
            orders_up_topic="shop-bsite.orders-up"
            eighty_six_topic="shop-bsite.eighty-six"
            ;;
        *)
            echo -e "${RED}不正な --site 値: ${DATAPRODUCTS_SITE} (asite|bsite|csite のいずれか)${RESET}" >&2
            exit 1
            ;;
    esac

    # order-events の sink (dataproduct-order-events) は現状 asite でのみ
    # 稼働している。asite 以外では MirrorMaker2 でミラーされたトピック名
    # (shop-asite.dataproduct-order-events) を参照する必要がある
    # (assembly-lead-time-qdca10 / qdca10pro など、order-events を
    # コンシュームするプロダクトが bsite/csite に投入される場合に使用)。
    local order_events_topic
    case "${DATAPRODUCTS_SITE:-csite}" in
        asite) order_events_topic="dataproduct-order-events" ;;
        *)     order_events_topic="shop-asite.dataproduct-order-events" ;;
    esac

    # 各サイトの Apicurio Service Registry は完全に独立しているため、
    # MirrorMaker2 でミラーされた Avro (avro-confluent) レコードに埋め込まれた
    # schema-id は、ミラー先サイトの Registry では別のスキーマを指してしまい
    # デシリアライズが壊れる (ArrayIndexOutOfBoundsException 等)。そのため
    # order-events 由来のレコードをデシリアライズする際は、実際にそのレコードを
    # シリアライズした asite の Registry URL を明示的に使う必要がある。
    local order_events_registry_url
    case "${DATAPRODUCTS_SITE:-csite}" in
        asite) order_events_registry_url="$(oc get secret dataproducts-flink-auth -n "$NAMESPACE" -o jsonpath='{.data.APICURIO_REGISTRY_URL}' | base64 -d)" ;;
        *)     order_events_registry_url="http://droneshop-apicurioregistry-kafkasql.quarkusdroneshop-demo.router-default.apps.ocp.zgjl6.sandbox780.opentlc.com" ;;
    esac

    # dataproduct-inventory-events (component-stock-events) は 2026-07-22 の
    # site 再配置決定により asite/bsite の両方で独立稼働している
    # (order-events と異なり単一の一次発行元ではない)。csite (dataproduct-inventory-analytics)
    # のような他サイトのプロダクトが参照する際は、代表として asite 産をミラー経由で参照する。
    local inventory_events_topic
    case "${DATAPRODUCTS_SITE:-csite}" in
        asite) inventory_events_topic="dataproduct-inventory-events" ;;
        *)     inventory_events_topic="shop-asite.dataproduct-inventory-events" ;;
    esac
    local inventory_events_registry_url
    case "${DATAPRODUCTS_SITE:-csite}" in
        asite) inventory_events_registry_url="$(oc get secret dataproducts-flink-auth -n "$NAMESPACE" -o jsonpath='{.data.APICURIO_REGISTRY_URL}' | base64 -d)" ;;
        *)     inventory_events_registry_url="http://droneshop-apicurioregistry-kafkasql.quarkusdroneshop-demo.router-default.apps.ocp.zgjl6.sandbox780.opentlc.com" ;;
    esac

    echo -e "${BLUE}Flink Session Cluster (${flink_deployment}) の Rest Service を待機中...${RESET}"
    until oc get flinkdeployment "${flink_deployment}" -n "$NAMESPACE" \
        -o jsonpath='{.status.jobManagerDeploymentStatus}' 2>/dev/null | grep -q "READY"; do
        sleep 5
    done

    local product sql job_name confirm
    for product in "${targets[@]}"; do
        # 誤ったサイトへの投入を防ぐため、プロダクトごとに投入先サイトを確認する。
        read -rp "$(echo -e "${YELLOW}『${product}』を ${DATAPRODUCTS_SITE} に投入してよいですか？(yes/no/skip): ${RESET}")" confirm
        if [ "$confirm" = "skip" ] || [ "$confirm" = "no" ]; then
            echo -e "${YELLOW}  → ${product} をスキップしました${RESET}"
            continue
        fi
        if [ "$confirm" != "yes" ]; then
            echo -e "${RED}  → 'yes' 以外が入力されたため中断します${RESET}"
            exit 1
        fi

        # shop-cluster は auto.create.topics.enable: false のため、sink トピックは
        # ジョブ投入前に明示作成する。
        if [ "$product" = "dataproduct-order-events" ]; then
            oc apply -f "$REPO_ROOT/openshift/dataproducts/dataproduct-order-events-topic.yaml" -n "$NAMESPACE"
        fi
        if [ "$product" = "dataproduct-assembly-lead-time-qdca10" ] || [ "$product" = "dataproduct-assembly-lead-time-qdca10pro" ]; then
            oc apply -f "$REPO_ROOT/openshift/dataproducts/dataproduct-assembly-lead-time-topic.yaml" -n "$NAMESPACE"
        fi
        if [ "$product" = "dataproduct-real-time-sales-trends" ]; then
            oc apply -f "$REPO_ROOT/openshift/dataproducts/dataproduct-sales-trends-topic.yaml" -n "$NAMESPACE"
        fi
        if [ "$product" = "dataproduct-inventory-event" ]; then
            oc apply -f "$REPO_ROOT/openshift/dataproducts/dataproduct-inventory-event-topics.yaml" -n "$NAMESPACE"
        fi
        if [ "$product" = "dataproduct-inventory-analytics" ]; then
            oc apply -f "$REPO_ROOT/openshift/dataproducts/dataproduct-inventory-analytics-topic.yaml" -n "$NAMESPACE"
        fi
        if [ "$product" = "dataproduct-customer-360" ]; then
            oc apply -f "$REPO_ROOT/openshift/dataproducts/dataproduct-customer-360-topic.yaml" -n "$NAMESPACE"
        fi

        for sql in "${DATAPRODUCTS_DIR}/${product}"/flink/*.sql; do
            [ -e "$sql" ] || continue
            job_name="dataproducts-$(basename "$sql" .sql)"
            echo -e "${BLUE}投入中: ${product}/$(basename "$sql") → ${DATAPRODUCTS_SITE}${RESET}"

            oc create configmap "${job_name}-sql" \
                --from-file="job.sql=${sql}" \
                -n "$NAMESPACE" \
                --dry-run=client -o yaml | oc apply -f -

            # Pod は spec が不変のため、内容が前回と同一だと oc apply が無変更として
            # 何もせず「configured」と表示するだけでジョブが再投入されない。
            # 毎回確実に再投入するため、既存 Pod を先に削除する。
            oc delete pod "${job_name}" -n "$NAMESPACE" --ignore-not-found=true --wait=true

            # SQL Client はローカルで DDL/DML をプラン化するため、Session Cluster と
            # 同じ Kafka connector / Avro-Confluent format jar が実行前に
            # /opt/flink/lib に必要 (base image には含まれない)。また
            # FLINK_REST_HOST 環境変数は通常の docker-entrypoint.sh 経由でしか
            # flink-conf.yaml に反映されないため、直接呼び出す場合は
            # -Drest.address / -Dexecution.target を明示する必要がある。
            oc run "${job_name}" \
                --image=apache/flink:1.19-java17 \
                --restart=Never \
                --namespace="$NAMESPACE" \
                --overrides="
{
  \"spec\": {
    \"containers\": [{
      \"name\": \"${job_name}\",
      \"image\": \"apache/flink:1.19-java17\",
      \"command\": [\"/bin/sh\", \"-c\", \"set -e; curl -fL -o /opt/flink/lib/flink-sql-connector-kafka.jar https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.2.0-1.19/flink-sql-connector-kafka-3.2.0-1.19.jar; curl -fL -o /opt/flink/lib/flink-sql-avro-confluent-registry.jar https://repo.maven.apache.org/maven2/org/apache/flink/flink-sql-avro-confluent-registry/1.19.1/flink-sql-avro-confluent-registry-1.19.1.jar; curl -fL -o /opt/flink/lib/iceberg-flink-runtime.jar https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-flink-runtime-1.19/1.10.2/iceberg-flink-runtime-1.19-1.10.2.jar; curl -fL -o /opt/flink/lib/iceberg-aws-bundle.jar https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/1.10.2/iceberg-aws-bundle-1.10.2.jar; curl -fL -o /opt/flink/lib/hadoop-client-api.jar https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-client-api/3.3.6/hadoop-client-api-3.3.6.jar; curl -fL -o /opt/flink/lib/hadoop-client-runtime.jar https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-client-runtime/3.3.6/hadoop-client-runtime-3.3.6.jar; envsubst < /etc/flink-sql/job.sql > /tmp/job.sql; /opt/flink/bin/sql-client.sh -Dexecution.target=remote -Drest.address=${flink_deployment}-rest.${NAMESPACE}.svc -Drest.port=8081 -f /tmp/job.sql\"],
      \"env\": [
        {\"name\": \"FLINK_REST_HOST\", \"value\": \"${flink_deployment}-rest.${NAMESPACE}.svc\"},
        {\"name\": \"KAFKA_BOOTSTRAP_URLS\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"dataproducts-flink-auth\", \"key\": \"KAFKA_BOOTSTRAP_URLS\", \"optional\": true}}},
        {\"name\": \"APICURIO_REGISTRY_URL\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"dataproducts-flink-auth\", \"key\": \"APICURIO_REGISTRY_URL\", \"optional\": true}}},
        {\"name\": \"ORDERS_IN_TOPIC\", \"value\": \"${orders_in_topic}\"},
        {\"name\": \"ORDERS_UP_TOPIC\", \"value\": \"${orders_up_topic}\"},
        {\"name\": \"EIGHTY_SIX_TOPIC\", \"value\": \"${eighty_six_topic}\"},
        {\"name\": \"ORDER_EVENTS_TOPIC\", \"value\": \"${order_events_topic}\"},
        {\"name\": \"ORDER_EVENTS_REGISTRY_URL\", \"value\": \"${order_events_registry_url}\"},
        {\"name\": \"INVENTORY_EVENTS_TOPIC\", \"value\": \"${inventory_events_topic}\"},
        {\"name\": \"INVENTORY_EVENTS_REGISTRY_URL\", \"value\": \"${inventory_events_registry_url}\"},
        {\"name\": \"ICEBERG_REST_CATALOG_URL\", \"value\": \"http://dataproducts-lakekeeper:8181/catalog\"},
        {\"name\": \"AWS_ACCESS_KEY_ID\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"dataproducts-minio-auth\", \"key\": \"rootUser\", \"optional\": true}}},
        {\"name\": \"AWS_SECRET_ACCESS_KEY\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"dataproducts-minio-auth\", \"key\": \"rootPassword\", \"optional\": true}}},
        {\"name\": \"AWS_REGION\", \"value\": \"us-east-1\"}
      ],
      \"volumeMounts\": [{\"name\": \"sql\", \"mountPath\": \"/etc/flink-sql\"}]
    }],
    \"volumes\": [{\"name\": \"sql\", \"configMap\": {\"name\": \"${job_name}-sql\"}}]
  }
}" \
                --dry-run=client -o yaml | oc apply -f -
        done
    done

    echo -e "${GREEN}ジョブの投入完了${RESET}"
}

dataproducts_deploy() {
    oc project "$NAMESPACE"

    # --site <asite|bsite|csite> を先頭から取り除き、残りをプロダクトの
    # 絞り込みフィルタとして dataproducts_submit_flink_jobs に渡す。
    # 例: dataproducts deploy --site asite dataproduct-order-events
    # --site 省略時は現在ログイン中のクラスタドメイン (DOMAIN_NAME) から自動判定する
    # (黙って csite にフォールバックすると誤ったトピックへ投入する事故につながるため)。
    DATAPRODUCTS_SITE=""
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --site)
                DATAPRODUCTS_SITE="$2"
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    if [ -z "$DATAPRODUCTS_SITE" ]; then
        case "$DOMAIN_NAME" in
            *zgjl6.sandbox780*)  DATAPRODUCTS_SITE="asite" ;;
            *659hh.sandbox2372*|*2cqhd.sandbox2372*) DATAPRODUCTS_SITE="bsite" ;;
            *44gnd.sandbox850*) DATAPRODUCTS_SITE="csite" ;;
            *)
                echo -e "${RED}現在のクラスタ (${DOMAIN_NAME}) がどのサイトか自動判定できません。${RESET}" >&2
                echo -e "${RED}--site asite|bsite|csite を明示的に指定してください。${RESET}" >&2
                exit 1
                ;;
        esac
        echo -e "${YELLOW}--site 未指定のため、クラスタドメインから自動判定しました${RESET}"
    fi
    export DATAPRODUCTS_SITE
    echo -e "${BLUE}対象サイト: ${DATAPRODUCTS_SITE} (${DOMAIN_NAME})${RESET}"

    # flink-session-cluster.yaml は high-availability.storageDir 等で MinIO の
    # "dataproducts" バケットに書き込む。setup を経ずに deploy だけを実行した
    # クラスタ (dataproducts_setup 未実行、または setup が古いバージョンで
    # このバケットを作っていない) では NoSuchBucket で JobManager が
    # Init:CrashLoopBackOff になるため、deploy 側でも毎回確実性を担保する
    # (2026-07-22, 3サイト全てで発生・原因調査済み。mc mb --ignore-existing のため
    # 既に存在していても安全)。
    if oc get secret dataproducts-minio-auth -n "$NAMESPACE" &>/dev/null; then
        echo -e "${BLUE}MinIO バケット (dataproducts) の存在を確認中...${RESET}"
        oc delete job dataproducts-minio-init-bucket -n "$NAMESPACE" --ignore-not-found=true
        oc apply -f "$REPO_ROOT/openshift/dataproducts/minio-init-bucket-job.yaml" -n "$NAMESPACE"
        oc wait --for=condition=complete job/dataproducts-minio-init-bucket -n "$NAMESPACE" --timeout=180s
    fi

    echo -e "${BLUE}Flink RBAC (HA用 Lease 権限含む) を適用中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/dataproducts/flink-rbac.yaml" -n "$NAMESPACE"

    echo -e "${BLUE}Flink Session Cluster (dataproducts-flink) を起動中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/dataproducts/flink-session-cluster.yaml" -n "$NAMESPACE"
    echo -e "${BLUE}  JobManager の起動を待っています (HAで永続化されたジョブグラフの自動復旧を含む)...${RESET}"
    oc rollout status deployment/dataproducts-flink -n "$NAMESPACE" --timeout=180s 2>/dev/null || true

    echo -e "${BLUE}Flink Web Dashboard 用 Route を作成中...${RESET}"
    echo -e "${BLUE}  dataproducts-flink-rest Service の準備を待っています...${RESET}"
    until oc get svc dataproducts-flink-rest -n "$NAMESPACE" &>/dev/null; do sleep 5; done
    oc create route edge dataproducts-flink-console \
        --service=dataproducts-flink-rest --port=8081 \
        -n "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -
    echo -e "${GREEN}  → https://$(oc get route dataproducts-flink-console -n "$NAMESPACE" -o jsonpath='{.spec.host}')${RESET}"

    echo -e "${BLUE}Lakekeeper OSS (Iceberg REST Catalog) をデプロイ中...${RESET}"
    dataproducts_lakekeeper_setup

    echo -e "${BLUE}Apicurio へスキーマを登録中...${RESET}"
    # args で絞り込まれたプロダクトのみ登録 (未指定時は全プロダクト)。
    dataproducts_schemas "${args[@]}"

    echo -e "${BLUE}依存順(OrderEvents → 後続プロダクト)でジョブを投入中...${RESET}"
    # 引数で対象プロダクトを絞り込める (例: dataproducts deploy dataproduct-customer-360)。
    # 未指定時は DATAPRODUCTS_DEFAULT_ORDER の全プロダクトを投入する。
    dataproducts_submit_flink_jobs "${args[@]}"
    echo -e "${GREEN}dataproducts deploy 完了 (Flink Session Cluster / Lakekeeper / スキーマ登録 / ジョブ投入)${RESET}"
}

# Flink の value.format=avro-confluent は Apicurio の ccompat (Confluent互換)
# API 経由でスキーマを解決する。Registry REST API v2 で group=dataproducts に
# 登録しても ccompat の subjects 一覧には出てこない (group スコープが ccompat の
# フラットな subject 名前空間にマッピングされないため)。そのため ccompat API
# (/apis/ccompat/v6/subjects/{subject}/versions) に直接登録する。
dataproducts_register_schemas() {
    # 引数でプロダクトを絞り込める (例: dataproduct-order-events)。未指定時は全プロダクトの
    # スキーマを登録する。
    local products=("$@")
    if [ ${#products[@]} -eq 0 ]; then
        case "${DATAPRODUCTS_SITE:-csite}" in
            asite) products=("${DATAPRODUCTS_ASITE_ORDER[@]}") ;;
            bsite) products=("${DATAPRODUCTS_BSITE_ORDER[@]}") ;;
            csite) products=("${DATAPRODUCTS_CSITE_ORDER[@]}") ;;
        esac
    fi

    local access_token
    access_token="$(curl -sf -X POST "$KEYCLOAK_TOKEN_URL" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "grant_type=client_credentials&client_id=${REGISTRY_CLIENT_ID}&client_secret=${REGISTRY_CLIENT_SECRET}" \
        | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])')"

    local product avsc artifact_id schema_json
    for product in "${products[@]}"; do
        for avsc in "${DATAPRODUCTS_DIR}/${product}"/schema/*.avsc; do
            [ -e "$avsc" ] || continue
            artifact_id="$(dataproducts_artifact_id_for "$avsc")"

            echo -e "${BLUE}登録中: subject=${artifact_id} (${avsc})${RESET}"
            schema_json="$(python3 -c "import json,sys; print(json.dumps({'schema': open(sys.argv[1]).read()}))" "${avsc}")"
            curl -sf -X POST "${APICURIO_REGISTRY_URL}/apis/ccompat/v6/subjects/${artifact_id}/versions" \
                -H "Authorization: Bearer ${access_token}" \
                -H "Content-Type: application/vnd.schemaregistry.v1+json" \
                --data-binary "${schema_json}" \
                || echo -e "${YELLOW}  ⚠ 登録に失敗、または既に同一内容が登録済みの可能性があります${RESET}"
        done
    done

    echo -e "${GREEN}スキーマ登録完了${RESET}"
}

dataproducts_schemas() {
    # dataproducts_setup() (dataproducts_provision_keycloak) が作成した
    # Secret 'dataproducts-flink-auth' から自動的に読み取る。
    # 環境変数で明示指定されていればそちらを優先する。
    if [ -z "${KEYCLOAK_TOKEN_URL:-}" ] && oc get secret dataproducts-flink-auth -n "$NAMESPACE" &>/dev/null; then
        KEYCLOAK_TOKEN_URL="$(oc get secret dataproducts-flink-auth -n "$NAMESPACE" -o jsonpath='{.data.KEYCLOAK_TOKEN_URL}' | base64 -d)"
        REGISTRY_CLIENT_ID="$(oc get secret dataproducts-flink-auth -n "$NAMESPACE" -o jsonpath='{.data.REGISTRY_CLIENT_ID}' | base64 -d)"
        REGISTRY_CLIENT_SECRET="$(oc get secret dataproducts-flink-auth -n "$NAMESPACE" -o jsonpath='{.data.REGISTRY_CLIENT_SECRET}' | base64 -d)"
        APICURIO_REGISTRY_URL="$(oc get secret dataproducts-flink-auth -n "$NAMESPACE" -o jsonpath='{.data.APICURIO_REGISTRY_URL}' | base64 -d)"
        export KEYCLOAK_TOKEN_URL REGISTRY_CLIENT_ID REGISTRY_CLIENT_SECRET APICURIO_REGISTRY_URL
    fi

    if [ -z "${KEYCLOAK_TOKEN_URL:-}" ] || [ -z "${REGISTRY_CLIENT_ID:-}" ] \
        || [ -z "${REGISTRY_CLIENT_SECRET:-}" ] || [ -z "${APICURIO_REGISTRY_URL:-}" ]; then
        echo -e "${RED}KEYCLOAK_TOKEN_URL / REGISTRY_CLIENT_ID / REGISTRY_CLIENT_SECRET / APICURIO_REGISTRY_URL を${RESET}"
        echo -e "${RED}環境変数で指定するか、先に './script/ocpdeploy.sh dataproducts setup' を実行してください。${RESET}"
        exit 1
    fi
    dataproducts_register_schemas "$@"
}

# Lakekeeper OSS (Iceberg REST Catalog 実装) を対象サイトにのみ導入する。
# tabulario/iceberg-rest (メタデータ非永続の生マニフェスト) の置き換え。
# 全サイト共通の dataproducts_setup には含めず、明示的に呼んだサイトにのみ
# 構築する (現状は asite のみを想定)。
dataproducts_lakekeeper_setup() {
    oc project "$NAMESPACE"

    if ! oc get secret dataproducts-minio-auth -n "$NAMESPACE" &>/dev/null; then
        echo -e "${RED}Secret 'dataproducts-minio-auth' がありません。先に './script/ocpdeploy.sh dataproducts setup' を実行してください。${RESET}" >&2
        exit 1
    fi

    echo -e "${BLUE}Lakekeeper OSS (Helm chart) をインストール中...${RESET}"
    helm repo add lakekeeper https://lakekeeper.github.io/lakekeeper-charts/ >/dev/null 2>&1 || true
    helm repo update lakekeeper >/dev/null 2>&1
    # catalog イメージは uid 65532 (distroless nonroot) で動くため
    # OpenShift の restricted-v2 デフォレンジと衝突する。チャートが生成する
    # 専用 SA (dataproducts-lakekeeper, fullnameOverride 由来) に
    # anyuid SCC を付与する (db-migration Job にも同じ SA が使われる)。
    oc adm policy add-scc-to-user anyuid -z dataproducts-lakekeeper -n "$NAMESPACE" 2>/dev/null || true
    helm upgrade --install lakekeeper lakekeeper/lakekeeper \
        -n "$NAMESPACE" \
        -f "$REPO_ROOT/openshift/dataproducts/lakekeeper-values.yaml"
    oc rollout status deployment/dataproducts-lakekeeper -n "$NAMESPACE" --timeout=240s

    local lk_url="http://dataproducts-lakekeeper:8181"
    echo -e "${BLUE}Lakekeeper をブートストラップ中...${RESET}"
    local bootstrap_ok=false
    for _ in $(seq 1 30); do
        code="$(oc run lakekeeper-bootstrap-$RANDOM --image=curlimages/curl --restart=Never -n "$NAMESPACE" --rm -i --command -- \
            curl -s -o /dev/null -w '%{http_code}' -X POST "${lk_url}/management/v1/bootstrap" \
            -H 'Content-Type: application/json' \
            -d '{"accept-terms-of-use": true}' 2>/dev/null < /dev/null | grep -oE '^[0-9]{3}')"
        # 204: ブートストラップ成功 / 400 (CatalogAlreadyBootstrapped): 実行済みで
        # 冪等に成功扱いにできる / 409: 念のため許容
        if [ "$code" = "204" ] || [ "$code" = "400" ] || [ "$code" = "409" ]; then
            bootstrap_ok=true
            break
        fi
        sleep 5
    done
    if [ "$bootstrap_ok" != "true" ]; then
        echo -e "${RED}Lakekeeper のブートストラップに失敗しました。${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}  → ブートストラップ完了${RESET}"

    echo -e "${BLUE}デフォルトウェアハウス (dataproducts-warehouse, MinIO 上) を登録中...${RESET}"
    local root_user root_pass
    root_user="$(oc get secret dataproducts-minio-auth -n "$NAMESPACE" -o jsonpath='{.data.rootUser}' | base64 -d)"
    root_pass="$(oc get secret dataproducts-minio-auth -n "$NAMESPACE" -o jsonpath='{.data.rootPassword}' | base64 -d)"
    local warehouse_json
    warehouse_json=$(cat <<EOF
{
  "warehouse-name": "dataproducts",
  "storage-profile": {
    "type": "s3",
    "bucket": "dataproducts-warehouse",
    "key-prefix": "iceberg",
    "endpoint": "http://dataproducts-minio:9000",
    "region": "us-east-1",
    "path-style-access": true,
    "flavor": "s3-compat",
    "sts-enabled": false
  },
  "storage-credential": {
    "type": "s3",
    "credential-type": "access-key",
    "aws-access-key-id": "${root_user}",
    "aws-secret-access-key": "${root_pass}"
  }
}
EOF
)
    oc run lakekeeper-warehouse-$RANDOM --image=curlimages/curl --restart=Never -n "$NAMESPACE" --rm -i --command -- \
        curl -s -X POST "${lk_url}/management/v1/warehouse" \
        -H 'Content-Type: application/json' \
        -d "${warehouse_json}" \
        < /dev/null \
        || echo -e "${YELLOW}  ⚠ ウェアハウス登録に失敗、または既に登録済みの可能性があります${RESET}"

    echo -e "${GREEN}dataproducts lakekeeper 完了 (REST Catalog: ${lk_url}/catalog, warehouse: dataproducts)${RESET}"
}

# ---------------------------------------------------------------------------
# quarkusdroneshop-inventory の Debezium Outbox (droneshop.outboxevent) を
# 実際に Kafka (inventory-out) へキャプチャするための Kafka Connect 基盤。
#
# 1. datamesh-dataproducts/kafka-connect/Dockerfile (Strimzi/AMQ Streams の
#    kafka-41-rhel9 ベース + Debezium PostgreSQL コネクタプラグイン) を
#    OpenShift Docker Build でビルドし、内部レジストリへ push する。
# 2. KafkaConnect / KafkaConnector (inventory-outbox-connect.yaml) を適用する。
#    droneshopdb-pguser-droneshopadmin の password はこの関数が実行時に
#    Secret から取得して埋め込む (ファイル自体には含めない)。
#
# quarkusdroneshop-inventory は quarkus.hibernate-orm.database.generation=
# drop-and-create のため、再デプロイのたびに droneshop.outboxevent の OID が
# 変わる。publication.autocreate.mode=all_tables (inventory-outbox-connect.yaml
# 側で設定済み) によりこれに追随できるが、コネクタが一度でも古い
# publication/slot 名で稼働した後に再作成すると、Kafka Connect 内部の
# オフセットストレージに残った古いオフセットと LSN が食い違い再起動に失敗する
# ことがある。その場合は KafkaConnector を削除し、Postgres 側の
# レプリケーションスロット/パブリケーションも削除した上で、
# slot.name/publication.name/コネクタ名を変えて再適用すること
# (詳細: datamesh-dataproducts/dataproduct-inventory-event/README.md)。
# ---------------------------------------------------------------------------
dataproducts_debezium_setup() {
    oc project "$NAMESPACE"

    echo -e "${BLUE}Debezium コネクタ用 Kafka Connect イメージ (dataproducts-connect) をビルド中...${RESET}"
    if ! oc get bc dataproducts-connect -n "$NAMESPACE" &>/dev/null; then
        oc new-build --binary --strategy=docker --name=dataproducts-connect -n "$NAMESPACE"
    fi
    oc start-build dataproducts-connect --from-dir="${DATAPRODUCTS_DIR}/kafka-connect" --follow -n "$NAMESPACE"

    if ! oc get secret droneshopdb-pguser-droneshopadmin -n "$NAMESPACE" &>/dev/null; then
        echo -e "${RED}Secret 'droneshopdb-pguser-droneshopadmin' がありません。先に droneshopdb (PostgresCluster) をデプロイしてください。${RESET}" >&2
        exit 1
    fi

    echo -e "${BLUE}KafkaConnect / KafkaConnector (inventory outbox) を適用中...${RESET}"
    local dbpw
    dbpw="$(oc get secret droneshopdb-pguser-droneshopadmin -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)"
    python3 -c "
import sys
pw = sys.argv[1]
with open(sys.argv[2]) as f:
    content = f.read()
print(content.replace('__DRONESHOPDB_ADMIN_PASSWORD__', pw))
" "$dbpw" "$REPO_ROOT/openshift/dataproducts/inventory-outbox-connect.yaml" | oc apply -f - -n "$NAMESPACE"

    echo -e "${BLUE}  KafkaConnect Pod の起動を待っています...${RESET}"
    until oc get pods -n "$NAMESPACE" -l strimzi.io/cluster=dataproducts-connect,strimzi.io/kind=KafkaConnect 2>/dev/null | grep -q "1/1.*Running"; do
        sleep 5
    done

    local connector_name
    connector_name="$(grep -A2 '^kind: KafkaConnector' "$REPO_ROOT/openshift/dataproducts/inventory-outbox-connect.yaml" | grep 'name:' | awk '{print $2}')"
    echo -e "${GREEN}dataproducts debezium 完了 (Kafka Connect: dataproducts-connect / コネクタ: ${connector_name})${RESET}"
    echo -e "${YELLOW}  ※ 状態確認: oc get kafkaconnector -n ${NAMESPACE}${RESET}"
}

dataproducts_cleanup() {
    oc delete route dataproducts-flink-console -n "$NAMESPACE" --ignore-not-found=true
    oc delete flinkdeployment dataproducts-flink -n "$NAMESPACE" --ignore-not-found=true
    oc delete job -l app=dataproducts -n "$NAMESPACE" --ignore-not-found=true
    helm uninstall trino -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall minio -n "$NAMESPACE" 2>/dev/null || true
    helm uninstall lakekeeper -n "$NAMESPACE" 2>/dev/null || true
    oc delete configmap trino-access-control -n "$NAMESPACE" --ignore-not-found=true
    oc delete job dataproducts-minio-init-bucket -n "$NAMESPACE" --ignore-not-found=true
    oc delete kafkaconnector -l strimzi.io/cluster=dataproducts-connect -n "$NAMESPACE" --ignore-not-found=true
    oc delete kafkaconnect dataproducts-connect -n "$NAMESPACE" --ignore-not-found=true
    # Secret (dataproducts-minio-auth / dataproducts-flink-auth / trino-oidc) と
    # Keycloak クライアント (dataproducts-registry / trino-coordinator) は
    # 認証情報の再生成コストが高いため cleanup では削除しない。
    # 完全に作り直したい場合は個別に削除すること。
}

# =============================================================================
# ai-agent サブコマンド
# =============================================================================

AI_AGENT_PLATFORM_DIR="$(cd "$REPO_ROOT/../datamesh-ai-agent-platform" && pwd)"

# A/B/Cサイトの Kafka 書き込み用トークン (KafkaTopic/KafkaMirrorMaker2 CR の
# get/list/create/update/patch のみを許可する最小権限 ServiceAccount のトークン)
# を対話入力させ、provision-site-mm2-tokens.sh (datamesh-ai-agent-platform側) を
# 直接トークン方式で実行する。
#
# サイト管理者パスワードを持たない場合(例: Skupper 経由の到達性のみで、
# サイト側の ServiceAccount 発行は別途各サイトで済ませている場合)に使う。
# 各サイトは空Enterでスキップ可能(該当サイトの Secret は作成されない)。
ai_agent_mm2_tokens() {
    echo -e "${BLUE}A/B/Cサイトの Kafka書き込み用トークンを設定します(不要なサイトは空Enterでスキップ)${RESET}"

    local site prefix server_var token_var server token
    for site in asite bsite csite; do
        prefix="$(echo "$site" | tr '[:lower:]' '[:upper:]')"
        server_var="${prefix}_MM2_API_SERVER"
        token_var="${prefix}_MM2_TOKEN"

        read -rp "[${site}] API サーバー URL (例: https://api.xxx.opentlc.com:6443) : " server
        if [ -z "$server" ]; then
            echo -e "${YELLOW}[${site}] スキップします${RESET}"
            continue
        fi
        read -rsp "[${site}] トークン: " token
        echo ""
        if [ -z "$token" ]; then
            echo -e "${RED}[${site}] トークンが未入力のためスキップします${RESET}" >&2
            continue
        fi

        export "${server_var}=${server}"
        export "${token_var}=${token}"
    done

    if [ -z "${ASITE_MM2_API_SERVER:-}${BSITE_MM2_API_SERVER:-}${CSITE_MM2_API_SERVER:-}" ]; then
        echo -e "${YELLOW}全サイトがスキップされました。何も実行せず終了します。${RESET}"
        return 0
    fi

    echo -e "${BLUE}provision-site-mm2-tokens.sh を実行中...${RESET}"
    (cd "$AI_AGENT_PLATFORM_DIR" && ./scripts/provision-site-mm2-tokens.sh)

    echo -e "${GREEN}ai-agent mm2-tokens 完了${RESET}"
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
            deploy)  dataproducts_deploy "${@:3}"  ;;
            schemas) dataproducts_schemas "${@:3}" ;;
            lakekeeper) dataproducts_lakekeeper_setup ;;
            debezium) dataproducts_debezium_setup ;;
            cleanup) dataproducts_cleanup ;;
        esac
        ;;

esac
