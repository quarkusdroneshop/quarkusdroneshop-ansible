#!/bin/bash

### openmetadataで必要となるため、管理者権限で実行する
export PGPASSWORD=$(oc get secret droneshopdb-pguser-postgres -n quarkusdroneshop-demo -o jsonpath='{.data.password}' | base64 -d)
export PGHOSTNAME=$(oc get secret droneshopdb-pguser-postgres -n quarkusdroneshop-demo -o jsonpath='{.data.host}' | base64 -d)

psql -U postgres -h ${PGHOSTNAME} -c "SHOW shared_preload_libraries;"
psql -U postgres -h ${PGHOSTNAME} -d droneshopdb -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
psql -U postgres -h ${PGHOSTNAME} -d droneshopdb -c "GRANT pg_read_all_stats TO droneshopadmin;"
