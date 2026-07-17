#!/bin/bash
# =============================================================================
# Script Name: register-schemas.sh
# Description: dataproducts/*/schema/*.avsc を Apicurio Service Registry に
#              登録する。認証は Keycloak (RHBK) のサービスアカウントクライアント
#              (dataproducts-registry) から OIDC Client Credentials で取得した
#              トークンを使用する。
#
# 前提 (都度決定・環境変数で注入):
#   KEYCLOAK_TOKEN_URL   例: https://<keycloak-route>/realms/<realm>/protocol/openid-connect/token
#   REGISTRY_CLIENT_ID   Keycloak に作成したサービスアカウントクライアントID
#   REGISTRY_CLIENT_SECRET
#   APICURIO_REGISTRY_URL 例: https://<apicurio-route>
#
# Usage:
#   ./script/register-schemas.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATAPRODUCTS_DIR="$(cd "${REPO_ROOT}/../dataproducts" && pwd)"

: "${KEYCLOAK_TOKEN_URL:?KEYCLOAK_TOKEN_URL is required}"
: "${REGISTRY_CLIENT_ID:?REGISTRY_CLIENT_ID is required}"
: "${REGISTRY_CLIENT_SECRET:?REGISTRY_CLIENT_SECRET is required}"
: "${APICURIO_REGISTRY_URL:?APICURIO_REGISTRY_URL is required}"

echo "Keycloak からアクセストークンを取得中..."
ACCESS_TOKEN=$(curl -sf -X POST "$KEYCLOAK_TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "grant_type=client_credentials&client_id=${REGISTRY_CLIENT_ID}&client_secret=${REGISTRY_CLIENT_SECRET}" \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])')

for avsc in "${DATAPRODUCTS_DIR}"/*/schema/*.avsc; do
    [ -e "$avsc" ] || continue
    artifact_id="$(basename "$avsc" .avsc)-value"
    group="dataproducts"

    echo "登録中: group=${group} artifactId=${artifact_id} (${avsc})"
    curl -sf -X POST "${APICURIO_REGISTRY_URL}/apis/registry/v3/groups/${group}/artifacts" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json; artifactType=AVRO" \
        -H "X-Registry-ArtifactId: ${artifact_id}" \
        -H "X-Registry-ArtifactType: AVRO" \
        --data-binary @"${avsc}" \
        || echo "  ⚠ 登録に失敗、または既に同一内容が登録済みの可能性があります"
done

echo "スキーマ登録完了"
