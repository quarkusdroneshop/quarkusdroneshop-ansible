#!/bin/bash
# =============================================================================
# Script Name: update-elb-hosts.sh
# Description: A/B/C サイトの Kafka 外部 LoadBalancer (ELB) が再作成され
#              ホスト名/IPが変わった際に、リポジトリ内のハードコードされた
#              値をまとめて更新する。
#              対象:
#                - openshift/droneshop-cluster-kafka-bootstrap-listeners-<site>.yaml
#                  の spec.kafka.listeners[external].configuration.bootstrap/brokers
#                  の advertisedHost
#                - datamesh-ai-agent-platform/deployment/kustomize/base/networkpolicy.yaml
#                  の egress 許可リスト (ELB の名前解決結果である IP アドレス)
# Author: Noriaki Mushino
# Date Created: 2026-07-17
# Last Modified: 2026-07-17
# Version: 1.0
#
# Usage:
#   ./script/update-elb-hosts.sh <a|b|c>
#
#   実行前に、更新したいサイトの OpenShift クラスタに `oc login` しておくこと。
#   スクリプトはそのクラスタの現在の oc セッションから
#   `oc get svc -n quarkusdroneshop-demo` を実行して ELB ホスト名を取得する。
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured, and logged into the
#     target site's cluster
#   - dig is installed (ELB ホスト名 -> IP の名前解決に使用)
#
# NOTE: ELB は再作成されるたびにホスト名(と裏側のIP)が変わりうる。特に
#   networkpolicy.yaml の許可リストは IP ベースの ipBlock なので、ELB の
#   名前解決結果が変わるたびにこのスクリプトを再実行して更新すること。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"

NAMESPACE="quarkusdroneshop-demo"
LISTENERS_DIR="${REPO_ROOT}/openshift"
NETWORKPOLICY_FILE="${WORKSPACE_ROOT}/datamesh-ai-agent-platform/deployment/kustomize/base/networkpolicy.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RESET='\033[0m'

usage() {
    echo "Usage: $0 <a|b|c>" >&2
    exit 1
}

[ $# -eq 1 ] || usage
SITE_LETTER="$1"
case "$SITE_LETTER" in
    a|b|c) ;;
    *) usage ;;
esac
SITE="${SITE_LETTER}site"
LISTENERS_FILE="${LISTENERS_DIR}/droneshop-cluster-kafka-bootstrap-listeners-${SITE}.yaml"

if ! oc whoami &>/dev/null; then
    echo -e "${RED}エラー: OpenShift にログインしていません。更新したいサイト(${SITE})のクラスタに 'oc login' してから再実行してください。${RESET}" >&2
    exit 1
fi
API_SERVER="$(oc whoami --show-server)"
echo -e "${GREEN}OpenShift にログイン済み: $(oc whoami) @ ${API_SERVER}${RESET}"
echo -e "${BLUE}このセッションが ${SITE} のクラスタであることを確認してから続行してください。${RESET}"

# コメントに残す環境ラベル。API サーバー URL から sandboxNNN 等を抽出できれば
# それを使い、抽出できない場合は日付にフォールバックする(特定の sandbox 名を
# 決め打ちで埋め込むと、別サイト/別クラスタで実行したときに誤った表記になるため)。
CLUSTER_LABEL="$(echo "$API_SERVER" | grep -oE 'sandbox[0-9]+' | head -1)"
CLUSTER_LABEL="${CLUSTER_LABEL:-$(date +%Y-%m-%d)}"

if [ ! -f "$LISTENERS_FILE" ]; then
    echo -e "${RED}エラー: ${LISTENERS_FILE} が見つかりません。${RESET}" >&2
    exit 1
fi

get_elb_host() {
    local svc_name="$1"
    oc get svc "$svc_name" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

resolve_ips() {
    local hostname="$1"
    dig +short "$hostname" 2>/dev/null | sort
}

echo -e "${BLUE}[1/3] ${SITE} の ELB ホスト名を取得中...${RESET}"

BOOTSTRAP_HOST="$(get_elb_host shop-cluster-kafka-external-bootstrap)"
BROKER0_HOST="$(get_elb_host shop-cluster-shop-cluster-brokers-0)"
BROKER1_HOST="$(get_elb_host shop-cluster-shop-cluster-brokers-1)"
BROKER2_HOST="$(get_elb_host shop-cluster-shop-cluster-brokers-2)"

if [ -z "$BOOTSTRAP_HOST" ]; then
    echo -e "${RED}エラー: shop-cluster-kafka-external-bootstrap の ELB ホスト名を取得できませんでした。${RESET}" >&2
    echo -e "${RED}  namespace=${NAMESPACE} で 'oc get svc' が正しく実行できるか、ELB がまだプロビジョニング中でないか確認してください。${RESET}" >&2
    exit 1
fi

# broker ごとに個別 LoadBalancer が無い場合(A/Bサイトのような、bootstrap と全ブローカーで
# 単一ELBを共有する構成)は bootstrap のホストにフォールバックする。
BROKER0_HOST="${BROKER0_HOST:-$BOOTSTRAP_HOST}"
BROKER1_HOST="${BROKER1_HOST:-$BOOTSTRAP_HOST}"
BROKER2_HOST="${BROKER2_HOST:-$BOOTSTRAP_HOST}"

echo "  bootstrap: $BOOTSTRAP_HOST"
echo "  broker 0 : $BROKER0_HOST"
echo "  broker 1 : $BROKER1_HOST"
echo "  broker 2 : $BROKER2_HOST"

echo -e "${BLUE}[2/3] ${LISTENERS_FILE##*/} の advertisedHost を更新中...${RESET}"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

python3 - "$LISTENERS_FILE" "$BOOTSTRAP_HOST" "$BROKER0_HOST" "$BROKER1_HOST" "$BROKER2_HOST" > "$TMP_FILE" <<'PYEOF'
import re
import sys

path, bootstrap_host, broker0_host, broker1_host, broker2_host = sys.argv[1:6]
with open(path) as f:
    text = f.read()

if "configuration:" not in text:
    sys.stderr.write(
        "エラー: {} に spec.kafka.listeners[external].configuration が見つかりません。"
        "手動で確認してください。\n".format(path)
    )
    sys.exit(1)

def replace_host(text, anchor_pattern, new_host):
    # anchor_pattern に続く最初の advertisedHost: <値> 行を書き換える
    pattern = re.compile(anchor_pattern + r"(\n\s*advertisedHost:\s*)\S+")
    if not pattern.search(text):
        sys.stderr.write("エラー: パターンが見つかりません: {}\n".format(anchor_pattern))
        sys.exit(1)
    return pattern.sub(lambda m: m.group(0).split("advertisedHost:")[0] + "advertisedHost: " + new_host, text, count=1)

text = replace_host(text, r"bootstrap:", bootstrap_host)
text = replace_host(text, r"-\s*broker:\s*0", broker0_host)
text = replace_host(text, r"-\s*broker:\s*1", broker1_host)
text = replace_host(text, r"-\s*broker:\s*2", broker2_host)

sys.stdout.write(text)
PYEOF

mv "$TMP_FILE" "$LISTENERS_FILE"
trap - EXIT
echo -e "${GREEN}  更新完了: ${LISTENERS_FILE}${RESET}"

echo -e "${BLUE}[3/3] networkpolicy.yaml の egress 許可 IP を更新中...${RESET}"

if [ ! -f "$NETWORKPOLICY_FILE" ]; then
    echo -e "${YELLOW}  警告: ${NETWORKPOLICY_FILE} が見つからないためスキップします。${RESET}"
elif ! command -v dig &>/dev/null; then
    echo -e "${YELLOW}  警告: 'dig' コマンドが無いため IP の名前解決をスキップします。手動で networkpolicy.yaml を更新してください。${RESET}"
else
    # ホストの並び順(bootstrap, broker0, broker1, broker2)を保った上で、
    # 同じホストが複数ラベルを指す場合(A/Bサイトのような単一ELB共有構成)は
    # 1回だけ解決するよう重複を除去する。
    ENTRIES_FILE="$(mktemp)"
    trap 'rm -f "$ENTRIES_FILE"' EXIT
    # macOS 標準の bash 3.2 は連想配列(declare -A)を使えないため、
    # 「既に処理したホスト」はスペース区切りの文字列で管理する。
    SEEN_HOSTS=" "
    for pair in "bootstrap:$BOOTSTRAP_HOST" "broker0:$BROKER0_HOST" "broker1:$BROKER1_HOST" "broker2:$BROKER2_HOST"; do
        LABEL="${pair%%:*}"
        HOST="${pair#*:}"
        case "$SEEN_HOSTS" in
            *" ${HOST} "*)
                continue
                ;;
        esac
        SEEN_HOSTS="${SEEN_HOSTS}${HOST} "

        IPS="$(resolve_ips "$HOST")"
        if [ -z "$IPS" ]; then
            echo -e "${YELLOW}  警告: ${HOST} の名前解決に失敗しました。networkpolicy.yaml のこのホスト分はスキップします。${RESET}"
            continue
        fi
        # ホストが単独(=全ロール共有)か broker 個別かでコメントの書き方を変える
        if [ "$HOST" = "$BOOTSTRAP_HOST" ] && [ "$HOST" = "$BROKER0_HOST" ]; then
            ROLE_LABEL=""
        else
            ROLE_LABEL="${LABEL} "
        fi
        AZ=1
        while IFS= read -r ip; do
            [ -n "$ip" ] || continue
            echo "${ip}|${ROLE_LABEL}AZ${AZ}" >> "$ENTRIES_FILE"
            AZ=$((AZ + 1))
        done <<< "$IPS"
    done

    if [ ! -s "$ENTRIES_FILE" ]; then
        echo -e "${YELLOW}  警告: 名前解決できた IP が1つもないため networkpolicy.yaml の更新をスキップします。${RESET}"
    else
        NP_TMP="$(mktemp)"
        NP_RC=0
        python3 - "$NETWORKPOLICY_FILE" "$SITE" "$ENTRIES_FILE" "$CLUSTER_LABEL" > "$NP_TMP" <<'PYEOF' || NP_RC=$?
import re
import sys

np_path, site, entries_path, cluster_label = sys.argv[1:5]

with open(entries_path) as f:
    entries = [line.strip().split("|", 1) for line in f if line.strip()]

tag = "external-shop-cluster-kafka-{}".format(site)

with open(np_path) as f:
    lines = f.readlines()

block_re = re.compile(r"^(\s*)-\s*ipBlock:\s*$")
cidr_re = re.compile(r"^\s*cidr:\s*(\S+)/32\s*#(.*)$")

out = []
i = 0
inserted = False
while i < len(lines):
    line = lines[i]
    m = block_re.match(line)
    if m and i + 1 < len(lines):
        cidr_m = cidr_re.match(lines[i + 1])
        if cidr_m and tag in cidr_m.group(2):
            indent = m.group(1)
            # このサイト用の連続ブロックの先頭。ここから同タグが続く限りスキップし、
            # 代わりに新しいエントリ一式を書き込む。
            if not inserted:
                for ip, comment_suffix in entries:
                    out.append("{}- ipBlock:\n".format(indent))
                    out.append(
                        "{}    cidr: {}/32  # {} advertised ELB ({}、{})\n".format(
                            indent, ip, tag, comment_suffix, cluster_label
                        )
                    )
                inserted = True
            i += 2
            continue
    out.append(line)
    i += 1

if not inserted:
    sys.stderr.write(
        "エラー: networkpolicy.yaml 内に '{}' のタグが付いた ipBlock が見つかりませんでした。"
        "手動で追加してください。\n".format(tag)
    )
    sys.exit(1)

sys.stdout.writelines(out)
PYEOF
        if [ "$NP_RC" -eq 0 ]; then
            mv "$NP_TMP" "$NETWORKPOLICY_FILE"
            echo -e "${GREEN}  更新完了: ${NETWORKPOLICY_FILE}${RESET}"
        else
            rm -f "$NP_TMP"
            echo -e "${YELLOW}  networkpolicy.yaml は更新されませんでした。上記のエラーを確認し手動で対応してください。${RESET}"
        fi
    fi
    rm -f "$ENTRIES_FILE"
    trap - EXIT
fi

echo -e "${GREEN}完了しました。git diff で変更内容を確認してからコミットしてください。${RESET}"
