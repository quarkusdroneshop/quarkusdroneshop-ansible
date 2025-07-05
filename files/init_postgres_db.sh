#!/bin/bash

### droneshopadminで実行する
export PGPASSWORD=$(oc get secret droneshopdb-pguser-droneshopadmin -n quarkusdroneshop-demo -o jsonpath='{.data.password}' | base64 -d)
export PGHOSTNAME=$(oc get secret droneshopdb-pguser-droneshopadmin -n quarkusdroneshop-demo -o jsonpath='{.data.host}' | base64 -d)

psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "CREATE SCHEMA IF NOT EXISTS droneshop;"
psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "CREATE SCHEMA droneshop AUTHORIZATION droneshopadmin;"
psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "alter table if exists droneshop.LineItems
    drop constraint if exists FK6fhxopytha3nnbpbfmpiv4xgn;"
psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "drop table if exists droneshop.LineItems cascade;
drop table if exists droneshop.Orders cascade;
drop table if exists droneshop.OutboxEvent cascade;"
psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "create table droneshop.LineItems (
                           id uuid not null,
                           order_id varchar(255) not null,
                           item varchar(255),
                           lineItemStatus varchar(255),
                           price numeric(19, 2),
                           primary key (id)
);"

psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "create table droneshop.Orders (
                        order_id varchar(255) not null,
                        loyaltyMemberId varchar(255),
                        location     varchar(255),
                        orderSource varchar(255),
                        orderStatus varchar(255),
                        timestamp timestamp,
                        primary key (order_id)
);"

psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "create table droneshop.OutboxEvent (
                             id uuid not null,
                             aggregatetype varchar(255) not null,
                             aggregateid varchar(255) not null,
                             type varchar(255) not null,
                             timestamp timestamp not null,
                             payload varchar(8000),
                             primary key (id)
);"

psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "alter table if exists droneshop.LineItems
    add constraint FK6fhxopytha3nnbpbfmpiv4xgn
        foreign key (order_id)
            references droneshop.Orders;"