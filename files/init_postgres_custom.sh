#!/bin/bash

### openmetadataで必要となるため、管理者権限で実行する
export PGHOSTNAME="droneshopdb-primary.quarkusdroneshop-demo.svc"
export PGPASSWORD="${PGPASSWORD}"
export PGPORT="5432"
export PGUSER="droneshopadmin"
export PGDATABASE="droneshopdb"

psql -h ${PGHOSTNAME} -d ${PGDATABASE} -c "SHOW shared_preload_libraries;"
psql -h ${PGHOSTNAME} -d ${PGDATABASE} -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -h ${PGHOSTNAME} -d ${PGDATABASE} -c "GRANT pg_read_all_stats TO droneshopadmin;"