#!/bin/bash
# =============================================================================
# Script Name: deploy.sh
# Description: This script deploys the application to OpenShift and verifies the setup.
# Author: Noriaki Mushino
# Date Created: 2025-03-26
# Last Modified: 2025-03-27
# Version: 1.4
#
# Usage:
#   ./deploy.sh setup       - To setup the environment.
#   ./deploy.sh deploy      - To deploy the application.
#   ./deploy.sh subdeploy1  - To deploy the application1.
#   ./deploy.sh subdeploy2  - To deploy the application2.
#   ./deploy.sh homedeploy  - To deploy the homeoffice application.
#   ./deploy.sh cleanup     - To delete the application.
#
# Prerequisites:
#   - OpenShift CLI (oc) is installed and configured
#   - figlet is installed and configured
#   - User is logged into OpenShift
#   - The Test was conducted on MacOS
#
# =============================================================================

NAMESPACE="quarkuscoffeeshop-demo"
OPENMETADATASPACE="openmetadata"
DOMAIN_NAME=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | cut -d'.' -f2-)
DOMAIN_TOKEN=$(oc whoami -t)
ENV_FILE="source.env"

# ロゴの表示
figlet "coffeeshop"

# 前処理
oc status
oc version

# 色を変数に格納
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
YELLOW="\033[33m"
RESET="\033[0m"

# 変数を使って色を変えたメッセージを表示
#echo -e "${BLUE}注意: 処理中です...${RESET}"
#echo -e "${RED}警告: エラーが発生しました！${RESET}"
#echo -e "${GREEN}成功: 操作が完了しました！${RESET}"

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
    echo "セットアップ開始..."
    # Podman イメージの作成とOperatorのインストール
    podman build --no-cache -t quarkuscoffeeshop . 
    podman run --platform linux/amd64 -it --env-file=./$ENV_FILE quarkuscoffeeshop
    oc expose svc coffeeshopdb-ha --name=coffeeshopdb-ha --port=5432 -n "$NAMESPACE"
}

deploy() {
    echo "デプロイ開始..."

    # 既存Appの削除
    oc delete all -l app=web -n "$NAMESPACE"
    oc delete all -l app=counter -n "$NAMESPACE"
    
    # Configmap の追加
    oc apply -f openshift/coffeeshop-configmap.yaml
    
    # Counter App
    oc new-app ubi8/openjdk-17~https://github.com/nmushino/quarkuscoffeeshop-counter.git --name=counter --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/counter-development.yaml -n "$NAMESPACE"

    # Web App
    oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-web.git --name=web --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/web-development.yaml -n "$NAMESPACE"
    oc expose deployment web --port=8080 --name=quarkuscoffeeshop-web -n "$NAMESPACE"
    oc expose svc quarkuscoffeeshop-web --name=quarkuscoffeeshop-web -n "$NAMESPACE"

    # ConfigMap の修正
    CORS_ORIGINS=$(oc get route quarkuscoffeeshop-web -o jsonpath='{.spec.host}' -n quarkuscoffeeshop-demo)
    LOYALTY_STREAM_URL=$(oc get route quarkuscoffeeshop-web -o jsonpath='{.spec.host}' -n quarkuscoffeeshop-demo)/dashboard/loyaltystream
    STREAM_URL=$(oc get route quarkuscoffeeshop-web -o jsonpath='{.spec.host}' -n quarkuscoffeeshop-demo)/dashboard/stream
    oc patch openshift coffeeshop-config -n "$NAMESPACE" -p "{\"data\":{\"CORS_ORIGINS\":\"http://$CORS_ORIGINS\"}}"
    oc patch openshift coffeeshop-config -n "$NAMESPACE" -p "{\"data\":{\"LOYALTY_STREAM_URL\":\"http://$LOYALTY_STREAM_URL\"}}"
    oc patch openshift coffeeshop-config -n "$NAMESPACE" -p "{\"data\":{\"STREAM_URL\":\"http://$STREAM_URL\"}}"
}

subdeploy1() {
    echo "デプロイ開始..."

    # 既存Appの削除
    oc delete all -l app=kitchen -n "$NAMESPACE"

    # Kitchen App
    oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-kitchen.git --name=kitchen --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/kitchen-development.yaml -n "$NAMESPACE"
}

subdeploy2() {
    echo "デプロイ開始..."

    # 既存Appの削除
    oc delete all -l app=barista -n "$NAMESPACE"
    
    # Barista App
    oc new-app ubi8/openjdk-11~https://github.com/nmushino/quarkuscoffeeshop-barista.git --name=barista --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/barista-development.yaml -n "$NAMESPACE"
}

homedeploy() {
    echo "デプロイ開始..."

    # 既存Appの削除
    oc delete all -l app=homeoffice-backend -n "$NAMESPACE"
    oc delete all -l app=homeoffice-ui -n "$NAMESPACE"
    
    # Homeoffice Backend App
    oc new-app ubi8/openjdk-17~https://github.com/nmushino/homeoffice-backend.git --name=homeoffice-backend --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc apply -f openshift/homeoffice-backend-development.yaml -n "$NAMESPACE"
    oc expose deployment homeoffice-backend --port=8080 --name=homeoffice-backend -n "$NAMESPACE"
    oc expose svc homeoffice-backend --name=homeoffice-backend -n "$NAMESPACE"

    # Homeoffice UI App
    oc new-app ubi8/nodejs-20~https://github.com/nmushino/quarkuscoffeeshop-homeoffice-ui.git --name=homeoffice-ui --allow-missing-images --strategy=source -n "$NAMESPACE"
    oc expose deployment homeoffice-ui --port=8080 --name=homeoffice-ui -n "$NAMESPACE"
    oc expose svc homeoffice-ui --name=homeoffice-ui -n "$NAMESPACE"
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
    helm install openmetadata open-metadata/openmetadata -n "$OPENMETADATASPACE"
    oc expose svc openmetadata -n "$OPENMETADATASPACE"
}

cleanup() {
    echo "クリーンナップ開始..."

    # quarkuscoffeeshop
    oc delete all --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete operator --all -n openshift-operators --ignore-not-found=true
    oc delete operator --all -n "$NAMESPACE" --ignore-not-found=true
    #oc delete pvc --all -n "$NAMESPACE" --ignore-not-found=true
    #oc delete pv --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete configmap --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete secrets --all -n "$NAMESPACE" --ignore-not-found=true
    oc delete routes --all -n "$NAMESPACE" --ignore-not-found=true
    oc get crds -o name | grep '.*\.strimzi\.io' | xargs -r -n 1 oc delete
    oc get crds -o name | grep '.*\.postgresclusters' | xargs -r -n 1 oc delete

    # openmetadata
    helm uninstall openmetadata -n "$OPENMETADATASPACE"
    helm uninstall openmetadata-dependencies -n "$OPENMETADATASPACE"

    read -p "本当にプロジェクトを削除してもよろしいですか？(yes/no): " DELETE_CONFREM
    if [ "$DELETE_CONFREM" == "yes" ]; then
        oc delete project "$NAMESPACE" --force --grace-period=0
        oc delete project "$OPENMETADATASPACE" --force --grace-period=0
    fi
}

case "$1" in
    setup)
        setup
        ;;
    deploy)
        read -p "すべてのアプリケーションを同クラスタにデプロイしますか(yes/no): " DEPLOY_CONFREM
        if [ "$DEPLOY_CONFREM" == "yes" ]; then
            deploy
            subdeploy1
            subdeploy2
        else
            deploy
        fi
        ;;
    subdeploy1)
        subdeploy1
        ;;
    subdeploy2)
        subdeploy2
        ;;
    homedeploy)
        homedeploy
        ;;
    openmetadata)
        openmetadata
        ;;
    cleanup)
        cleanup
        ;;
    *)
        echo -e "${RED}無効なコマンドです: $1${RESET}"
        echo -e "${RED}使用方法: $0 {setup|deploy|subdeploy1|subdeploy2|homedeploy|openmetadata|cleanup}${RESET}"
        exit 1
        ;;
esac