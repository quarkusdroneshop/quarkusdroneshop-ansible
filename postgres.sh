#!/bin/bash
# =============================================================================
# Script Name: postgres.sh
# Description: This script is for connecting to PostgreSQL via Port-Fowad.
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2025-03-26
# Version: 1.0
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - User is logged into OpenShift
#
# =============================================================================

NAMESPACE="quarkuscoffeeshop-demo"
echo "Postgres Password: " oc get secret coffeeshopdb-pguser-coffeeshopadmin -o jsonpath='{.data.password}' -n $NAMESPACE | base64 -d
POSTGRES_POD_NAME=$(oc get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep coffeeshopdb | head -n 1)
oc port-forward pod/$POSTGRES_POD_NAME 5432:5432 -n $NAMESPACE