#!/bin/bash
# =============================================================================
# Script Name: podman.sh
# Description: This script is for Maintenance shell for local startup.
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2026-07-18
# Version: 1.1
#
# Prerequisites:
#   - podman is installed
#
# =============================================================================

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

NAMESPACE="quarkusdroneshop-demo"

echo "###################################"
echo "このシェルはメンテナンスシェルです"
echo "###################################"
echo

echo -e "${BLUE}kafka-net ネットワークを作成中...${RESET}"
podman network create kafka-net

echo -e "${BLUE}kafka コンテナを起動中...${RESET}"
podman run -d --name kafka --network kafka-net \
  -p 9092:9092 \
  -e KAFKA_CFG_PROCESS_ROLES=broker,controller \
  -e KAFKA_CFG_NODE_ID=1 \
  -e KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
  -e KAFKA_CFG_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093 \
  -e KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://host.containers.internal:9092 \
  -e KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  -e KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=1@localhost:9093 \
  bitnami/kafka:latest

echo -e "${BLUE}postgres コンテナを起動中...${RESET}"
podman run -d \
  --name postgres \
  --network kafka-net \
  -e POSTGRES_USER=droneshopadmin \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=droneshopdb \
  -p 5432:5432 \
  postgres:latest

echo -e "${BLUE}kafdrop コンテナを起動中...${RESET}"
podman run -d --name kafdrop \
  --network kafka-net \
  -p 9000:9000 \
  -e KAFKA_BROKERCONNECT=kafka:9092 \
  -e JVM_OPTS="-Xms32M -Xmx64M" \
  obsidiandynamics/kafdrop

echo -e "${GREEN}起動が完了しました。${RESET}"