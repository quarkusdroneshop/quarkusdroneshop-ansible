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
OPENMETADATA_DEPLOYMENT="${OPENMETADATA_DEPLOYMENT:-openmetadata}"
OPENMETADATA_MYSQL_SECRET="${OPENMETADATA_MYSQL_SECRET:-mysql}"
DEVELOPERHUB_NAMESPACE="${DEVELOPERHUB_NAMESPACE:-quarkusdroneshop-rhdh}"
DEVELOPERHUB_POD="${DEVELOPERHUB_POD:-backstage-psql-developer-hub-0}"
DEVELOPERHUB_DEPLOYMENT="${DEVELOPERHUB_DEPLOYMENT:-backstage-developer-hub}"

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

# QRTZ_*/FLW_EVENT_DEPLOYMENT/rdf_index_job/search_index_job は、mysqldumpの
# CREATE TABLE文がOpenMetadataマイグレーションのcharset(utf8mb3)と食い違い、
# DROPだけ成功してCREATEが失敗し、テーブルごと消えてしまうことがある。
# その場合にOpenMetadataコンテナ内の正規マイグレーションSQL相当の定義で
# 再作成するためのスキーマ。既存テーブル(QRTZ_TRIGGERS等)に合わせてutf8mb3固定。
_OM_RESTORE_MISSING_TABLES_SQL='
SET FOREIGN_KEY_CHECKS=0;

CREATE TABLE IF NOT EXISTS QRTZ_JOB_DETAILS(
SCHED_NAME VARCHAR(120) NOT NULL,
JOB_NAME VARCHAR(190) NOT NULL,
JOB_GROUP VARCHAR(190) NOT NULL,
DESCRIPTION VARCHAR(250) NULL,
JOB_CLASS_NAME VARCHAR(250) NOT NULL,
IS_DURABLE VARCHAR(1) NOT NULL,
IS_NONCONCURRENT VARCHAR(1) NOT NULL,
IS_UPDATE_DATA VARCHAR(1) NOT NULL,
REQUESTS_RECOVERY VARCHAR(1) NOT NULL,
JOB_DATA BLOB NULL,
PRIMARY KEY (SCHED_NAME,JOB_NAME,JOB_GROUP))
ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE IF NOT EXISTS QRTZ_SIMPLE_TRIGGERS (
SCHED_NAME VARCHAR(120) NOT NULL,
TRIGGER_NAME VARCHAR(190) NOT NULL,
TRIGGER_GROUP VARCHAR(190) NOT NULL,
REPEAT_COUNT BIGINT(7) NOT NULL,
REPEAT_INTERVAL BIGINT(12) NOT NULL,
TIMES_TRIGGERED BIGINT(10) NOT NULL,
PRIMARY KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP),
FOREIGN KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP)
REFERENCES QRTZ_TRIGGERS(SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP))
ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE IF NOT EXISTS QRTZ_CRON_TRIGGERS (
SCHED_NAME VARCHAR(120) NOT NULL,
TRIGGER_NAME VARCHAR(190) NOT NULL,
TRIGGER_GROUP VARCHAR(190) NOT NULL,
CRON_EXPRESSION VARCHAR(120) NOT NULL,
TIME_ZONE_ID VARCHAR(80),
PRIMARY KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP),
FOREIGN KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP)
REFERENCES QRTZ_TRIGGERS(SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP))
ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE IF NOT EXISTS QRTZ_SIMPROP_TRIGGERS
  (
    SCHED_NAME VARCHAR(120) NOT NULL,
    TRIGGER_NAME VARCHAR(190) NOT NULL,
    TRIGGER_GROUP VARCHAR(190) NOT NULL,
    STR_PROP_1 VARCHAR(512) NULL,
    STR_PROP_2 VARCHAR(512) NULL,
    STR_PROP_3 VARCHAR(512) NULL,
    INT_PROP_1 INT NULL,
    INT_PROP_2 INT NULL,
    LONG_PROP_1 BIGINT NULL,
    LONG_PROP_2 BIGINT NULL,
    DEC_PROP_1 NUMERIC(13,4) NULL,
    DEC_PROP_2 NUMERIC(13,4) NULL,
    BOOL_PROP_1 VARCHAR(1) NULL,
    BOOL_PROP_2 VARCHAR(1) NULL,
    PRIMARY KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP),
    FOREIGN KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP)
    REFERENCES QRTZ_TRIGGERS(SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP))
ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE IF NOT EXISTS QRTZ_BLOB_TRIGGERS (
SCHED_NAME VARCHAR(120) NOT NULL,
TRIGGER_NAME VARCHAR(190) NOT NULL,
TRIGGER_GROUP VARCHAR(190) NOT NULL,
BLOB_DATA BLOB NULL,
PRIMARY KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP),
INDEX (SCHED_NAME,TRIGGER_NAME, TRIGGER_GROUP),
FOREIGN KEY (SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP)
REFERENCES QRTZ_TRIGGERS(SCHED_NAME,TRIGGER_NAME,TRIGGER_GROUP))
ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE IF NOT EXISTS FLW_EVENT_DEPLOYMENT (ID_ VARCHAR(255) NOT NULL, NAME_ VARCHAR(255) NULL, CATEGORY_ VARCHAR(255) NULL, DEPLOY_TIME_ datetime(3) NULL, TENANT_ID_ VARCHAR(255) NULL, PARENT_DEPLOYMENT_ID_ VARCHAR(255) NULL, CONSTRAINT PK_FLW_EVENT_DEPLOYMENT PRIMARY KEY (ID_)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE IF NOT EXISTS rdf_index_job (
    id VARCHAR(36) NOT NULL,
    status VARCHAR(32) NOT NULL,
    jobConfiguration JSON NOT NULL,
    totalRecords BIGINT NOT NULL DEFAULT 0,
    processedRecords BIGINT NOT NULL DEFAULT 0,
    successRecords BIGINT NOT NULL DEFAULT 0,
    failedRecords BIGINT NOT NULL DEFAULT 0,
    stats JSON,
    createdBy VARCHAR(256) NOT NULL,
    createdAt BIGINT NOT NULL,
    startedAt BIGINT,
    completedAt BIGINT,
    updatedAt BIGINT NOT NULL,
    errorMessage TEXT,
    PRIMARY KEY (id),
    INDEX idx_rdf_index_job_status (status),
    INDEX idx_rdf_index_job_created (createdAt DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

CREATE TABLE IF NOT EXISTS search_index_job (
    id VARCHAR(36) NOT NULL,
    status VARCHAR(32) NOT NULL,
    jobConfiguration JSON NOT NULL,
    targetIndexPrefix VARCHAR(255),
    stagedIndexMapping JSON,
    totalRecords BIGINT NOT NULL DEFAULT 0,
    processedRecords BIGINT NOT NULL DEFAULT 0,
    successRecords BIGINT NOT NULL DEFAULT 0,
    failedRecords BIGINT NOT NULL DEFAULT 0,
    stats JSON,
    createdBy VARCHAR(256) NOT NULL,
    createdAt BIGINT NOT NULL,
    startedAt BIGINT,
    completedAt BIGINT,
    updatedAt BIGINT NOT NULL,
    errorMessage TEXT,
    registrationDeadline BIGINT,
    registeredServerCount INT,
    PRIMARY KEY (id),
    INDEX idx_search_index_job_status (status),
    INDEX idx_search_index_job_created (createdAt DESC)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3;

SET FOREIGN_KEY_CHECKS=1;
'

import_openmetadata() {
    local dump_file
    dump_file="$(select_dump_file "$OPENMETADATA_EXPORT_DIR")"
    echo -e "${GREEN}選択されたファイル: $(basename "$dump_file")${RESET}"
    echo -e "${YELLOW}※ このダンプは mysqldump --all-databases 形式のため、root ユーザーでの投入が必要です。${RESET}"
    echo -e "${YELLOW}※ 以下の手順で実行します:${RESET}"
    echo -e "${YELLOW}  [1/7] OpenMetadataを一時停止${RESET}"
    echo -e "${YELLOW}  [2/7] openmetadata_db を DROP/CREATE で完全リセット${RESET}"
    echo -e "${YELLOW}  [3/7] OpenMetadataを起動し、マイグレーションで正規スキーマ(177テーブル)を作成${RESET}"
    echo -e "${YELLOW}  [4/7] 再度停止${RESET}"
    echo -e "${YELLOW}  [5/7] ダンプを流し込み(--force、内部テーブルのcharset不一致を自動修復)${RESET}"
    echo -e "${YELLOW}  [6/8] OpenMetadataを再開${RESET}"
    echo -e "${YELLOW}  [7/8] Search Indexing を再実行してOpenSearchのExplore/リネージ表示を復旧${RESET}"
    echo -e "${YELLOW}  [8/8] データカタログ埋め込み用プロキシ(om-embed-proxy)とom-proxy-openmetadataルートを作成/更新${RESET}"
    echo -e "${RED}  ※ 現在のOpenMetadataのデータは完全に失われます。${RESET}"
    confirm_or_abort "namespace '${OPENMETADATA_NAMESPACE}' の openmetadata_db を完全リセットしてインポートします。よろしいですか？"

    local root_pw
    root_pw="$(oc get secret "$OPENMETADATA_MYSQL_SECRET" -n "$OPENMETADATA_NAMESPACE" \
        -o jsonpath='{.data.mysql-root-password}' 2>/dev/null | base64 -d)"
    if [ -z "$root_pw" ]; then
        echo -e "${RED}ERROR: ${OPENMETADATA_MYSQL_SECRET} secret から mysql-root-password を取得できませんでした${RESET}" >&2
        exit 1
    fi

    echo -e "${BLUE}[1/7] OpenMetadata を一時停止中...${RESET}"
    oc scale deployment/"$OPENMETADATA_DEPLOYMENT" -n "$OPENMETADATA_NAMESPACE" --replicas=0
    oc wait --for=delete pod -l app.kubernetes.io/name=openmetadata \
        -n "$OPENMETADATA_NAMESPACE" --timeout=120s 2>/dev/null || true

    # 何が起きても最後は必ずOpenMetadataを再開する
    trap 'echo -e "${BLUE}OpenMetadata を再開中...${RESET}"; oc scale deployment/"$OPENMETADATA_DEPLOYMENT" -n "$OPENMETADATA_NAMESPACE" --replicas=1' EXIT

    echo -e "${BLUE}[2/7] openmetadata_db をリセット中...${RESET}"
    oc exec -n "$OPENMETADATA_NAMESPACE" mysql-0 -- bash -c "mysql -u root -p'${root_pw}' -e \"
        DROP DATABASE IF EXISTS openmetadata_db;
        CREATE DATABASE openmetadata_db DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    \""

    echo -e "${BLUE}[3/7] OpenMetadata を起動してマイグレーション実行中(数分かかります)...${RESET}"
    oc scale deployment/"$OPENMETADATA_DEPLOYMENT" -n "$OPENMETADATA_NAMESPACE" --replicas=1
    oc rollout status deployment/"$OPENMETADATA_DEPLOYMENT" -n "$OPENMETADATA_NAMESPACE" --timeout=300s

    local table_count
    table_count="$(oc exec -n "$OPENMETADATA_NAMESPACE" mysql-0 -- bash -c \
        "mysql -u root -p'${root_pw}' -N -e \"SELECT count(*) FROM information_schema.tables WHERE table_schema='openmetadata_db';\"" 2>/dev/null | tr -d '\r')"
    echo -e "${GREEN}  → マイグレーション完了、テーブル数: ${table_count}${RESET}"

    echo -e "${BLUE}[4/7] OpenMetadata を一時停止中(インポートのため)...${RESET}"
    oc scale deployment/"$OPENMETADATA_DEPLOYMENT" -n "$OPENMETADATA_NAMESPACE" --replicas=0
    oc wait --for=delete pod -l app.kubernetes.io/name=openmetadata \
        -n "$OPENMETADATA_NAMESPACE" --timeout=120s 2>/dev/null || true

    echo -e "${BLUE}[5/7] MySQL にインポート中 (oc exec -i、port-forwardは接続が不安定なため使用しない)...${RESET}"
    # --force: ダンプのDROP/CREATEがマイグレーション作成済みスキーマと衝突しても
    # 処理全体を中断せず、エラー行だけスキップして最後まで実行する。
    oc exec -i -n "$OPENMETADATA_NAMESPACE" mysql-0 -- bash -c "mysql --force -u root -p'${root_pw}'" < "$dump_file"

    echo -e "${BLUE}  → QRTZ/FLW/index_job系の内部テーブルを復旧中...${RESET}"
    echo "$_OM_RESTORE_MISSING_TABLES_SQL" | oc exec -i -n "$OPENMETADATA_NAMESPACE" mysql-0 -- \
        bash -c "mysql -u root -p'${root_pw}' openmetadata_db"

    echo -e "${BLUE}[6/7] OpenMetadata を再開中...${RESET}"
    trap - EXIT
    oc scale deployment/"$OPENMETADATA_DEPLOYMENT" -n "$OPENMETADATA_NAMESPACE" --replicas=1
    oc rollout status deployment/"$OPENMETADATA_DEPLOYMENT" -n "$OPENMETADATA_NAMESPACE" --timeout=300s

    echo -e "${BLUE}[7/8] Search Indexing を再実行中 (Explore/リネージ表示の復旧)...${RESET}"
    local om_host token
    om_host="$(oc get route openmetadata -n "$OPENMETADATA_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)"
    if [ -z "$om_host" ]; then
        echo -e "${YELLOW}  → openmetadata route が見つからないため、再インデックスは手動で実行してください${RESET}"
    else
        token="$(curl -s -X POST "http://${om_host}/api/v1/users/login" \
            -H "Content-Type: application/json" \
            -d '{"email":"admin@open-metadata.org","password":"YWRtaW4="}' \
            | python3 -c 'import json,sys; print(json.load(sys.stdin).get("accessToken",""))' 2>/dev/null)"
        if [ -z "$token" ]; then
            echo -e "${YELLOW}  → OpenMetadataへのログインに失敗したため、再インデックスは手動で実行してください${RESET}"
        else
            curl -s -X POST "http://${om_host}/api/v1/apps/trigger/SearchIndexingApplication" \
                -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" > /dev/null
            echo -e "${GREEN}  → 再インデックスジョブをトリガーしました(バックグラウンドで実行されます)${RESET}"
        fi
    fi

    echo -e "${BLUE}[8/8] データカタログ埋め込み用プロキシ/ルートを作成中...${RESET}"
    setup_om_embed_proxy "$om_host"

    echo -e "${GREEN}OpenMetadata (MySQL) のインポートが完了しました。${RESET}"
}

# RHDHの「データカタログ」タブはOpenMetadataの画面を素のままiframe表示すると
# 左サイドメニュー/ヘッダーが二重に出て見苦しいため、間にCSS注入用の
# 軽量nginxリバースプロキシ(om-embed-proxy)を挟み、`om-proxy-openmetadata`
# という名前のRoute経由でアクセスさせる。内部プラグイン側は
# `https://om-proxy-openmetadata.<openmetadataルートと同じクラスタドメイン>`
# を決め打ちで参照するため、ルート名とホスト命名規則は変更しないこと。
setup_om_embed_proxy() {
    local om_host="$1"
    if [ -z "$om_host" ]; then
        echo -e "${YELLOW}  → openmetadata route が見つからないため、om-embed-proxy のセットアップをスキップします${RESET}"
        return
    fi

    local proxy_host
    proxy_host="$(echo "$om_host" | sed -E 's/^openmetadata-openmetadata\./om-proxy-openmetadata./')"
    if [ "$proxy_host" = "$om_host" ]; then
        echo -e "${YELLOW}  → openmetadata route のホスト名が想定形式(openmetadata-openmetadata.*)と異なるため、${RESET}"
        echo -e "${YELLOW}    om-embed-proxy のセットアップをスキップします (host: ${om_host})${RESET}"
        return
    fi

    cat <<EOF | oc apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: om-embed-proxy-nginx-conf
  namespace: ${OPENMETADATA_NAMESPACE}
data:
  default.conf: |
    server {
        listen 8080;

        location / {
            proxy_pass http://${OPENMETADATA_DEPLOYMENT}.${OPENMETADATA_NAMESPACE}.svc.cluster.local:8585;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Accept-Encoding "";

            proxy_hide_header Content-Security-Policy;
            proxy_hide_header X-Frame-Options;

            sub_filter_types text/html;
            sub_filter_once on;
            sub_filter '</head>' '<style>.app-container > aside.ant-layout-sider{display:none !important;} .app-container > section.ant-layout > header.ant-layout-header:not(.pricing-banner){display:none !important;}</style></head>';
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: om-embed-proxy
  namespace: ${OPENMETADATA_NAMESPACE}
  labels:
    app: om-embed-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: om-embed-proxy
  template:
    metadata:
      labels:
        app: om-embed-proxy
    spec:
      containers:
        - name: nginx
          image: docker.io/nginxinc/nginx-unprivileged:alpine
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: conf
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: conf
          configMap:
            name: om-embed-proxy-nginx-conf
---
apiVersion: v1
kind: Service
metadata:
  name: om-embed-proxy
  namespace: ${OPENMETADATA_NAMESPACE}
spec:
  selector:
    app: om-embed-proxy
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: om-proxy-openmetadata
  namespace: ${OPENMETADATA_NAMESPACE}
  labels:
    app.kubernetes.io/instance: openmetadata
    app.kubernetes.io/name: openmetadata
spec:
  host: ${proxy_host}
  port:
    targetPort: http
  to:
    kind: Service
    name: om-embed-proxy
    weight: 100
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

    echo -e "${BLUE}  → om-embed-proxy Podの起動を待機中...${RESET}"
    local i
    for i in $(seq 1 30); do
        if oc get pods -n "$OPENMETADATA_NAMESPACE" -l app=om-embed-proxy \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
            break
        fi
        sleep 3
    done

    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${proxy_host}/my-data" || true)"
    echo -e "${GREEN}  → https://${proxy_host}/my-data -> HTTP ${code}${RESET}"
}

import_developerhub() {
    local dump_file
    dump_file="$(select_dump_file "$DEVELOPERHUB_EXPORT_DIR")"
    echo -e "${GREEN}選択されたファイル: $(basename "$dump_file")${RESET}"
    echo -e "${YELLOW}※ ${DEVELOPERHUB_DEPLOYMENT} を一時停止し、ダンプが対象とするプラグインDBを"
    echo -e "  DROP/CREATEでリセットしてからインポートします（既存データは失われます）。${RESET}"
    confirm_or_abort "namespace '${DEVELOPERHUB_NAMESPACE}' の ${DEVELOPERHUB_POD} へインポートします。よろしいですか？"

    # ダンプ内の \connect からリセット対象データベース一覧を抽出 (postgres/template1 は除外)
    local -a target_dbs
    while IFS= read -r db; do
        target_dbs+=("$db")
    done < <(grep -oP "(?<=^\\\\connect )(-reuse-previous=on \"dbname='[a-zA-Z0-9_-]+'\"|[a-zA-Z0-9_-]+)" "$dump_file" \
        | sed -E "s/-reuse-previous=on \"dbname='([a-zA-Z0-9_-]+)'\"/\1/" \
        | grep -v -E "^(template1|template0|postgres)$" \
        | sort -u)

    echo -e "${BLUE}[1/5] ${DEVELOPERHUB_DEPLOYMENT} を一時停止中...${RESET}"
    oc scale deployment/"$DEVELOPERHUB_DEPLOYMENT" -n "$DEVELOPERHUB_NAMESPACE" --replicas=0
    oc wait --for=delete pod -l "rhdh.redhat.com/backstage-name=developer-hub" \
        -n "$DEVELOPERHUB_NAMESPACE" --timeout=120s || true

    # 何が起きても最後は必ずレプリカを1に戻す
    trap 'echo -e "${BLUE}${DEVELOPERHUB_DEPLOYMENT} を再開中...${RESET}"; oc scale deployment/"$DEVELOPERHUB_DEPLOYMENT" -n "$DEVELOPERHUB_NAMESPACE" --replicas=1' EXIT

    if [ "${#target_dbs[@]}" -gt 0 ]; then
        echo -e "${BLUE}[2/5] 対象プラグインDBをリセット中 (${#target_dbs[@]} 件)...${RESET}"
        local reset_sql=""
        for db in "${target_dbs[@]}"; do
            reset_sql="${reset_sql}DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE); CREATE DATABASE \"${db}\" OWNER postgres;
"
        done
        printf '%s' "$reset_sql" | oc exec -i "$DEVELOPERHUB_POD" -n "$DEVELOPERHUB_NAMESPACE" -- \
            bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$PGUSER" -h 127.0.0.1 -d postgres'
    else
        echo -e "${YELLOW}[2/5] ダンプから対象DBを検出できなかったため、リセットをスキップします。${RESET}"
    fi

    echo -e "${BLUE}[3/5] Pod 内の psql へ流し込み中...${RESET}"
    oc exec -i "$DEVELOPERHUB_POD" -n "$DEVELOPERHUB_NAMESPACE" -- \
        bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$PGUSER" -h 127.0.0.1' \
        < "$dump_file"

    # ダンプに `ALTER ROLE postgres ... PASSWORD '...'` が含まれている場合、
    # ダンプ取得時点の古いパスワードで postgres ロールが上書きされてしまい、
    # backstage-psql-secret-developer-hub (Operatorが管理する実パスワード) と
    # 食い違って backstage-backend が password authentication failed で
    # クラッシュループする。インポート後は必ず実パスワードへ再同期する。
    echo -e "${BLUE}[4/5] postgres ロールのパスワードを再同期中...${RESET}"
    local psql_pw
    psql_pw="$(oc get secret backstage-psql-secret-developer-hub -n "$DEVELOPERHUB_NAMESPACE" \
        -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d)"
    if [ -n "$psql_pw" ]; then
        echo "ALTER ROLE postgres WITH PASSWORD '${psql_pw}';" | oc exec -i "$DEVELOPERHUB_POD" -n "$DEVELOPERHUB_NAMESPACE" -- \
            bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$PGUSER" -h 127.0.0.1 -d postgres'
    else
        echo -e "${YELLOW}  → backstage-psql-secret-developer-hub が見つからないため再同期をスキップします。${RESET}"
    fi

    echo -e "${BLUE}[5/5] ${DEVELOPERHUB_DEPLOYMENT} を再開中...${RESET}"
    trap - EXIT
    oc scale deployment/"$DEVELOPERHUB_DEPLOYMENT" -n "$DEVELOPERHUB_NAMESPACE" --replicas=1
    oc rollout status deployment/"$DEVELOPERHUB_DEPLOYMENT" -n "$DEVELOPERHUB_NAMESPACE" --timeout=180s || true

    echo -e "${GREEN}Developer Hub (PostgreSQL) のインポートが完了しました。${RESET}"
}

# =============================================================================
# Step 3: ディスパッチ
# =============================================================================

case "$TARGET" in
    openmetadata) import_openmetadata ;;
    developerhub) import_developerhub ;;
esac
