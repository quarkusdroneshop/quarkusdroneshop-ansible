#!/bin/bash 

set -x 

mongoimport --db shopdb --collection Order \
          --authenticationDatabase shopdb --username ${MONGO_USERNAME} --password ${MONGO_PASSWORD} \
          --drop --file /data/sample_mongo_data.json  --host ${MONGO_CONNECTION_STRING} --port 27017

