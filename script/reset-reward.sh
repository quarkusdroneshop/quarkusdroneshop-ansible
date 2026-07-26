#!/bin/bash
# =============================================================================
# Script Name: reset-reward.sh
# Description: reward マイクロサービスに関する全リソースをリセット(削除)する。
#              対象:
#                1. OpenMetadata から reward 関連トピックのメタデータを削除
#                2. RHDH(Backstage)カタログから reward コンポーネントを削除
#                   (※ 現状は自動削除の認証手段が確立できていないため、
#                      手動手順を案内するのみ。下記「RHDHカタログについて」参照)
#                3. Bサイトの rewards Kafkaトピック(KafkaTopic CR)を削除
#                4. Bサイトの reward Pipeline/PipelineRun/BuildConfig等を削除
#                5. Aサイトの shop-bsite.rewards ミラートピックを削除
#                6. Cサイトの shop-bsite.rewards ミラートピックを削除
#                7. OpenMetadata の検索インデックスを再構築
#                8. GitHub の quarkusdroneshop-reward リポジトリを削除
#                   (存在する場合のみ。存在しなければスキップする)
#
# Author: Noriaki Mushino
# Date Created: 2026-07-26
# Last Modified: 2026-07-26
# Version: 1.3
#
# Usage:
#   ./reset-reward.sh                 # 対話確認の上、全ステップを実行
#   ./reset-reward.sh --yes           # 確認プロンプトなしで実行
#   ./reset-reward.sh --dry-run       # 実行コマンドを表示するだけで何もしない
#
# Prerequisites:
#   - OpenShift CLI (oc) がインストール済みであること
#   - curl がインストール済み
#
#   各サイトの oc context (下記デフォルト値) に既にログイン済みでなくてもよい。
#   未接続の場合、このスクリプトが admin ユーザー名 + パスワード入力を促し、
#   その場で `oc login` を試みる(パスワードスキップ = 空Enterでその
#   サイトの処理だけスキップして続行する)。
#
# 環境変数(すべて既定値あり。異なるsandbox環境で使う場合は上書きすること):
#   BSITE_CONTEXT        (既定: quarkusdroneshop-demo/api-ocp-659hh-sandbox2372-opentlc-com:6443/admin)
#   BSITE_API_SERVER     (既定: https://api.ocp.659hh.sandbox2372.opentlc.com:6443)
#   ASITE_CONTEXT        (既定: quarkusdroneshop-demo/api-ocp-zgjl6-sandbox780-opentlc-com:6443/admin)
#   ASITE_API_SERVER     (既定: https://api.ocp.zgjl6.sandbox780.opentlc.com:6443)
#   CSITE_CONTEXT        (既定: quarkusdroneshop-demo/api-ocp-44gnd-sandbox850-opentlc-com:6443/admin)
#   CSITE_API_SERVER     (既定: https://api.ocp.44gnd.sandbox850.opentlc.com:6443)
#   HUB_CONTEXT          (既定: ai-agent-platform/api-ocp-t6gss-sandbox1120-opentlc-com:6443/admin)
#   HUB_API_SERVER       (既定: https://api.ocp.t6gss.sandbox1120.opentlc.com:6443)
#   OM_HOST              (既定: http://openmetadata-openmetadata.apps.ocp.t6gss.sandbox1120.opentlc.com)
#   GITHUB_REPO          (既定: quarkusdroneshop/quarkusdroneshop-reward)
#
# GitHubリポジトリ削除には gh CLI (認証済み、対象リポジトリへの delete 権限が
# あること)が必要。gh が無い、または未認証の場合はこのステップのみスキップする。
#
# RHDHカタログについて:
#   RHDH の Backstage カタログAPI (DELETE /api/catalog/entities/by-uid/{uid}) は
#   認証が必須だが、この環境の externalAccess (type: legacy, Secret: BACKEND_SECRET)
#   をそのまま Bearer トークンとして渡すと "Illegal token" で拒否され、
#   有効な呼び出し方法をこのスクリプトからは確立できなかった。
#   そのため本スクリプトはRHDHカタログの自動削除を行わず、削除対象と
#   手動手順(UIでの Unregister)を画面に表示するのみとする。
#   自動化する場合は、RHDHの認証設定(Keycloak/OIDCクライアント等)を
#   別途確認のうえ、正規の認証情報を使った呼び出しに置き換えること。
# =============================================================================

set -uo pipefail

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

BSITE_CONTEXT="${BSITE_CONTEXT:-quarkusdroneshop-demo/api-ocp-659hh-sandbox2372-opentlc-com:6443/admin}"
BSITE_API_SERVER="${BSITE_API_SERVER:-https://api.ocp.659hh.sandbox2372.opentlc.com:6443}"
ASITE_CONTEXT="${ASITE_CONTEXT:-quarkusdroneshop-demo/api-ocp-zgjl6-sandbox780-opentlc-com:6443/admin}"
ASITE_API_SERVER="${ASITE_API_SERVER:-https://api.ocp.zgjl6.sandbox780.opentlc.com:6443}"
CSITE_CONTEXT="${CSITE_CONTEXT:-quarkusdroneshop-demo/api-ocp-44gnd-sandbox850-opentlc-com:6443/admin}"
CSITE_API_SERVER="${CSITE_API_SERVER:-https://api.ocp.44gnd.sandbox850.opentlc.com:6443}"
HUB_CONTEXT="${HUB_CONTEXT:-ai-agent-platform/api-ocp-t6gss-sandbox1120-opentlc-com:6443/admin}"
HUB_API_SERVER="${HUB_API_SERVER:-https://api.ocp.t6gss.sandbox1120.opentlc.com:6443}"
OM_HOST="${OM_HOST:-http://openmetadata-openmetadata.apps.ocp.t6gss.sandbox1120.opentlc.com}"
GITHUB_REPO="${GITHUB_REPO:-quarkusdroneshop/quarkusdroneshop-reward}"

APP_NAME="reward"
INSTANCE_LABEL="app.kubernetes.io/instance=quarkusdroneshop-${APP_NAME}"
DEMO_NAMESPACE="quarkusdroneshop-demo"
CICD_NAMESPACE="quarkusdroneshop-cicd"
AIAGENT_NAMESPACE="ai-agent-platform"
BSITE_TOPIC="rewards"
ASITE_MIRROR_TOPIC="shop-bsite.rewards"
CSITE_MIRROR_TOPIC="shop-bsite.rewards"

DRY_RUN=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    *) echo -e "${RED}不明なオプション: $arg${RESET}" >&2; exit 1 ;;
  esac
done

run() {
  echo -e "${BLUE}\$ $*${RESET}"
  if [ "$DRY_RUN" = true ]; then
    return 0
  fi
  "$@"
}

# 接続できない場合に admin ユーザー名 + パスワードの入力を促し、その場で
# oc login を試みる。成功したら $2 で渡された変数名にログイン後の
# context名を書き戻す(以降の oc --context=... はこの新しいcontextを使う)。
# 戻り値: 0=接続可能(既存 or ログイン成功) / 1=接続不可(スキップされた)
ensure_login() {
  local label="$1" api_server="$2" ctx_var_name="$3"
  local current_ctx="${!ctx_var_name}"

  if oc --context="$current_ctx" whoami --request-timeout=10s &>/dev/null; then
    return 0
  fi

  echo -e "${YELLOW}${label} (${current_ctx}) に接続できません。${RESET}"

  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}(dry-run のためログインは試行しません)${RESET}"
    return 1
  fi

  read -rp "  ${label} にログインします。ユーザー名 [admin]: " LOGIN_USER
  LOGIN_USER="${LOGIN_USER:-admin}"
  read -rsp "  ${label} (${LOGIN_USER}) パスワード (スキップする場合は空でEnter): " LOGIN_PASSWORD
  echo
  if [ -z "$LOGIN_PASSWORD" ]; then
    echo -e "${YELLOW}${label} をスキップしました。${RESET}"
    return 1
  fi

  local login_log
  login_log="$(mktemp)"
  if oc login "$api_server" -u "$LOGIN_USER" -p "$LOGIN_PASSWORD" \
      --insecure-skip-tls-verify=true &>"$login_log"; then
    local new_ctx
    new_ctx="$(oc config current-context)"
    printf -v "$ctx_var_name" '%s' "$new_ctx"
    echo -e "${GREEN}${label} へのログインに成功しました(context: ${new_ctx})${RESET}"
    rm -f "$login_log"
    return 0
  else
    echo -e "${RED}${label} へのログインに失敗しました:${RESET}"
    cat "$login_log" >&2
    rm -f "$login_log"
    return 1
  fi
}

command -v oc &>/dev/null || { echo -e "${RED}エラー: oc (OpenShift CLI) が必要です${RESET}" >&2; exit 1; }
command -v curl &>/dev/null || { echo -e "${RED}エラー: curl が必要です${RESET}" >&2; exit 1; }

echo "###################################"
echo "reward リセットシェル"
echo "###################################"
echo
echo "以下を削除します:"
echo "  - OpenMetadata: reward関連トピックのメタデータ(hard delete)"
echo "  - RHDH: reward コンポーネントの登録(※手動手順の案内のみ)"
echo "  - Bサイト: KafkaTopic '${BSITE_TOPIC}' (namespace: ${DEMO_NAMESPACE})"
echo "  - Bサイト: reward の Pipeline/PipelineRun/BuildConfig等 (namespace: ${DEMO_NAMESPACE}, ${CICD_NAMESPACE})"
echo "  - Aサイト: ミラートピック '${ASITE_MIRROR_TOPIC}' (namespace: ${DEMO_NAMESPACE})"
echo "  - Cサイト: ミラートピック '${CSITE_MIRROR_TOPIC}' (namespace: ${DEMO_NAMESPACE})"
echo "  - OpenMetadata: 検索インデックスの再構築(SearchIndexingApplication)"
echo "  - GitHub: ${GITHUB_REPO} リポジトリ(存在する場合のみ)"
echo
echo "接続できないクラスタがあれば、その場で admin ユーザー名/パスワードの入力を求めます。"
echo

if [ "$ASSUME_YES" != true ] && [ "$DRY_RUN" != true ]; then
  read -rp "本当に実行してよろしいですか？(yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo -e "${YELLOW}中止しました。${RESET}"
    exit 0
  fi
fi

# -----------------------------------------------------------------------------
# 1. OpenMetadata: reward 関連トピックのメタデータ削除
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[1/8] OpenMetadata: reward関連トピックのメタデータを削除中...${RESET}"

if ! ensure_login "Hubクラスタ" "$HUB_API_SERVER" HUB_CONTEXT; then
  echo -e "${RED}OpenMetadata削除・reindexをスキップします。${RESET}"
else
  # AI Agent Platform が使っている OpenMetadata の長期有効なbotトークンを流用する
  # (個人ユーザーのブラウザセッショントークンは短時間で失効するため使わない)
  OM_TOKEN=$(oc --context="$HUB_CONTEXT" get secret openmetadata-secret \
    -n "$AIAGENT_NAMESPACE" -o jsonpath='{.data.jwt-token}' 2>/dev/null | base64 -d)

  if [ -z "$OM_TOKEN" ]; then
    echo -e "${RED}OpenMetadataのbotトークンが取得できませんでした。OpenMetadata削除・reindexをスキップします。${RESET}"
  else
    # NOTE: fullyQualifiedName に "reward" を含むかで緩く絞り込むと、無関係な
    # "rewards-display" (Web表示専用の別トピック)まで誤って削除してしまう
    # (実際に一度誤削除する事故があった)。トピック名(name)の完全一致でのみ
    # 対象を絞る: 本体 "rewards" と、他サイトへのミラー "shop-<site>.rewards" のみ。
    REWARD_TOPIC_IDS=$(curl -sk -m 15 -H "Authorization: Bearer ${OM_TOKEN}" \
      "${OM_HOST}/api/v1/topics?limit=200" \
      | python3 -c "
import json, sys
d = json.load(sys.stdin)
target_names = {'${BSITE_TOPIC}', 'shop-asite.${BSITE_TOPIC}', 'shop-bsite.${BSITE_TOPIC}', 'shop-csite.${BSITE_TOPIC}'}
for t in d.get('data', []):
    if t.get('name') in target_names:
        print(t['id'], t['fullyQualifiedName'])
" 2>/dev/null)

    if [ -z "$REWARD_TOPIC_IDS" ]; then
      echo -e "${YELLOW}reward関連のトピックはOpenMetadataに見つかりませんでした(既に削除済みの可能性)。${RESET}"
    else
      echo "$REWARD_TOPIC_IDS" | while read -r TOPIC_ID TOPIC_FQN; do
        [ -z "$TOPIC_ID" ] && continue
        echo -e "${YELLOW}削除: ${TOPIC_FQN} (id=${TOPIC_ID})${RESET}"
        if [ "$DRY_RUN" = true ]; then
          echo -e "${BLUE}\$ curl -X DELETE -H 'Authorization: Bearer ***' ${OM_HOST}/api/v1/topics/${TOPIC_ID}?hardDelete=true&recursive=true${RESET}"
        else
          curl -sk -m 15 -X DELETE -H "Authorization: Bearer ${OM_TOKEN}" \
            "${OM_HOST}/api/v1/topics/${TOPIC_ID}?hardDelete=true&recursive=true" -o /dev/null -w "  HTTP: %{http_code}\n"
        fi
      done
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 2. RHDH: reward コンポーネントの削除(手動手順の案内のみ)
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[2/8] RHDH: reward コンポーネントの削除${RESET}"
echo -e "${YELLOW}このスクリプトからはRHDHカタログAPIへの認証が確立できていないため、"
echo -e "以下を手動で実施してください:${RESET}"
echo "  1. RHDH の Catalog 画面で 'quarkusdroneshop-reward' コンポーネントを開く"
echo "  2. 右上メニューから 'Unregister entity' を実行する"

# -----------------------------------------------------------------------------
# 3+4. Bサイト: Kafkaトピック / Pipeline関連リソースの削除
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[3/8] Bサイト: KafkaTopic '${BSITE_TOPIC}' を削除中...${RESET}"

if ! ensure_login "Bサイト" "$BSITE_API_SERVER" BSITE_CONTEXT; then
  echo -e "${RED}スキップします。${RESET}"
else
  run oc --context="$BSITE_CONTEXT" delete kafkatopic "$BSITE_TOPIC" \
    -n "$DEMO_NAMESPACE" --ignore-not-found --request-timeout=30s
fi

echo
echo -e "${BLUE}[4/8] Bサイト: reward の Pipeline/PipelineRun/BuildConfig等を削除中...${RESET}"

if ! oc --context="$BSITE_CONTEXT" whoami --request-timeout=10s &>/dev/null; then
  echo -e "${RED}Bサイトに接続できません。アプリリソースの削除をスキップします。${RESET}"
else
  # Deployment/Service/Route/BuildConfig/ImageStream 等、reward アプリの
  # 全リソースを app.kubernetes.io/instance ラベルで一括削除する
  run oc --context="$BSITE_CONTEXT" delete all,bc,is,pvc \
    -l "$INSTANCE_LABEL" -n "$DEMO_NAMESPACE" --ignore-not-found --request-timeout=30s
  run oc --context="$BSITE_CONTEXT" delete route "$APP_NAME" \
    -n "$DEMO_NAMESPACE" --ignore-not-found --request-timeout=30s

  # Pipeline/PipelineRun は同じクラスタの quarkusdroneshop-cicd namespace にある
  run oc --context="$BSITE_CONTEXT" delete pipeline,pipelinerun \
    -l "$INSTANCE_LABEL" -n "$CICD_NAMESPACE" --ignore-not-found --request-timeout=30s
  # 名前が直接分かっているものは念のため個別にも指定して削除する(ラベル漏れ対策)
  run oc --context="$BSITE_CONTEXT" delete pipeline \
    "build-and-push-quarkusdroneshop-${APP_NAME}" \
    -n "$CICD_NAMESPACE" --ignore-not-found --request-timeout=30s
  run oc --context="$BSITE_CONTEXT" delete pipelinerun \
    "build-and-push-quarkusdroneshop-${APP_NAME}" \
    -n "$CICD_NAMESPACE" --ignore-not-found --request-timeout=30s
  run oc --context="$BSITE_CONTEXT" delete pvc \
    "quarkusdroneshop-${APP_NAME}-shared-workspace-pvc" \
    -n "$CICD_NAMESPACE" --ignore-not-found --request-timeout=30s
fi

# -----------------------------------------------------------------------------
# 5. Aサイト: ミラートピックの削除
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[5/8] Aサイト: ミラートピック '${ASITE_MIRROR_TOPIC}' を削除中...${RESET}"

if ! ensure_login "Aサイト" "$ASITE_API_SERVER" ASITE_CONTEXT; then
  echo -e "${RED}スキップします。${RESET}"
else
  run oc --context="$ASITE_CONTEXT" delete kafkatopic "$ASITE_MIRROR_TOPIC" \
    -n "$DEMO_NAMESPACE" --ignore-not-found --request-timeout=30s
  echo -e "${YELLOW}注意: MirrorMaker2 の topicsPattern に '${BSITE_TOPIC}' が含まれたままだと"
  echo -e "再度自動でミラーされる可能性があります。恒久的に止めたい場合は"
  echo -e "mm2-extended の spec.mirrors[].topicsPattern から除外することを検討してください。${RESET}"
fi

# -----------------------------------------------------------------------------
# 6. Cサイト: ミラートピックの削除
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[6/8] Cサイト: ミラートピック '${CSITE_MIRROR_TOPIC}' を削除中...${RESET}"

if ! ensure_login "Cサイト" "$CSITE_API_SERVER" CSITE_CONTEXT; then
  echo -e "${RED}スキップします。${RESET}"
else
  run oc --context="$CSITE_CONTEXT" delete kafkatopic "$CSITE_MIRROR_TOPIC" \
    -n "$DEMO_NAMESPACE" --ignore-not-found --request-timeout=30s
fi

# -----------------------------------------------------------------------------
# 7. OpenMetadata: 検索インデックスの再構築
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[7/8] OpenMetadata: 検索インデックスを再構築中...${RESET}"

if [ -n "${OM_TOKEN:-}" ]; then
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}\$ curl -X POST -H 'Authorization: Bearer ***' ${OM_HOST}/api/v1/apps/trigger/SearchIndexingApplication${RESET}"
  else
    curl -sk -m 30 -X POST -H "Authorization: Bearer ${OM_TOKEN}" \
      "${OM_HOST}/api/v1/apps/trigger/SearchIndexingApplication" -o /dev/null -w "  HTTP: %{http_code}\n"
  fi
else
  echo -e "${YELLOW}OpenMetadataのトークンが取得できなかったため、reindexをスキップしました。${RESET}"
fi

# -----------------------------------------------------------------------------
# 8. GitHub: quarkusdroneshop-reward リポジトリの削除(存在する場合のみ)
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[8/8] GitHub: ${GITHUB_REPO} リポジトリを削除中...${RESET}"

if ! command -v gh &>/dev/null; then
  echo -e "${YELLOW}gh (GitHub CLI) が見つからないため、このステップをスキップします。${RESET}"
elif ! gh auth status &>/dev/null; then
  echo -e "${YELLOW}gh が未認証のため、このステップをスキップします(gh auth login を実行してください)。${RESET}"
elif ! gh repo view "$GITHUB_REPO" &>/dev/null; then
  echo -e "${YELLOW}リポジトリ ${GITHUB_REPO} は存在しないため、スキップします。${RESET}"
else
  run gh repo delete "$GITHUB_REPO" --yes
fi

echo
echo -e "${GREEN}完了しました。${RESET}"
