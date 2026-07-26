# quarkusdroneshop-ansible

quarkusdroneshop を使った **Data Mesh** デモアプリの OpenShift 自動構築リポジトリです。  
Ansible Playbook と複数のシェルスクリプトによって、ミドルウェアのインストールからアプリデプロイまでを一括管理します。

- オリジナルサイト: [quarkusdroneshop.github.io](https://quarkusdroneshop.github.io)

## 動作確認済み環境

| コンポーネント | バージョン |
|---|---|
| OpenShift | 4.21.41 |
| OpenShift Pipelines (Tekton) | 1.18.0 |
| AMQ Streams | 2.9.0-2 (Operator: v3.2.0-26) |
| AMQ Streams Console | v3.2.0-12 |
| Crunchy Postgres Operator | v5.8.7 |
| Apicurio Service Registry | v2.6.10 |
| PostgreSQL | 17 |

---

## 全体アーキテクチャ（3サイト Data Mesh）

```
[Aサイト]                    [Bサイト]                [Cサイト]
quarkusdroneshop-web         qdca10                  homeoffice-backend
quarkusdroneshop-counter     qdca10pro               homeoffice-ui
                             inventory

         ↕ Skupper (VAN)  ↕ KafkaMirrorMaker2 ↕

[RHDHサイト (オプション)]
  Red Hat Developer Hub (Backstage)
  OpenMetadata
  AI Agent Platform
```

---

## 事前条件

Mac で実行することを前提にしています。以下のツールが必要です。

```
oc          # OpenShift CLI
podman      # コンテナランタイム
figlet      # バナー表示
kustomize   # Pipeline デプロイ用
tkn         # Tekton CLI
skupper     # Skupper (Interconnect 2.0)
helm        # Helm (OpenMetadata / AI Agent 用)
jq          # JSON 処理
```

---

## デプロイ手順

### 1. 環境設定ファイルの作成

`source.env` をディレクトリ直下に作成します（`script/ocpdeploy.sh setup` が自動更新します）。

```bash
ACM_WORKLOADS=n
AMQ_STREAMS=y
CONFIGURE_POSTGRES=y
HELM_DEPLOYMENT=n
DELETE_DEPLOYMENT=false
DEBUG=-v
```

### 2. OCP 環境セットアップ（Aサイト / Bサイト / Cサイト 共通）

AMQ Streams・Crunchy PostgreSQL Operator をインストールし、`quarkusdroneshop-demo` プロジェクトを作成します。  
内部で Podman イメージをビルドして Ansible Playbook を実行します。

```bash
./script/ocpdeploy.sh setup
```

### 3. Data Mesh ネットワーク構築

各サイトで実行してください。サイト種別 (`A` / `B` / `C` / `DH`) を選択するメニューが表示されます。  
Skupper VAN の構築と KafkaMirrorMaker2 の設定を自動的に行います。

```bash
./script/ocpdeploy.sh skupper deploy
```

### 4. Pipeline セットアップとアプリデプロイ

`quarkusdroneshop-cicd` プロジェクトに Tekton Pipeline をデプロイします。

```bash
# Tekton Operator インストール
./script/ocpdeploy.sh pipeline setup

# Pipeline (kustomize) デプロイ ← デプロイするアプリをメニューで選択
./script/ocpdeploy.sh pipeline deploy

# Demo 用 ConfigMap 適用
./script/ocpdeploy.sh pipeline config
```

**推奨デプロイ構成**

| サイト | デプロイアプリ |
|---|---|
| **Aサイト** | web, counter |
| **Bサイト** | qdca10, qdca10pro, inventory |
| **Cサイト** | homeoffice-backend, homeoffice-ui |

Pipeline 実行後は OpenShift コンソールの `quarkusdroneshop-cicd` プロジェクトから各 Pipeline を手動実行します。

---

## シェルスクリプト一覧

> すべてのシェルスクリプトは `script/` ディレクトリ配下にあります（例: `./script/ocpdeploy.sh setup`）。

### `script/ocpdeploy.sh` — メイン統合管理スクリプト

| コマンド | 内容 |
|---|---|
| `setup` | OCP 環境セットアップ（Podman + Ansible でミドルウェアをインストール） |
| `cleanup` | `quarkusdroneshop-demo` プロジェクトの全リソース削除 |
| `pipeline setup` | Tekton Operator インストール・coschedule 無効化 |
| `pipeline deploy` | Pipeline kustomize デプロイ（メニュー形式でアプリ選択） |
| `pipeline config` | Demo 用 ConfigMap 適用 |
| `pipeline cleanup` | `quarkusdroneshop-cicd` プロジェクト削除 |
| `skupper deploy` | Skupper サイト作成・トークン発行・Kafka リスナー/コネクター設定・MirrorMaker2 適用 |
| `skupper retoken` | Skupper アクセストークン再発行・再接続 |
| `skupper status` | Skupper サイト / リンク / リスナー / コネクター状態確認 |
| `skupper console` | Skupper Network Observer デプロイ |
| `skupper cleanup` | Skupper 全リソース削除・MirrorMaker2 削除 |
| `dataproducts setup` | Flink Kubernetes Operator インストール + Trino (Helm chart) デプロイ |
| `dataproducts deploy` | Flink Session Cluster 起動 + `dataproducts/*/flink/*.sql` を依存順(OrderEvents → 後続)で投入 |
| `dataproducts schemas` | `dataproducts/*/schema/*.avsc` を Apicurio Service Registry へ登録(Keycloak OIDC 認証) |
| `dataproducts cleanup` | Flink Session Cluster・投入ジョブ・Trino (Helm) の削除 |

`dataproducts` サブコマンドは、リポジトリルートの [`dataproducts/`](../dataproducts/README.md) に定義された 7 つのデータプロダクト(OrderEvents / Real-time Sales Trends / Drone Component Stock / Inventory Analytics / Assembly Lead Time QDCA10 / QDCA10pro / Customer 360)を Apache Flink・Apache Iceberg・Trino 上に構築するためのもの。設計方針(ドメイン越境はデータプロダクト経由に限定、Kafka を中心に据える、Apicurio Service Registry でスキーマ管理、認証は Keycloak に一元化・認可は Trino のアクセス制御)は [`dataproducts/README.md`](../dataproducts/README.md) を参照。

### `script/developer-hub.sh` — Red Hat Developer Hub (RHDH) 管理

| コマンド | 内容 |
|---|---|
| `setup` | RHDH 名前空間・Operator・前提リソース作成 |
| `deploy` | RHDH アプリデプロイ (ConfigMap / Secret / BackstageInstance 適用) |
| `keycloak` | Keycloak の realm / client / ユーザー設定 |
| `regithubtoken` | GitHub トークン再発行・Secret 更新 |
| `target-token <domain>` | 対象クラスタの SA 永続トークン作成 |
| `system-token` | A/B/C 全クラスタの SA トークン取得・Secret 更新 |
| `customimage` | カスタム RHDH イメージのビルド |
| `resetcustombuild` | カスタムイメージのリセット＆再ビルド |
| `update-plugin` | test-report / data-catalog / kafka-topic-request / skupper-console プラグイン再ビルド・integrity ハッシュ更新・RHDH 再起動 |
| `cleanup` | RHDH 全リソース削除 |

### `script/openmetadata.sh` — OpenMetadata 管理

| コマンド | 内容 |
|---|---|
| `deploy` | `openmetadata` プロジェクト作成・Secrets・SCC 付与・Helm で依存サービス + 本体をインストール |
| `cleanup` | Helm アンインストール・プロジェクト削除 |

### `script/aiagent.sh` — Datamesh AI Agent Platform 管理

| コマンド | 内容 |
|---|---|
| `setup` | OpenShift AI Operator・前提ミドルウェアのインストール |
| `deploy` | AI Agent Platform を dev overlay でデプロイ |
| `deploy-prod` | AI Agent Platform を prod overlay でデプロイ |
| `vllm` | vLLM モデルサービング (デフォルト: granite-20b-code-instruct) デプロイ |
| `status` | 全コンポーネントの状態確認 |
| `logs` | AI Agent の最新ログ表示 |
| `cleanup` | AI Agent Platform 全削除 |

### メンテナンス用シェル

| シェル | 内容 |
|---|---|
| `script/postgres.sh` | PostgreSQL Pod へのポートフォワード (5432) を開き、接続パスワードを表示 |
| `script/podman.sh` | ローカルで Kafka + PostgreSQL + Kafdrop を Podman コンテナとして起動 |
| `script/kafka-delete-topic.sh` | `shop-asite.*` / `shop-bsite.*` / `shop-csite.*` の全 Kafka トピックを削除 |
| `script/delete-project.sh <namespace>` | Terminating のまま残るプロジェクトの finalizer を除去して強制削除 |
| `script/sqldump.sh` | OpenMetadata の MySQL をポートフォワード経由でダンプ (`openmetadata_backup.sql`) |
| `script/sqlimport.sh` | ダンプファイルを OpenMetadata MySQL へインポート |
| `script/get-rhtoken.sh <refresh_token>` | Red Hat SSO のリフレッシュトークンからアクセストークンを取得 |

---

## Ansible Playbook

### `ansible-tower.yml` — メインプレイブック

`localhost` に対して `quarkusdroneshop-ansible` ロールを実行します。

```yaml
- hosts: localhost
  vars:
    openshift_token: <トークン>
    domain: example.com
    postgres_password: <パスワード>
    storeid: TOKYO
    project_namespace: quarkusdroneshop-demo
    skip_amq_install: false
    skip_configure_postgres: false
    skip_quarkusdroneshop_helm_install: true
  roles:
    - quarkusdroneshop-ansible
```

### `tasks/main.yml` — ロールのタスクフロー

```
1. クラスタログイン
2. プロジェクト作成 (quarkusdroneshop-demo)
3. AMQ Streams インストール
4. Crunchy Postgres Operator インストール
5. PostgreSQL データベース設定
6. DB ウォッチドッグ CronJob デプロイ
7. MongoDB Operator インストール (skip_mongodb_operator_install=false の場合)
8. MongoDB デプロイ (single_mongodb_install=true の場合)
9. Helm Chart デプロイ (skip_quarkusdroneshop_helm_install=false の場合)
```

---

## 主要な変数 (`defaults/main.yml`)

| 変数 | デフォルト値 | 説明 |
|---|---|---|
| `project_namespace` | `quarkusdroneshop-demo` | デプロイ先プロジェクト |
| `kafka_cluster_name` | `shop-cluster` | Kafka クラスター名 |
| `amqstartingCSV` | `amqstreams.v3.2.0-16` | AMQ Streams バージョン |
| `crunchystartingCSV` | `postgresoperator.v5.8.7` | Crunchy Postgres バージョン |
| `pgsql_username` | `droneshopadmin` | PostgreSQL ユーザー名 |
| `postgres_password` | `postgres` | PostgreSQL パスワード（**変更必須**） |
| `pgsql_url` | `jdbc:postgresql://droneshopdb:5432/droneshopdb?currentSchema=droneshop` | JDBC URL |
| `storeid` | `RALEIGH` | Web フロントエンドの店舗 ID |
| `version_counter` | `5.0.3-SNAPSHOT` | counter コンテナタグ |
| `version_web` | `5.0.3-SNAPSHOT` | web コンテナタグ |
| `version_QDCA10` | `5.0.0-SNAPSHOT` | qdca10 コンテナタグ |
| `version_QDCA10Pro` | `5.0.0-SNAPSHOT` | qdca10pro コンテナタグ |
| `version_inventory` | `5.0.0-SNAPSHOT` | inventory コンテナタグ |
| `pgadmin_setup_email` | `nmushino@redhat.com` | pgAdmin ログイン Email |

---

## openshift/ ディレクトリの YAML

| カテゴリ | ファイル | 内容 |
|---|---|---|
| **アプリ設定** | `droneshop-configmap.yaml` | 全アプリ共通の環境変数 ConfigMap |
| **アプリ設定** | `*-development.yaml` | 各マイクロサービスの Deployment/Service/Route |
| **Tekton** | `openshift-pipline.yaml` | Tekton Operator サブスクリプション |
| **Tekton** | `tektonconfig.yaml` | TektonConfig (coschedule 無効化) |
| **Tekton** | `tekton-configmap.yaml` | Pipeline 実行用 ConfigMap |
| **Skupper** | `skupper-operator.yaml` | Skupper Operator インストール |
| **Skupper** | `skupper-network-observer.yaml` | Skupper コンソール (Network Observer) |
| **Kafka** | `droneshop-cluster-kafka-bootstrap-listeners-*.yaml` | A/B/C サイトの Kafka ブートストラップリスナー |
| **Kafka** | `kafka-mm2-*.yaml` | A/B/C サイトの KafkaMirrorMaker2 設定 |
| **RHDH** | `developer-hub-operator.yaml` | RHDH Operator サブスクリプション |
| **RHDH** | `developer-hub.yaml` | Backstage インスタンス定義 |
| **RHDH** | `app-config-rhdh.yaml` | RHDH アプリ設定 ConfigMap |
| **RHDH** | `dynamic-plugins-rhdh.yaml` | 動的プラグイン設定 |
| **RHDH** | `secrets-rhdh.yaml` | RHDH 用 Secret テンプレート |
| **OpenMetadata** | `values-openmetadata.yaml` | OpenMetadata Helm values |
| **OpenMetadata** | `values-openmetadata-dependencies.yaml` | 依存サービス (MySQL/Airflow 等) Helm values |
| **AI Agent** | `values-ai-agent.yaml` | AI Agent Platform Helm values |
| **AI Agent** | `ai-agent-scc.yaml` | AI Agent 用 SCC 設定 |
| **その他** | `catalog-info.yaml` | Backstage カタログ定義 |
| **その他** | `postgres-ingress.yaml` | PostgreSQL 外部アクセス用 Ingress |

---

## アプリへのアクセス

デプロイ後、以下の URL でアクセスします（`<DOMAIN>` は実際のクラスタドメインに置き換え）。

```
Web フロント:   http://quarkusdroneshop-web-quarkusdroneshop-demo.apps.<DOMAIN>/
Dashboard:      http://homeoffice-ui-quarkusdroneshop-demo.apps.<DOMAIN>/
GraphQL UI:     https://homeoffice-backend-quarkusdroneshop-demo.apps.<DOMAIN>/q/graphql-ui
OpenMetadata:   http://openmetadata-openmetadata.apps.<DOMAIN>/
pgAdmin:        quarkusdroneshop プロジェクトの pgadmin4 Route
```

### 手動で注文を投入する

```bash
export ENDPOINT="quarkusdroneshop-web-quarkusdroneshop-demo.apps.<DOMAIN>"
curl --request POST http://${ENDPOINT}/order \
  --header 'Content-Type: application/json' \
  -d '{
    "beverages": [
      {"item": "DRONE_WITH_ROOM", "name": "Mickey"},
      {"item": "CAPPUCCINO", "name": "Minnie"}
    ],
    "QDCA10ProOrders": [
      {"item": "CAKEPOP", "name": "Mickey"},
      {"item": "CROISSANT", "name": "Minnie"}
    ]
  }'
```

---

## GitHub トークンの設定 (`regithubtoken`)

RHDH の GitHub Integration (カタログの GitHub Org Provider / Scaffolder の GitHub Publish) が使う `GITHUB_TOKEN` は、
`secrets-rhdh.yaml` には**意図的に定義されていません**(このファイルを `oc apply` するたびに固定値へ巻き戻り、
GitHub API が 401 Unauthorized になる事故が過去にあったため)。

新規クラスタへのデプロイ後、および `secrets-rhdh` Secret を作り直した後は、必ず以下を実行してトークンを設定してください。

```bash
# 1. 手元の gh CLI トークンを使う場合
export GITHUB_TOKEN=$(gh auth token)
./script/developer-hub.sh regithubtoken

# 2. 対話的に入力する場合 (環境変数を設定しなければ入力プロンプトが出ます)
./script/developer-hub.sh regithubtoken
```

`regithubtoken` は `secrets-rhdh` Secret への直接 `oc patch`(YAMLファイルの apply ではない)でトークンを設定し、
`backstage-developer-hub` Deployment を自動的にロールアウト再起動します。

**未設定のまま放置すると起きること:**
- GitHub API が未認証扱いになり、レート制限が 5000 回/時間 → 60 回/時間に低下する
- カタログの GitHub Org Provider (`quarkusdroneshop` org の定期クロール、既定 30 分間隔) がレート制限で失敗し続け、
  カタログエンティティの `catalog-info.yaml` の場所などが**古いまま更新されなくなる**
  (例: 「Unable to read url, no matching files found for .../src/main/resources/catalog-info.yaml」のような、
  実際には存在しないパスを指すエラーがカタログ画面に表示され続ける)
- Scaffolder の `publish:github` アクション (GitHubへのPush) が
  `No token available for host: github.com` で失敗する

設定後、`oc exec` でPod内から `curl -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/rate_limit` を
叩けば、認証済みレート制限 (`"limit": 5000`) になっているか確認できます。

---

## RHDH データベースの復元 (`developerhub-export/`)

`../developerhub-export/` に `pg_dumpall` によるフルバックアップがあります。詳細な取得・復元コマンドは
[`developerhub-export/README.md`](../developerhub-export/README.md) を参照してください。**新規クラスタや
再デプロイ後にこのダンプをインポートする際は、以下のチェック・手順を必ず踏んでください。**

### 1. インポート前のダンプファイルチェック

複数のダンプファイルがある場合、`.tmp` サフィックスのファイルや、取得中に中断されたものが混在していることが
あります。**必ず末尾が正常に終端しているか確認してから使うファイルを選ぶこと。**

```bash
tail -c 500 backstage_psql_dump_<timestamp>.sql
# 正常なファイルは以下で終わっている:
#   -- PostgreSQL database dump complete
#   -- PostgreSQL database cluster dump complete
```

途中で切れている(バイナリデータの途中で終わっている等)ファイルは不完全なダンプなので使用しないこと。

### 2. 復元先が「空」であることを確認する

`deploy` 実行直後の新規クラスタでは、Backstage 自身が起動時に空のスキーマ/テーブルを既に作成済みです。
この状態にそのまま `pg_dumpall` の出力を流し込むと、`CREATE TABLE` が "already exists" で全て失敗し、
さらに外部キー制約違反で実データ (`final_entities` 等) が 0 件のまま復元が"見かけ上成功"してしまいます
(`psql` はデフォルトでエラーを無視して次の文へ進み続けるため、終了コードは 0 になり気づきにくい)。

**復元前に必ず対象データベース群を削除して空にすること:**

```bash
# 1. Backstage を停止 (DBへの接続・マイグレーションを止める)
oc scale deployment/backstage-developer-hub -n quarkusdroneshop-rhdh --replicas=0

# 2. 既存の backstage_plugin_* データベースを列挙して削除
oc exec -i backstage-psql-developer-hub-0 -n quarkusdroneshop-rhdh -- \
  bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$PGUSER" -h 127.0.0.1 -tAc \
    "SELECT datname FROM pg_database WHERE datname LIKE '"'"'backstage_plugin_%'"'"';"'

for db in <上記で列挙されたDB名から backstage_plugin_ を除いた部分を並べる>; do
  oc exec -i backstage-psql-developer-hub-0 -n quarkusdroneshop-rhdh -- \
    bash -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -U \"\$PGUSER\" -h 127.0.0.1 -c \"DROP DATABASE IF EXISTS \\\"backstage_plugin_${db}\\\" WITH (FORCE);\""
done

# 3. developerhub-export/README.md の手順でダンプを流し込む
```

### 3. 復元後は必ずデータ件数を検証する

エラーが出ていなくても実データが入っていないことがあるため、必ず件数を確認する。

```bash
oc exec -i backstage-psql-developer-hub-0 -n quarkusdroneshop-rhdh -- \
  bash -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$PGUSER" -h 127.0.0.1 -d backstage_plugin_catalog -tAc "SELECT count(*) FROM final_entities;"'
# 0 件なら復元失敗 (手順2をやり直す)
```

### 4. `postgres` ロールのパスワードを復元する

`pg_dumpall` の出力には `ALTER ROLE postgres ... PASSWORD ...` が含まれており、**復元すると `postgres` ロールの
実パスワードがダンプ取得元(古いクラスタ)の値に上書きされる。** そのままだと `backstage-backend` が
`password authentication failed for user "postgres"` でクラッシュループする。

復元直後に、今のクラスタの Pod が実際に持っている `POSTGRES_PASSWORD` へ必ず戻すこと:

```bash
oc exec -i backstage-psql-developer-hub-0 -n quarkusdroneshop-rhdh -- \
  bash -c 'psql -U "$PGUSER" -h 127.0.0.1 -c "ALTER ROLE postgres WITH PASSWORD '"'"'${POSTGRES_PASSWORD}'"'"';"'
```

### 5. Backstage を再起動して確認

```bash
oc scale deployment/backstage-developer-hub -n quarkusdroneshop-rhdh --replicas=1
oc rollout status deployment/backstage-developer-hub -n quarkusdroneshop-rhdh --timeout=300s
```

再起動後、上記「GitHub トークンの設定」も必ず確認すること。カタログの GitHub Org Provider が
GITHUB_TOKEN 未設定/レート制限で再クロールできないと、復元した古いダンプに含まれる**古いカタログ情報
(存在しないファイルパス等)がいつまでも更新されない**ため、復元後の初回確認では特にセットで確認する。

---

## トラブルシューティング

### Operator バージョン不一致でインストールが失敗する

`defaults/main.yml` のバージョンを実際の Operator に合わせて修正し、commit/push してください。

```yaml
amqstartingCSV: amqstreams.v3.2.0-16
crunchystartingCSV: postgresoperator.v5.8.7
registry_starting_csv: service-registry-operator.v2.6.10
```

### Kafka CRD が残留して削除できない

```bash
oc get crds -o name | grep '.*\.strimzi\.io' | xargs -r -n 1 oc delete
```

### Kafka トピックをすべて削除したい

```bash
./script/kafka-delete-topic.sh
```

shop-asite.* / shop-bsite.* / shop-csite.* の全トピックを Kafka Pod 内から直接削除します。

### プロジェクトが Terminating のまま消えない

```bash
./script/delete-project.sh quarkusdroneshop-demo
```

finalizer を除去して強制削除します。`jq` が必要です。

### Skupper の接続がうまくいかない

```bash
./script/ocpdeploy.sh skupper status     # 状態確認
./script/ocpdeploy.sh skupper retoken    # トークン再発行・再接続
```

### Pipeline 実行後に Demo ConfigMap が見つからない

```bash
./script/ocpdeploy.sh pipeline config
```

### PostgreSQL にローカルから接続したい

```bash
./script/postgres.sh   # パスワード表示 + ポートフォワード (5432)
```

### ローカルで Kafka + PostgreSQL + Kafdrop を動かしたい

```bash
./script/podman.sh
# Kafka:   localhost:9092
# Postgres: localhost:5432
# Kafdrop:  http://localhost:9000
```

---

## E2E テスト (Cypress)

全商品を購入する E2E テストが含まれています。

```bash
./cypress-tests.sh
```

---

## ライセンス

GPLv3

## 作成者

- 2020: [Tosin Akinosho](https://github.com/tosin2013)
- 2025–2026: [Noriaki Mushino](https://github.com/nmushino)
