#!/bin/bash
# =============================================================================
# Script Name: postgres.sh
# Description: This script is for connecting to PostgreSQL via Port-Fowad.
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2025-04-17
# Version: 1.0
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - User is logged into OpenShift
#
# =============================================================================

NAMESPACE="quarkusdroneshop-demo"

echo "###################################"
echo "このシェルはメンテナンスシェルです"
echo "###################################"
echo

echo "Postgres Password: $(oc get secret droneshopdb-pguser-droneshopadmin -o jsonpath='{.data.password}' -n $NAMESPACE | base64 -d)"
POSTGRES_POD_NAME=$(oc get pods -o jsonpath='{.items[*].metadata.name}' -n $NAMESPACE | tr ' ' '\n' | grep droneshopdb | head -n 1)
oc port-forward pod/$POSTGRES_POD_NAME 5432:5432 -n $NAMESPACE
