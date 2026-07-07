#!/bin/bash
# =============================================================================
# Script Name: aiagent.sh
# Description: Datamesh AI Agent Platform を OpenShift AI 上にデプロイする
# Author: Noriaki Mushino
# Date Created: 2026-06-26
# Last Modified: 2026-06-26
# Version: 1.0
#
# Usage:
#   ./script/aiagent.sh setup           - OpenShift AI Operator / 前提ミドルをインストール
#   ./script/aiagent.sh deploy          - AI Agent Platform をデプロイ (dev overlay)
#   ./script/aiagent.sh deploy-prod     - AI Agent Platform を本番デプロイ (prod overlay)
#   ./script/aiagent.sh vllm            - vLLM モデルサービングをデプロイ
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
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ─── ロゴ ──────────────────────────────────────────────────────────────────────
figlet "DS AI Agent" 2>/dev/null || echo "=== Datamesh AI Agent Platform ==="
echo -e "${CYAN}Datamesh AI Agent Platform — OpenShift AI Deployment${RESET}"
echo ""

# ─── ログイン確認 ──────────────────────────────────────────────────────────────
if ! oc whoami &>/dev/null; then
    echo -e "${RED}エラー: OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo -e "${GREEN}OpenShift にログイン済み: $(oc whoami)${RESET}"

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

# ─── setup: 前提 Operator のインストール ───────────────────────────────────────
setup() {
    # Streams for Apache Kafka (旧 AMQ Streams) は quarkusdroneshop 側 (ocpdeploy.sh) の
    # リモートクラスターに既に導入済みだが、このクラスター自体には未導入のため、
    # openshift-operators (AllNamespaces) に共通コンポーネントとして新規インストールする。

    echo -e "${BLUE}=== [1/7] Skupper 接続確認 ===${RESET}"
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
    echo -e "${BLUE}=== [2/7] 共通コンポーネントの確認 (Pipelines / Keycloak) ===${RESET}"
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

    echo -e "${BLUE}=== [3/7] Streams for Apache Kafka Operator のインストール ===${RESET}"

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

    echo -e "${BLUE}=== [4/7] Streams for Apache Kafka Console のインストール ===${RESET}"

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
  name: aiagent-cluster
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
        echo -e "${GREEN}  → Streams for Apache Kafka Console Subscription を openshift-operators に適用しました${RESET}"
        _wait_operator "openshift-operators" "amq-streams-console" 300
    fi

    echo -e "${BLUE}=== [5/7] OpenShift AI Operator (RHOAI) のインストール ===${RESET}"

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
    echo -e "${BLUE}=== [6/7] DataScienceCluster の作成 ===${RESET}"
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

    echo -e "${BLUE}=== [7/7] AI Agent Platform Namespace の作成 ===${RESET}"
    oc new-project "${AI_AGENT_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  Namespace ${AI_AGENT_NAMESPACE} は既に存在します${RESET}"

    # anyuid SCC — AI Agent は UID 1001、Business API は UID 185 で動作
    oc adm policy add-scc-to-user anyuid \
        -z default -n "${AI_AGENT_NAMESPACE}" 2>/dev/null || true

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
    if oc get service kafka-cluster-kafka-bootstrap -n "${AI_AGENT_NAMESPACE}" &>/dev/null; then
        echo -e "${GREEN}  → Skupper 仮想 Service (kafka-cluster-kafka-bootstrap): 確認済み ✓${RESET}"
    else
        echo -e "${YELLOW}  ⚠ kafka-cluster-kafka-bootstrap Service が見つかりません。${RESET}"
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
    # クラスター内部の Keycloak Service を使う
    oc patch configmap business-api-config -n "${AI_AGENT_NAMESPACE}" --type merge \
        -p '{"data":{"keycloak-url":"http://keycloak.keycloak.svc.cluster.local:8080"}}' >/dev/null 2>&1 \
        && echo -e "${GREEN}  → business-api-config の keycloak-url を設定しました${RESET}" \
        || echo -e "${YELLOW}  ⚠ business-api-config が見つからずスキップ${RESET}"

    # ── Tekton タスク・パイプラインをデプロイ ──
    echo -e "${BLUE}[6/7] Tekton タスク / パイプラインをデプロイ中...${RESET}"
    oc new-project "${CICD_NAMESPACE}" 2>/dev/null \
        || echo -e "${YELLOW}  Namespace ${CICD_NAMESPACE} は既に存在します${RESET}"

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

# ─── コマンド dispatch ──────────────────────────────────────────────────────────
case "${1:-}" in
    setup)
        setup
        ;;
    vllm)
        vllm
        ;;
    deploy)
        deploy "dev"
        ;;
    deploy-prod)
        deploy_prod
        ;;
    status)
        status
        ;;
    logs)
        logs "$@"
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: ${1:-（引数なし）}${RESET}"
        echo ""
        echo -e "${YELLOW}使用方法:${RESET}"
        echo -e "  $0 setup         OpenShift AI / Streams for Apache Kafka / Tekton Operator をインストール"
        echo -e "  $0 vllm          vLLM モデルサービングをデプロイ (${MODEL_NAME})"
        echo -e "  $0 deploy        AI Agent Platform を dev 環境にデプロイ"
        echo -e "  $0 deploy-prod   AI Agent Platform を prod 環境にデプロイ (確認あり)"
        echo -e "  $0 status        全コンポーネントの状態と URL を表示"
        echo -e "  $0 logs [n]      AI Agent のログを表示 (デフォルト 100 行)"
        echo -e "  $0 cleanup       AI Agent Platform を削除"
        exit 1
        ;;
esac
