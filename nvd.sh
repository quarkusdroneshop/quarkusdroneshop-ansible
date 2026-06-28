#!/bin/bash
# =============================================================================
# Script Name: nvd.sh
# Description: OWASP Dependency-Check 用 NVD データベースのセットアップと
#              日次更新 CronJob を OpenShift 上に構築するスクリプト。
#
# Author: Noriaki Mushino
# Date Created: 2026-06-21
# Last Modified: 2026-06-21
# Version: 1.0
#
# Usage:
#   ./nvd.sh setup    - PVC / Secret / CronJob を作成し初回 DB 更新を実行する
#   ./nvd.sh status   - CronJob・Job・PVC の状態を確認する
#   ./nvd.sh update   - 手動で DB 更新 Job を即時実行する
#   ./nvd.sh cleanup  - 作成したリソースをすべて削除する
#
# Prerequisites:
#   - OpenShift CLI (oc) がインストール・ログイン済みであること
#   - NVD API キーを取得済みであること（https://nvd.nist.gov/developers/request-an-api-key）
#   - EFS StorageClass (efs-sc) が利用可能であること（ReadWriteMany が必要）-> gp3-csiへ変更
#   - The Test was conducted on MacOS
#
# =============================================================================

NAMESPACE="quarkusdroneshop-demo"
SECRET_NAME="nvd-api-key"
PVC_NAME="dependency-check-db"
CRONJOB_NAME="dependency-check-update"
INIT_JOB_NAME="dependency-check-init"
DC_IMAGE="owasp/dependency-check:latest"
PVC_YAML="../tekton-pipelines/volumeClaimTemplate/dependency-check-db-pvc.yaml"
API_KEY=”7d80d299-f5d4-4560-acff-8a4492017383”

# 色定義
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

# ロゴ表示
figlet "NVD Setup" 2>/dev/null || echo "=== NVD Setup ==="

# ログイン確認
if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo -e "${GREEN}OpenShift にログイン済み: $(oc whoami)${RESET}"

# ============================================================
# setup: PVC / Secret / CronJob を作成し初回 DB 更新を実行
# ============================================================
setup() {
    echo -e "${BLUE}=== NVD セットアップ開始 ===${RESET}"

    # Namespace 確認
    if ! oc get project "$NAMESPACE" &>/dev/null; then
        echo -e "${RED}Namespace ${NAMESPACE} が存在しません。piplines.sh setup を先に実行してください。${RESET}"
        exit 1
    fi

    # NVD API キー入力
    echo ""
    echo -e "${YELLOW}NVD API キーを入力してください（https://nvd.nist.gov/developers/request-an-api-key）:${RESET}"
    read -rsp "API KEY: " NVD_API_KEY_VALUE
    echo ""
    if [ -z "${NVD_API_KEY_VALUE}" ]; then
        echo -e "${RED}API キーが入力されていません。処理を中断します。${RESET}"
        exit 1
    fi

    # Secret 作成（既存の場合は上書き）
    echo -e "${BLUE}[1/4] Secret を作成します...${RESET}"
    oc delete secret "${SECRET_NAME}" -n "${NAMESPACE}" --ignore-not-found
    oc create secret generic "${SECRET_NAME}" \
        --from-literal=key="${NVD_API_KEY_VALUE}" \
        -n "${NAMESPACE}"
    echo -e "${GREEN}Secret '${SECRET_NAME}' を作成しました。${RESET}"

    # PVC 作成
    echo -e "${BLUE}[2/4] PVC を作成します...${RESET}"
    if oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        echo -e "${YELLOW}PVC '${PVC_NAME}' はすでに存在します。スキップします。${RESET}"
    else
        sed "s/namespace:.*/namespace: ${NAMESPACE}/" "${PVC_YAML}" | oc apply -n "${NAMESPACE}" -f -
        echo -e "${GREEN}PVC '${PVC_NAME}' を作成しました。${RESET}"
    fi

    # CronJob 作成
    echo -e "${BLUE}[3/4] 日次更新 CronJob を作成します（毎日 JST 03:00）...${RESET}"
    oc apply -n "${NAMESPACE}" -f - <<EOF

apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${CRONJOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: owasp-dependency-check
spec:
  schedule: "0 18 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:

        spec:
          template:
            spec:
              securityContext:
                fsGroup: 1000
        
          restartPolicy: OnFailure
          containers:
          - name: update
            image: ${DC_IMAGE}
            env:
            - name: NVD_API_KEY
              valueFrom:
                secretKeyRef:
                  name: ${SECRET_NAME}
                  key: key
            command:
            - /bin/sh
            - -c
            - |
              set -e
              CACHE_DIR=/dc-data/nvd-data
              mkdir -p "\${CACHE_DIR}"
              echo "=== NVD DB 更新開始: \$(date) ==="
              /usr/share/dependency-check/bin/dependency-check.sh \\
                --updateonly \\
                --data "\${CACHE_DIR}" \\
                --nvdApiKey "\${NVD_API_KEY}"
              echo "=== NVD DB 更新完了: \$(date) ==="
              echo "=== DB サイズ ===" && du -sh "\${CACHE_DIR}"
            volumeMounts:
            - name: dc-db
              mountPath: /dc-data
          volumes:
          - name: dc-db
            persistentVolumeClaim:
              claimName: ${PVC_NAME}
EOF

    echo -e "${GREEN}CronJob '${CRONJOB_NAME}' を作成しました。${RESET}"

    # 初回 DB 更新 Job を即時実行
    echo -e "${BLUE}[4/4] 初回 DB 更新 Job を実行します（完了まで数分かかります）...${RESET}"
    oc delete job "${INIT_JOB_NAME}" -n "${NAMESPACE}" --ignore-not-found

    oc create job "${INIT_JOB_NAME}" \
        --from="cronjob/${CRONJOB_NAME}" \
        -n "${NAMESPACE}"

    echo -e "${YELLOW}Job '${INIT_JOB_NAME}' を起動しました。ログを監視します（Ctrl+C で監視を中断できます）...${RESET}"

    # Pod が起動するまで待機
    echo "Pod 起動待機中..."
    POD=""
    for i in $(seq 1 30); do
        POD=$(oc get pods -n "${NAMESPACE}" \
            -l "job-name=${INIT_JOB_NAME}" \
            --field-selector=status.phase!=Pending \
            -o name 2>/dev/null | head -1)
        if [ -n "${POD}" ]; then
            break
        fi
        sleep 5
    done

    if [ -n "${POD}" ]; then
        oc logs -f "${POD}" -n "${NAMESPACE}" 2>/dev/null || true
    else
        echo -e "${YELLOW}Pod がタイムアウト前に起動しませんでした。'./nvd.sh status' で状態を確認してください。${RESET}"
    fi

    echo ""
    echo -e "${GREEN}=============================================="
    echo " セットアップ完了"
    echo " 毎日 JST 03:00 に NVD DB が自動更新されます"
    echo -e "==============================================${RESET}"
}

# ============================================================
# status: リソースの状態確認
# ============================================================
status() {
    echo -e "${BLUE}=== NVD リソース状態確認 ===${RESET}"
    echo ""

    echo -e "${YELLOW}--- PVC ---${RESET}"
    oc get pvc "${PVC_NAME}" -n "${NAMESPACE}" 2>/dev/null \
        || echo "PVC '${PVC_NAME}' は存在しません"

    echo ""
    echo -e "${YELLOW}--- Secret ---${RESET}"
    oc get secret "${SECRET_NAME}" -n "${NAMESPACE}" 2>/dev/null \
        || echo "Secret '${SECRET_NAME}' は存在しません"

    echo ""
    echo -e "${YELLOW}--- CronJob ---${RESET}"
    oc get cronjob "${CRONJOB_NAME}" -n "${NAMESPACE}" 2>/dev/null \
        || echo "CronJob '${CRONJOB_NAME}' は存在しません"

    echo ""
    echo -e "${YELLOW}--- 直近の Job ---${RESET}"
    oc get jobs -n "${NAMESPACE}" \
        --sort-by='.metadata.creationTimestamp' 2>/dev/null \
        | grep -E "dependency-check|NAME" || echo "Job が見つかりません"

    echo ""
    echo -e "${YELLOW}--- 直近の Pod ログ（末尾 30 行）---${RESET}"
    LATEST_POD=$(oc get pods -n "${NAMESPACE}" \
        --sort-by='.metadata.creationTimestamp' \
        -o name 2>/dev/null \
        | grep "dependency-check" | tail -1)
    if [ -n "${LATEST_POD}" ]; then
        oc logs "${LATEST_POD}" -n "${NAMESPACE}" --tail=30 2>/dev/null || true
    else
        echo "関連 Pod が見つかりません"
    fi
}

# ============================================================
# update: 手動で DB 更新 Job を即時実行
# ============================================================
update() {
    echo -e "${BLUE}=== NVD DB 手動更新 ===${RESET}"

    # CronJob 存在確認
    if ! oc get cronjob "${CRONJOB_NAME}" -n "${NAMESPACE}" &>/dev/null; then
        echo -e "${RED}CronJob '${CRONJOB_NAME}' が存在しません。先に './nvd.sh setup' を実行してください。${RESET}"
        exit 1
    fi

    MANUAL_JOB_NAME="dependency-check-manual-$(date +%Y%m%d%H%M%S)"

    oc create job "${MANUAL_JOB_NAME}" \
        --from="cronjob/${CRONJOB_NAME}" \
        -n "${NAMESPACE}"

    echo -e "${GREEN}Job '${MANUAL_JOB_NAME}' を起動しました。${RESET}"
    echo -e "${YELLOW}ログを監視します（Ctrl+C で中断可）...${RESET}"

    POD=""
    for i in $(seq 1 30); do
        POD=$(oc get pods -n "${NAMESPACE}" \
            -l "job-name=${MANUAL_JOB_NAME}" \
            --field-selector=status.phase!=Pending \
            -o name 2>/dev/null | head -1)
        if [ -n "${POD}" ]; then
            break
        fi
        sleep 5
    done

    if [ -n "${POD}" ]; then
        oc logs -f "${POD}" -n "${NAMESPACE}" 2>/dev/null || true
    else
        echo -e "${YELLOW}Pod 起動待機タイムアウト。'./nvd.sh status' で確認してください。${RESET}"
    fi
}

# ============================================================
# cleanup: 作成したリソースをすべて削除
# ============================================================
cleanup() {
    echo -e "${YELLOW}=== NVD リソース削除 ===${RESET}"
    echo -e "${RED}以下のリソースを削除します:${RESET}"
    echo "  - CronJob : ${CRONJOB_NAME}"
    echo "  - Job     : ${INIT_JOB_NAME} および dependency-check-manual-*"
    echo "  - PVC     : ${PVC_NAME}（NVD データが失われます）"
    echo "  - Secret  : ${SECRET_NAME}"
    echo ""
    read -rp "本当に削除しますか？(yes/no): " CONFIRM
    if [ "${CONFIRM}" != "yes" ]; then
        echo -e "${RED}処理を中断します。${RESET}"
        exit 1
    fi

    oc delete cronjob "${CRONJOB_NAME}" -n "${NAMESPACE}" --ignore-not-found

    # dependency-check 関連 Job を一括削除
    for JOB in $(oc get jobs -n "${NAMESPACE}" -o name 2>/dev/null | grep "dependency-check"); do
        oc delete "${JOB}" -n "${NAMESPACE}" --ignore-not-found
    done

    # PVC を削除するには finalizer を外す
    oc patch pvc "${PVC_NAME}" -n "${NAMESPACE}" \
        --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    oc delete pvc "${PVC_NAME}" -n "${NAMESPACE}" --ignore-not-found

    oc delete secret "${SECRET_NAME}" -n "${NAMESPACE}" --ignore-not-found

    echo -e "${GREEN}削除完了。${RESET}"
}

# ============================================================
# エントリポイント
# ============================================================
case "$1" in
    setup)
        setup
        ;;
    status)
        status
        ;;
    update)
        update
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "使用方法: $0 {setup|status|update|cleanup}"
        exit 1
        ;;
esac




###########
#　APIキーを取得した場合には下記を実行する

# oc create secret generic nvd-api-key \
#   --from-literal=key=<YOUR_NVD_API_KEY> \
#   -n quarkusdroneshop-cicd \
#   --context="quarkusdroneshop-cicd/api-ocp-mnlq9-sandbox1332-opentlc-com:6443/admin"
#   7d820e39-9ec7-41c4-ae4a-27f3ad57a367

