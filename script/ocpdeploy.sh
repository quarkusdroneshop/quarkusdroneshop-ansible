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
    echo "  $0 acm                    RHACM への追加クラスタ import"
    echo ""
    echo "  $0 skupper deploy         Skupper + Kafka クラスター構築"
    echo "  $0 skupper retoken        Skupper トークン再作成"
    echo "  $0 skupper status         Skupper ステータス確認"
    echo "  $0 skupper console        Skupper コンソールデプロイ"
    echo "  $0 skupper cleanup        Skupper リソース削除"
    echo ""
    echo "  $0 pipeline setup         Tekton Operator インストール"
    echo "  $0 pipeline deploy        Pipeline kustomize デプロイ"
    echo "  $0 pipeline config        Demo ConfigMap 設定"
    echo "  $0 pipeline cleanup       CICD NS 削除"

}

# =============================================================================
# Step 1: コマンド検証（無効なら即終了）
# =============================================================================

case "$1" in
    setup|cleanup|acm) ;;
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

# =============================================================================
# RHACM: 追加クラスタの import（ACM_WORKLOADS=y でハブを構築済みの場合のみ）
# =============================================================================

acm_import_cluster() {
    echo -e "${YELLOW}-------------------------------------------${RESET}"

    if ! oc get multiclusterhub -n open-cluster-management &>/dev/null; then
        echo -e "${YELLOW}RHACM (MultiClusterHub) が見つかりません。importをスキップします。${RESET}"
        echo -e "${YELLOW}(ACM_WORKLOADS=y でハブを構築した場合のみ、このステップは有効になります)${RESET}"
        return
    fi

    read -p "追加クラスタをRHACMにimportしますか？(yes/no): " ACM_IMPORT_CONFIRM
    if [ "$ACM_IMPORT_CONFIRM" != "yes" ]; then
        echo "importをスキップします。"
        return
    fi

    echo -e "${YELLOW}利用可能な oc context 一覧:${RESET}"
    oc config get-contexts -o name

    read -p "importするクラスタの oc context 名を入力してください: " TARGET_CONTEXT
    if ! oc config get-contexts -o name | grep -qx "$TARGET_CONTEXT"; then
        echo -e "${RED}指定された context が見つかりません: $TARGET_CONTEXT${RESET}"
        return 1
    fi

    read -p "RHACM上でのクラスタ名を入力してください: " TARGET_CLUSTER_NAME
    if [ -z "$TARGET_CLUSTER_NAME" ]; then
        echo -e "${RED}クラスタ名が指定されていません。${RESET}"
        return 1
    fi

    HUB_CONTEXT=$(oc config current-context)
    echo -e "${BLUE}ハブ context: $HUB_CONTEXT / 対象 context: $TARGET_CONTEXT${RESET}"

    # --- ハブ側: namespace + ManagedCluster を作成 ---
    oc --context="$HUB_CONTEXT" get namespace "$TARGET_CLUSTER_NAME" >/dev/null 2>&1 || \
        oc --context="$HUB_CONTEXT" create namespace "$TARGET_CLUSTER_NAME"

    cat <<EOF | oc --context="$HUB_CONTEXT" apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${TARGET_CLUSTER_NAME}
spec:
  hubAcceptsClient: true
EOF

    # --- import 用マニフェストが自動生成される Secret を待つ ---
    echo -e "${BLUE}import 用 Secret の生成を待っています...${RESET}"
    until oc --context="$HUB_CONTEXT" get secret "${TARGET_CLUSTER_NAME}-import" -n "$TARGET_CLUSTER_NAME" &>/dev/null; do
        sleep 5
    done

    # --- 生成された CRD / import マニフェストを対象クラスタへ適用 ---
    echo -e "${BLUE}klusterlet CRD を対象クラスタへ適用中...${RESET}"
    oc --context="$HUB_CONTEXT" get secret "${TARGET_CLUSTER_NAME}-import" -n "$TARGET_CLUSTER_NAME" \
        -o jsonpath='{.data.crds\.yaml}' | base64 --decode | oc --context="$TARGET_CONTEXT" apply -f -

    sleep 10

    echo -e "${BLUE}import マニフェストを対象クラスタへ適用中...${RESET}"
    oc --context="$HUB_CONTEXT" get secret "${TARGET_CLUSTER_NAME}-import" -n "$TARGET_CLUSTER_NAME" \
        -o jsonpath='{.data.import\.yaml}' | base64 --decode | oc --context="$TARGET_CONTEXT" apply -f -

    # --- ハブ側で join 完了を待つ ---
    echo -e "${BLUE}クラスタの join を待っています（数分かかることがあります）...${RESET}"
    for i in $(seq 1 40); do
        AVAILABLE=$(oc --context="$HUB_CONTEXT" get managedcluster "$TARGET_CLUSTER_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null)
        if [ "$AVAILABLE" == "True" ]; then
            echo -e "${GREEN}クラスタ ${TARGET_CLUSTER_NAME} の import が完了しました。${RESET}"
            return 0
        fi
        sleep 30
    done
    echo -e "${RED}タイムアウトしました。RHACM コンソールでステータスを確認してください。${RESET}"
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

skupper_operator_setup() {
    oc project "$NAMESPACE"

    echo -e "${BLUE}Skupper Operator をインストール中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/skupper-operator.yaml"

    echo -e "${BLUE}Skupper CRD の準備を待っています...${RESET}"
    until oc get crd sites.skupper.io &>/dev/null; do sleep 5; done
    echo -e "${GREEN}  → Skupper CRD 準備完了${RESET}"
}

skupper_deploy() {
    skupper_operator_setup

    read -p "どのサイトを構築しますか？(A/B/C/DH): " SITE_CONFREM

    if [ "$SITE_CONFREM" = "A" ]; then
        skupper site create skupper-asite
        skupper site update --enable-link-access -n "$NAMESPACE"
        skupper site status
        skupper token issue "$REPO_ROOT/skupper-token-a.yaml" -r 3

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
        skupper connector create external-shop-cluster-postgres-asite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"
        skupper connector create external-shop-cluster-apicurio 8080 --selector app=droneshop-apicurioregistry-kafkasql -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-asite.yaml" -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-a-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "B" ]; then
        skupper site create skupper-bsite
        skupper site update --enable-link-access -n "$NAMESPACE"
        skupper site status
        skupper token issue "$REPO_ROOT/skupper-token-b.yaml" -r 3

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
        skupper connector create external-shop-cluster-postgres-bsite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-bsite.yaml" -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-b-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "C" ]; then
        skupper site create skupper-csite
        skupper site update --enable-link-access -n "$NAMESPACE"
        skupper site status
        skupper token issue "$REPO_ROOT/skupper-token-c.yaml" -r 3

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
        skupper connector create external-shop-cluster-postgres-csite 5432 --selector postgres-operator.crunchydata.com/instance-set=droneshopdb -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/droneshop-cluster-kafka-bootstrap-listeners-csite.yaml" -n "$NAMESPACE"
        oc apply -f "$REPO_ROOT/openshift/kafka-mm2-c-site.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "DH" ]; then
        skupper site create skupper-rhdh
        skupper site update --enable-link-access -n "$NAMESPACE"
        skupper site status
        skupper token issue "$REPO_ROOT/skupper-token-dh.yaml" -r 3

        read -p "LINK を作成しますか？(yes/no): " LINK_CONFREM
        if [ "$LINK_CONFREM" != "yes" ]; then
            echo -e "${YELLOW}処理を終了します。${RESET}"; exit 1
        fi

        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-asite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-bsite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-kafka-csite 9094 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-apicurio 8080 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-postgres-asite 5432 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-postgres-bsite 5432 -n "$NAMESPACE"
        skupper listener create external-shop-cluster-postgres-csite 5432 -n "$NAMESPACE"
    fi

    sleep 10
    skupper link status
    skupper listener status
    skupper connector status
}

skupper_retoken() {
    read -p "どのサイトで LINK を再作成しますか？(A/B/C/DH): " SITE_CONFREM

    if [ "$SITE_CONFREM" = "A" ]; then
        skupper token issue "$REPO_ROOT/skupper-token-a.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "B" ]; then
        skupper token issue "$REPO_ROOT/skupper-token-b.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "C" ]; then
        skupper token issue "$REPO_ROOT/skupper-token-c.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"

    elif [ "$SITE_CONFREM" = "DH" ]; then
        skupper token issue "$REPO_ROOT/skupper-token-dh.yaml" -r 3
        oc delete accesstokens.skupper.io --all -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-a.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-b.yaml" -n "$NAMESPACE"
        skupper token redeem "$REPO_ROOT/skupper-token-c.yaml" -n "$NAMESPACE"

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
    fi

    sleep 5
    skupper site status
    skupper link status
    skupper listener status
    skupper connector status
}

skupper_status() {
    skupper site status
    skupper link status
    skupper listener status
    skupper connector status
}

skupper_console() {
    echo -e "${BLUE}Skupper Network Observer (コンソール) をデプロイ中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/skupper-network-observer.yaml" -n "$NAMESPACE"

    echo -e "${BLUE}Pod の起動を待っています...${RESET}"
    oc rollout status deployment/skupper-network-observer -n "$NAMESPACE" --timeout=120s
    oc rollout status deployment/skupper-prometheus -n "$NAMESPACE" --timeout=120s

    CONSOLE_URL=$(oc get route skupper-network-observer -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    echo -e "${GREEN}Skupper コンソール URL: https://${CONSOLE_URL}${RESET}"
}

skupper_cleanup() {
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
# Step 3: ディスパッチ
# =============================================================================

case "$1" in
    setup)   ocp_setup           ;;
    cleanup) ocp_cleanup         ;;
    acm)     acm_import_cluster  ;;
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
            setup)   pipeline_setup   ;;
            deploy)  pipeline_deploy  ;;
            config)  pipeline_config  ;;
            cleanup) pipeline_cleanup ;;
        esac
        ;;

esac
