#!/bin/bash


#!/bin/sh
# postgresql.confのshared_preload_librariesを設定
#echo "shared_preload_libraries = 'pg_stat_statements,auto_explain,pgaudit'" >> /pgdata/pg17/postgresql.conf

### openmetadataで必要となるため、管理者権限で実行する
export PGPASSWORD=$(oc get secret coffeeshopdb-pguser-coffeeshopadmin -n quarkuscoffeeshop-demo -o jsonpath='{.data.password}' | base64 -d)
export PGHOSTNAME=$(oc get secret coffeeshopdb-pguser-coffeeshopadmin -n quarkuscoffeeshop-demo -o jsonpath='{.data.host}' | base64 -d)
psql -U postgres -h ${PGHOSTNAME} -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" >> /pgdata/pg17/init-extensions.sql
psql -U postgres -h ${PGHOSTNAME} -c "CREATE EXTENSION IF NOT EXISTS auto_explain;" >> /pgdata/pg17/init-extensions.sql
