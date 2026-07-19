#!/bin/bash
# =============================================================================
# Script Name: postgres.sh
# Description: This script is for connecting to PostgreSQL via Port-Fowad.
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2026-07-18
# Version: 1.1
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - User is logged into OpenShift
#
# =============================================================================

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

NAMESPACE="quarkusdroneshop-demo"

echo "###################################"
echo "このシェルはメンテナンスシェルです"
echo "###################################"
echo

echo -e "${BLUE}Postgres Password: $(oc get secret droneshopdb-pguser-droneshopadmin -o jsonpath='{.data.password}' -n $NAMESPACE | base64 -d)${RESET}"
POSTGRES_POD_NAME=$(oc get pods -o jsonpath='{.items[*].metadata.name}' -n $NAMESPACE | tr ' ' '\n' | grep droneshopdb | head -n 1)
echo -e "${GREEN}ポートフォワードを開始します: pod/${POSTGRES_POD_NAME} (5432)${RESET}"
oc port-forward pod/$POSTGRES_POD_NAME 5432:5432 -n $NAMESPACE
