#!/bin/bash
# =============================================================================
# Script Name: delete-project.sh
# Description: This script is for deleteing to Project.
# Author: Noriaki Mushino
# Date Created: 2025-05-25
# Last Modified: 2025-05-25
# Version: 1.0
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - User is logged into OpenShift
#
# =============================================================================
# 注意: 対象プロジェクトを消していいか再度確認ください。
# 注意: 対象のプロジェクトがどうしても削除できない場合に利用してください

NAMESPACE="openmetadata"
TMP_JSON="/tmp/${NAMESPACE}.json"

echo "################################################################"
echo "このシェルはメンテナンスシェルです"
echo "################################################################"
echo
echo "################################################################"
echo "このシェルは「openmetadata」プロジェクトを強制削除します"
echo "################################################################"
echo

# Namespace のJSONを取得
oc get namespace ${NAMESPACE} -o json > ${TMP_JSON}

# finalizers フィールドを空の配列に書き換え（jqがあれば便利）
# jqがなければ sed で空の配列に置換（例: "finalizers": [...] → "finalizers": []）
if command -v jq > /dev/null 2>&1; then
  jq '.spec.finalizers = []' ${TMP_JSON} > ${TMP_JSON}.tmp && mv ${TMP_JSON}.tmp ${TMP_JSON}
else
  # jqが無い場合は sed で削除（原則はjq推奨）
  sed -i -E 's/"finalizers":\s*\[[^]]*\]/"finalizers": []/' ${TMP_JSON}
fi

# API Server のホスト名を取得
API_SERVER=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerURL}' | sed 's|https://||')

# Namespace の finalize API にPUTリクエスト送信
curl -k -H "Authorization: Bearer $(oc whoami -t)" \
     -H "Content-Type: application/json" \
     -X PUT \
     --data-binary @${TMP_JSON} \
     https://${API_SERVER}/api/v1/namespaces/${NAMESPACE}/finalize
