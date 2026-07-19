#!/bin/bash
# =============================================================================
# Script Name: kafka-delete-topic.sh
# Description: This script is for deleteing to Kafka Topic.
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2026-07-18
# Version: 1.2
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - User is logged into OpenShift
#
# =============================================================================
# 注意: ログイン後、対象ドメインのすべてのTopicを消します。

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
KAFKA_POD=$(oc get pod -n "$NAMESPACE" -l strimzi.io/kind=Kafka -o jsonpath='{.items[1].metadata.name}')
BOOTSTRAP_SERVER="shop-cluster-kafka-bootstrap:9092"                                    ## ローカルKafka
A_PATTERN="^shop-asite.*"
B_PATTERN="^shop-bsite.*"
C_PATTERN="^shop-csite.*"

echo "###################################"
echo "このシェルはメンテナンスシェルです"
echo "###################################"
echo
echo "###################################"
echo "このシェルは不要なTopicを消します"
echo "###################################"
echo
echo -e "${BLUE}Target Kafka Pod: $KAFKA_POD${RESET}"

# Kafka Pod 内でトピックリストを取得し、該当するものだけ削除する
oc exec -n "$NAMESPACE" -it "$KAFKA_POD" -- bash -c "
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --list | grep -E '$A_PATTERN' | while read topic; do
    echo 'Deleting topic: '\$topic
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --delete --topic \"\$topic\"
  done
"
# Kafka Pod 内でトピックリストを取得し、該当するものだけ削除する
oc exec -n "$NAMESPACE" -it "$KAFKA_POD" -- bash -c "
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --list | grep -E '$B_PATTERN' | while read topic; do
    echo 'Deleting topic: '\$topic
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --delete --topic \"\$topic\"
  done
"
# Kafka Pod 内でトピックリストを取得し、該当するものだけ削除する
oc exec -n "$NAMESPACE" -it "$KAFKA_POD" -- bash -c "
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --list | grep -E '$C_PATTERN' | while read topic; do
    echo 'Deleting topic: '\$topic
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --delete --topic \"\$topic\"
  done
"
# Kafka Pod 内でトピックリストを取得し、残りのTopicをすべて削除する
# NOTE: 旧バージョンはここが `for topic in $(...)` のネストしたダブルクォートで
# 引用符の対応が崩れ、シェルの構文エラーになっていた(実行不能なバグ)。
# 他の3ブロックと同じ while-read 形式に修正。
oc exec -n "$NAMESPACE" -it "$KAFKA_POD" -- bash -c "
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --list | while read topic; do
    echo 'Deleting topic: '\$topic
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --delete --topic \"\$topic\"
  done
"

echo -e "${GREEN}完了しました。${RESET}"
