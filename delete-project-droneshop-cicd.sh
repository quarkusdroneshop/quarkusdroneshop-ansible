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

NAMESPACE="quarkusdroneshop-cicd"
TMP_JSON="/tmp/${NAMESPACE}.json"

echo "################################################################"
echo "このシェルはメンテナンスシェルです"
echo "################################################################"
echo
echo "################################################################"
echo "このシェルは「quarkusdroneshop-cicd」プロジェクトを強制削除します"
echo "################################################################"
echo

# Namespace のJSONを取得
oc get namespace ${NAMESPACE} -o json > ${TMP_JSON}

# YAML を取得して finalizers から "kubernetes" を削除し保存
kubectl get project "${PROJECT_NAME}" -o json \
| jq 'del(.spec.finalizers[] | select(. == "kubernetes"))' > "${TMP_FILE}"

# 削除した JSON を適用
kubectl replace -f "${TMP_FILE}"

# 一時ファイル削除
rm -f "${TMP_FILE}"