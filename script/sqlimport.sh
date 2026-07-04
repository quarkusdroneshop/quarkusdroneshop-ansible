#!/bin/bash
# =============================================================================
# Script Name: sqlimport.sh
# Description: This script is for import OpenMetadata data.
# Author: Noriaki Mushino
# Date Created: 2025-05-28
# Last Modified: 2025-05-28
# Version: 1.0
#
# Prerequisites:
#   - mysql command is required
#   - User is logged into OpenShift
#
# =============================================================================

echo "###################################"
echo "このシェルはメンテナンスシェルです"
echo "###################################"
echo
echo "デフォルトパスワードは、 openmetadata_password です"

# ポートフォワードをバックグラウンドで起動
oc port-forward pod/mysql-0 3306:3306 > /dev/null 2>&1 &
PF_PID=$!

# フォワーディングが有効になるまで待つ（最大10秒）
for i in {1..10}; do
  nc -z 127.0.0.1 3306 && break
  sleep 1
done

# SQLファイルをMySQLにインポート
mysql -h 127.0.0.1 -P 3306 -u openmetadata_user -p openmetadata_db < openmetadata_backup.sql

# ポートフォワード停止
kill $PF_PID
