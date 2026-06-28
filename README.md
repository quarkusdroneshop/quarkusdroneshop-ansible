# quarkusdroneshop-ansible

quarkusdroneshop を使った **Data Mesh** デモアプリの OpenShift 自動構築リポジトリです。  
Ansible Playbook と複数のシェルスクリプトによって、ミドルウェアのインストールからアプリデプロイまでを一括管理します。

- オリジナルサイト: [quarkusdroneshop.github.io](https://quarkusdroneshop.github.io)

## 動作確認済み環境

| コンポーネント | バージョン |
|---|---|
| OpenShift | 4.21.41 |
| OpenShift Pipelines (Tekton) | 1.18.0 |
| AMQ Streams | 2.9.0-2 (Operator: v3.2.0-16) |
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

`source.env` をディレクトリ直下に作成します（`ocpdeploy.sh setup` が自動更新します）。

```bash
CLUSTER_DOMAIN_NAME=<クラスタドメイン>
TOKEN=<OCP ログイントークン>
ACM_WORKLOADS=n
AMQ_STREAMS=y
CONFIGURE_POSTGRES=y
MONGODB_OPERATOR=n
MONGODB=n
HELM_DEPLOYMENT=n
DELETE_DEPLOYMENT=false
DEBUG=-v
```

### 2. OCP 環境セットアップ（Aサイト / Bサイト / Cサイト 共通）

AMQ Streams・Crunchy PostgreSQL Operator をインストールし、`quarkusdroneshop-demo` プロジェクトを作成します。  
内部で Podman イメージをビルドして Ansible Playbook を実行します。

```bash
./ocpdeploy.sh setup
```

### 3. Data Mesh ネットワーク構築

各サイトで実行してください。サイト種別 (`A` / `B` / `C` / `DH`) を選択するメニューが表示されます。  
Skupper VAN の構築と KafkaMirrorMaker2 の設定を自動的に行います。

```bash
./ocpdeploy.sh skupper deploy
```

### 4. Pipeline セットアップとアプリデプロイ

`quarkusdroneshop-cicd` プロジェクトに Tekton Pipeline をデプロイします。

```bash
# Tekton Operator インストール
./ocpdeploy.sh pipeline setup

# Pipeline (kustomize) デプロイ ← デプロイするアプリをメニューで選択
./ocpdeploy.sh pipeline deploy

# Demo 用 ConfigMap 適用
./ocpdeploy.sh pipeline config
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

### `ocpdeploy.sh` — メイン統合管理スクリプト

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

### `developer-hub.sh` — Red Hat Developer Hub (RHDH) 管理

| コマンド | 内容 |
|---|---|
| `setup` | RHDH 名前空間・Operator・前提リソース作成 |
| `deploy` | RHDH アプリデプロイ (ConfigMap / Secret / BackstageInstance 適用) |
| `keycloak` | Keycloak の realm / client / ユーザー設定 |
| `retoken` | GitHub トークン再発行・Secret 更新 |
| `target-token <domain>` | 対象クラスタの SA 永続トークン作成 |
| `system-token` | A/B/C 全クラスタの SA トークン取得・Secret 更新 |
| `customimage` | カスタム RHDH イメージのビルド |
| `resetcustombuild` | カスタムイメージのリセット＆再ビルド |
| `update-plugin` | test-report プラグイン再ビルド・integrity ハッシュ更新・RHDH 再起動 |
| `cleanup` | RHDH 全リソース削除 |

### `openmetadata.sh` — OpenMetadata 管理

| コマンド | 内容 |
|---|---|
| `deploy` | `openmetadata` プロジェクト作成・Secrets・SCC 付与・Helm で依存サービス + 本体をインストール |
| `cleanup` | Helm アンインストール・プロジェクト削除 |

### `aiagent.sh` — Enterprise AI Agent Platform 管理

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
| `postgres.sh` | PostgreSQL Pod へのポートフォワード (5432) を開き、接続パスワードを表示 |
| `podman.sh` | ローカルで Kafka + PostgreSQL + Kafdrop を Podman コンテナとして起動 |
| `kafka-delete-topic.sh` | `shop-asite.*` / `shop-bsite.*` / `shop-csite.*` の全 Kafka トピックを削除 |
| `delete-project.sh <namespace>` | Terminating のまま残るプロジェクトの finalizer を除去して強制削除 |
| `sqldump.sh` | OpenMetadata の MySQL をポートフォワード経由でダンプ (`openmetadata_backup.sql`) |
| `sqlimport.sh` | ダンプファイルを OpenMetadata MySQL へインポート |
| `get-rhtoken.sh <refresh_token>` | Red Hat SSO のリフレッシュトークンからアクセストークンを取得 |

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
./kafka-delete-topic.sh
```

shop-asite.* / shop-bsite.* / shop-csite.* の全トピックを Kafka Pod 内から直接削除します。

### プロジェクトが Terminating のまま消えない

```bash
./delete-project.sh quarkusdroneshop-demo
```

finalizer を除去して強制削除します。`jq` が必要です。

### Skupper の接続がうまくいかない

```bash
./ocpdeploy.sh skupper status     # 状態確認
./ocpdeploy.sh skupper retoken    # トークン再発行・再接続
```

### Pipeline 実行後に Demo ConfigMap が見つからない

```bash
./ocpdeploy.sh pipeline config
```

### PostgreSQL にローカルから接続したい

```bash
./postgres.sh   # パスワード表示 + ポートフォワード (5432)
```

### ローカルで Kafka + PostgreSQL + Kafdrop を動かしたい

```bash
./podman.sh
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
