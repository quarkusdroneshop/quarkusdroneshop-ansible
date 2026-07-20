#!/bin/bash

### droneshopadminで実行する
export PGHOSTNAME="droneshopdb-primary.quarkusdroneshop-demo.svc"
export PGPASSWORD="${PGPASSWORD}"
export PGPORT="5432"
export PGUSER="droneshopadmin"
export PGDATABASE="droneshopdb"

echo "Waiting for PostgreSQL to become available..."

until pg_isready -h "$PGHOSTNAME" -p "$PGPORT" -U "$PGUSER"; do
  sleep 2
done

echo "PostgreSQL is ready"

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
                           name varchar(255),
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
                             tracingSpanContext varchar(256),
                             primary key (id)
);"

psql -h ${PGHOSTNAME} -p 5432 -U droneshopadmin droneshopdb  -c "alter table if exists droneshop.LineItems
    add constraint FK6fhxopytha3nnbpbfmpiv4xgn
        foreign key (order_id)
            references droneshop.Orders;"