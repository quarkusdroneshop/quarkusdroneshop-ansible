#!/bin/bash
# =============================================================================
# Script Name: delete-project.sh
# Description: This script is for deleteing to Project.
# Author: Noriaki Mushino
# Date Created: 2025-05-25
# Last Modified: 2025-07-19
# Version: 1.0
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - User is logged into OpenShift
#
# =============================================================================
# 注意: 対象プロジェクトを消していいか再度確認ください。
# 注意: 対象のプロジェクトがどうしても削除できない場合に利用してください

NAMESPACE="quarkusdroneshop-demo"
TMP_FILE="/tmp/${NAMESPACE}-patched.json"

echo "################################################################"
echo "このシェルはメンテナンスシェルです"
echo "################################################################"

echo
echo "################################################################"
echo "このシェルは「${NAMESPACE}」プロジェクトを強制削除します"
echo "################################################################"
echo

# プロジェクト存在確認
oc get namespace "${NAMESPACE}" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "エラー: プロジェクト ${NAMESPACE} は存在しません。"
  exit 1
fi

# Finalizers の削除
echo "[INFO] Finalizers を削除しています..."
oc get namespace "${NAMESPACE}" -o json \
| jq 'del(.spec.finalizers[] | select(. == "kubernetes"))' > "${TMP_FILE}"

# JSONを置き換え
echo "[INFO] JSONを更新しています..."
oc replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" -f "${TMP_FILE}"

# 一時ファイル削除
rm -f "${TMP_FILE}"

echo "[SUCCESS] ${NAMESPACE} の削除処理が完了しました。"