#!/bin/bash
# =============================================================================
# Script Name: sqlimport.sh
# Description: OpenMetadata (MySQL) / Developer Hub (RHDH/Backstage, PostgreSQL)
#              のDBダンプをインポートする。どちらにインポートするかを対話式で
#              確認してから実行する。
# Author: Noriaki Mushino
# Date Created: 2025-05-28
# Last Modified: 2026-07-18
# Version: 2.1
#
# Usage:
#   ./script/sqlimport.sh                 - 対話式でインポート先・ダンプファイルを選択
#   ./script/sqlimport.sh openmetadata     - OpenMetadata (MySQL) にインポート
#   ./script/sqlimport.sh developerhub     - Developer Hub (PostgreSQL) にインポート
#
# Prerequisites:
#   - openmetadata: mysql コマンド, nc コマンドが必要
#   - developerhub: oc コマンドのみで完結 (Pod 内で psql 実行)
#   - User is logged into OpenShift
#   - ../openmetadata-export/*.sql, ../developerhub-export/*.sql が存在すること
#     (それぞれ quarkusdroneshop-ansible の兄弟ディレクトリ)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPENMETADATA_EXPORT_DIR="${REPO_ROOT}/../openmetadata-export"
DEVELOPERHUB_EXPORT_DIR="${REPO_ROOT}/../developerhub-export"

OPENMETADATA_NAMESPACE="${OPENMETADATA_NAMESPACE:-openmetadata}"
DEVELOPERHUB_NAMESPACE="${DEVELOPERHUB_NAMESPACE:-quarkusdroneshop-rhdh}"
DEVELOPERHUB_POD="${DEVELOPERHUB_POD:-backstage-psql-developer-hub-0}"

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0                        対話式でインポート先・ダンプファイルを選択"
    echo "  $0 openmetadata           OpenMetadata (MySQL) にインポート"
    echo "  $0 developerhub           Developer Hub (PostgreSQL) にインポート"
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
    echo -e "${YELLOW}インポート先を選択してください:${RESET}"
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
        echo -e "${RED}無効なインポート先です: ${TARGET}${RESET}"
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

# 指定ディレクトリの *.sql から最新順に選択させる。選んだファイルのフルパスを
# 標準出力へ返す(呼び出し側で `dump_file=$(select_dump_file "$dir")` のように使う)。
select_dump_file() {
    local dir="$1"
    local -a files
    # -z 区切りで mtime 降順ソート (ファイル名に空白が無い前提)
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -maxdepth 1 -name '*.sql' -print0 | xargs -0 ls -t -d 2>/dev/null | tr '\n' '\0')

    if [ "${#files[@]}" -eq 0 ]; then
        echo -e "${RED}  ${dir} に *.sql が見つかりません。${RESET}" >&2
        exit 1
    fi

    echo -e "${YELLOW}インポートするダンプファイルを選択してください (${dir}):${RESET}" >&2
    local i=1
    for f in "${files[@]}"; do
        echo "  [$i] $(basename "$f")" >&2
        i=$((i + 1))
    done
    local choice
    read -rp "番号を入力 (デフォルト: 1 = 最新): " choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
        echo -e "${RED}  無効な選択です。${RESET}" >&2
        exit 1
    fi
    echo "${files[$((choice - 1))]}"
}

confirm_or_abort() {
    local message="$1"
    local confirm
    read -rp "${message} (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}中断しました。${RESET}"
        exit 0
    fi
}

import_openmetadata() {
    local dump_file
    dump_file="$(select_dump_file "$OPENMETADATA_EXPORT_DIR")"
    echo -e "${GREEN}選択されたファイル: $(basename "$dump_file")${RESET}"
    echo -e "${YELLOW}デフォルトパスワードは、 openmetadata_password です${RESET}"
    echo -e "${YELLOW}※ このダンプは mysqldump --all-databases 形式のため、root ユーザーでの投入が必要です。${RESET}"
    confirm_or_abort "namespace '${OPENMETADATA_NAMESPACE}' の mysql-0 へインポートします。よろしいですか？"

    echo -e "${BLUE}ポートフォワードを起動中...${RESET}"
    oc port-forward pod/mysql-0 -n "$OPENMETADATA_NAMESPACE" 3306:3306 > /dev/null 2>&1 &
    local pf_pid=$!
    trap 'kill "$pf_pid" 2>/dev/null || true' EXIT

    for _ in {1..10}; do
        nc -z 127.0.0.1 3306 && break
        sleep 1
    done

    echo -e "${BLUE}MySQL にインポート中...${RESET}"
    mysql -h 127.0.0.1 -P 3306 -u root -p < "$dump_file"

    kill "$pf_pid" 2>/dev/null || true
    trap - EXIT
    echo -e "${GREEN}OpenMetadata (MySQL) のインポートが完了しました。${RESET}"
}

import_developerhub() {
    local dump_file
    dump_file="$(select_dump_file "$DEVELOPERHUB_EXPORT_DIR")"
    echo -e "${GREEN}選択されたファイル: $(basename "$dump_file")${RESET}"
    confirm_or_abort "namespace '${DEVELOPERHUB_NAMESPACE}' の ${DEVELOPERHUB_POD} へインポートします。よろしいですか？"

    echo -e "${BLUE}Pod 内の psql へ流し込み中...${RESET}"
    oc exec -i "$DEVELOPERHUB_POD" -n "$DEVELOPERHUB_NAMESPACE" -- \
        bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$PGUSER" -h 127.0.0.1' \
        < "$dump_file"

    echo -e "${GREEN}Developer Hub (PostgreSQL) のインポートが完了しました。${RESET}"
}

# =============================================================================
# Step 3: ディスパッチ
# =============================================================================

case "$TARGET" in
    openmetadata) import_openmetadata ;;
    developerhub) import_developerhub ;;
esac
