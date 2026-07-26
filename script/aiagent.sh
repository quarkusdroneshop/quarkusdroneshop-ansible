#!/bin/bash
# =============================================================================
# Script Name: aiagent.sh
# Description: Datamesh AI Agent Platform を OpenShift AI 上にデプロイする
# Author: Noriaki Mushino
# Date Created: 2026-06-26
# Last Modified: 2026-07-18
# Version: 1.1
#
# Usage:
#   ./script/aiagent.sh setup           - OpenShift AI Operator / 前提ミドルをインストール
#   ./script/aiagent.sh deploy          - AI Agent Platform をデプロイ (dev overlay)
#   ./script/aiagent.sh deploy-prod     - AI Agent Platform を本番デプロイ (prod overlay)
#   ./script/aiagent.sh deploy-latest   - ai-agent-cicd パイプラインの最新ビルドイメージのみ反映
#   ./script/aiagent.sh vllm            - vLLM モデルサービングをデプロイ
#   ./script/aiagent.sh keycloak        - Keycloak レルム/クライアント/初期ユーザーの作成
#   ./script/aiagent.sh mm2-tokens      - A/B/CサイトのKafka書き込み用トークンを設定
#   ./script/aiagent.sh status          - 全コンポーネントの状態確認
#   ./script/aiagent.sh logs            - AI Agent の最新ログを表示
#   ./script/aiagent.sh cleanup         - AI Agent Platform を削除
#
# Prerequisites:
#   - OpenShift CLI (oc) が インストール・ログイン済み
#   - helm がインストール済み
#   - git がインストール済み
#   - figlet がインストール済み
#   - MacOS または Linux で動作確認済み
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── 定数 ──────────────────────────────────────────────────────────────────────
AI_AGENT_NAMESPACE="ai-agent-platform"
RHOAI_NAMESPACE="redhat-ods-operator"
MODEL_NAMESPACE="ai-model-serving"
CICD_NAMESPACE="ai-agent-cicd"

PLATFORM_REPO="https://github.com/nmushino/datamesh-ai-agent-platform.git"
PLATFORM_DIR="${SCRIPT_DIR}/tmp-datamesh-ai-agent-platform"

# vLLM モデル設定 (環境変数で上書き可能)
MODEL_NAME="${VLLM_MODEL_NAME:-Qwen/Qwen3-8B}"
MODEL_DISPLAY_NAME="${VLLM_MODEL_DISPLAY_NAME:-qwen3-8b}"

# ─── カラー定義 ────────────────────────────────────────────────────────────────
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0 setup         OpenShift AI / Streams for Apache Kafka / Tekton Operator をインストール"
    echo "  $0 vllm          vLLM モデルサービングをデプロイ (${MODEL_NAME})"
    echo "  $0 keycloak      Keycloak レルム/クライアント(business-api, chat-ui)/初期ユーザーの作成 (べき等)"
    echo "  $0 mm2-tokens    A/B/CサイトのKafka書き込み用トークンを対話入力し、ai-agent-platformに反映"
    echo "  $0 deploy        AI Agent Platform を dev 環境にデプロイ"
    echo "  $0 deploy-prod   AI Agent Platform を prod 環境にデプロイ (確認あり)"
    echo "  $0 deploy-latest ai-agent-cicd パイプラインの最新ビルドイメージのみを反映"
    echo "  $0 status        全コンポーネントの状態と URL を表示"
    echo "  $0 logs [n]      AI Agent のログを表示 (デフォルト 100 行)"
    echo "  $0 cleanup       AI Agent Platform を削除"
}

# =============================================================================
# Step 1: コマンド検証（無効なら即終了）
# =============================================================================

case "${1:-}" in
    setup|vllm|keycloak|mm2-tokens|deploy|deploy-prod|deploy-latest|status|logs|cleanup) ;;
    *)
        echo -e "${RED}無効なコマンドです: ${1:-（引数なし）}${RESET}"
        usage; exit 1
        ;;
esac

# =============================================================================
# Step 2: ロゴ表示・OCP 接続確認
# =============================================================================

figlet "DS AI Agent" 2>/dev/null || echo "=== Datamesh AI Agent Platform ==="
echo -e "${CYAN}Datamesh AI Agent Platform — OpenShift AI Deployment${RESET}"
echo ""

oc status
oc version

if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)
APPS_DOMAIN="apps.${DOMAIN_NAME}"

# ─── ドメイン確認 (status / logs はスキップ) ──────────────────────────────────
if [[ "${1:-}" != "status" && "${1:-}" != "logs" ]]; then
    echo ""
    echo -e "${YELLOW}Cluster Domain : ${DOMAIN_NAME}${RESET}"
    echo -e "${YELLOW}Apps Domain    : ${APPS_DOMAIN}${RESET}"
    echo -e "-------------------------------------------"
    read -rp "指定されたドメインで間違いないですか？(yes/no): " DOMAIN_CONFREM
    if [ "$DOMAIN_CONFREM" != "yes" ]; then
        echo -e "${RED}処理を中断します。${RESET}"
        exit 1
    fi
fi

# ─── ユーティリティ関数 ────────────────────────────────────────────────────────

# コマンドの存在確認
_require() {
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}エラー: '$cmd' が見つかりません。インストールしてください。${RESET}" >&2
            exit 1
        fi
    done
}

# リソースの準備完了を待機 (oc wait ラッパー)
_wait_ready() {
    local kind="$1" name="$2" ns="$3" timeout="${4:-300s}"
    echo -e "${BLUE}  待機中: ${kind}/${name} in ${ns} (timeout: ${timeout})${RESET}"
    oc wait "${kind}/${name}" -n "${ns}" \
        --for=condition=Available \
        --timeout="${timeout}" 2>/dev/null \
    || oc rollout status "${kind}/${name}" -n "${ns}" --timeout="${timeout}" 2>/dev/null \
    || true
}

# Operator の CSV が Succeeded になるまで待機
_wait_operator() {
    local ns="$1" display="$2" timeout="${3:-300}"
    echo -e "${BLUE}  Operator 起動待機中: ${display}${RESET}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local phase
        phase=$(oc get csv -n "${ns}" --no-headers 2>/dev/null \
            | grep -i "${display}" | awk '{print $NF}' | head -1 || true)
        if [ "${phase}" = "Succeeded" ]; then
            echo -e "${GREEN}  → ${display} Operator: Succeeded${RESET}"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -e "${YELLOW}  → ${phase:-待機中...} (${elapsed}s / ${timeout}s)${RESET}"
    done
    echo -e "${YELLOW}  ⚠ タイムアウト。手動で確認してください: oc get csv -n ${ns}${RESET}"
}

# リポジトリをクローン (既存なら pull)
_sync_repo() {
    if [ -d "${PLATFORM_DIR}/.git" ]; then
        echo -e "${BLUE}  リポジトリを更新中: ${PLATFORM_DIR}${RESET}"
        git -C "${PLATFORM_DIR}" pull --ff-only 2>/dev/null \
            || echo -e "${YELLOW}  ⚠ git pull に失敗。既存ディレクトリを使用します。${RESET}"
    else
        echo -e "${BLUE}  リポジトリをクローン中: ${PLATFORM_REPO}${RESET}"
        git clone "${PLATFORM_REPO}" "${PLATFORM_DIR}"
    fi
}

# ─── Keycloak (keycloak namespace の既存共有インスタンス) に AI Agent 用の ───
# ─── レルム・クライアント・初期ユーザーを作成する ──────────────────────────
# KeycloakRealmImport CR は初回インポートしか反映されず、かつ他 namespace の
# Keycloak CR を跨いで参照できないため、Admin REST API を直接叩いて冪等に作成する。
# (これが無いと business-api が起動時に Keycloak realm "ai-agent" を見つけられず
# OidcCommonUtils で "OIDC Server is not available" → クラッシュループする。
# 2026-07-22, sandbox39 で発生・原因調査済み。deploy.sh の同名関数を移植した。)
provision_keycloak() {
    local keycloak_namespace="${KEYCLOAK_NAMESPACE:-keycloak}"
    local keycloak_realm="${KEYCLOAK_REALM:-ai-agent}"

    local keycloak_route_host
    keycloak_route_host="$(oc get route keycloak -n "$keycloak_namespace" -o jsonpath='{.spec.host}' 2>/dev/null)"
    if [ -z "$keycloak_route_host" ]; then
        keycloak_route_host="$(oc get route -n "$keycloak_namespace" -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
    fi
    if [ -z "$keycloak_route_host" ]; then
        echo -e "${YELLOW}  警告: ${keycloak_namespace} namespace に Keycloak の Route が見つかりません。レルム作成をスキップします${RESET}"
        return 0
    fi

    local admin_user admin_password base_url
    admin_user="${KEYCLOAK_ADMIN_USER:-$(oc get secret keycloak-initial-admin -n "$keycloak_namespace" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)}"
    admin_password="${KEYCLOAK_ADMIN_PASSWORD:-$(oc get secret keycloak-initial-admin -n "$keycloak_namespace" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)}"
    if [ -z "$admin_user" ] || [ -z "$admin_password" ]; then
        echo -e "${YELLOW}  警告: Keycloak管理者認証情報を取得できません。レルム作成をスキップします${RESET}"
        return 0
    fi
    base_url="https://${keycloak_route_host}/admin/realms"

    # NOTE: master レルムの admin-cli トークンは既定で有効期限が60秒しかなく、
    # このステップ全体(存在確認GET x4 + 作成POST)を1つのトークンで
    # 使い回すと、途中でトークンが失効して "401 Unauthorized" になり
    # レルム作成以降が全て失敗することを実際に確認した(2026-07-24)。
    # そのため各ステップの直前で毎回トークンを取り直す。
    _kc_token() {
        curl -sk -X POST "https://${keycloak_route_host}/realms/master/protocol/openid-connect/token" \
            -d "grant_type=password" -d "client_id=admin-cli" \
            -d "username=${admin_user}" -d "password=${admin_password}" \
            | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null
    }

    local admin_token auth_header
    admin_token="$(_kc_token)"
    if [ -z "$admin_token" ]; then
        echo -e "${YELLOW}  警告: Keycloak管理者トークンの取得に失敗しました。レルム作成をスキップします${RESET}"
        return 0
    fi
    auth_header="Authorization: Bearer ${admin_token}"

    if [ "$(curl -sk -o /dev/null -w '%{http_code}' -H "$auth_header" "${base_url}/${keycloak_realm}")" != "200" ]; then
        auth_header="Authorization: Bearer $(_kc_token)"
        curl -sk -X POST "${base_url}" -H "$auth_header" -H "Content-Type: application/json" \
            -d "{\"id\":\"${keycloak_realm}\",\"realm\":\"${keycloak_realm}\",\"enabled\":true}" >/dev/null
        echo -e "${GREEN}  → レルム ${keycloak_realm} を作成しました${RESET}"
    else
        echo -e "${YELLOW}  → レルム ${keycloak_realm}: 作成済み${RESET}"
    fi

    # business-api用 confidentialクライアント (サービスアカウント有効)
    auth_header="Authorization: Bearer $(_kc_token)"
    if [ "$(curl -sk -H "$auth_header" "${base_url}/${keycloak_realm}/clients?clientId=business-api" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null)" == "0" ]; then
        auth_header="Authorization: Bearer $(_kc_token)"
        curl -sk -X POST "${base_url}/${keycloak_realm}/clients" -H "$auth_header" -H "Content-Type: application/json" -d "{
      \"clientId\": \"business-api\",
      \"secret\": \"${KEYCLOAK_CLIENT_SECRET:-dev-client-secret}\",
      \"enabled\": true,
      \"standardFlowEnabled\": true,
      \"serviceAccountsEnabled\": true,
      \"directAccessGrantsEnabled\": true,
      \"redirectUris\": [\"*\"]
    }" >/dev/null
        echo -e "${GREEN}  → クライアント business-api を作成しました${RESET}"
    else
        echo -e "${YELLOW}  → クライアント business-api: 作成済み${RESET}"
    fi

    # chat-ui用 publicクライアント (Authorization Code + PKCE)
    auth_header="Authorization: Bearer $(_kc_token)"
    if [ "$(curl -sk -H "$auth_header" "${base_url}/${keycloak_realm}/clients?clientId=chat-ui" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null)" == "0" ]; then
        auth_header="Authorization: Bearer $(_kc_token)"
        curl -sk -X POST "${base_url}/${keycloak_realm}/clients" -H "$auth_header" -H "Content-Type: application/json" -d "{
      \"clientId\": \"chat-ui\",
      \"publicClient\": true,
      \"enabled\": true,
      \"standardFlowEnabled\": true,
      \"directAccessGrantsEnabled\": false,
      \"redirectUris\": [\"*\"],
      \"webOrigins\": [\"*\"],
      \"attributes\": {\"pkce.code.challenge.method\": \"S256\"}
    }" >/dev/null
        echo -e "${GREEN}  → クライアント chat-ui を作成しました${RESET}"
    else
        echo -e "${YELLOW}  → クライアント chat-ui: 作成済み${RESET}"
    fi

    # 初期ユーザー
    local initial_username="${KEYCLOAK_INITIAL_USERNAME:-nmushino}"
    auth_header="Authorization: Bearer $(_kc_token)"
    if [ "$(curl -sk -H "$auth_header" "${base_url}/${keycloak_realm}/users?username=${initial_username}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null)" == "0" ]; then
        auth_header="Authorization: Bearer $(_kc_token)"
        curl -sk -X POST "${base_url}/${keycloak_realm}/users" -H "$auth_header" -H "Content-Type: application/json" -d "{
      \"username\": \"${initial_username}\",
      \"firstName\": \"Noriaki\",
      \"lastName\": \"Mushino\",
      \"email\": \"${KEYCLOAK_INITIAL_USER_EMAIL:-nmushino@redhat.com}\",
      \"enabled\": true,
      \"credentials\": [{\"type\": \"password\", \"value\": \"${KEYCLOAK_INITIAL_USER_PASSWORD:-changeme123}\", \"temporary\": true}]
    }" >/dev/null
        echo -e "${GREEN}  → 初期ユーザー ${initial_username} を作成しました(初回ログイン時パスワード変更必須)${RESET}"
    else
        echo -e "${YELLOW}  → 初期ユーザー ${initial_username}: 作成済み${RESET}"
    fi

    # business-api の OIDC 設定は internal Route hostname (sso.apps...) 経由の
    # 外部到達性が pod ネットワークから無い場合があるため、discovery で返る
    # jwks_uri 等の外部URLに頼らず、内部 Service (https://keycloak.<ns>.svc.cluster.local:8443)
    # を discovery 無効化 + 相対パス指定で使う構成を前提とする
    # (business-api-config ConfigMap の keycloak-url、および
    # QUARKUS_OIDC_DISCOVERY_ENABLED=false 等の env は deploy() 側で設定する)。
}

# ─── mm2-tokens: A/B/C サイトの Kafka 書き込み用トークンを設定 ─────────────────
# KafkaTopic/KafkaMirrorMaker2 CR の get/list/create/update/patch のみを許可する
# 最小権限 ServiceAccount のトークンを対話入力させ、
# scripts/provision-site-mm2-tokens.sh (直接トークン方式) を実行して
# ai-agent-platform namespace の <site>-mm2-pause-token Secret に反映する。
# これが無いと tools/kafka/admin_tools.py の create_kafka_topic (managed=True) /
# delete_kafka_topic が「K8s API 認証情報が未設定」で失敗する。
#
# サイト管理者パスワードを持たない場合(例: Skupper 経由の到達性のみで、
# サイト側の ServiceAccount 発行は別途各サイトで済ませている場合)に使う。
# 各サイトは空Enterでスキップ可能(該当サイトの Secret は作成されない)。
mm2_tokens() {
    _sync_repo

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
    NAMESPACE="$AI_AGENT_NAMESPACE" "${PLATFORM_DIR}/scripts/provision-site-mm2-tokens.sh"

    echo -e "${GREEN}mm2-tokens 完了${RESET}"
}

# ─── setup: 前提 Operator のインストール ───────────────────────────────────────
setup() {
    # Streams for Apache Kafka (旧 AMQ Streams) は quarkusdroneshop 側 (ocpdeploy.sh) の
    # リモートクラスターに既に導入済みだが、このクラスター自体には未導入のため、
    # openshift-operators (AllNamespaces) に共通コンポーネントとして新規インストールする。

    echo -e "${BLUE}=== [1/9] ノードあたりの Pod 上限引き上げ ===${RESET}"
    # デフォルト 250 だと RHACM 等の追加コンポーネントがスケジュールできなくなるため、
    # master プールに適用する（このクラスターは全ノードが master ロールを兼ねる構成の
    # ため、worker プールを対象にしても実ノードに反映されない）。
    # MachineConfig の再展開が走り、対象ノードが再起動する点に注意。
    # 既に適用済みなら oc apply は無変更で完了する。
    cat <<'KUBELETCFG' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increase-max-pods
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    maxPods: 500
    podsPerCore: 0
KUBELETCFG

    echo -e "${BLUE}=== [2/9] Skupper 接続確認 ===${RESET}"
    # NOTE: `oc get csv ... | grep -q ...` は pipefail 環境下で誤判定を起こす (SIGPIPE)。
    # 必ず一度変数に capture してから grep する。
    local ALL_CSV
    ALL_CSV="$(oc get csv --all-namespaces 2>/dev/null || true)"
    if grep -q "skupper-operator.*Succeeded" <<<"${ALL_CSV}"; then
        echo -e "${GREEN}  → Skupper Operator は既に共通導入済みです ✓${RESET}"
    else
        echo -e "${YELLOW}  ⚠ Skupper Operator が見つかりません。手動でインストールしてください${RESET}"
    fi

    # Tekton Pipelines / Keycloak は cluster-wide (AllNamespaces) Operator のため、
    # 既に別の Namespace (openshift-operators / keycloak 等) にインストール済みであれば
    # 共通コンポーネントとして扱い、ここでの再インストールはスキップする。
    echo -e "${BLUE}=== [3/9] 共通コンポーネントの確認 (Pipelines / Keycloak) ===${RESET}"
    if grep -q "openshift-pipelines-operator-rh.*Succeeded" <<<"${ALL_CSV}"; then
        echo -e "${YELLOW}  → OpenShift Pipelines (Tekton) Operator は既に共通導入済みです。スキップします${RESET}"
    else
        echo -e "${YELLOW}  ⚠ OpenShift Pipelines (Tekton) Operator が見つかりません。手動でインストールしてください${RESET}"
    fi
    if grep -qi "rhbk-operator.*Succeeded" <<<"${ALL_CSV}"; then
        echo -e "${YELLOW}  → Keycloak (RHBK) Operator は既に共通導入済みです。スキップします${RESET}"
    else
        echo -e "${YELLOW}  ⚠ Keycloak (RHBK) Operator が見つかりません。手動でインストールしてください${RESET}"
    fi

    echo -e "${BLUE}=== [4/9] Streams for Apache Kafka Operator のインストール ===${RESET}"

    # このクラスター自体には Streams for Apache Kafka (Strimzi) が未導入のため、
    # openshift-operators (AllNamespaces) に共通コンポーネントとして新規インストールする。
    # (パッケージ名は amq-streams のままだが、表示名は Streams for Apache Kafka)
    if grep -qi "amqstreams.*Succeeded" <<<"${ALL_CSV}"; then
        echo -e "${YELLOW}  → Streams for Apache Kafka Operator は既に共通導入済みです。スキップします${RESET}"
    else
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: openshift-operators
spec:
  channel: stable
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  annotations:
    strimzi.io/kraft: enabled
    strimzi.io/node-pools: enabled
  name: aiagent-cluster
  namespace: openshift-operators
  labels:
    environment: dev
spec:
  kafka:
    version: "4.1.0"
    controllerReplicas: 3
    config:
      process.roles: "controller,broker"
      controller.listener.names: CONTROLLER
      log.dirs: "/var/lib/kafka/data"
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
  entityOperator:
    topicOperator: {}
    userOperator: {}
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: agent-cluster-controllers
  namespace: openshift-operators
  labels:
    strimzi.io/cluster: aiagent-cluster
spec:
  replicas: 3
  roles:
    - controller
  storage:
    type: persistent-claim
    size: 10Gi
    deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: agent-cluster-brokers
  namespace: openshift-operators
  labels:
    strimzi.io/cluster: aiagent-cluster
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: persistent-claim
    size: 10Gi
    deleteClaim: false
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: history
  namespace: openshift-operators
  labels:
    strimzi.io/cluster: aiagent-cluster
spec:
  partitions: 10
  replicas: 3
  config:
    retention.ms: 604800000
    segment.bytes: 1073741824
EOF
        echo -e "${GREEN}  → Streams for Apache Kafka Subscription を openshift-operators に適用しました${RESET}"
        _wait_operator "openshift-operators" "amqstreams" 300
    fi

    echo -e "${BLUE}=== [5/9] Streams for Apache Kafka Console のインストール ===${RESET}"

    # パッケージ名は amq-streams-console のままだが、表示名は Streams for Apache Kafka Console
    if grep -qi "amq-streams-console.*Succeeded" <<<"${ALL_CSV}"; then
        echo -e "${YELLOW}  → Streams for Apache Kafka Console は既に共通導入済みです。スキップします${RESET}"
    else
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams-console
  namespace: openshift-operators
spec:
  channel: stable
  name: amq-streams-console
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
        echo -e "${GREEN}  → Streams for Apache Kafka Console Subscription を openshift-operators に適用しました${RESET}"
        _wait_operator "openshift-operators" "amq-streams-console" 300
    fi

    echo -e "${BLUE}=== [6/9] OpenShift AI Operator (RHOAI) のインストール ===${RESET}"

    # RHOAI が既にインストール済みかを確認 (他 Namespace の共通導入も含めて確認)
    if oc get subscription rhods-operator -n "${RHOAI_NAMESPACE}" &>/dev/null \
        || grep -q "rhods-operator.*Succeeded" <<<"${ALL_CSV}"; then
        echo -e "${YELLOW}  → RHOAI Operator は既に共通導入済みです。スキップします${RESET}"
    else
        oc create namespace "${RHOAI_NAMESPACE}" 2>/dev/null \
            || echo -e "${YELLOW}  Namespace ${RHOAI_NAMESPACE} は既に存在します${RESET}"

        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: ${RHOAI_NAMESPACE}
spec:
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: ${RHOAI_NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
        echo -e "${GREEN}  → RHOAI Subscription を適用しました${RESET}"
        _wait_operator "${RHOAI_NAMESPACE}" "rhods" 360
    fi

    # DataScienceCluster の作成 (RHOAI 2.x)
    echo -e "${BLUE}=== [7/9] DataScienceCluster の作成 ===${RESET}"
    if oc get datasciencecluster default-dsc &>/dev/null; then
        echo -e "${YELLOW}  → DataScienceCluster は既に存在します${RESET}"
    else
        oc apply -f - <<EOF
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    kserve:
      managementState: Managed
      serving:
        ingressGateway:
          certificate:
            type: SelfSigned
        managementState: Managed
        name: knative-serving
    modelmeshserving:
      managementState: Removed
    ray:
      managementState: Removed
    workbenches:
      managementState: Managed
    datasciencepipelines:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
EOF
        echo -e "${GREEN}  → DataScienceCluster を作成しました${RESET}"
    fi

    echo -e "${BLUE}=== [8/9] AI Agent Platform Namespace の作成 ===${RESET}"
    oc new-project "${AI_AGENT_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  Namespace ${AI_AGENT_NAMESPACE} は既に存在します${RESET}"

    # anyuid SCC — AI Agent は UID 1001、Business API は UID 185 で動作
    oc adm policy add-scc-to-user anyuid \
        -z default -n "${AI_AGENT_NAMESPACE}" 2>/dev/null || true

    # postgresql (bitnami/postgresql系イメージ) は起動時に fsGroup=26 を要求するが、
    # restricted-v2/v3 SCC はこれを許可せず "unable to validate against any
    # security context constraint" で Pod が永久に FailedCreate になっていた
    # (2026-07-22, sandbox39 で発生・原因調査済み)。default SA には既に anyuid を
    # 付与済みだが、念のため postgresql の Deployment が使う default SA にも
    # 明示的に再付与しておく (上の行と同じ SA だが、実行順序の意図を明確化するため)。
    oc adm policy add-scc-to-user anyuid \
        -z default -n "${AI_AGENT_NAMESPACE}" 2>/dev/null || true

    echo -e "${BLUE}=== [9/9] Keycloak レルム・クライアント・初期ユーザーの作成 ===${RESET}"
    provision_keycloak

    echo ""
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}セットアップ完了${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}次のステップ:${RESET}"
    echo -e "  1. ${CYAN}./script/aiagent.sh vllm${RESET}    — vLLM モデルサービングをデプロイ"
    echo -e "  2. ${CYAN}./script/aiagent.sh deploy${RESET}  — AI Agent Platform をデプロイ"
}

# ─── vllm: モデルサービングのデプロイ ──────────────────────────────────────────
vllm() {
    _require git oc

    echo -e "${BLUE}=== vLLM モデルサービングのデプロイ ===${RESET}"
    echo -e "${YELLOW}モデル: ${MODEL_NAME}${RESET}"

    _sync_repo

    # モデルサービング専用 Namespace の作成
    # NOTE: redhat-ods-applications は RHOAI が自動生成する保護対象 namespace のため、
    # ユーザーが直接 InferenceService を作成することはできない。
    # 専用の Data Science Project (opendatahub.io/dashboard=true) を別途用意する。
    oc new-project "${MODEL_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  Namespace ${MODEL_NAMESPACE} は既に存在します${RESET}"
    oc label namespace "${MODEL_NAMESPACE}" opendatahub.io/dashboard=true --overwrite 2>/dev/null || true

    # vLLM ServingRuntime + InferenceService を適用
    # (vllm-serving.yaml 内の MODEL_DISPLAY_NAME_PLACEHOLDER を実際のモデル名に置換してから適用)
    echo -e "${BLUE}[1/3] vLLM ServingRuntime を適用中...${RESET}"
    sed "s|MODEL_DISPLAY_NAME_PLACEHOLDER|${MODEL_DISPLAY_NAME}|g" \
        "${PLATFORM_DIR}/deployment/openshift/vllm-serving.yaml" \
        | oc apply -n "${MODEL_NAMESPACE}" -f -
    echo -e "${GREEN}  → ServingRuntime / InferenceService を適用しました${RESET}"

    # モデルダウンロード用 Job (Hugging Face → PVC)
    echo -e "${BLUE}[2/3] モデルダウンロード Job を作成中...${RESET}"
    oc apply -n "${MODEL_NAMESPACE}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: download-${MODEL_DISPLAY_NAME}
  namespace: ${MODEL_NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
        - name: wait-for-pvc
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["sh", "-c", "until ls /mnt/models; do sleep 2; done"]
          volumeMounts:
            - name: model-storage
              mountPath: /mnt/models
      containers:
        - name: downloader
          image: python:3.11-slim
          command:
            - sh
            - -c
            - |
              pip install -q huggingface_hub
              python3 -c "
              from huggingface_hub import snapshot_download
              snapshot_download(
                  repo_id='${MODEL_NAME}',
                  local_dir='/mnt/models/${MODEL_DISPLAY_NAME}',
                  ignore_patterns=['*.pt', '*.bin']
              )
              print('Download complete')
              "
          resources:
            requests:
              cpu: "2"
              memory: "4Gi"
            limits:
              cpu: "4"
              memory: "8Gi"
          volumeMounts:
            - name: model-storage
              mountPath: /mnt/models
          env:
            - name: HF_HUB_DISABLE_PROGRESS_BARS
              value: "1"
            # OpenShift は任意 UID でコンテナを実行するため、デフォルトの HOME (/) は
            # 書き込み不可。pip / huggingface_hub のキャッシュ先を書き込み可能な
            # /tmp 配下に変更する。
            - name: HOME
              value: /tmp
      volumes:
        - name: model-storage
          persistentVolumeClaim:
            claimName: model-storage
EOF
    echo -e "${GREEN}  → モデルダウンロード Job を作成しました${RESET}"

    echo -e "${BLUE}[3/3] InferenceService の起動を待機中 (最大 10 分)...${RESET}"
    local elapsed=0
    while [ $elapsed -lt 600 ]; do
        local ready
        ready=$(oc get inferenceservice "${MODEL_DISPLAY_NAME}" \
            -n "${MODEL_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "${ready}" = "True" ]; then
            break
        fi
        sleep 15
        elapsed=$((elapsed + 15))
        echo -e "${YELLOW}  → 待機中... (${elapsed}s / 600s)${RESET}"
    done

    # vLLM エンドポイントを取得して表示
    local vllm_url
    vllm_url=$(oc get inferenceservice "${MODEL_DISPLAY_NAME}" \
        -n "${MODEL_NAMESPACE}" \
        -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    echo ""
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}vLLM デプロイ完了${RESET}"
    if [ -n "${vllm_url}" ]; then
        echo -e "${GREEN}エンドポイント: ${vllm_url}/v1${RESET}"
        echo -e "${YELLOW}この URL を VLLM_BASE_URL として deploy コマンドに使用します${RESET}"
    else
        echo -e "${YELLOW}⚠ エンドポイント取得に失敗。oc get inferenceservice -n ${MODEL_NAMESPACE} で確認してください${RESET}"
    fi
    echo -e "${GREEN}========================================${RESET}"
}

# ─── deploy: AI Agent Platform のデプロイ ──────────────────────────────────────
deploy() {
    local OVERLAY="${1:-dev}"
    _require git oc

    echo -e "${BLUE}=== AI Agent Platform デプロイ (overlay: ${OVERLAY}) ===${RESET}"

    _sync_repo

    # ── vLLM エンドポイント取得 ──
    # NOTE: .status.url はポート番号を含まない (例: http://host)。
    # predictor Service は headless (ClusterIP: None) のためポート変換されず、
    # ポート省略時のデフォルト80番では Connection refused になる。
    # ポート込みの .status.address.url (例: http://host:8080) を使うこと。
    local VLLM_URL
    VLLM_URL=$(oc get inferenceservice "${MODEL_DISPLAY_NAME}" \
        -n "${MODEL_NAMESPACE}" \
        -o jsonpath='{.status.address.url}' 2>/dev/null || echo "")

    if [ -z "${VLLM_URL}" ]; then
        echo -e "${YELLOW}⚠ vLLM InferenceService が見つかりません。${RESET}"
        read -rp "VLLM_BASE_URL を手動入力してください (例: https://qwen3-8b.apps.xxx.com): " VLLM_URL
    else
        VLLM_URL="${VLLM_URL}/v1"
        echo -e "${GREEN}  vLLM URL: ${VLLM_URL}${RESET}"
    fi

    # ── Secret の作成 ──
    echo -e "${BLUE}[1/6] Secret を作成中...${RESET}"

    # PostgreSQL パスワード
    local PG_PASSWORD
    if [ -n "${POSTGRESQL_PASSWORD:-}" ]; then
        PG_PASSWORD="${POSTGRESQL_PASSWORD}"
    else
        read -rsp "PostgreSQL パスワードを入力してください: " PG_PASSWORD
        echo ""
    fi

    # OpenMetadata JWT トークン
    local OM_TOKEN
    if [ -n "${OPENMETADATA_JWT_TOKEN:-}" ]; then
        OM_TOKEN="${OPENMETADATA_JWT_TOKEN}"
    else
        read -rsp "OpenMetadata JWT トークンを入力してください (未取得の場合は Enter): " OM_TOKEN
        echo ""
        OM_TOKEN="${OM_TOKEN:-dummy-token}"
    fi

    oc project "${AI_AGENT_NAMESPACE}"

    oc create secret generic postgresql-secret \
        --from-literal=password="${PG_PASSWORD}" \
        -n "${AI_AGENT_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -

    oc create secret generic agent-db-secret \
        --from-literal=url="postgresql://postgres:${PG_PASSWORD}@postgresql:5432/agentdb" \
        -n "${AI_AGENT_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -

    oc create secret generic openmetadata-secret \
        --from-literal=jwt-token="${OM_TOKEN}" \
        -n "${AI_AGENT_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -

    # business-api の Keycloak クライアントシークレット。setup() の
    # provision_keycloak() で作成したクライアントの secret と値を一致させる必要が
    # ある (不一致だと business-api が起動時に client_secret_basic 認証で失敗する)。
    # 未指定時のデフォルト値 "dev-client-secret" は provision_keycloak() 側の
    # デフォルトと揃えてある。
    oc create secret generic keycloak-secret \
        --from-literal=client-secret="${KEYCLOAK_CLIENT_SECRET:-dev-client-secret}" \
        -n "${AI_AGENT_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -

    echo -e "${GREEN}  → Secret を作成しました${RESET}"

    # ── ConfigMap の vLLM URL 上書き ──
    echo -e "${BLUE}[2/6] vLLM URL を ConfigMap に設定中...${RESET}"
    oc create configmap ai-agent-vllm-config \
        --from-literal=vllm-base-url="${VLLM_URL}" \
        --from-literal=vllm-model-name="${MODEL_DISPLAY_NAME}" \
        -n "${AI_AGENT_NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -
    echo -e "${GREEN}  → ConfigMap (ai-agent-vllm-config) を作成しました${RESET}"

    # ── Kafka 接続確認 (Skupper 経由のためデプロイ不要) ──
    echo -e "${BLUE}[3/6] Skupper Kafka 接続確認...${RESET}"
    if oc get service shop-cluster-kafka-bootstrap -n "${AI_AGENT_NAMESPACE}" &>/dev/null; then
        echo -e "${GREEN}  → Skupper 仮想 Service (shop-cluster-kafka-bootstrap): 確認済み ✓${RESET}"
    else
        echo -e "${YELLOW}  ⚠ shop-cluster-kafka-bootstrap Service が見つかりません。${RESET}"
        echo -e "${YELLOW}    Skupper リンクが未確立の可能性があります。デプロイは続行しますが、${RESET}"
        echo -e "${YELLOW}    Kafka 接続が必要な機能は Skupper 接続後に動作します。${RESET}"
    fi

    # ── Kustomize overlay 適用 ──
    echo -e "${BLUE}[4/7] Kustomize overlay (${OVERLAY}) を適用中...${RESET}"
    if ! command -v kustomize &>/dev/null; then
        echo -e "${YELLOW}  kustomize が見つかりません。oc kustomize を使用します${RESET}"
        oc apply -k "${PLATFORM_DIR}/deployment/kustomize/overlays/${OVERLAY}"
    else
        kustomize build "${PLATFORM_DIR}/deployment/kustomize/overlays/${OVERLAY}" \
            | oc apply -f -
    fi
    echo -e "${GREEN}  → Kustomize (${OVERLAY}) を適用しました${RESET}"

    # ── Route ホスト名を使って外部 URL 系の env/ConfigMap を上書き ──
    # (chat-ui/deployment.yaml, business-api-config はビルド時点で自身の Route
    #  ホスト名が分からないため空文字のまま。Route 作成後にここで実際の値を注入する)
    echo -e "${BLUE}[5/7] 外部 URL (Keycloak/OpenMetadata/RHDH 等) を設定中...${RESET}"
    local elapsed=0
    while [ $elapsed -lt 60 ]; do
        oc get route ai-agent-orchestrator -n "${AI_AGENT_NAMESPACE}" &>/dev/null \
            && oc get route business-api -n "${AI_AGENT_NAMESPACE}" &>/dev/null \
            && oc get route chat-ui -n "${AI_AGENT_NAMESPACE}" &>/dev/null \
            && break
        sleep 5
        elapsed=$((elapsed + 5))
    done

    local AI_AGENT_HOST BUSINESS_API_HOST CHAT_UI_HOST KEYCLOAK_HOST OPENMETADATA_HOST_EXT RHDH_HOST
    AI_AGENT_HOST=$(oc get route ai-agent-orchestrator -n "${AI_AGENT_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    BUSINESS_API_HOST=$(oc get route business-api -n "${AI_AGENT_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    CHAT_UI_HOST=$(oc get route chat-ui -n "${AI_AGENT_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    KEYCLOAK_HOST=$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    OPENMETADATA_HOST_EXT=$(oc get route om-proxy -n openmetadata -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    RHDH_HOST=$(oc get route backstage-developer-hub -n quarkusdroneshop-rhdh -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    if [ -n "${CHAT_UI_HOST}" ]; then
        oc set env deploy/chat-ui -n "${AI_AGENT_NAMESPACE}" \
            API_BASE_URL="https://${AI_AGENT_HOST}" \
            KEYCLOAK_URL="https://${KEYCLOAK_HOST}" \
            OPENMETADATA_URL="https://${OPENMETADATA_HOST_EXT}" \
            DEVELOPER_HUB_URL="https://${RHDH_HOST}" >/dev/null
        echo -e "${GREEN}  → chat-ui の env を設定しました${RESET}"
    else
        echo -e "${YELLOW}  ⚠ chat-ui の Route がまだ無いため env 設定をスキップ${RESET}"
    fi

    # business-api はサーバー側の OIDC トークン検証用のため、外部 Route ではなく
    # クラスター内部の Keycloak Service を使う。
    # NOTE: Keycloak CR は httpEnabled: false のため 8080(HTTP) は接続不可
    # (connection timeout, 2026-07-22 sandbox39 で確認済み)。8443(HTTPS) のみ
    # keycloak-network-policy で内部到達可能。
    oc patch configmap business-api-config -n "${AI_AGENT_NAMESPACE}" --type merge \
        -p '{"data":{"keycloak-url":"https://keycloak.keycloak.svc.cluster.local:8443"}}' >/dev/null 2>&1 \
        && echo -e "${GREEN}  → business-api-config の keycloak-url を設定しました${RESET}" \
        || echo -e "${YELLOW}  ⚠ business-api-config が見つからずスキップ${RESET}"

    # Keycloak の OIDC discovery document は内部 Service 経由で取得しても
    # issuer/jwks_uri 等が外部 Route ホスト名を返す (split-horizon)。
    # 外部ホストは Pod ネットワークから到達不可なため、discovery を無効化して
    # 全パスを内部 Keycloak 基準の相対パスで固定する
    # (2026-07-22 sandbox39 で診断・修正済み)。
    if oc get deployment business-api -n "${AI_AGENT_NAMESPACE}" &>/dev/null; then
        oc set env deployment/business-api -n "${AI_AGENT_NAMESPACE}" \
            QUARKUS_OIDC_TLS_VERIFICATION=none \
            QUARKUS_OIDC_DISCOVERY_ENABLED=false \
            QUARKUS_OIDC_AUTHORIZATION_PATH=/protocol/openid-connect/auth \
            QUARKUS_OIDC_TOKEN_PATH=/protocol/openid-connect/token \
            QUARKUS_OIDC_JWKS_PATH=/protocol/openid-connect/certs \
            QUARKUS_OIDC_USER_INFO_PATH=/protocol/openid-connect/userinfo \
            QUARKUS_OIDC_END_SESSION_PATH=/protocol/openid-connect/logout \
            QUARKUS_OIDC_INTROSPECTION_PATH=/protocol/openid-connect/token/introspect >/dev/null
        echo -e "${GREEN}  → business-api の OIDC discovery 無効化 env を設定しました${RESET}"
    else
        echo -e "${YELLOW}  ⚠ business-api Deployment がまだ無いため OIDC env 設定をスキップ${RESET}"
    fi

    # ── Tekton タスク・パイプラインをデプロイ ──
    echo -e "${BLUE}[6/7] Tekton タスク / パイプラインをデプロイ中...${RESET}"
    oc new-project "${CICD_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  Namespace ${CICD_NAMESPACE} は既に存在します${RESET}"

    # pipeline SA によるイメージビルド (別 namespace の internal registry への push) には
    # system:image-builder ロールが必要 (2026-07-21 sandbox39 で確認済み)
    oc adm policy add-role-to-user system:image-builder \
        "system:serviceaccount:${CICD_NAMESPACE}:pipeline" \
        -n "${AI_AGENT_NAMESPACE}" >/dev/null 2>&1 \
        && echo -e "${GREEN}  → pipeline SA に image-builder ロールを付与しました${RESET}" \
        || echo -e "${YELLOW}  ⚠ image-builder ロール付与に失敗 (既に付与済みの可能性)${RESET}"

    # 各パイプラインの tag-dev タスク (oc tag でコミットSHAタグを :dev へ付け替える) は
    # imagestreams の get/update が必要だが、system:image-builder には create しか
    # 含まれておらず不十分 (2026-07-24 sandbox242 の新規クラスタで
    # "cannot get resource imagestreams" により失敗するのを確認済み)。
    # edit ロールを追加で付与する。
    oc adm policy add-role-to-user edit \
        "system:serviceaccount:${CICD_NAMESPACE}:pipeline" \
        -n "${AI_AGENT_NAMESPACE}" >/dev/null 2>&1 \
        && echo -e "${GREEN}  → pipeline SA に edit ロールを付与しました (tag-dev 用)${RESET}" \
        || echo -e "${YELLOW}  ⚠ edit ロール付与に失敗 (既に付与済みの可能性)${RESET}"

    # internal registry への push 用 docker-registry Secret
    # (TriggerTemplate の workspace が参照する固定名: internal-registry-credentials)
    if ! oc get secret internal-registry-credentials -n "${CICD_NAMESPACE}" &>/dev/null; then
        local PIPELINE_SA_TOKEN
        PIPELINE_SA_TOKEN=$(oc create token pipeline -n "${CICD_NAMESPACE}" --duration=24h 2>/dev/null || echo "")
        if [ -n "${PIPELINE_SA_TOKEN}" ]; then
            oc create secret docker-registry internal-registry-credentials \
                -n "${CICD_NAMESPACE}" \
                --docker-server="image-registry.openshift-image-registry.svc:5000" \
                --docker-username=pipeline \
                --docker-password="${PIPELINE_SA_TOKEN}" \
                --docker-email=unused@example.com >/dev/null 2>&1 \
                && echo -e "${GREEN}  → internal-registry-credentials Secret を作成しました${RESET}"
        else
            echo -e "${YELLOW}  ⚠ pipeline SA トークン取得に失敗、internal-registry-credentials 未作成${RESET}"
        fi
    else
        echo -e "${GREEN}  → internal-registry-credentials Secret は既に存在します${RESET}"
    fi

    # business-api-build-pipeline の Maven キャッシュ用 PVC
    if ! oc get pvc maven-cache-pvc -n "${CICD_NAMESPACE}" &>/dev/null; then
        oc apply -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: maven-cache-pvc
  namespace: ${CICD_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
        echo -e "${GREEN}  → maven-cache-pvc を作成しました${RESET}"
    else
        echo -e "${GREEN}  → maven-cache-pvc は既に存在します${RESET}"
    fi

    oc apply -f "${PLATFORM_DIR}/deployment/tekton/tasks/" -n "${CICD_NAMESPACE}"
    oc apply -f "${PLATFORM_DIR}/deployment/tekton/pipelines/" -n "${CICD_NAMESPACE}"
    oc apply -f "${PLATFORM_DIR}/deployment/tekton/triggers/" -n "${CICD_NAMESPACE}"
    echo -e "${GREEN}  → Tekton リソースを適用しました${RESET}"

    # ── Prometheus 監視ルール ──
    echo -e "${BLUE}[7/7] 監視ルール (PrometheusRule) を適用中...${RESET}"
    oc apply -f "${PLATFORM_DIR}/deployment/monitoring/prometheus-rules.yaml" \
        -n "${AI_AGENT_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  ⚠ PrometheusRule の適用をスキップ (monitoring.coreos.com CRD が未インストール)${RESET}"

    # ── Route から URL を取得して表示 ──
    echo -e "${BLUE}  AI Agent Route の起動を待機中...${RESET}"
    local elapsed=0
    while [ $elapsed -lt 120 ]; do
        if oc get route ai-agent-orchestrator -n "${AI_AGENT_NAMESPACE}" &>/dev/null; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    local AGENT_URL
    AGENT_URL=$(oc get route ai-agent-orchestrator \
        -n "${AI_AGENT_NAMESPACE}" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    local BIZ_URL
    BIZ_URL=$(oc get route business-api \
        -n "${AI_AGENT_NAMESPACE}" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    echo ""
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}デプロイ完了 (overlay: ${OVERLAY})${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    [ -n "${AGENT_URL}" ] && echo -e "${GREEN}AI Agent API : https://${AGENT_URL}${RESET}"
    [ -n "${BIZ_URL}"   ] && echo -e "${GREEN}Business API : https://${BIZ_URL}${RESET}"
    echo ""
    echo -e "${YELLOW}Pod 起動確認: oc get pod -n ${AI_AGENT_NAMESPACE} -w${RESET}"
    echo -e "${YELLOW}ログ確認    : ./script/aiagent.sh logs${RESET}"
}

# ─── deploy-latest: ai-agent-cicd パイプラインが最後にビルドしたイメージのみを
# ai-agent-orchestrator Deployment に反映する ──────────────────────────────────
# NOTE: `deploy` (oc apply -k overlays/dev) は kustomization.yaml が image tag を
# 常に "dev" に固定しているため、内部レジストリの "dev" ImageStreamTag を
# 更新しない限りパイプラインの最新ビルドを拾わない。またDeploymentのcontainers
# 配列全体を丸ごと置き換えるパッチ(type=merge)を使うと env/ports/resources/probes
# が消える事故になることを実際に確認済みのため、image フィールドだけをJSON Patch
# (type=json) で更新する。
deploy_latest_image() {
    _require oc

    echo -e "${BLUE}=== ai-agent-orchestrator: 最新ビルドイメージのみデプロイ ===${RESET}"

    if ! oc get deployment ai-agent-orchestrator -n "${AI_AGENT_NAMESPACE}" &>/dev/null; then
        echo -e "${RED}エラー: Deployment ai-agent-orchestrator が ${AI_AGENT_NAMESPACE} に見つかりません。${RESET}" >&2
        echo -e "${YELLOW}先に './script/aiagent.sh deploy' を実行してください。${RESET}" >&2
        exit 1
    fi

    # ai-agent-cicd パイプラインは各ビルドを "dev" とは別に、コミットSHAをタグ名
    # としてイメージストリームへ push する ("dev" タグ自体はkustomizeが上書きし
    # 続ける可変ポインタのため除外する)。タグの作成日時で最新を判定する。
    local LATEST_TAG
    LATEST_TAG=$(oc get imagestream ai-agent-orchestrator -n "${AI_AGENT_NAMESPACE}" \
        -o jsonpath='{range .status.tags[*]}{.tag}{"\t"}{.items[0].created}{"\n"}{end}' 2>/dev/null \
        | grep -v '^dev\s' \
        | sort -t $'\t' -k2 -r \
        | head -1 \
        | cut -f1)

    if [ -z "${LATEST_TAG}" ]; then
        echo -e "${RED}エラー: ai-agent-orchestrator イメージストリームに ('dev' 以外の) タグが見つかりません。${RESET}" >&2
        echo -e "${YELLOW}ai-agent-cicd パイプラインが少なくとも1回成功している必要があります。${RESET}" >&2
        exit 1
    fi

    local IMAGE="image-registry.openshift-image-registry.svc:5000/${AI_AGENT_NAMESPACE}/ai-agent-orchestrator:${LATEST_TAG}"
    echo -e "${GREEN}  最新ビルド: ${LATEST_TAG}${RESET}"
    echo -e "${BLUE}  image: ${IMAGE}${RESET}"

    oc patch deployment ai-agent-orchestrator -n "${AI_AGENT_NAMESPACE}" \
        --type=json \
        -p "[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"${IMAGE}\"}]"

    echo -e "${BLUE}ロールアウト待機中...${RESET}"
    oc rollout status deployment/ai-agent-orchestrator -n "${AI_AGENT_NAMESPACE}" --timeout=180s

    echo -e "${GREEN}デプロイ完了: ai-agent-orchestrator は ${LATEST_TAG} で稼働中${RESET}"
}

# ─── deploy-prod: 本番デプロイ ─────────────────────────────────────────────────
deploy_prod() {
    echo -e "${RED}⚠ 本番環境へのデプロイを実行します。${RESET}"
    read -rp "本当に本番 (prod) へデプロイしますか？(yes/no): " PROD_CONFIRM
    if [ "${PROD_CONFIRM}" != "yes" ]; then
        echo -e "${YELLOW}処理を中断しました。${RESET}"
        exit 0
    fi
    deploy "prod"
}

# ─── status: 全コンポーネントの状態確認 ────────────────────────────────────────
status() {
    echo -e "${CYAN}=== Datamesh AI Agent Platform — 状態確認 ===${RESET}"
    echo ""

    echo -e "${BLUE}── AI Agent Platform (${AI_AGENT_NAMESPACE}) ──${RESET}"
    oc get pod,svc,route,pvc -n "${AI_AGENT_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  Namespace ${AI_AGENT_NAMESPACE} が見つかりません${RESET}"
    echo ""

    echo -e "${BLUE}── vLLM InferenceService (${MODEL_NAMESPACE}) ──${RESET}"
    oc get inferenceservice -n "${MODEL_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  InferenceService が見つかりません${RESET}"
    echo ""

    echo -e "${BLUE}── Kafka (${AI_AGENT_NAMESPACE}) ──${RESET}"
    oc get kafka,kafkatopic -n "${AI_AGENT_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  Kafka リソースが見つかりません${RESET}"
    echo ""

    echo -e "${BLUE}── Tekton PipelineRun (${CICD_NAMESPACE}) ──${RESET}"
    oc get pipelinerun -n "${CICD_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  PipelineRun が見つかりません${RESET}"
    echo ""

    # AI Agent の URL を表示
    local AGENT_URL
    AGENT_URL=$(oc get route ai-agent-orchestrator \
        -n "${AI_AGENT_NAMESPACE}" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${AGENT_URL}" ]; then
        echo -e "${GREEN}AI Agent API  : https://${AGENT_URL}${RESET}"
        echo -e "${CYAN}Health チェック: https://${AGENT_URL}/health${RESET}"
        echo -e "${CYAN}Chat エンドポイント: https://${AGENT_URL}/api/v1/chat${RESET}"
        echo -e "${CYAN}API Docs      : https://${AGENT_URL}/docs${RESET}"
    fi
}

# ─── logs: AI Agent のログ表示 ─────────────────────────────────────────────────
logs() {
    local TAIL="${2:-100}"
    echo -e "${BLUE}=== AI Agent Orchestrator ログ (最新 ${TAIL} 行) ===${RESET}"

    local POD
    POD=$(oc get pod -n "${AI_AGENT_NAMESPACE}" \
        -l app=ai-agent-orchestrator \
        --no-headers 2>/dev/null \
        | grep "Running" | head -1 | awk '{print $1}')

    if [ -z "${POD}" ]; then
        echo -e "${YELLOW}⚠ 実行中の AI Agent Pod が見つかりません${RESET}"
        echo -e "${YELLOW}  oc get pod -n ${AI_AGENT_NAMESPACE} で確認してください${RESET}"
        return 0
    fi

    echo -e "${GREEN}Pod: ${POD}${RESET}"
    oc logs "${POD}" -n "${AI_AGENT_NAMESPACE}" --tail="${TAIL}" -f
}

# ─── cleanup: 全リソースの削除 ─────────────────────────────────────────────────
cleanup() {
    echo -e "${RED}=== AI Agent Platform クリーンアップ ===${RESET}"
    echo -e "${YELLOW}以下の Namespace を削除します:${RESET}"
    echo -e "  - ${AI_AGENT_NAMESPACE}"
    echo -e "  - ${CICD_NAMESPACE}"
    echo ""
    read -rp "続行しますか？(yes/no): " CLEANUP_CONFIRM
    if [ "${CLEANUP_CONFIRM}" != "yes" ]; then
        echo -e "${YELLOW}処理を中断しました。${RESET}"
        exit 0
    fi

    echo -e "${BLUE}Kafka リソースのファイナライザーを削除中...${RESET}"
    for topic in $(oc get kafkatopics.kafka.strimzi.io \
        -n "${AI_AGENT_NAMESPACE}" -o name 2>/dev/null); do
        oc patch "${topic}" -n "${AI_AGENT_NAMESPACE}" \
            --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done

    echo -e "${BLUE}Tekton リソースを削除中...${RESET}"
    oc delete project "${CICD_NAMESPACE}" \
        --force --grace-period=0 2>/dev/null || true

    echo -e "${BLUE}AI Agent Platform を削除中...${RESET}"
    oc delete all --all -n "${AI_AGENT_NAMESPACE}" \
        --force --grace-period=0 2>/dev/null || true

    read -rp "Namespace 自体も削除しますか？(yes/no): " DELETE_NS
    if [ "${DELETE_NS}" = "yes" ]; then
        oc delete project "${AI_AGENT_NAMESPACE}" \
            --force --grace-period=0 2>/dev/null || true
        echo -e "${GREEN}Namespace ${AI_AGENT_NAMESPACE} を削除しました${RESET}"
    fi

    # クローンしたリポジトリを削除
    if [ -d "${PLATFORM_DIR}" ]; then
        read -rp "クローンしたリポジトリ (${PLATFORM_DIR}) も削除しますか？(yes/no): " DELETE_REPO
        if [ "${DELETE_REPO}" = "yes" ]; then
            rm -rf "${PLATFORM_DIR}"
            echo -e "${GREEN}  → リポジトリを削除しました${RESET}"
        fi
    fi

    echo -e "${GREEN}クリーンアップ完了${RESET}"
}

# =============================================================================
# Step 3: ディスパッチ
# =============================================================================

case "$1" in
    setup)         setup               ;;
    vllm)          vllm                ;;
    keycloak)      provision_keycloak  ;;
    mm2-tokens)    mm2_tokens          ;;
    deploy)        deploy "dev"        ;;
    deploy-prod)   deploy_prod         ;;
    deploy-latest) deploy_latest_image ;;
    status)        status              ;;
    logs)          logs "$@"           ;;
    cleanup)       cleanup             ;;
esac
