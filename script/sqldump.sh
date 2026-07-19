#!/bin/bash
# =============================================================================
# Script Name: sqldump.sh
# Description: OpenMetadata (MySQL) / Developer Hub (RHDH/Backstage, PostgreSQL)
#              のDBダンプを取得する。どちらからダンプするかを対話式で確認して
#              から実行する。出力先は sqlimport.sh が参照するディレクトリと同じ
#              (../openmetadata-export/, ../developerhub-export/)。
# Author: Noriaki Mushino
# Date Created: 2025-05-28
# Last Modified: 2026-07-18
# Version: 2.1
#
# Usage:
#   ./script/sqldump.sh                 - 対話式でダンプ元を選択
#   ./script/sqldump.sh openmetadata     - OpenMetadata (MySQL) からダンプ
#   ./script/sqldump.sh developerhub     - Developer Hub (PostgreSQL) からダンプ
#
# Prerequisites:
#   - oc コマンドのみで完結 (Pod 内で mysqldump / pg_dumpall を実行し、
#     パスワードは Pod 内の環境変数/ファイルをコンテナ内部でのみ参照する。
#     外部には一切出力しない)
#   - User is logged into OpenShift
#   - ../openmetadata-export/, ../developerhub-export/ が存在すること
#     (それぞれ quarkusdroneshop-ansible の兄弟ディレクトリ)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPENMETADATA_EXPORT_DIR="${REPO_ROOT}/../openmetadata-export"
DEVELOPERHUB_EXPORT_DIR="${REPO_ROOT}/../developerhub-export"

OPENMETADATA_NAMESPACE="${OPENMETADATA_NAMESPACE:-openmetadata}"
OPENMETADATA_POD="${OPENMETADATA_POD:-mysql-0}"
DEVELOPERHUB_NAMESPACE="${DEVELOPERHUB_NAMESPACE:-quarkusdroneshop-rhdh}"
DEVELOPERHUB_POD="${DEVELOPERHUB_POD:-backstage-psql-developer-hub-0}"

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0                        対話式でダンプ元を選択"
    echo "  $0 openmetadata           OpenMetadata (MySQL) からダンプ"
    echo "  $0 developerhub           Developer Hub (PostgreSQL) からダンプ"
}

echo "###################################"
echo "このシェルはメンテナンスシェルです"
echo "###################################"
echo

# =============================================================================
# Step 1: コマンド検証（無効なら即終了）
# =============================================================================

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    echo -e "${YELLOW}ダンプ元を選択してください:${RESET}"
    echo "  [1] openmetadata   (MySQL, namespace: ${OPENMETADATA_NAMESPACE})"
    echo "  [2] developerhub   (PostgreSQL, namespace: ${DEVELOPERHUB_NAMESPACE})"
    read -rp "番号を入力: " target_choice
    case "$target_choice" in
        1) TARGET="openmetadata" ;;
        2) TARGET="developerhub" ;;
        *)
            echo -e "${RED}無効な選択です。${RESET}"
            exit 1
            ;;
    esac
fi

case "$TARGET" in
    openmetadata|developerhub) ;;
    *)
        echo -e "${RED}無効なダンプ元です: ${TARGET}${RESET}"
        usage; exit 1
        ;;
esac

# =============================================================================
# Step 2: ロゴ表示・OCP 接続確認
# =============================================================================

figlet "droneshop"

oc status
oc version

if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# 失敗時に空/不完全なダンプファイルが「最新のダンプ」として sqlimport.sh に
# 誤って拾われないよう、一時ファイルに書き出してから成功時のみ本来の場所へ move する。
dump_openmetadata() {
    mkdir -p "$OPENMETADATA_EXPORT_DIR"
    local out_file="${OPENMETADATA_EXPORT_DIR}/mysql_dump_${TIMESTAMP}.sql"
    local tmp_file="${out_file}.tmp"

    echo -e "${BLUE}${OPENMETADATA_POD} (namespace: ${OPENMETADATA_NAMESPACE}) から mysqldump --all-databases を取得中...${RESET}"
    echo -e "${YELLOW}  ※ パスワードは Pod 内の MYSQL_ROOT_PASSWORD_FILE をコンテナ内部でのみ参照し、外部には出力しません。${RESET}"

    oc exec "$OPENMETADATA_POD" -n "$OPENMETADATA_NAMESPACE" -- \
        bash -c 'mysqldump -uroot -p"$(cat "$MYSQL_ROOT_PASSWORD_FILE")" --all-databases' \
        > "$tmp_file"
    mv "$tmp_file" "$out_file"

    echo -e "${GREEN}OpenMetadata (MySQL) のダンプを取得しました: ${out_file}${RESET}"
}

dump_developerhub() {
    mkdir -p "$DEVELOPERHUB_EXPORT_DIR"
    local out_file="${DEVELOPERHUB_EXPORT_DIR}/backstage_psql_dump_${TIMESTAMP}.sql"
    local tmp_file="${out_file}.tmp"

    echo -e "${BLUE}${DEVELOPERHUB_POD} (namespace: ${DEVELOPERHUB_NAMESPACE}) から pg_dumpall を取得中...${RESET}"
    echo -e "${YELLOW}  ※ パスワードは Pod 内の POSTGRES_PASSWORD をコンテナ内部でのみ参照し、外部には出力しません。${RESET}"

    oc exec "$DEVELOPERHUB_POD" -n "$DEVELOPERHUB_NAMESPACE" -- \
        bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -U "$PGUSER" -h 127.0.0.1' \
        > "$tmp_file"
    mv "$tmp_file" "$out_file"

    echo -e "${GREEN}Developer Hub (PostgreSQL) のダンプを取得しました: ${out_file}${RESET}"
}

# =============================================================================
# Step 3: ディスパッチ
# =============================================================================

case "$TARGET" in
    openmetadata) dump_openmetadata ;;
    developerhub) dump_developerhub ;;
esac
