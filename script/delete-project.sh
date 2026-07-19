#!/bin/bash
# =============================================================================
# Script Name: delete-project.sh
# Description: Force delete OpenShift project(namespace)
# Author: Noriaki Mushino
# Date Created: 2025-05-25
# Last Modified: 2026-07-18
# Version: 2.1
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

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0 <namespace>"
}

# -----------------------------------------------------------------------------
# Parameter Check
# -----------------------------------------------------------------------------
if [ $# -ne 1 ]; then
  echo -e "${RED}[ERROR] Namespace is required.${RESET}"
  echo
  usage
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
  echo -e "${RED}[ERROR] oc command not found.${RESET}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo -e "${RED}[ERROR] jq command not found.${RESET}"
  exit 1
fi

# -----------------------------------------------------------------------------
# Login Check
# -----------------------------------------------------------------------------
echo -e "${BLUE}[INFO] Checking OpenShift login...${RESET}"

if ! oc whoami >/dev/null 2>&1; then
  echo -e "${RED}[ERROR] Not logged in to OpenShift.${RESET}"
  exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

# -----------------------------------------------------------------------------
# Namespace Existence Check
# -----------------------------------------------------------------------------
echo -e "${BLUE}[INFO] Checking namespace existence...${RESET}"

if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${RED}[ERROR] Namespace ${NAMESPACE} does not exist.${RESET}"
  exit 1
fi

# -----------------------------------------------------------------------------
# Current Namespace Status
# -----------------------------------------------------------------------------
PHASE=$(oc get namespace "${NAMESPACE}" -o jsonpath='{.status.phase}')

echo -e "${BLUE}[INFO] Namespace status: ${PHASE}${RESET}"

if [ "${PHASE}" != "Terminating" ]; then
  echo
  echo -e "${YELLOW}[WARN] Namespace is not in Terminating state.${RESET}"
  echo -e "${YELLOW}[WARN] Normal deletion should be attempted first:${RESET}"
  echo
  echo "       oc delete project ${NAMESPACE}"
  echo
fi

# -----------------------------------------------------------------------------
# Backup Original JSON
# -----------------------------------------------------------------------------
echo -e "${BLUE}[INFO] Exporting namespace JSON...${RESET}"

oc get namespace "${NAMESPACE}" -o json > "${TMP_FILE}"

# -----------------------------------------------------------------------------
# Remove Finalizers
# -----------------------------------------------------------------------------
echo -e "${BLUE}[INFO] Removing finalizers...${RESET}"

jq '
.spec.finalizers = []
' "${TMP_FILE}" > "${TMP_FILE}.tmp"

mv "${TMP_FILE}.tmp" "${TMP_FILE}"

# -----------------------------------------------------------------------------
# Force Finalize Namespace
# -----------------------------------------------------------------------------
echo -e "${BLUE}[INFO] Sending finalize request...${RESET}"

oc replace --raw "/api/v1/namespaces/${NAMESPACE}/finalize" \
  -f "${TMP_FILE}"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}[INFO] Checking deletion status...${RESET}"

sleep 5

if oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${YELLOW}[WARN] Namespace still exists.${RESET}"
  echo -e "${YELLOW}[WARN] Additional stuck resources or APIService issues may exist.${RESET}"
else
  echo -e "${GREEN}[SUCCESS] Namespace ${NAMESPACE} has been force deleted.${RESET}"
fi

echo
echo -e "${BLUE}[INFO] Completed.${RESET}"
