#!/bin/bash

### openmetadataで必要となるため、管理者権限で実行する
export PGHOSTNAME="droneshopdb-primary.quarkusdroneshop-demo.svc"
export PGPASSWORD="${PGPASSWORD}"
export PGPORT="5432"
export PGUSER="droneshopadmin"
export PGDATABASE="droneshopdb"

psql -U postgres -h ${PGHOSTNAME} -c "SHOW shared_preload_libraries;"
psql -U postgres -h ${PGHOSTNAME} -d droneshopdb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -U postgres -h ${PGHOSTNAME} -d droneshopdb -c "GRANT pg_read_all_stats TO droneshopadmin;"
