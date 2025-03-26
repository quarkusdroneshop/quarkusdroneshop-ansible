#!/bin/bash
# =============================================================================
# Script Name: postgres.sh
# Description: This script is for connecting to OpenMetadata via Port-Fowad.
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
OPENMETADATA_POD_NAME=$(oc get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep openmetadata | head -n 1)
oc port-forward service/$OPENMETADATA_POD_NAME 5432:5432 -n $NAMESPACE
