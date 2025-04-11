#!/bin/bash

####################################################
# 注意: ログイン後、対象ドメインのすべてのTopicを消します。


NAMESPACE="quarkuscoffeeshop-demo"
KAFKA_POD=$(oc get pod -n "$NAMESPACE" -l strimzi.io/kind=Kafka -o jsonpath='{.items[0].metadata.name}')
BOOTSTRAP_SERVER="cafe-cluster-kafka-bootstrap:9092"
PATTERN="^cafe-asite.*"

echo "Target Kafka Pod: $KAFKA_POD"

# Kafka Pod 内でトピックリストを取得し、該当するものだけ削除
oc exec -n "$NAMESPACE" -it "$KAFKA_POD" -- bash -c "
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --list | grep -E '$PATTERN' | while read topic; do
    echo 'Deleting topic: '\$topic
    /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BOOTSTRAP_SERVER --delete --topic \"\$topic\"
  done
"
