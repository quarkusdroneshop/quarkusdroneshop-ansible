#!/bin/bash


# オフライントークンの発行先
#https://access.redhat.com/management/api


REFRESH_TOKEN="$1"  # 第1引数で refresh_token を受け取る

# チェック
if [ -z "$REFRESH_TOKEN" ]; then
  echo "Usage: $0 <refresh_token>"
  exit 1
fi

# アクセストークン取得
curl -s -X POST "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token" \
  -d "client_id=rhsm-api" \
  -d "refresh_token=$REFRESH_TOKEN" | jq -r .access_token