#!/bin/bash
# =============================================================================
# Script Name: delete-project.sh
# Description: Force delete OpenShift project(namespace)
# Author: Noriaki Mushino
# Date Created: 2025-05-25
# Last Modified: 2026-05-28
# Version: 2.0
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed
#   - jq is installed
#   - User is logged into OpenShift
#
# Usage:
#   ./delete-project.sh <namespace>
#
# Example:
#   ./delete-project.sh quarkusdroneshop-demo
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Parameter Check
# -----------------------------------------------------------------------------
if [ $# -ne 1 ]; then
  echo "[ERROR] Namespace is required."
  echo
  echo "Usage:"
  echo "  $0 <namespace>"
  echo
  exit 1
fi

NAMESPACE="$1"
TMP_FILE="/tmp/${NAMESPACE}-patched.json"

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
cleanup() {
  rm -f "${TMP_FILE}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
echo "################################################################"
echo " OpenShift Project Force Delete Maintenance Script"
echo "################################################################"
echo
echo " Namespace : ${NAMESPACE}"
echo

# -----------------------------------------------------------------------------
# Prerequisite Check
# -----------------------------------------------------------------------------
if ! command -v oc >/dev/null 2>&1; then
  echo "[ERROR] oc command not found."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[ERROR] jq command not found."
  exit 1
fi

# -----------------------------------------------------------------------------
# Login Check
# -----------------------------------------------------------------------------
echo "[INFO] Checking OpenShift login..."

if ! oc whoami >/dev/null 2>&1; then
  echo "[ERROR] Not logged in to OpenShift."
  exit 1
fi

# -----------------------------------------------------------------------------
# Namespace Existence Check
# -----------------------------------------------------------------------------
echo "[INFO] Checking namespace existence..."

if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "[ERROR] Namespace ${NAMESPACE} does not exist."
  exit 1
fi

# -----------------------------------------------------------------------------
# Current Namespace Status
# -----------------------------------------------------------------------------
PHASE=$(oc get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}')

echo "[INFO] Namespace status: ${PHASE}"

if [ "${PHASE}" != "Terminating" ]; then
  echo
  echo "[WARN] Namespace is not in Terminating state."
  echo "[WARN] Normal deletion should be attempted first:"
  echo
  echo "       oc delete project ${NAMESPACE}"
  echo
fi

# -----------------------------------------------------------------------------
# Backup Original JSON
# -----------------------------------------------------------------------------
echo "[INFO] Exporting namespace JSON..."

oc get namespace "${NAMESPACE}" -o json > "${TMP_FILE}"

# -----------------------------------------------------------------------------
# Remove Finalizers
# -----------------------------------------------------------------------------
echo "[INFO] Removing finalizers..."

jq '
.spec.finalizers = []
' "${TMP_FILE}" > "${TMP_FILE}.tmp"

mv "${TMP_FILE}.tmp" "${TMP_FILE}"

# -----------------------------------------------------------------------------
# Force Finalize Namespace
# -----------------------------------------------------------------------------
echo "[INFO] Sending finalize request..."

oc replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" \
  -f "${TMP_FILE}"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo
echo "[INFO] Checking deletion status..."

sleep 5

if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "[WARN] Namespace still exists."
  echo "[WARN] Additional stuck resources or APIService issues may exist."
else
  echo "[SUCCESS] Namespace ${NAMESPACE} has been force deleted."
fi

echo
echo "[INFO] Completed."