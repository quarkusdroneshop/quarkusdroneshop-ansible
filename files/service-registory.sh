#!/bin/bash 
set -xe

curl -X POST \
  http://coffeeshop-apicurioregistry-kafkasql.quarkuscoffeeshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/orders-in/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"orders_in\",\"namespace\":\"quarkuscoffeeshop.demo\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"},{\"name\":\"orderSource\",\"type\":\"string\"},{\"name\":\"location\",\"type\":\"string\"},{\"name\":\"loyaltyMemberId\",\"type\":\"string\"},{\"name\":\"baristaLineItems\",\"type\":{\"type\":\"array\",\"items\":{\"type\":\"record\",\"name\":\"BaristaLineItem\",\"fields\":[{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"price\",\"type\":\"float\"},{\"name\":\"name\",\"type\":\"string\"}]} }},{\"name\":\"kitchenLineItems\",\"type\":{\"type\":\"array\",\"items\":\"string\"}}]}",
    "schemaType": "AVRO"
  }'
sleep 5

curl -X POST \
  http://coffeeshop-apicurioregistry-kafkasql.quarkuscoffeeshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/kitchen-in/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"kitchen_in\",\"namespace\":\"quarkuscoffeeshop_demo\",\"fields\":[{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"lineItemId\",\"type\":\"string\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"timestamp\",\"type\":{\"type\":\"long\",\"logicalType\":\"timestamp-millis\"}}]}",
    "schemaType": "AVRO"
  }'
sleep 5

curl -X POST \
  http://coffeeshop-apicurioregistry-kafkasql.quarkuscoffeeshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/barista-in/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"barista_in\",\"namespace\":\"quarkuscoffeeshop_demo\",\"fields\":[{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"lineItemId\",\"type\":\"string\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"timestamp\",\"type\":\"string\"}]}",
    "schemaType": "AVRO"
  }'
sleep 5

curl -X POST \
  http://coffeeshop-apicurioregistry-kafkasql.quarkuscoffeeshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/web-updates/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"web_updates\",\"namespace\":\"quarkuscoffeeshop_demo\",\"fields\":[{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"itemId\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"status\",\"type\":\"string\"},{\"name\":\"madeBy\",\"type\":[\"null\",\"string\"],\"default\":null}]}",
    "schemaType": "AVRO"
  }'
sleep 5