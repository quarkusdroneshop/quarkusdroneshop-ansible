#!/bin/bash
# =============================================================================
# Script Name: developer-hub.sh
# Description: This script sets up the developer-hub image and application skeleton.
# Author: Noriaki Mushino
# Date Created: 2025-03-30
# Last Modified: 2026-06-21
# Version: 2.0
#
# Usage:
#   ./developer-hub.sh setup           - To setup the environment.
#   ./developer-hub.sh deploy          - To deploy the application.
#   ./developer-hub.sh keycloak        - To setup Keycloak realm/client/user for RHDH.
#   ./developer-hub.sh retoken         - Reissuing a GitHub token.
#   ./developer-hub.sh target-token <domain> - Create persistent SA token for target cluster.
#   ./developer-hub.sh system-token          - Create SA tokens for a/b/c-cluster and update secrets.
#   ./developer-hub.sh cleanup         - To delete the application.
#   ./developer-hub.sh customimage     - The creation of a customised RHDH image.
#   ./developer-hub.sh resetcustombuild - Reset and rebuild the custom RHDH image from scratch.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - The corepack, yarn and node commands can be executed
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

set -euo pipefail

RHDH_NAMESPACE="quarkusdroneshop-rhdh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 色を変数に格納
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

# ロゴの表示
figlet "droneshop"

# OpenShift にログインしているか確認（最初に実行）
if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo -e "${GREEN}OpenShift にログイン済み: $(oc whoami)${RESET}"

# 前処理
oc status
oc version

DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)

# ドメインの確認（トークンは表示しない）
echo -e "${YELLOW}Domain Name: $DOMAIN_NAME${RESET}"
echo -e "-------------------------------------------"
read -rp "指定されたドメインで間違いないですか？(yes/no): " DOMAIN_CONFREM
if [ "$DOMAIN_CONFREM" != "yes" ]; then
    echo -e "${RED}処理を中断します。${RESET}"
    exit 1
fi

deploy() {

    oc project "$RHDH_NAMESPACE"

    # カスタムイメージの存在確認
    if ! oc get istag rhdh-hub-custom:latest -n "$RHDH_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${RED}エラー: カスタムイメージ rhdh-hub-custom:latest が存在しません。${RESET}" >&2
        echo -e "${YELLOW}先に './developer-hub.sh customimage' を実行してビルドを完了させてください。${RESET}" >&2
        exit 1
    fi

    echo -e "${BLUE}デプロイの開始...${RESET}"

    # 自クラスタードメインを自動検出してsecrets-rhdh.yamlとtemplate.yamlのデフォルトを更新
    local CLUSTER_API_URL
    CLUSTER_API_URL=$(oc whoami --show-server)
    local CLUSTER_DOMAIN
    CLUSTER_DOMAIN=$(echo "$CLUSTER_API_URL" | sed 's|https://api\.||' | sed 's|:6443||')
    local APPS_DOMAIN="apps.${CLUSTER_DOMAIN}"
    local RHDH_BASE_URL="https://backstage-developer-hub-${RHDH_NAMESPACE}.${APPS_DOMAIN}"

    echo -e "${BLUE}クラスタードメイン: ${APPS_DOMAIN}${RESET}"

    # secrets-rhdh.yaml の BASE_URL と AUTH_OIDC_METADATA_URL を現在のクラスタードメインで更新
    sed -i.bak \
        -e "s|BASE_URL: \"https://backstage-developer-hub-${RHDH_NAMESPACE}\.apps\.[^\"]*\"|BASE_URL: \"${RHDH_BASE_URL}\"|" \
        -e "s|AUTH_OIDC_METADATA_URL: \"https://sso\.apps\.[^\"]*\"|AUTH_OIDC_METADATA_URL: \"https://sso.${APPS_DOMAIN}/realms/rhdh/.well-known/openid-configuration\"|" \
        -e "s|K8S_CLUSTER_NAME: \"[^\"]*\"|K8S_CLUSTER_NAME: \"${CLUSTER_DOMAIN}\"|" \
        -e "s|K8S_CLUSTER_URL: \"[^\"]*\"|K8S_CLUSTER_URL: \"${CLUSTER_API_URL}\"|" \
        "$SCRIPT_DIR/openshift/secrets-rhdh.yaml"
    rm -f "$SCRIPT_DIR/openshift/secrets-rhdh.yaml.bak"

    # template.yaml の clusterDomain デフォルト値を更新
    local TEMPLATE_YAML="$SCRIPT_DIR/../developerhub-skeleton/template.yaml"
    if [ -f "$TEMPLATE_YAML" ]; then
        sed -i.bak \
            "s|default: apps\.ocp\.[^[:space:]]*\.opentlc\.com|default: ${APPS_DOMAIN}|" \
            "$TEMPLATE_YAML"
        rm -f "${TEMPLATE_YAML}.bak"
        echo -e "${BLUE}template.yaml の clusterDomain を ${APPS_DOMAIN} に更新しました${RESET}"
        (cd "$(dirname "$TEMPLATE_YAML")" && git add template.yaml && \
            git commit -m "Auto-update clusterDomain=${APPS_DOMAIN}" && \
            git push origin main) || true
    fi

    oc apply -f "$SCRIPT_DIR/openshift/developer-hub.yaml" -n "$RHDH_NAMESPACE"
    oc apply -f "$SCRIPT_DIR/openshift/app-config-rhdh.yaml" -n "$RHDH_NAMESPACE"
    oc apply -f "$SCRIPT_DIR/openshift/secrets-rhdh.yaml" -n "$RHDH_NAMESPACE"
    oc apply -f "$SCRIPT_DIR/openshift/dynamic-plugins-rhdh.yaml" -n "$RHDH_NAMESPACE"
    oc apply -f "$SCRIPT_DIR/openshift/catalog-info.yaml" -n "$RHDH_NAMESPACE"
    oc apply -f "$SCRIPT_DIR/openshift/k8-plugin-sa.yaml" -n "$RHDH_NAMESPACE"

    oc adm policy add-cluster-role-to-user edit \
        -z rhdh-k8s-plugin \
        -n "$RHDH_NAMESPACE"

    oc adm policy add-cluster-role-to-user view \
        -z rhdh-k8s-plugin \
        -n "$RHDH_NAMESPACE"

    # ロールアウト完了を待機（imagePullPolicy: Always は developer-hub.yaml で設定済み）
    echo -e "${BLUE}Deploymentのロールアウトを待機中...${RESET}"
    oc rollout status deployment/backstage-developer-hub \
        -n "$RHDH_NAMESPACE" \
        --timeout=300s

    # デプロイ後にルートを取得して表示
    ROUTE_HOST=$(oc get route backstage-developer-hub \
        -n "$RHDH_NAMESPACE" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$ROUTE_HOST" ]; then
        echo -e "${GREEN}Developer Hub URL: https://${ROUTE_HOST}${RESET}"
    fi

    echo -e "${GREEN}デプロイ完了${RESET}"
}

_setup_build() {
    # Docker設定ファイルの存在確認
    if [ ! -f "$HOME/.docker/config.json" ]; then
        echo -e "${RED}$HOME/.docker/config.json が見つかりません。registry.redhat.io へのログインが必要です。${RESET}" >&2
        exit 1
    fi

    # Scopioの認証情報をセットする
    oc create secret generic redhat-pull-secret \
        --from-file=.dockerconfigjson="$HOME/.docker/config.json" \
        --type=kubernetes.io/dockerconfigjson \
        -n "$RHDH_NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -

    # Podに認証情報をリンクする
    oc secrets link default redhat-pull-secret --for=pull
    oc secrets link builder redhat-pull-secret --for=pull

    # RHDHのイメージを取得する
    if ! oc get istag rhdh-hub-rhel9:1.10.1 >/dev/null 2>&1; then
        oc import-image rhdh-hub-rhel9:1.10.1 \
            --from=registry.redhat.io/rhdh/rhdh-hub-rhel9:1.10.1 \
            --confirm
    else
        echo "ImageStreamTag rhdh-hub-rhel9:1.10.1 already exists. Skipping import."
    fi

    # BuildConfigが存在しない場合のみ新規作成（キャッシュ保持のため削除しない）
    if ! oc get buildconfig rhdh-hub-custom >/dev/null 2>&1; then
        echo -e "${BLUE}BuildConfig を新規作成します...${RESET}"
        oc new-build \
            --name=rhdh-hub-custom \
            --binary \
            --strategy=docker \
            --to=rhdh-hub-custom:latest

        oc patch bc rhdh-hub-custom \
            -n "$RHDH_NAMESPACE" \
            --type=merge \
            -p '{
                "spec": {
                    "strategy": {
                        "dockerStrategy": {
                            "dockerfilePath": "dockerfile-rhdh"
                        }
                    },
                    "resources": {
                        "requests": {
                            "cpu": "2",
                            "memory": "6Gi",
                            "ephemeral-storage": "20Gi"
                        },
                        "limits": {
                            "cpu": "4",
                            "memory": "12Gi",
                            "ephemeral-storage": "60Gi"
                        }
                    }
                }
            }'
    else
        echo -e "${BLUE}BuildConfig は既存のものを再利用します（Dockerレイヤーキャッシュ保持）${RESET}"
    fi
}

_local_build() {
    local build_dir="$1"

    echo -e "${BLUE}ローカルビルド開始: $build_dir${RESET}"

    # node / yarn の存在確認
    if ! command -v node &>/dev/null; then
        echo -e "${RED}エラー: node が見つかりません。Node.js をインストールしてください。${RESET}" >&2
        exit 1
    fi
    if ! command -v yarn &>/dev/null; then
        echo -e "${RED}エラー: yarn が見つかりません。corepack enable を実行してください。${RESET}" >&2
        exit 1
    fi

    echo -e "${BLUE}node: $(node --version) / yarn: $(yarn --version)${RESET}"

    # 依存インストール（yarn.lock が変わっていなければ高速）
    (cd "$build_dir" && yarn install --immutable) || {
        echo -e "${RED}yarn install に失敗しました。${RESET}" >&2
        exit 1
    }

    # ビルド実行
    (cd "$build_dir" && yarn build) || {
        echo -e "${RED}yarn build に失敗しました。${RESET}" >&2
        exit 1
    }

    echo -e "${GREEN}ローカルビルド完了${RESET}"
}

_stage_tarballs() {
    local build_dir="$1"
    local skeleton="$build_dir/packages/backend/dist/skeleton.tar.gz"
    local bundle="$build_dir/packages/backend/dist/bundle.tar.gz"

    if [ ! -f "$skeleton" ] || [ ! -f "$bundle" ]; then
        echo -e "${RED}エラー: tarball が見つかりません。ローカルビルドを実行します...${RESET}"
        _local_build "$build_dir"
    fi

    # .dockerignore が **/dist を除外するため、ルートへコピーして回避
    cp "$skeleton" "$build_dir/skeleton.tar.gz"
    cp "$bundle"   "$build_dir/bundle.tar.gz"
    echo -e "${GREEN}tarball をビルドコンテキストのルートに配置しました${RESET}"
    echo -e "${GREEN}  skeleton: $(du -sh "$build_dir/skeleton.tar.gz" | cut -f1)${RESET}"
    echo -e "${GREEN}  bundle  : $(du -sh "$build_dir/bundle.tar.gz"   | cut -f1)${RESET}"
}

_cleanup_tarballs() {
    local build_dir="$1"
    rm -f "$build_dir/skeleton.tar.gz" "$build_dir/bundle.tar.gz"
}

customimage() {

    oc project "$RHDH_NAMESPACE"

    local build_dir
    build_dir="$(cd "$SCRIPT_DIR/../developerhub-skeleton/developerhub" && pwd)"

    _stage_tarballs "$build_dir"
    _setup_build

    # 完了済みPodの削除（ディスク確保）
    oc delete pod -A --field-selector=status.phase=Succeeded --ignore-not-found

    echo -e "${BLUE}ビルドディレクトリ: $build_dir${RESET}"
    oc start-build rhdh-hub-custom --from-dir="$build_dir" --follow
    _cleanup_tarballs "$build_dir"

    echo -e "${GREEN}カスタムイメージのビルド完了${RESET}"
}

resetcustombuild() {

    oc project "$RHDH_NAMESPACE"

    local build_dir
    build_dir="$(cd "$SCRIPT_DIR/../developerhub-skeleton/developerhub" && pwd)"

    # resetcustombuild は常にフレッシュなビルドを保証する
    _local_build "$build_dir"
    _stage_tarballs "$build_dir"

    echo -e "${YELLOW}BuildConfigとImageStreamを削除してキャッシュをリセットします...${RESET}"
    oc delete -f "$SCRIPT_DIR/openshift/developer-hub.yaml" --ignore-not-found
    oc delete buildconfig rhdh-hub-custom --ignore-not-found
    oc delete imagestream rhdh-hub-custom --ignore-not-found
    oc delete builds --all --ignore-not-found

    _setup_build

    # 完了済みPodの削除（ディスク確保）
    oc delete pod -A --field-selector=status.phase=Succeeded --ignore-not-found

    echo -e "${BLUE}ビルドディレクトリ: $build_dir${RESET}"
    oc start-build rhdh-hub-custom --from-dir="$build_dir" --follow
    _cleanup_tarballs "$build_dir"

    echo -e "${GREEN}リセットビルド完了${RESET}"
}

keycloak() {

    # ===== Keycloak 設定値 =====
    # SSO URL は DOMAIN_NAME から自動導出 (apps.<DOMAIN_NAME>)
    local SSO_URL="https://sso.apps.${DOMAIN_NAME}"
    local RHDH_BASE_URL="https://backstage-developer-hub-${RHDH_NAMESPACE}.apps.${DOMAIN_NAME}"

    # クライアント設定は secrets-rhdh.yaml と同期させること
    local REALM="rhdh"
    local CLIENT_ID="rhdh"
    local CLIENT_SECRET="yvoKhHeg1M29PwaAPnlmbt4Avw2OM6Cd"

    # テストユーザー（ワークショップ参加者用）
    local TEST_USER="user1"
    local TEST_USER_PASSWORD="password1"
    local TEST_USER_EMAIL="user1@example.com"

    echo -e "${BLUE}Keycloak セットアップ開始${RESET}"
    echo -e "${YELLOW}SSO URL     : ${SSO_URL}${RESET}"
    echo -e "${YELLOW}RHDH URL    : ${RHDH_BASE_URL}${RESET}"
    echo -e "${YELLOW}Realm       : ${REALM}${RESET}"
    echo -e "-------------------------------------------"

    # Keycloak 管理者パスワードの入力
    local KEYCLOAK_ADMIN="admin"
    local KEYCLOAK_ADMIN_PASSWORD
    if [ -n "${KEYCLOAK_ADMIN_PASSWORD:-}" ]; then
        echo -e "${YELLOW}環境変数 KEYCLOAK_ADMIN_PASSWORD を使用します${RESET}"
    else
        read -rsp "Keycloak 管理者パスワードを入力してください: " KEYCLOAK_ADMIN_PASSWORD
        echo ""
    fi

    # ===== Step 1: admin トークン取得 =====
    echo -e "${BLUE}[1/4] admin トークン取得中...${RESET}"
    local ADMIN_TOKEN
    ADMIN_TOKEN=$(curl -sk -X POST \
        "${SSO_URL}/realms/master/protocol/openid-connect/token" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=${KEYCLOAK_ADMIN}" \
        -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)

    if [ -z "$ADMIN_TOKEN" ]; then
        echo -e "${RED}ERROR: admin トークン取得失敗。URL・パスワードを確認してください。${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}OK: admin トークン取得成功${RESET}"

    # ===== Step 2: rhdh レルム作成 =====
    echo -e "${BLUE}[2/4] ${REALM} レルム作成中...${RESET}"
    local HTTP_CODE
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
        "${SSO_URL}/admin/realms" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"realm\": \"${REALM}\",
            \"enabled\": true,
            \"displayName\": \"RHDH\",
            \"registrationAllowed\": false
        }")

    case "$HTTP_CODE" in
        201) echo -e "${GREEN}OK: ${REALM} レルム作成成功${RESET}" ;;
        409) echo -e "${YELLOW}SKIP: ${REALM} レルムは既に存在します${RESET}" ;;
        *)   echo -e "${RED}ERROR: レルム作成失敗 (HTTP ${HTTP_CODE})${RESET}" >&2; exit 1 ;;
    esac

    # ===== Step 3: rhdh クライアント作成 =====
    echo -e "${BLUE}[3/4] ${CLIENT_ID} クライアント作成中...${RESET}"
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
        "${SSO_URL}/admin/realms/${REALM}/clients" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"clientId\": \"${CLIENT_ID}\",
            \"secret\": \"${CLIENT_SECRET}\",
            \"enabled\": true,
            \"protocol\": \"openid-connect\",
            \"publicClient\": false,
            \"standardFlowEnabled\": true,
            \"directAccessGrantsEnabled\": true,
            \"redirectUris\": [
                \"${RHDH_BASE_URL}/*\",
                \"http://localhost:7007/*\"
            ],
            \"webOrigins\": [
                \"${RHDH_BASE_URL}\",
                \"http://localhost:7007\"
            ]
        }")

    case "$HTTP_CODE" in
        201) echo -e "${GREEN}OK: ${CLIENT_ID} クライアント作成成功${RESET}" ;;
        409) echo -e "${YELLOW}SKIP: ${CLIENT_ID} クライアントは既に存在します${RESET}" ;;
        *)   echo -e "${RED}ERROR: クライアント作成失敗 (HTTP ${HTTP_CODE})${RESET}" >&2; exit 1 ;;
    esac

    # ===== Step 4: テストユーザー作成 =====
    echo -e "${BLUE}[4/4] テストユーザー ${TEST_USER} 作成中...${RESET}"
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
        "${SSO_URL}/admin/realms/${REALM}/users" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${TEST_USER}\",
            \"email\": \"${TEST_USER_EMAIL}\",
            \"enabled\": true,
            \"emailVerified\": true,
            \"firstName\": \"Workshop\",
            \"lastName\": \"User1\",
            \"credentials\": [{
                \"type\": \"password\",
                \"value\": \"${TEST_USER_PASSWORD}\",
                \"temporary\": false
            }]
        }")

    case "$HTTP_CODE" in
        201) echo -e "${GREEN}OK: ユーザー ${TEST_USER} 作成成功${RESET}" ;;
        409) echo -e "${YELLOW}SKIP: ユーザー ${TEST_USER} は既に存在します${RESET}" ;;
        *)   echo -e "${RED}ERROR: ユーザー作成失敗 (HTTP ${HTTP_CODE})${RESET}" >&2; exit 1 ;;
    esac

    echo ""
    echo -e "${GREEN}=== Keycloak セットアップ完了 ===${RESET}"
    echo -e "${GREEN}ログイン URL : ${RHDH_BASE_URL}${RESET}"
    echo -e "${GREEN}ユーザー    : ${TEST_USER} / ${TEST_USER_PASSWORD}${RESET}"
    echo -e "${GREEN}OIDC metadata: ${SSO_URL}/realms/${REALM}/.well-known/openid-configuration${RESET}"
}

setup() {

    echo -e "${BLUE}セットアップ開始...${RESET}"

    # プロジェクトが既に存在する場合はスキップ
    oc new-project "$RHDH_NAMESPACE" 2>/dev/null \
        || echo -e "${YELLOW}Project $RHDH_NAMESPACE already exists.${RESET}"
    oc new-project rhdh-operator 2>/dev/null \
        || echo -e "${YELLOW}Project rhdh-operator already exists.${RESET}"

    # オペレータが準備できるまで待機（固定sleep廃止）
    echo -e "${BLUE}オペレータの準備を待機中...${RESET}"
    oc wait --for=condition=Available deployment --all -n rhdh-operator \
        --timeout=120s 2>/dev/null || true

    oc apply -f "$SCRIPT_DIR/openshift/developer-hub-operator.yaml" -n rhdh-operator

    echo -e "${GREEN}セットアップ完了${RESET}"
}

pipeline() {
    local APP_NAME="${2:-quarkusdroneshop-reward}"
    local NAMESPACE="${3:-quarkusdroneshop-cicd}"
    local GIT_OWNER="${4:-quarkusdroneshop}"
    local PIPELINE_FILE="$SCRIPT_DIR/../tekton-pipelines/${APP_NAME}/pipeline/deploy-pipeline.yaml"

    echo -e "${BLUE}Pipeline セットアップ: ${APP_NAME} in ${NAMESPACE}${RESET}"

    oc new-project "$NAMESPACE" 2>/dev/null \
        || echo -e "${YELLOW}Project $NAMESPACE already exists.${RESET}"

    if [ -f "$PIPELINE_FILE" ]; then
        oc apply -f "$PIPELINE_FILE" -n "$NAMESPACE"
        echo -e "${GREEN}Pipeline applied from ${PIPELINE_FILE}${RESET}"
    else
        echo -e "${YELLOW}Pipeline file not found: ${PIPELINE_FILE}${RESET}"
        echo -e "${YELLOW}Applying inline pipeline definition...${RESET}"
        oc apply -n "$NAMESPACE" -f - <<PIPELINEEOF
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: ${APP_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${APP_NAME}
spec:
  params:
    - default: latest
      description: Image Tag Value
      name: IMAGE_TAG
      type: string
  workspaces:
    - name: shared-workspace
    - name: dependency-check-cache
  tasks:
    - name: fetch-repository
      params:
        - name: url
          value: "https://github.com/${GIT_OWNER}/${APP_NAME}"
        - name: subdirectory
          value: ''
        - name: deleteExisting
          value: 'true'
      taskRef:
        kind: Task
        name: git-clone
      workspaces:
        - name: output
          workspace: shared-workspace
    - name: semgrep-scan
      runAfter: [fetch-repository]
      taskRef:
        kind: Task
        name: semgrep-scan
      params:
        - name: RULES
          value: "p/java,p/owasp-top-ten,p/secrets"
        - name: FAIL_ON_FINDINGS
          value: "false"
      workspaces:
        - name: source
          workspace: shared-workspace
    - name: maven-run
      runAfter: [semgrep-scan]
      taskRef:
        kind: Task
        name: maven-no-settings11
      params:
        - name: CONTEXT_DIR
          value: .
        - name: GOALS
          value: "clean package"
      workspaces:
        - name: source
          workspace: shared-workspace
    - name: push-oc-apps
      runAfter: [maven-run]
      taskRef:
        name: push-app-task
      params:
        - name: SCRIPT
          value: |
            #!/bin/bash
            set -e
            APP=${APP_NAME}
            NS=quarkusdroneshop-demo
            oc delete all -l app=\$APP -n \$NS || true
            oc new-build --binary --name=\$APP --image-stream=ubi8-openjdk-21:1.18 -n \$NS
            oc start-build \$APP --from-dir=target/quarkus-app/ --follow -n \$NS
            oc new-app \$APP --name=\$APP --allow-missing-images -n \$NS
      workspaces:
        - name: source
          workspace: shared-workspace
PIPELINEEOF
    fi

    # PVC作成
    oc apply -n "$NAMESPACE" -f - <<PVCEOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP_NAME}-shared-workspace-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
PVCEOF

    echo -e "${GREEN}Pipeline / PVC セットアップ完了${RESET}"
}

retoken() {

    local NEW_TOKEN
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        NEW_TOKEN="$GITHUB_TOKEN"
        echo -e "${YELLOW}環境変数 GITHUB_TOKEN を使用します${RESET}"
    else
        read -rsp "新しい GitHub Token を入力してください (ghp_...): " NEW_TOKEN
        echo ""
    fi

    if [ -z "$NEW_TOKEN" ]; then
        echo -e "${RED}ERROR: Token が入力されていません${RESET}" >&2
        exit 1
    fi

    echo -e "${BLUE}Secret を更新中...${RESET}"
    oc patch secret secrets-rhdh \
        -n "$RHDH_NAMESPACE" \
        --type=merge \
        -p "{\"stringData\":{\"GITHUB_TOKEN\":\"${NEW_TOKEN}\"}}"

    echo -e "${BLUE}Deployment を再起動中...${RESET}"
    oc rollout restart deployment/backstage-developer-hub \
        -n "$RHDH_NAMESPACE"

    oc rollout status deployment/backstage-developer-hub \
        -n "$RHDH_NAMESPACE" \
        --timeout=300s

    echo -e "${GREEN}GitHub Token の更新完了${RESET}"
}

target_token() {
    local TARGET_DOMAIN="${2:-}"
    local TARGET_NAMESPACE="${3:-quarkusdroneshop-cicd}"
    local SA_NAME="rhdh-proxy"
    local SECRET_NAME="rhdh-proxy-token"

    if [ -z "$TARGET_DOMAIN" ]; then
        echo -e "${RED}使用方法: $0 target-token <cluster-domain>${RESET}" >&2
        echo -e "${YELLOW}例: $0 target-token ocp.mnlq9.sandbox1332.opentlc.com${RESET}" >&2
        exit 1
    fi

    local TARGET_API="https://api.${TARGET_DOMAIN}:6443"
    echo -e "${BLUE}ターゲットクラスターにログイン: ${TARGET_API}${RESET}"
    oc login "$TARGET_API" -u admin

    echo -e "${BLUE}ServiceAccount ${SA_NAME} を作成中...${RESET}"
    oc create serviceaccount "$SA_NAME" -n "$TARGET_NAMESPACE" 2>/dev/null \
        && echo -e "${GREEN}ServiceAccount 作成済み${RESET}" \
        || echo -e "${YELLOW}ServiceAccount はすでに存在します${RESET}"

    echo -e "${BLUE}cluster-admin 権限を付与中...${RESET}"
    oc adm policy add-cluster-role-to-user cluster-admin \
        -z "$SA_NAME" -n "$TARGET_NAMESPACE"

    echo -e "${BLUE}永続トークン Secret を作成中...${RESET}"
    oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${TARGET_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

    echo -e "${BLUE}トークンが生成されるまで待機中...${RESET}"
    for i in $(seq 1 20); do
        TOKEN=$(oc get secret "$SECRET_NAME" -n "$TARGET_NAMESPACE" \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
        if [ -n "$TOKEN" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "$TOKEN" ]; then
        echo -e "${RED}トークンの取得に失敗しました${RESET}" >&2
        exit 1
    fi

    echo ""
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${GREEN}トークン取得成功${RESET}"
    echo -e "${GREEN}========================================${RESET}"
    echo -e "${YELLOW}TARGET_K8S_CLUSTER_URL: ${TARGET_API}${RESET}"
    echo -e "${YELLOW}TARGET_K8S_CLUSTER_TOKEN: ${TOKEN}${RESET}"
    echo ""

    # secrets-rhdh.yaml を自動更新するか確認
    read -rp "secrets-rhdh.yaml を自動更新して RHDH に適用しますか？ [y/N]: " APPLY
    if [[ "$APPLY" =~ ^[Yy]$ ]]; then
        sed -i.bak \
            -e "s|TARGET_K8S_CLUSTER_URL: \"[^\"]*\"|TARGET_K8S_CLUSTER_URL: \"${TARGET_API}\"|" \
            -e "s|TARGET_K8S_CLUSTER_TOKEN: \"[^\"]*\"|TARGET_K8S_CLUSTER_TOKEN: \"${TOKEN}\"|" \
            "$SCRIPT_DIR/openshift/secrets-rhdh.yaml"
        rm -f "$SCRIPT_DIR/openshift/secrets-rhdh.yaml.bak"

        # RHDHクラスターに戻って適用
        local RHDH_API
        RHDH_API=$(grep 'K8S_CLUSTER_URL' "$SCRIPT_DIR/openshift/secrets-rhdh.yaml" \
            | grep -v TARGET | sed 's/.*"\(https[^"]*\)".*/\1/')
        echo -e "${BLUE}RHDHクラスター (${RHDH_API}) に切り替えて適用中...${RESET}"
        oc login "$RHDH_API" -u admin 2>/dev/null || true
        oc patch secret secrets-rhdh -n "$RHDH_NAMESPACE" \
            --type=merge \
            -p "{\"stringData\":{\"TARGET_K8S_CLUSTER_URL\":\"${TARGET_API}\",\"TARGET_K8S_CLUSTER_TOKEN\":\"${TOKEN}\"}}"
        oc rollout restart deployment/backstage-developer-hub -n "$RHDH_NAMESPACE"
        echo -e "${GREEN}RHDH への適用完了（バックグラウンドで再起動中）${RESET}"
    else
        echo -e "${YELLOW}手動で secrets-rhdh.yaml を更新してください${RESET}"
    fi
}

system_token() {
    # 各システムクラスターの SA トークンを取得して secrets-rhdh.yaml を更新する
    # 使用方法: ./developer-hub.sh system-token
    # クラスター URL はプロビジョニングごとに変わるため実行時に入力する
    local SA_NAME="rhdh-k8s-plugin"
    local SECRET_NAME="rhdh-k8s-plugin-sa-token"
    local CICD_NS="quarkusdroneshop-cicd"
    local SECRETS_FILE="$SCRIPT_DIR/openshift/secrets-rhdh.yaml"

    declare -A CLUSTER_KEYS
    CLUSTER_KEYS["a-cluster"]="A"
    CLUSTER_KEYS["b-cluster"]="B"
    CLUSTER_KEYS["c-cluster"]="C"

    local RHDH_API
    RHDH_API=$(oc whoami --show-server)

    # 各クラスタードメインを対話入力
    echo -e "${YELLOW}クラスタードメインを入力してください（例: ocp.hnkwm.sandbox225.opentlc.com）${RESET}"
    echo -e "${YELLOW}スキップする場合は Enter を押してください${RESET}"
    echo ""

    declare -A CLUSTER_DOMAINS
    for CLUSTER_NAME in a-cluster b-cluster c-cluster; do
        local KEY="${CLUSTER_KEYS[$CLUSTER_NAME]}"
        # 現在の設定値を secrets-rhdh.yaml から読み取ってデフォルト表示
        local CURRENT_URL
        CURRENT_URL=$(grep "K8S_CLUSTER_URL_${KEY}:" "$SECRETS_FILE" 2>/dev/null \
            | sed 's/.*"https:\/\/api\.\([^"]*\):6443".*/\1/' || true)
        read -rp "${CLUSTER_NAME} (システム${KEY}) のドメイン [${CURRENT_URL:-未設定}]: " INPUT_DOMAIN
        if [ -n "$INPUT_DOMAIN" ]; then
            CLUSTER_DOMAINS[$CLUSTER_NAME]="$INPUT_DOMAIN"
        elif [ -n "$CURRENT_URL" ]; then
            CLUSTER_DOMAINS[$CLUSTER_NAME]="$CURRENT_URL"
            echo -e "${YELLOW}  → 現在の設定を使用: ${CURRENT_URL}${RESET}"
        else
            CLUSTER_DOMAINS[$CLUSTER_NAME]=""
        fi
    done
    echo ""

    for CLUSTER_NAME in a-cluster b-cluster c-cluster; do
        local DOMAIN="${CLUSTER_DOMAINS[$CLUSTER_NAME]}"
        local KEY="${CLUSTER_KEYS[$CLUSTER_NAME]}"

        if [ -z "$DOMAIN" ]; then
            echo -e "${YELLOW}${CLUSTER_NAME}: ドメイン未指定のためスキップします${RESET}"
            continue
        fi

        local API_URL="https://api.${DOMAIN}:6443"
        echo -e "${BLUE}=== ${CLUSTER_NAME} (${API_URL}) ===${RESET}"
        oc login "$API_URL" -u admin --insecure-skip-tls-verify 2>/dev/null || {
            echo -e "${RED}${CLUSTER_NAME} へのログインに失敗しました。スキップします${RESET}"
            continue
        }

        # SA 作成（存在しなければ）
        oc create serviceaccount "$SA_NAME" -n "$CICD_NS" 2>/dev/null || true
        oc adm policy add-cluster-role-to-user cluster-admin -z "$SA_NAME" -n "$CICD_NS" 2>/dev/null || true

        # 永続トークン Secret 作成
        oc apply -n "$CICD_NS" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${CICD_NS}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

        # トークン取得
        local TOKEN=""
        for i in $(seq 1 20); do
            TOKEN=$(oc get secret "$SECRET_NAME" -n "$CICD_NS" \
                -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
            [ -n "$TOKEN" ] && break
            sleep 2
        done

        if [ -z "$TOKEN" ]; then
            echo -e "${RED}${CLUSTER_NAME} のトークン取得に失敗しました${RESET}"
            continue
        fi

        echo -e "${GREEN}${CLUSTER_NAME} トークン取得成功${RESET}"

        # secrets-rhdh.yaml 更新
        sed -i.bak \
            -e "s|K8S_CLUSTER_URL_${KEY}: \"[^\"]*\"|K8S_CLUSTER_URL_${KEY}: \"${API_URL}\"|" \
            -e "s|K8S_CLUSTER_TOKEN_${KEY}: \"[^\"]*\"|K8S_CLUSTER_TOKEN_${KEY}: \"${TOKEN}\"|" \
            "$SECRETS_FILE"
        rm -f "${SECRETS_FILE}.bak"
        echo -e "${GREEN}secrets-rhdh.yaml の ${CLUSTER_NAME} 設定を更新しました${RESET}"
    done

    # RHDH クラスターに戻って適用
    echo -e "${BLUE}RHDHクラスター (${RHDH_API}) に切り替えて適用中...${RESET}"
    oc login "$RHDH_API" -u admin --insecure-skip-tls-verify 2>/dev/null || true
    oc apply -f "$SECRETS_FILE" -n "$RHDH_NAMESPACE"
    oc rollout restart deployment/backstage-developer-hub -n "$RHDH_NAMESPACE"
    echo -e "${GREEN}全クラスターのトークン設定完了。RHDH を再起動しました${RESET}"
}

cleanup() {

    echo -e "${BLUE}クリーンナップ開始...${RESET}"

    ## 共通タスクの削除（ファイル名を deploy と統一: k8-plugin-sa.yaml）
    oc delete -f "$SCRIPT_DIR/openshift/developer-hub.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$SCRIPT_DIR/openshift/app-config-rhdh.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$SCRIPT_DIR/openshift/secrets-rhdh.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$SCRIPT_DIR/openshift/dynamic-plugins-rhdh.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$SCRIPT_DIR/openshift/catalog-info.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$SCRIPT_DIR/openshift/k8-plugin-sa.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found

    ## プロジェクトの削除
    oc delete project "$RHDH_NAMESPACE" --ignore-not-found

    echo -e "${GREEN}クリーンナップ完了${RESET}"
}

case "$1" in
    setup)
        setup
        ;;
    deploy)
        deploy
        ;;
    keycloak)
        keycloak
        ;;
    pipeline)
        pipeline "$@"
        ;;
    retoken)
        retoken
        ;;
    customimage)
        customimage
        ;;
    resetcustombuild)
        resetcustombuild
        ;;
    target-token)
        target_token "$@"
        ;;
    system-token)
        system_token
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {setup|deploy|keycloak|pipeline|retoken|target-token|system-token|customimage|resetcustombuild|cleanup}${RESET}"
        echo -e "${YELLOW}  target-token <cluster-domain>  ターゲットクラスターの永続トークンを作成${RESET}"
        echo -e "${YELLOW}  system-token                   a/b/c-cluster の SA トークンを取得して secrets を更新${RESET}"
        exit 1
        ;;
esac
