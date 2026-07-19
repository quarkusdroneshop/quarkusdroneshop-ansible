#!/bin/bash
# =============================================================================
# Script Name: get-rhtoken.sh
# Description: オフライントークンの発行先
# Author: Noriaki Mushino
# Date Created: 2025-05-25
# Last Modified: 2026-07-18
# Version: 1.4
#
# Usage:
#   ./get-rhtoken.sh <refresh_token>
#
# Prerequisites:
#   - curl / jq is installed
#
# https://access.redhat.com/management/api
#
# =============================================================================

RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

usage() {
    echo -e "${YELLOW}使用方法:${RESET}"
    echo "  $0 <refresh_token>"
}

REFRESH_TOKEN="${1:-}"  # 第1引数で refresh_token を受け取る

# チェック
if [ -z "$REFRESH_TOKEN" ]; then
  echo -e "${RED}[ERROR] refresh_token is required.${RESET}"
  usage
  exit 1
fi

# アクセストークン取得
curl -s -X POST "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token" \
  -d "client_id=rhsm-api" \
  -d "refresh_token=$REFRESH_TOKEN" | jq -r .access_token
