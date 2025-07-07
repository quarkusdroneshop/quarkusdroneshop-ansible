#!/bin/bash 
set -xe

curl -X POST \
  http://droneshop-apicurioregistry-kafkasql.quarkusdroneshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/orders-in/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"orders_in\",\"namespace\":\"quarkusdroneshop.demo\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"},{\"name\":\"orderSource\",\"type\":\"string\"},{\"name\":\"location\",\"type\":\"string\"},{\"name\":\"loyaltyMemberId\",\"type\":\"string\"},{\"name\":\"Qdca10LineItems\",\"type\":{\"type\":\"array\",\"items\":{\"type\":\"record\",\"name\":\"QDCA10LineItem\",\"fields\":[{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"price\",\"type\":\"float\"},{\"name\":\"name\",\"type\":\"string\"}]} }},{\"name\":\"qdca10proLineItems\",\"type\":{\"type\":\"array\",\"items\":\"string\"}}]}",
    "schemaType": "AVRO"
  }'
sleep 5

curl -X POST \
  http://droneshop-apicurioregistry-kafkasql.quarkusdroneshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/qdca10pro-in/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"QDCA10Pro_in\",\"namespace\":\"quarkusdroneshop_demo\",\"fields\":[{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"lineItemId\",\"type\":\"string\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"timestamp\",\"type\":{\"type\":\"long\",\"logicalType\":\"timestamp-millis\"}}]}",
    "schemaType": "AVRO"
  }'
sleep 5

curl -X POST \
  http://droneshop-apicurioregistry-kafkasql.quarkusdroneshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/qdca10-in/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"QDCA10_in\",\"namespace\":\"quarkusdroneshop_demo\",\"fields\":[{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"lineItemId\",\"type\":\"string\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"timestamp\",\"type\":\"string\"}]}",
    "schemaType": "AVRO"
  }'
sleep 5

curl -X POST \
  http://droneshop-apicurioregistry-kafkasql.quarkusdroneshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/web-updates/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"web_updates\",\"namespace\":\"quarkusdroneshop_demo\",\"fields\":[{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"itemId\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"status\",\"type\":\"string\"},{\"name\":\"madeBy\",\"type\":[\"null\",\"string\"],\"default\":null}]}",
    "schemaType": "AVRO"
  }'
sleep 5

curl -X POST \
  http://droneshop-apicurioregistry-kafkasql.quarkusdroneshop-demo.router-default.apps.${CLUSTER_DOMAIN_NAME}/apis/ccompat/v7/subjects/web-updates/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{
    "schema": "{\"type\":\"record\",\"name\":\"web_updates\",\"namespace\":\"quarkusdroneshop_demo\",\"fields\":[{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"lineItemId\",\"type\":\"string\"},{\"name\":\"item\",\"type\":\"string\"},{\"name\":\"name\",\"type\":\"string\"},{\"name\":\"timestamp\",\"type\":\"double\"},{\"name\":\"madeBy\",\"type\":[\"null\",\"string\"],\"default\":null}]}",
    "schemaType": "AVRO"
  }'
