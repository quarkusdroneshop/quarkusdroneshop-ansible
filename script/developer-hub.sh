#!/bin/bash
# =============================================================================
# Script Name: developer-hub.sh
# Description: This script sets up the developer-hub image and application skeleton.
# Author: Noriaki Mushino
# Date Created: 2025-03-30
# Last Modified: 2026-07-04
# Version: 2.2
#
# Usage:
#   ./script/developer-hub.sh setup           - To setup the environment.
#   ./script/developer-hub.sh deploy          - To deploy the application.
#   ./script/developer-hub.sh keycloak        - To setup Keycloak realm/client/user for RHDH.
#   ./script/developer-hub.sh regithubtoken    - Reissuing a GitHub token.
#   ./script/developer-hub.sh target-token <domain> - Create persistent SA token for target cluster.
#   ./script/developer-hub.sh system-token          - Create SA tokens for a/b/c-cluster and update secrets.
#   ./script/developer-hub.sh cleanup         - To delete the application.
#   ./script/developer-hub.sh customimage     - The creation of a customised RHDH image.
#   ./script/developer-hub.sh resetcustombuild - Reset and rebuild the custom RHDH image from scratch.
#   ./script/developer-hub.sh update-plugin    - Rebuild test-report/data-catalog/kafka-topic-request-scaffolder-actions/skupper-console plugins, update integrity hashes, restart RHDH.
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
# script/ から見たリポジトリルート（openshift/ などはここ基準）
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

# ドメインの確認（update-plugin はドメイン確認不要のためスキップ）
echo -e "${YELLOW}Domain Name: $DOMAIN_NAME${RESET}"
echo -e "-------------------------------------------"
if [ "${1:-}" != "update-plugin" ]; then
    read -rp "指定されたドメインで間違いないですか？(yes/no): " DOMAIN_CONFREM
    if [ "$DOMAIN_CONFREM" != "yes" ]; then
        echo -e "${RED}処理を中断します。${RESET}"
        exit 1
    fi
fi

# secrets-rhdh が指すDBパスワードと、PostgreSQL Operator (Backstage CR) が
# 実際に生成したパスワードが一致しているかを確認する。
# 一致していないと backstage-backend が "password authentication failed" で
# クラッシュループするため、デプロイ直後に検知できるようにする。
# 値そのものは画面に出力せず、一致/不一致の判定のみ行う。
_check_db_password_match() {
    local psql_secret="backstage-psql-secret-developer-hub"
    local rhdh_secret="secrets-rhdh"

    echo -e "${BLUE}DBパスワードの整合性を確認中...${RESET}"

    local psql_pw_b64=""
    for i in $(seq 1 12); do
        psql_pw_b64="$(oc get secret "$psql_secret" -n "$RHDH_NAMESPACE" \
            -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null || true)"
        [ -n "$psql_pw_b64" ] && break
        sleep 5
    done

    if [ -z "$psql_pw_b64" ]; then
        echo -e "${YELLOW}  → ${psql_secret} がまだ作成されていないためスキップします(Operatorのプロビジョニング待ちの可能性があります)${RESET}"
        return 0
    fi

    local rhdh_pw_b64
    rhdh_pw_b64="$(oc get secret "$rhdh_secret" -n "$RHDH_NAMESPACE" \
        -o jsonpath='{.data.APP_CONFIG_backend_database_connection_password}' 2>/dev/null || true)"

    if [ -z "$rhdh_pw_b64" ]; then
        echo -e "${YELLOW}  → ${rhdh_secret} に DBパスワードのキーが見つからないためスキップします${RESET}"
        return 0
    fi

    if [ "$psql_pw_b64" == "$rhdh_pw_b64" ]; then
        echo -e "${GREEN}  → OK: DBパスワードは一致しています${RESET}"
    else
        echo -e "${RED}  ⚠ 警告: DBパスワードが一致していません！${RESET}" >&2
        echo -e "${YELLOW}    ${psql_secret} (実際のPostgreSQLパスワード) と ${RESET}" >&2
        echo -e "${YELLOW}    ${rhdh_secret} の APP_CONFIG_backend_database_connection_password が異なります。${RESET}" >&2
        echo -e "${YELLOW}    backstage-backend が 'password authentication failed' でクラッシュループします。${RESET}" >&2
        echo -e "${YELLOW}    修正例:${RESET}" >&2
        echo -e "${YELLOW}      PW_B64=\$(oc get secret ${psql_secret} -o jsonpath='{.data.POSTGRES_PASSWORD}')${RESET}" >&2
        echo -e "${YELLOW}      oc patch secret ${rhdh_secret} --type=json -p=\"[{\\\"op\\\":\\\"replace\\\",\\\"path\\\":\\\"/data/APP_CONFIG_backend_database_connection_password\\\",\\\"value\\\":\\\"\$PW_B64\\\"}]\"${RESET}" >&2
        echo -e "${YELLOW}      oc rollout restart deployment/backstage-developer-hub${RESET}" >&2
    fi
}

deploy() {

    oc project "$RHDH_NAMESPACE"

    # カスタムイメージの存在確認
    if ! oc get istag rhdh-hub-custom:latest -n "$RHDH_NAMESPACE" >/dev/null 2>&1; then
        echo -e "${RED}エラー: カスタムイメージ rhdh-hub-custom:latest が存在しません。${RESET}" >&2
        echo -e "${YELLOW}先に './script/developer-hub.sh customimage' を実行してビルドを完了させてください。${RESET}" >&2
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
    # (クォート付き/無し どちらの表記でも確実にマッチするよう、各項目とも2パターン用意する。
    #  以前 AUTH_OIDC_METADATA_URL がクォート無しで書かれていたためにこの置換がヒットせず、
    #  古いクラスタードメインのままSSO認証が失敗する事故があったための対策)
    sed -i.bak \
        -e "s|BASE_URL: \"https://backstage-developer-hub-${RHDH_NAMESPACE}\.apps\.[^\"]*\"|BASE_URL: \"${RHDH_BASE_URL}\"|" \
        -e "s|BASE_URL: https://backstage-developer-hub-${RHDH_NAMESPACE}\.apps\.[^[:space:]]*|BASE_URL: \"${RHDH_BASE_URL}\"|" \
        -e "s|AUTH_OIDC_METADATA_URL: \"https://sso\.apps\.[^\"]*\"|AUTH_OIDC_METADATA_URL: \"https://sso.${APPS_DOMAIN}/realms/rhdh/.well-known/openid-configuration\"|" \
        -e "s|AUTH_OIDC_METADATA_URL: https://sso\.apps\.[^[:space:]]*|AUTH_OIDC_METADATA_URL: \"https://sso.${APPS_DOMAIN}/realms/rhdh/.well-known/openid-configuration\"|" \
        -e "s|K8S_CLUSTER_NAME: \"[^\"]*\"|K8S_CLUSTER_NAME: \"${CLUSTER_DOMAIN}\"|" \
        -e "s|K8S_CLUSTER_NAME: [^\"[:space:]][^[:space:]]*|K8S_CLUSTER_NAME: \"${CLUSTER_DOMAIN}\"|" \
        -e "s|K8S_CLUSTER_URL: \"[^\"]*\"|K8S_CLUSTER_URL: \"${CLUSTER_API_URL}\"|" \
        -e "s|K8S_CLUSTER_URL: [^\"[:space:]][^[:space:]]*|K8S_CLUSTER_URL: \"${CLUSTER_API_URL}\"|" \
        "$REPO_ROOT/openshift/secrets-rhdh.yaml"
    rm -f "$REPO_ROOT/openshift/secrets-rhdh.yaml.bak"

    # 置換後、主要4項目が実際に現在のクラスタードメインを指しているか検証する
    # (クォート有無以外の予期しない不一致でも、ここで気づけるようにする)
    local _mismatch=0
    for _key in BASE_URL AUTH_OIDC_METADATA_URL K8S_CLUSTER_NAME K8S_CLUSTER_URL; do
        if ! grep -q "^  ${_key}:.*${CLUSTER_DOMAIN}" "$REPO_ROOT/openshift/secrets-rhdh.yaml"; then
            echo -e "${RED}  ⚠ 警告: secrets-rhdh.yaml の ${_key} が現在のクラスタードメイン(${CLUSTER_DOMAIN})を指していません${RESET}" >&2
            _mismatch=1
        fi
    done
    [ "$_mismatch" -eq 0 ] && echo -e "${GREEN}  → secrets-rhdh.yaml のドメイン置換を確認しました${RESET}"

    # template.yaml の clusterDomain デフォルト値を更新
    local TEMPLATE_YAML="$REPO_ROOT/../developerhub-skeleton/template.yaml"
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

    if oc get backstage developer-hub -n "$RHDH_NAMESPACE" &>/dev/null; then
        oc replace -f "$REPO_ROOT/openshift/developer-hub.yaml" -n "$RHDH_NAMESPACE"
    else
        oc apply -f "$REPO_ROOT/openshift/developer-hub.yaml" -n "$RHDH_NAMESPACE"
    fi
    oc apply -f "$REPO_ROOT/openshift/app-config-rhdh.yaml" -n "$RHDH_NAMESPACE"
    oc apply -f "$REPO_ROOT/openshift/secrets-rhdh.yaml" -n "$RHDH_NAMESPACE"
    oc apply -f "$REPO_ROOT/openshift/dynamic-plugins-rhdh.yaml" -n "$RHDH_NAMESPACE"

    # {{ ocp_apps_domain }} を実際のドメインに置換してから apply
    echo -e "${BLUE}OpenMetadata URLのドメインを ${APPS_DOMAIN} に置換して適用...${RESET}"
    sed "s|{{ ocp_apps_domain }}|${APPS_DOMAIN}|g" \
        "$REPO_ROOT/openshift/catalog-info.yaml" | oc apply -f - -n "$RHDH_NAMESPACE"
    sed "s|{{ ocp_apps_domain }}|${APPS_DOMAIN}|g" \
        "$REPO_ROOT/openshift/om-proxy.yaml" | oc apply -f -

    oc apply -f "$REPO_ROOT/openshift/k8-plugin-sa.yaml" -n "$RHDH_NAMESPACE"

    oc adm policy add-cluster-role-to-user edit \
        -z rhdh-k8s-plugin \
        -n "$RHDH_NAMESPACE"

    oc adm policy add-cluster-role-to-user view \
        -z rhdh-k8s-plugin \
        -n "$RHDH_NAMESPACE"

    # DBパスワードの整合性確認（不一致の場合は警告のみ、デプロイは継続する）
    _check_db_password_match

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
    # registry.redhat.io の有効な認証情報を持つ設定ファイルを探す。
    # podmanは既定で ~/.config/containers/auth.json、dockerは ~/.docker/config.json を
    # 使い分けており、`podman login`していても~/.docker/config.jsonにはauthが空のまま
    # 残ることがある。気づかずそちらをSecretへコピーするとイメージインポート時の
    # "unauthorized" で初めて発覚するため、事前に両方probeして案内する
    local candidates=(
        "$HOME/.config/containers/auth.json"
        "$HOME/.docker/config.json"
    )
    local auth_file=""
    for f in "${candidates[@]}"; do
        if [ -f "$f" ] && python3 -c "
import json, sys
with open('$f') as fh:
    d = json.load(fh)
auth = d.get('auths', {}).get('registry.redhat.io', {})
sys.exit(0 if auth.get('auth') else 1)
" 2>/dev/null; then
            auth_file="$f"
            break
        fi
    done

    if [ -z "$auth_file" ]; then
        echo -e "${RED}registry.redhat.io の有効な認証情報が見つかりません。${RESET}" >&2
        echo -e "${YELLOW}Customer Portal アカウントでログインしてから再実行してください:${RESET}" >&2
        echo "       docker login registry.redhat.io" >&2
        echo "       (または: podman login registry.redhat.io)" >&2
        exit 1
    fi

    echo "  registry.redhat.io の認証情報を使用: ${auth_file}"

    # Scopioの認証情報をセットする
    oc create secret generic redhat-pull-secret \
        --from-file=.dockerconfigjson="$auth_file" \
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
    build_dir="$(cd "$REPO_ROOT/../developerhub-skeleton/developerhub" && pwd)"

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
    build_dir="$(cd "$REPO_ROOT/../developerhub-skeleton/developerhub" && pwd)"

    # resetcustombuild は常にフレッシュなビルドを保証する
    _local_build "$build_dir"
    _stage_tarballs "$build_dir"

    echo -e "${YELLOW}BuildConfigとImageStreamを削除してキャッシュをリセットします...${RESET}"
    oc delete -f "$REPO_ROOT/openshift/developer-hub.yaml" --ignore-not-found
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
    # 形式: "username:password:email:firstName:lastName"
    local -a TEST_USERS=(
        "nmushino:password0:nmushino@redhat.com:Noraki:Mushino"
        "User1:password1:user1@example.com:Workshop:User1"
        "User2:password2:user2@example.com:Workshop:User2"
        "User3:password3:user3@example.com:Workshop:User3"
    )

    echo -e "${BLUE}Keycloak セットアップ開始${RESET}"
    echo -e "${YELLOW}SSO URL     : ${SSO_URL}${RESET}"
    echo -e "${YELLOW}RHDH URL    : ${RHDH_BASE_URL}${RESET}"
    echo -e "${YELLOW}Realm       : ${REALM}${RESET}"
    echo -e "-------------------------------------------"

    # Keycloak 管理者ユーザー名・パスワードの入力
    # (RHBK Operator のブートストラップ管理者名は "admin" 固定ではなく
    #  keycloak-initial-admin Secret の username で決まる。例: temp-admin 等)
    # 注意: bare な `local VAR` は環境変数からの値も空にシャドーイングしてしまうため、
    # 必ず `local VAR="${VAR:-}"` の形で既存の値を保持してから判定すること
    local KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-}"
    if [ -n "$KEYCLOAK_ADMIN" ]; then
        echo -e "${YELLOW}環境変数 KEYCLOAK_ADMIN を使用します: ${KEYCLOAK_ADMIN}${RESET}"
    else
        read -rp "Keycloak 管理者ユーザー名を入力してください [admin]: " KEYCLOAK_ADMIN
        KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
    fi

    local KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-}"
    if [ -n "$KEYCLOAK_ADMIN_PASSWORD" ]; then
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
        echo -e "${RED}ERROR: admin トークン取得失敗。URL・ユーザー名(${KEYCLOAK_ADMIN})・パスワードを確認してください。${RESET}" >&2
        echo -e "${YELLOW}  ヒント: RHBK Operator のブートストラップ管理者名は次で確認できます:${RESET}" >&2
        echo -e "${YELLOW}    oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d${RESET}" >&2
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
    echo -e "${BLUE}[4/4] テストユーザー作成中 (${#TEST_USERS[@]}件)...${RESET}"
    local user_entry username password email first_name last_name
    for user_entry in "${TEST_USERS[@]}"; do
        IFS=':' read -r username password email first_name last_name <<< "${user_entry}"

        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
            "${SSO_URL}/admin/realms/${REALM}/users" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{
                \"username\": \"${username}\",
                \"email\": \"${email}\",
                \"enabled\": true,
                \"emailVerified\": true,
                \"firstName\": \"${first_name}\",
                \"lastName\": \"${last_name}\",
                \"credentials\": [{
                    \"type\": \"password\",
                    \"value\": \"${password}\",
                    \"temporary\": false
                }]
            }")

        case "$HTTP_CODE" in
            201)
                echo -e "${GREEN}OK: ユーザー ${username} 作成成功${RESET}"
                ;;
            409)
                # 既に存在する場合は、TEST_USERS の内容(email/氏名/パスワード)で
                # 上書き更新する。username で作成した際のズレ(例: 過去に別メールで
                # 作成済みだった等)を再実行のたびに解消できるようにするため
                local existing_id
                existing_id=$(curl -sk -G \
                    "${SSO_URL}/admin/realms/${REALM}/users" \
                    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                    --data-urlencode "username=${username}" \
                    --data-urlencode "exact=true" \
                    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)

                if [ -z "$existing_id" ]; then
                    echo -e "${RED}ERROR: ユーザー ${username} のID取得に失敗しました${RESET}" >&2
                    exit 1
                fi

                local update_code
                update_code=$(curl -sk -o /dev/null -w "%{http_code}" -X PUT \
                    "${SSO_URL}/admin/realms/${REALM}/users/${existing_id}" \
                    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d "{
                        \"email\": \"${email}\",
                        \"enabled\": true,
                        \"emailVerified\": true,
                        \"firstName\": \"${first_name}\",
                        \"lastName\": \"${last_name}\"
                    }")

                local pw_code
                pw_code=$(curl -sk -o /dev/null -w "%{http_code}" -X PUT \
                    "${SSO_URL}/admin/realms/${REALM}/users/${existing_id}/reset-password" \
                    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -d "{
                        \"type\": \"password\",
                        \"value\": \"${password}\",
                        \"temporary\": false
                    }")

                if [ "$update_code" == "204" ] && [ "$pw_code" == "204" ]; then
                    echo -e "${GREEN}UPDATE: ユーザー ${username} は既存のため属性(email等)とパスワードを更新しました${RESET}"
                else
                    echo -e "${RED}ERROR: ユーザー ${username} の更新に失敗しました (profile:${update_code} password:${pw_code})${RESET}" >&2
                    exit 1
                fi
                ;;
            *)
                echo -e "${RED}ERROR: ユーザー ${username} 作成失敗 (HTTP ${HTTP_CODE})${RESET}" >&2
                exit 1
                ;;
        esac
    done

    echo ""
    echo -e "${GREEN}=== Keycloak セットアップ完了 ===${RESET}"
    echo -e "${GREEN}ログイン URL : ${RHDH_BASE_URL}${RESET}"
    echo -e "${GREEN}ユーザー一覧:${RESET}"
    for user_entry in "${TEST_USERS[@]}"; do
        IFS=':' read -r username password email first_name last_name <<< "${user_entry}"
        echo -e "${GREEN}  ${username} / ${password}${RESET}"
    done
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

    oc apply -f "$REPO_ROOT/openshift/developer-hub-operator.yaml" -n rhdh-operator

    echo -e "${GREEN}セットアップ完了${RESET}"
}

pipeline() {
    local APP_NAME="${2:-quarkusdroneshop-reward}"
    local NAMESPACE="${3:-quarkusdroneshop-cicd}"
    local GIT_OWNER="${4:-quarkusdroneshop}"
    local PIPELINE_FILE="$REPO_ROOT/../tekton-pipelines/${APP_NAME}/pipeline/deploy-pipeline.yaml"

    echo -e "${BLUE}Pipeline セットアップ: ${APP_NAME} in ${NAMESPACE}${RESET}"

    oc new-project "$NAMESPACE" 2>/dev/null \
        || echo -e "${YELLOW}Project $NAMESPACE already exists.${RESET}"

    if [ -f "$PIPELINE_FILE" ]; then
        sed "s/\${{ values.app_name }}/${APP_NAME}/g" "$PIPELINE_FILE" \
            | oc delete -f - -n "$NAMESPACE" --ignore-not-found || true
        sed "s/\${{ values.app_name }}/${APP_NAME}/g" "$PIPELINE_FILE" \
            | oc create -f - -n "$NAMESPACE"
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
        name: maven-no-settings21
      params:
        - name: CONTEXT_DIR
          value: .
        - name: GOALS
          value: "clean verify -Dquarkus.package.jar.type=uber-jar"
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
            oc delete bc/quarkusdroneshop-\$APP -n \$NS || true

            RUNNER_JAR=\$(ls target/*-runner.jar | head -1)
            oc new-build --binary --name=quarkusdroneshop-\$APP --docker-image=registry.access.redhat.com/ubi8/openjdk-21:1.20 -n \$NS
            oc start-build quarkusdroneshop-\$APP --from-file="\$RUNNER_JAR" --follow -n \$NS
            oc new-app quarkusdroneshop-\$APP --name=quarkusdroneshop-\$APP --allow-missing-images -n \$NS
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

regithubtoken() {

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

    # ターゲットクラスターにログインする前に現在のRHDHクラスターのURLを保存
    local RHDH_API
    RHDH_API=$(oc whoami --show-server)

    local TARGET_API="https://api.${TARGET_DOMAIN}:6443"
    echo -e "${BLUE}ターゲットクラスターにログイン: ${TARGET_API}${RESET}"
    oc login "$TARGET_API" -u admin

    echo -e "${BLUE}rhdh-proxy RBAC (SA / ClusterRole / ClusterRoleBinding / Secret) を適用中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/rhdh-plugin-sa.yaml" \
        && echo -e "${GREEN}RBAC 適用済み${RESET}" \
        || { echo -e "${RED}RBAC 適用失敗${RESET}" >&2; exit 1; }

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
            "$REPO_ROOT/openshift/secrets-rhdh.yaml"
        rm -f "$REPO_ROOT/openshift/secrets-rhdh.yaml.bak"

        # RHDHクラスターに戻って適用
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

_system_token_one() {
    # 1クラスター分のトークン取得処理（bash 3.x 互換）
    local CLUSTER_NAME="$1"
    local KEY="$2"
    local SA_NAME="rhdh-k8s-plugin"
    local SECRET_NAME="rhdh-k8s-plugin-sa-token"
    local CICD_NS="quarkusdroneshop-cicd"
    local SECRETS_FILE="$REPO_ROOT/openshift/secrets-rhdh.yaml"

    # 現在の設定値をデフォルト表示
    local CURRENT_URL
    CURRENT_URL=$(grep "K8S_CLUSTER_URL_${KEY}:" "$SECRETS_FILE" 2>/dev/null \
        | sed 's/.*"https:\/\/api\.\([^"]*\):6443".*/\1/' || true)
    read -rp "${CLUSTER_NAME} (システム${KEY}) のドメイン [${CURRENT_URL:-未設定}]: " INPUT_DOMAIN

    local DOMAIN
    if [ -n "$INPUT_DOMAIN" ]; then
        DOMAIN="$INPUT_DOMAIN"
    elif [ -n "$CURRENT_URL" ]; then
        DOMAIN="$CURRENT_URL"
        echo -e "${YELLOW}  → 現在の設定を使用: ${CURRENT_URL}${RESET}"
    else
        echo -e "${YELLOW}${CLUSTER_NAME}: ドメイン未指定のためスキップします${RESET}"
        return 0
    fi

    local API_URL="https://api.${DOMAIN}:6443"
    echo -e "${BLUE}=== ${CLUSTER_NAME} (${API_URL}) ===${RESET}"
    oc login "$API_URL" -u admin --insecure-skip-tls-verify 2>/dev/null || {
        echo -e "${RED}${CLUSTER_NAME} へのログインに失敗しました。スキップします${RESET}"
        return 0
    }

    oc create serviceaccount "$SA_NAME" -n "$CICD_NS" 2>/dev/null || true
    oc adm policy add-cluster-role-to-user cluster-admin -z "$SA_NAME" -n "$CICD_NS" 2>/dev/null || true

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

    local TOKEN=""
    for i in $(seq 1 20); do
        TOKEN=$(oc get secret "$SECRET_NAME" -n "$CICD_NS" \
            -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
        [ -n "$TOKEN" ] && break
        sleep 2
    done

    if [ -z "$TOKEN" ]; then
        echo -e "${RED}${CLUSTER_NAME} のトークン取得に失敗しました${RESET}"
        return 0
    fi

    echo -e "${GREEN}${CLUSTER_NAME} トークン取得成功${RESET}"
    sed -i.bak \
        -e "s|K8S_CLUSTER_URL_${KEY}: \"[^\"]*\"|K8S_CLUSTER_URL_${KEY}: \"${API_URL}\"|" \
        -e "s|K8S_CLUSTER_TOKEN_${KEY}: \"[^\"]*\"|K8S_CLUSTER_TOKEN_${KEY}: \"${TOKEN}\"|" \
        "$SECRETS_FILE"
    rm -f "${SECRETS_FILE}.bak"
    echo -e "${GREEN}secrets-rhdh.yaml の ${CLUSTER_NAME} 設定を更新しました${RESET}"
}

system_token() {
    # 各システムクラスターの SA トークンを取得して secrets-rhdh.yaml を更新する
    # クラスター URL はプロビジョニングごとに変わるため実行時に入力する
    local SECRETS_FILE="$REPO_ROOT/openshift/secrets-rhdh.yaml"
    local RHDH_API
    RHDH_API=$(oc whoami --show-server)

    echo -e "${YELLOW}クラスタードメインを入力してください（例: ocp.hnkwm.sandbox225.opentlc.com）${RESET}"
    echo -e "${YELLOW}スキップする場合は Enter を押してください${RESET}"
    echo ""

    _system_token_one "a-cluster" "A"
    _system_token_one "b-cluster" "B"
    _system_token_one "c-cluster" "C"

    echo ""
    echo -e "${BLUE}RHDHクラスター (${RHDH_API}) に切り替えて適用中...${RESET}"
    oc login "$RHDH_API" -u admin --insecure-skip-tls-verify 2>/dev/null || true
    oc apply -f "$SECRETS_FILE" -n "$RHDH_NAMESPACE"
    oc rollout restart deployment/backstage-developer-hub -n "$RHDH_NAMESPACE"
    echo -e "${GREEN}全クラスターのトークン設定完了。RHDH を再起動しました${RESET}"
}

update_plugin() {

    oc project "$RHDH_NAMESPACE"

    local dynamic_plugins_yaml="$REPO_ROOT/openshift/dynamic-plugins-rhdh.yaml"

    echo -e "${BLUE}[1/5] プラグインをビルド中...${RESET}"
    (
        export NVM_DIR="$HOME/.nvm"
        # shellcheck disable=SC1091
        [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
        nvm use 22 2>/dev/null || true

        local dh_dir="$REPO_ROOT/../developerhub-skeleton/developerhub"
        cd "$dh_dir"

        # test-report ビルド
        mkdir -p dist-types/plugins/test-report
        npx tsc -p plugins/test-report/tsconfig.json \
            --declaration --emitDeclarationOnly \
            --outDir dist-types/plugins/test-report \
            --skipLibCheck 2>/dev/null || true
        yarn workspace @internal/plugin-test-report build
        cd "$dh_dir/plugins/test-report"
        npx --yes @red-hat-developer-hub/cli@latest plugin export

        # data-catalog ビルド（backstage-cli を直接実行）
        cd "$dh_dir/plugins/data-catalog"
        "$dh_dir/node_modules/.bin/backstage-cli" package build
        npx --yes @red-hat-developer-hub/cli@latest plugin export

        # kafka-topic-request-scaffolder-actions ビルド
        mkdir -p dist-types/plugins/kafka-topic-request-scaffolder-actions
        npx tsc -p plugins/kafka-topic-request-scaffolder-actions/tsconfig.json \
            --declaration --emitDeclarationOnly \
            --outDir dist-types/plugins/kafka-topic-request-scaffolder-actions \
            --skipLibCheck 2>/dev/null || true
        cd "$dh_dir/plugins/kafka-topic-request-scaffolder-actions"
        "$dh_dir/node_modules/.bin/backstage-cli" package build
        npx --yes @red-hat-developer-hub/cli@latest plugin export

        # skupper-console ビルド
        cd "$dh_dir/plugins/skupper-console"
        "$dh_dir/node_modules/.bin/backstage-cli" package build
        npx --yes @red-hat-developer-hub/cli@latest plugin export
    )
    echo -e "${GREEN}  → ビルド完了${RESET}"

    echo -e "${BLUE}[2/5] カスタムイメージをビルド中...${RESET}"
    local build_dir
    build_dir="$(cd "$REPO_ROOT/../developerhub-skeleton/developerhub" && pwd)"
    _stage_tarballs "$build_dir"
    oc delete pod -A --field-selector=status.phase=Succeeded --ignore-not-found 2>/dev/null || true
    local build_name
    build_name=$(oc start-build rhdh-hub-custom --from-dir="$build_dir" -o name)
    _cleanup_tarballs "$build_dir"
    echo -e "${GREEN}  → ビルド開始: ${build_name}${RESET}"
    oc wait --for=condition=complete "$build_name" -n "$RHDH_NAMESPACE" --timeout=1800s || \
        { oc logs "$build_name" -n "$RHDH_NAMESPACE" --tail=20 2>/dev/null; exit 1; }
    echo -e "${GREEN}  → イメージビルド完了${RESET}"

    echo -e "${BLUE}[3/5] プラグインサーバーを適用・再起動してtgzを再生成中...${RESET}"
    oc apply -f "$REPO_ROOT/openshift/plugin-server.yaml" -n "$RHDH_NAMESPACE" 2>/dev/null || \
        oc replace -f "$REPO_ROOT/openshift/plugin-server.yaml" -n "$RHDH_NAMESPACE"
    oc rollout restart deployment/plugin-proxy-server -n "$RHDH_NAMESPACE"
    oc rollout status deployment/plugin-proxy-server -n "$RHDH_NAMESPACE" --timeout=180s
    local server_pod
    server_pod=$(oc get pod -n "$RHDH_NAMESPACE" -l app=plugin-proxy-server \
        --no-headers 2>/dev/null | grep "1/1.*Running" | grep -v Terminating | awk '{print $1}' | head -1)
    [ -z "$server_pod" ] && echo -e "${RED}エラー: プラグインサーバーのポッドが見つかりません${RESET}" && exit 1
    echo -e "${GREEN}  → プラグインサーバー起動: ${server_pod}${RESET}"

    echo -e "${BLUE}[4/5] integrity ハッシュを計算中...${RESET}"
    local hash_test_report hash_data_catalog hash_kafka_topic_request_scaffolder_actions hash_skupper_console
    hash_test_report=$(oc exec -n "$RHDH_NAMESPACE" "$server_pod" -- sh -c \
        'sha512sum /tarball/internal-plugin-test-report-dynamic-0.1.0.tgz | awk "{print \$1}" | xxd -r -p | base64 -w0')
    hash_data_catalog=$(oc exec -n "$RHDH_NAMESPACE" "$server_pod" -- sh -c \
        'sha512sum /tarball/internal-plugin-data-catalog-dynamic-0.1.0.tgz | awk "{print \$1}" | xxd -r -p | base64 -w0')
    hash_kafka_topic_request_scaffolder_actions=$(oc exec -n "$RHDH_NAMESPACE" "$server_pod" -- sh -c \
        'sha512sum /tarball/internal-plugin-kafka-topic-request-scaffolder-actions-dynamic-0.1.0.tgz | awk "{print \$1}" | xxd -r -p | base64 -w0')
    hash_skupper_console=$(oc exec -n "$RHDH_NAMESPACE" "$server_pod" -- sh -c \
        'sha512sum /tarball/internal-plugin-skupper-console-dynamic-0.1.0.tgz | awk "{print \$1}" | xxd -r -p | base64 -w0')
    local integrity_test_report="sha512-${hash_test_report}"
    local integrity_data_catalog="sha512-${hash_data_catalog}"
    local integrity_kafka_topic_request_scaffolder_actions="sha512-${hash_kafka_topic_request_scaffolder_actions}"
    local integrity_skupper_console="sha512-${hash_skupper_console}"
    echo -e "${GREEN}  → test-report integrity: ${integrity_test_report}${RESET}"
    echo -e "${GREEN}  → data-catalog integrity: ${integrity_data_catalog}${RESET}"
    echo -e "${GREEN}  → kafka-topic-request-scaffolder-actions integrity: ${integrity_kafka_topic_request_scaffolder_actions}${RESET}"
    echo -e "${GREEN}  → skupper-console integrity: ${integrity_skupper_console}${RESET}"

    echo -e "${BLUE}[5/5] dynamic-plugins-rhdh.yaml の integrity を更新して RHDH を再起動中...${RESET}"

    # test-report の integrity を更新（tgzファイル名の次の行のみ置換）
    python3 - "$dynamic_plugins_yaml" "$integrity_test_report" "$integrity_data_catalog" "$integrity_kafka_topic_request_scaffolder_actions" "$integrity_skupper_console" <<'PYEOF'
import sys, re

yaml_file = sys.argv[1]
hash_test = sys.argv[2]
hash_data = sys.argv[3]
hash_kafka_topic_request_scaffolder_actions = sys.argv[4]
hash_skupper_console = sys.argv[5]

with open(yaml_file) as f:
    content = f.read()

# test-report ブロック内の integrity を更新（package行からdisabled行の後のintegrity行）
content = re.sub(
    r"(internal-plugin-test-report[^\n]*\n(?:[^\n]*\n){0,3}?\s*integrity:)\s*'[^']*'",
    lambda m: m.group(1) + f" '{hash_test}'",
    content
)
# data-catalog ブロック内の integrity を更新
content = re.sub(
    r"(internal-plugin-data-catalog[^\n]*\n(?:[^\n]*\n){0,3}?\s*integrity:)\s*'[^']*'",
    lambda m: m.group(1) + f" '{hash_data}'",
    content
)
# kafka-topic-request-scaffolder-actions ブロック内の integrity を更新し、ビルド済みになったので disabled: false にする
content = re.sub(
    r"(internal-plugin-kafka-topic-request-scaffolder-actions[^\n]*\n)\s*disabled:\s*true",
    lambda m: m.group(1) + "        disabled: false",
    content
)
content = re.sub(
    r"(internal-plugin-kafka-topic-request-scaffolder-actions[^\n]*\n(?:[^\n]*\n){0,3}?\s*integrity:)\s*'[^']*'",
    lambda m: m.group(1) + f" '{hash_kafka_topic_request_scaffolder_actions}'",
    content
)
# skupper-console ブロック内の integrity を更新し、ビルド済みになったので disabled: false にする
content = re.sub(
    r"(internal-plugin-skupper-console[^\n]*\n)\s*disabled:\s*true",
    lambda m: m.group(1) + "        disabled: false",
    content
)
content = re.sub(
    r"(internal-plugin-skupper-console[^\n]*\n(?:[^\n]*\n){0,3}?\s*integrity:)\s*'[^']*'",
    lambda m: m.group(1) + f" '{hash_skupper_console}'",
    content
)

with open(yaml_file, "w") as f:
    f.write(content)
print("Updated integrity hashes in", yaml_file)
PYEOF

    # クラスター上の ConfigMap を更新
    oc apply -f "$dynamic_plugins_yaml" -n "$RHDH_NAMESPACE"

    oc rollout restart deployment/backstage-developer-hub -n "$RHDH_NAMESPACE"

    echo -e "${GREEN}update-plugin 完了。RHDH の起動をお待ちください。${RESET}"
}

cleanup() {

    echo -e "${BLUE}クリーンナップ開始...${RESET}"

    ## 共通タスクの削除（ファイル名を deploy と統一: k8-plugin-sa.yaml）
    oc delete -f "$REPO_ROOT/openshift/developer-hub.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$REPO_ROOT/openshift/app-config-rhdh.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$REPO_ROOT/openshift/secrets-rhdh.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$REPO_ROOT/openshift/dynamic-plugins-rhdh.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$REPO_ROOT/openshift/catalog-info.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found
    oc delete -f "$REPO_ROOT/openshift/k8-plugin-sa.yaml" -n "$RHDH_NAMESPACE" --ignore-not-found

    ## プロジェクトの削除
    oc delete project "$RHDH_NAMESPACE" --ignore-not-found

    echo -e "${GREEN}クリーンナップ完了${RESET}"
}

case "${1:-}" in
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
    regithubtoken)
        regithubtoken
        ;;
    customimage)
        customimage
        ;;
    resetcustombuild)
        resetcustombuild
        ;;
    update-plugin)
        update_plugin
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
        echo -e "${RED}無効なコマンドです: ${1:-（引数なし）}${RESET}"
        echo -e "${RED}使用方法: $0 {setup|deploy|keycloak|pipeline|regithubtoken|target-token|system-token|customimage|resetcustombuild|update-plugin|cleanup}${RESET}"
        echo -e "${YELLOW}  target-token <cluster-domain>  ターゲットクラスターの永続トークンを作成${RESET}"
        echo -e "${YELLOW}  system-token                   a/b/c-cluster の SA トークンを取得して secrets を更新${RESET}"
        exit 1
        ;;
esac
