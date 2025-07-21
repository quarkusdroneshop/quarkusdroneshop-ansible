#!/bin/bash
# =============================================================================
# Script Name: deploy.sh
# Description: This script deploys the application to OpenShift and verifies the setup.
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2025-06-04
# Version: 1.13
#
# Usage:
#   ./deploy.sh setup           - To setup the environment.
#   ./deploy.sh deploy          - To deploy the all application.
#   ./deploy.sh openmetadata    - To deploy the openmetadata application.
#   ./deploy.sh cleanup         - To delete the application.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

NAMESPACE="quarkusdroneshop-demo"
OPENMETADATASPACE="openmetadata"
DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)
DOMAIN_TOKEN=$(oc whoami -t)
ENV_FILE="source.env"

# ロゴの表示
figlet "droneshop"

# 前処理
oc status
oc version

# 色を変数に格納
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

# OpenShift にログインしているか確認
if ! oc whoami &>/dev/null; then
    echo -e "${RED}OpenShift にログインしていません。まず 'oc login' を実行してください。${RESET}" >&2
    exit 1
fi
echo "OpenShift にログイン済み: $(oc whoami)"

# OpenShift にログインしているか確認
echo -e "${YELLOW}Domain Name: $DOMAIN_NAME${RESET}"
echo -e "${YELLOW}Domain Token: $DOMAIN_TOKEN${RESET}"
echo -e "-------------------------------------------"
read -p "指定されたドメインで間違いないですか？(yes/no): " DOMAIN_CONFREM
if [ "$DOMAIN_CONFREM" != "yes" ]; then
    echo -e "${RED}処理を中断します。${RESET}"
    exit 1
fi

# source.env ファイルのCLUSTER_DOMAIN_NAMEとTOKEN を更新する
sed -i '' "s/^CLUSTER_DOMAIN_NAME=.*$/CLUSTER_DOMAIN_NAME=$DOMAIN_NAME/" $ENV_FILE
sed -i '' "s/^TOKEN=.*$/TOKEN=$DOMAIN_TOKEN/" $ENV_FILE

setup() {

    # OCPのセットアップ、共通ミドルのセットアップ
    echo "セットアップ開始..."
    # default ServiceAccount へ権限の追加
    oc adm policy add-scc-to-user anyuid system:serviceaccount:"$NAMESPACE":default
    # Podman イメージの作成とOperatorのインストール
    podman build --no-cache -t "$NAMESPACE" . 
    podman run --platform linux/amd64 -it --env-file=./$ENV_FILE "$NAMESPACE"
    # PostgreSQLCluster へ権限の追加
    oc adm policy add-scc-to-user anyuid -z droneshopdb-instance -n "$NAMESPACE"
    oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE"
}

deploy() {

    read -p "本当にアプリインストールしますか？推奨はPiplineによるインストールです。(yes/no): " DEPLOY_CONFREM
    if [ "$DEPLOY_CONFREM" != "yes" ]; then
        echo -e "${RED}処理を中断します。${RESET}"
        exit 1
    fi

    #############################################################
    # 本パラメータは、tekton-pipline に移行したため、現在利用なし。
    # Tektonで問題がでた時のバックアップ用とする。
    #############################################################
    echo "デプロイ開始..."

    # 既存Appの削除
    oc delete all -l app=web -n "$NAMESPACE"
    oc delete all -l app=counter -n "$NAMESPACE"
    oc delete all -l app=inventory -n "$NAMESPACE"
    oc delete all -l app=QDCA10Pro -n "$NAMESPACE"
    oc delete all -l app=QDCA10 -n "$NAMESPACE"
    oc delete all -l app=homeoffice-backend -n "$NAMESPACE"
    oc delete all -l app=homeoffice-ui -n "$NAMESPACE"
    oc delete all -l app=customermocker -n "$NAMESPACE"
    
    # Configmap の追加
    oc apply -f openshift/droneshop-configmap.yaml

    # Counter App
    oc new-app ubi8/openjdk-17~https://github.com/quarkusdroneshop/quarkusdroneshop-counter.git --name=counter --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/counter-development.yaml -n "$NAMESPACE"

    # Inventory App
    oc new-app ubi8/openjdk-11~https://github.com/quarkusdroneshop/quarkusdroneshop-inventory.git --name=inventory --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/inventory-development.yaml -n "$NAMESPACE"

    # Web App
    oc new-app ubi8/openjdk-11~https://github.com/quarkusdroneshop/quarkusdroneshop-web.git --name=web --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/web-development.yaml -n "$NAMESPACE"
    oc expose deployment web --port=8080 --name=quarkusdroneshop-web -n "$NAMESPACE"
    oc expose svc quarkusdroneshop-web --name=quarkusdroneshop-web -n "$NAMESPACE"

    # ConfigMap の修正
    CORS_ORIGINS=$(oc get route quarkusdroneshop-web -o jsonpath='{.spec.host}' -n quarkusdroneshop-demo)
    LOYALTY_STREAM_URL=$(oc get route quarkusdroneshop-web -o jsonpath='{.spec.host}' -n quarkusdroneshop-demo)/dashboard/loyaltystream
    STREAM_URL=$(oc get route quarkusdroneshop-web -o jsonpath='{.spec.host}' -n quarkusdroneshop-demo)/dashboard/stream
    oc patch configmap droneshop-config -n "$NAMESPACE" -p "{\"data\":{\"CORS_ORIGINS\":\"http://$CORS_ORIGINS\"}}"
    oc patch configmap droneshop-config -n "$NAMESPACE" -p "{\"data\":{\"LOYALTY_STREAM_URL\":\"http://$LOYALTY_STREAM_URL\"}}"
    oc patch configmap droneshop-config -n "$NAMESPACE" -p "{\"data\":{\"STREAM_URL\":\"http://$STREAM_URL\"}}"

    # QDCA10Pro App
    oc new-app ubi8/openjdk-11~https://github.com/quarkusdroneshop/quarkusdroneshop-qdca10pro.git --name=QDCA10Pro --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/QDCA10Pro-development.yaml -n "$NAMESPACE"

    # QDCA10 App
    oc new-app ubi8/openjdk-11~https://github.com/quarkusdroneshop/quarkusdroneshop-qdca10.git --name=QDCA10 --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/QDCA10-development.yaml -n "$NAMESPACE"
    
    # Homeoffice Backend App
    oc new-app ubi8/openjdk-17~https://github.com/quarkusdroneshop/homeoffice-backend.git --name=homeoffice-backend --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/homeoffice-backend-development.yaml -n "$NAMESPACE"
    oc expose deployment homeoffice-backend --port=8080 --name=homeoffice-backend -n "$NAMESPACE"
    oc expose svc homeoffice-backend --name=homeoffice-backend -n "$NAMESPACE"

    # Homeoffice UI App
    oc new-app ubi8/nodejs-20~https://github.com/quarkusdroneshop/quarkusdroneshop-homeoffice-ui.git --name=homeoffice-ui --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc expose deployment homeoffice-ui --port=8080 --name=homeoffice-ui -n "$NAMESPACE"
    oc expose svc homeoffice-ui --name=homeoffice-ui -n "$NAMESPACE"

    # Customermocker App
    oc new-app ubi8/openjdk-11~https://github.com/quarkusdroneshop/quarkusdroneshop-customermocker.git --name=customermocker --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/customermocker-development.yaml -n "$NAMESPACE"
    oc expose deployment customermocker --port=8080 --name=quarkusdroneshop-customermocker -n "$NAMESPACE"
    oc expose svc quarkusdroneshop-customermocker --name=quarkusdroneshop-customermocker -n "$NAMESPACE"

    # ConfigMap の修正
    REST_URL=$(oc get route quarkusdroneshop-customermocker -o jsonpath='{.spec.host}' -n quarkusdroneshop-demo)
    oc patch configmap droneshop-config -n "$NAMESPACE" -p "{\"data\":{\"REST_URL\":\"http://$REST_URL/orders\"}}"
}

openmetadata() {
    echo "セットアップ開始..."

    # プロジェクトの作成
    oc delete project "$OPENMETADATASPACE"
    oc new-project "$OPENMETADATASPACE"

    # シークレットの作成
    oc create secret generic mysql-secrets --from-literal=openmetadata-mysql-password=openmetadata_password -n "$OPENMETADATASPACE"
    oc create secret generic airflow-secrets --from-literal=openmetadata-airflow-password=admin -n "$OPENMETADATASPACE"
    oc create secret generic airflow-mysql-secrets --from-literal=airflow-mysql-password=airflow_pass -n "$OPENMETADATASPACE"

    # SCCの作成
    oc adm policy add-scc-to-user anyuid -z airflow -n "$OPENMETADATASPACE"
    oc adm policy add-scc-to-user anyuid -z builder -n "$OPENMETADATASPACE"
    oc adm policy add-scc-to-user anyuid -z default -n "$OPENMETADATASPACE"
    oc adm policy add-scc-to-user anyuid -z deployer -n "$OPENMETADATASPACE"
    oc adm policy add-scc-to-user anyuid -z mysql -n "$OPENMETADATASPACE"

    # OpenMetadataの依存Podの作成
    helm repo add open-metadata https://helm.open-metadata.org
    helm repo update
    helm install openmetadata-dependencies open-metadata/openmetadata-dependencies -n "$OPENMETADATASPACE"

    # 既存PVCを一度削除
    oc delete pvc openmetadata-dependencies-dags -n "$OPENMETADATASPACE"
    oc delete pvc openmetadata-dependencies-logs -n "$OPENMETADATASPACE"

    # PVCを再作成
    oc apply -f openshift/openmetadata-dependencies-dags.yaml -n "$OPENMETADATASPACE"
    oc apply -f openshift/openmetadata-dependencies-logs.yaml -n "$OPENMETADATASPACE"

    # PVCにラベルとアノテーションを追加
    oc label pvc openmetadata-dependencies-dags app.kubernetes.io/managed-by=Helm -n "$OPENMETADATASPACE"
    oc annotate pvc openmetadata-dependencies-dags meta.helm.sh/release-name=openmetadata-dependencies -n "$OPENMETADATASPACE"
    oc annotate pvc openmetadata-dependencies-dags meta.helm.sh/release-namespace=openmetadata -n "$OPENMETADATASPACE"
    oc label pvc openmetadata-dependencies-logs app.kubernetes.io/managed-by=Helm -n "$OPENMETADATASPACE"
    oc annotate pvc openmetadata-dependencies-logs meta.helm.sh/release-name=openmetadata-dependencies -n "$OPENMETADATASPACE"
    oc annotate pvc openmetadata-dependencies-logs meta.helm.sh/release-namespace=openmetadata -n "$OPENMETADATASPACE"
    
    # OpenMetadataの作成
    #helm install openmetadata open-metadata/openmetadata -n "$OPENMETADATASPACE" -f ./openshift/values-openmetadata.yaml
    helm install openmetadata open-metadata/openmetadata -n "$OPENMETADATASPACE"
    oc expose svc openmetadata -n "$OPENMETADATASPACE"

    #helm repo add minio https://charts.min.io/
    #helm repo update
    #helm install minio minio/minio \
    #    --namespace openmetadata \
    #    --set rootUser=minioadmin \
    #    --set rootPassword=minioadmin \
    #    --set mode=standalone \
    #    --set persistence.storageClass=gp3-csi \
    #    --set resources.requests.memory=256Mi \
    #    --set service.type=ClusterIP \
    #    --set securityContext.enabled=false \
    #    --set containerSecurityContext.enabled=false \
    #    --set lifecycleHooks.postInstallJob.enabled=false \
    #    --set lifecycleHooks.postUpgradeJob.enabled=false \
    #    --wait
    #pip install psycopg2-binary
    #oc expose svc droneshopdb-primary 
    #metadata ingest -c ./openshift/values-openmetadata.yaml

}

cleanup() {
    echo "クリーンナップ開始..."

    # quarkusdroneshop
    oc delete subscription amq-streams --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete subscription crunchy-postgres-operator --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete operator --all -n openshift-operators --ignore-not-found=true
    oc delete operator --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete all --all -n "$NAMESPACE" --ignore-not-found=true --force --grace-period=0

    # openmetadata
    helm uninstall openmetadata -n "$OPENMETADATASPACE"
    helm uninstall openmetadata-dependencies -n "$OPENMETADATASPACE"

    read -p "本当にプロジェクトを削除してもよろしいですか？(yes/no): " DELETE_CONFREM
    if [ "$DELETE_CONFREM" == "yes" ]; then
        # KafkaTopic リソースを強制削除
        for topic in $(oc get kafkatopics.kafka.strimzi.io -n "$NAMESPACE" -o name); do
            oc patch $topic -n "$NAMESPACE" --type=merge -p '{"metadata":{"finalizers":[]}}' 
        done
        oc delete project "$NAMESPACE" --force --grace-period=0
        oc delete project "$OPENMETADATASPACE" --force --grace-period=0
    fi
}

case "$1" in
    setup)
        setup
        ;;
    deploy)
        deploy
        ;;
    openmetadata)
        openmetadata
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {setup|deploy|openmetadata|cleanup}${RESET}"
        exit 1
        ;;
esac