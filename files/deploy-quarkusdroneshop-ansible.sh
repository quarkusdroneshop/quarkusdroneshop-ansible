#!/bin/bash
#set -e
# For development export the enviorment variable below
#export DEVELOPMENT=true 
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -x

if [ "$EUID" -ne 0 ]
then 
  export USE_SUDO="sudo"
fi

# Print usage
function usage() {
  echo -n "${0} [OPTION]
 Options:
  -d      Add domain 
  -t      OpenShift Token
  -s      Store ID
  -h      Display this help and exit
  -u      Uninstall droneshop 
  To deploy qaurkusdroneshop-ansible playbooks
  ${0}  -d ocp4.example.com -t sha-123456789  -s ATLANTA
  To Delete qaurkusdroneshop-ansible playbooks from OpenShift
  ${0}  -d ocp4.example.com -t sha-123456789  -s ATLANTA -u true
"
}

# community.kubernetes.helm_repository
function configure-ansible-and-playbooks(){
  echo "Check if community.kubernetes exists"
  if [ ! -d ~/.ansible/collections/ansible_collections/community/kubernetes ] || [ ! -d /root/.ansible/collections/ansible_collections/community/kubernetes ];
  then 
    echo "Installing community.kubernetes ansible role"
    ${USE_SUDO} git clone https://github.com/ansible-collections/kubernetes.core.git
    ${USE_SUDO} mkdir -p /home/${USER}/.ansible/plugins/modules
    ${USE_SUDO} cp kubernetes.core/plugins/action/k8s.py /home/${USER}/.ansible/plugins/modules/
    ${USE_SUDO} ansible-galaxy collection install community.kubernetes
    ${USE_SUDO} ansible-galaxy collection install kubernetes.core
    ${USE_SUDO} ansible-galaxy collection install cloud.common
    ${USE_SUDO} ansible-galaxy collection install community.general
    ${USE_SUDO} pip3 install kubernetes || exit $?
    ${USE_SUDO} pip3 install openshift || exit $?
    ${USE_SUDO} pip3 install jmespath || exit $?
  fi 

  echo "Check if Helm is installed exists"
  if [ ! -f "/usr/local/bin/helm" ];
  then 
    echo "Installing helm"
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
    chmod 700 get_helm.sh
    ${USE_SUDO} ./get_helm.sh
    ${USE_SUDO} ln /usr/local/bin/helm /bin/helm
  fi 

  echo "Check if quarkusdroneshop-ansible role exists"
  if [ ! -z ${USE_SUDO} ];
  then 
    ROLE_LOC=$(${USE_SUDO}  find  /root/.ansible/roles -name quarkusdroneshop-ansible)
  else 
    ROLE_LOC=$(find  ~/.ansible/roles -name quarkusdroneshop-ansible)
  fi 
  

  if [[ $DEVELOPMENT == "false" ]] || [[ -z $DEVELOPMENT ]];
  then
    ${USE_SUDO} rm -rf ${ROLE_LOC}
    ${USE_SUDO} ansible-galaxy install git+https://github.com/quarkusdroneshop/quarkusdroneshop-ansible.git
    echo "****************"
    echo "Start Deployment"
    echo "****************"
  elif  [ $DEVELOPMENT == "true" ];
  then 
    ${USE_SUDO} rm -rf ${ROLE_LOC}
    ${USE_SUDO} ansible-galaxy install git+https://github.com/quarkusdroneshop/quarkusdroneshop-ansible.git,dev
    echo "****************"
    echo " Start Deployment "
    echo " DEVELOPMENT MODE "
    echo "****************"
    DEVMOD="-vv"
  fi 
  
  checkpipmodules
  echo "${USE_SUDO} ansible-playbook  /tmp/deploy-quarkus-shop.yml -t $(cat /tmp/tags) --extra-vars delete_deployment=${DESTROY} ${DEVMOD}"
  ${USE_SUDO} ansible-playbook  /tmp/deploy-quarkus-shop.yml -t $(cat /tmp/tags) --extra-vars delete_deployment=${DESTROY} ${DEVMOD} -e 'ansible_python_interpreter=/usr/bin/python3' ${DEBUG}
}

function destory_drone_shop(){
  echo "******************"
  echo "Destroy Deployment"
  echo "******************"
  configure-ansible-and-playbooks
  checkpipmodules

  echo "${USE_SUDO} ansible-playbook  /tmp/deploy-quarkus-shop.yml -t $(cat /tmp/tags) --extra-vars delete_deployment=${DESTROY} ${DEVMOD}"
  ${USE_SUDO} ansible-playbook  /tmp/deploy-quarkus-shop.yml -t $(cat /tmp/tags) --extra-vars delete_deployment=${DESTROY} ${DEVMOD} -e 'ansible_python_interpreter=/usr/bin/python3'  ${DEBUG}
}

function checkpipmodules(){
  if python3 -c "import openshift" &> /dev/null; then
    echo 'openshift pip module is installed '
  else
      echo 'openshift pip module is not installed '
      exit $?
  fi

  if python3 -c "import kubernetes" &> /dev/null; then
    echo 'kubernetes pip module is installed '
  else
      echo 'kubernetes pip module is not installed '
      exit $?
  fi

  if python3 -c "import jmespath" &> /dev/null; then
    echo 'jmespath pip module is installed '
  else
      echo 'jmespath pip module is not installed '
      exit $?
  fi
}

function run_tags(){
  if [ ! -f /tmp/tags ];
  then 
    touch /tmp/tags.temp
  fi 

  case $1 in
    ACM_WORKLOADS) echo -n "quay gogs pipelines gitops acm-workload " >> /tmp/tags.temp ;;
    AMQ_STREAMS) echo -n "amq " >> /tmp/tags.temp ;;
    CONFIGURE_POSTGRES) echo -n "postgres " >> /tmp/tags.temp ;;
    MONGODB_OPERATOR) echo -n "mongodb-operator " >> /tmp/tags.temp ;;
    MONGODB) echo -n "mongodb " >> /tmp/tags.temp ;;
    HELM_DEPLOYMENT) echo -n "helm " >> /tmp/tags.temp ;;
  esac
}

if [ -z "$1" ];
then
  usage
  exit 1
fi

while getopts ":d:t:s:h:u:" arg; do
  case $arg in
    h) export  HELP=True;;
    d) export  DOMAIN=$OPTARG;;
    t) export  OCP_TOKEN=$OPTARG;;
    s) export  STORE_ID=$OPTARG;;
    u) export  DESTROY=$OPTARG;;
  esac
done

echo "${DESTROY}"

if [ -z "${DESTROY}" ];
then 
  export DESTROY=false
elif [ "${DESTROY}" != true ];
then
  echo "Incorrect destory setting passed"
  usage
  exit 0
fi

if [[ "$1" == "-h" ]];
then
  usage
  exit 0
fi

export GROUP=$(id -gn)
export USERNAME=$(whoami)

function install_ansible() {
  echo "Ansible is not installed. Installing Ansible..."
  source /etc/os-release

  if [[ "$ID" == "rhel" || "$ID" == "centos" ]]; then
    sudo yum install -y ansible-core
  elif [[ "$ID" == "ubuntu" ]]; then
    echo "Ansible is not installed. Installing Ansible..."
    sudo apt-get update && sudo apt-get install -y python3-pip
    sudo pip3 install ansible
    pwd
    git clone https://github.com/ansible-collections/kubernetes.core.git && \
    mkdir -p /home/runner/work/.ansible/plugins/modules && \
    cp kubernetes.core/plugins/action/k8s.py /home/runner/work/.ansible/plugins/modules/ 
    ansible-galaxy collection install community.kubernetes
    ansible-galaxy collection install kubernetes.core
    ansible-galaxy collection install cloud.common
    ansible-galaxy collection install community.general
    pip3 install kubernetes || exit $?
    pip3 install openshift || exit $?
    pip3 install jmespath || exit $?

  elif [[ "$ID" == "darwin" ]]; then
    if ! command -v brew &> /dev/null; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install ansible
  else
    echo "Unsupported OS: $ID. Please install Ansible manually."
    exit 1
  fi

  echo "Ansible installed successfully."
  whereis ansible
}

function modulecheck(){
  local value=$(eval echo \$${1})
  if [[ $value =~ ^[Yy]$ ]]; then
    run_tags ${1}
  fi
}

echo -e "\n$DOMAIN  $OCP_TOKEN  $STORE_ID\n"

if [ -f $HOME/env.variables ];
then 
  source  $HOME/env.variables
  for p in $(cat $HOME/env.variables)
  do 
      VALUE=$(echo $p | cut -d '=' -f 2)
      ITEM=$(echo $p | cut -d '=' -f 1)
      case $VALUE in
        [Yy]* ) run_tags ${ITEM};;
        [Nn]* ) continue;;
        * ) echo "Please answer yes or no.";;
    esac
  done
  x=$(for i in $(cat /tmp/tags.temp); do echo -n "${i}",; done| sed 's/,$//') ; echo  $x > /tmp/tags
  rm -rf /tmp/tags.temp
else
  tags=( "ACM_WORKLOADS" "AMQ_STREAMS" "CONFIGURE_POSTGRES" "MONGODB_OPERATOR" "MONGODB" "HELM_DEPLOYMENT")
  for i in "${tags[@]}"
  do
    modulecheck ${i}

  done
  x=$(for i in $(cat /tmp/tags.temp); do echo -n "${i}",; done| sed 's/,$//') ; echo  $x > /tmp/tags
  rm -rf /tmp/tags.temp

fi

OC_VERSION=$(oc version  | grep Client | awk '{print $3}' | grep -oE "4.[0-20][0-9]")
if [ -z "${OC_VERSION}" ];
then
  OC_VERSION=$(oc version  | grep Client | grep -o  "[4].[*]")
  exit 
fi

if [ $OC_VERSION == '4.8' ];
then 
  QUAY_URL="quayecosystem-quay-{{ quay_project_name }}.router-default"
else
  QUAY_URL="quayecosystem-quay-{{ quay_project_name }}"
fi 

cat >/tmp/deploy-quarkus-shop.yml<<YAML
- hosts: localhost
  become: yes
  vars:
    openshift_token: ${OCP_TOKEN}
    openshift_url: https://api.${DOMAIN}:6443
    insecure_skip_tls_verify: true
    default_owner: ${USERNAME}
    default_group: ${GROUP}
    project_namespace: quarkusdroneshop-demo
    delete_deployment: "${DESTROY}"
    domain: ${DOMAIN}
    storeid: ${STORE_ID}
    oc_version: ${OC_VERSION}
    quay_urlprefix: ${QUAY_URL}
  roles:
    - quarkusdroneshop-ansible
YAML

cat /tmp/deploy-quarkus-shop.yml
sleep 3s 

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     machine=Linux;;
    Darwin*)    machine=Mac;;
    CYGWIN*)    machine=Cygwin;;
    MINGW*)     machine=MinGw;;
    *)          machine="UNKNOWN:${unameOut}"
esac


if [ "${machine}" == 'Linux' ] && [ -f /bin/ansible ];
then 
  if [ "${DESTROY}" == false ];
  then 
    configure-ansible-and-playbooks
  else 
    destory_drone_shop
  fi
elif [ "${machine}" == 'Mac' ] && [ -f /usr/local/bin/ansible ];
then
  if [ "${DESTROY}" == false ];
  then 
    configure-ansible-and-playbooks
  else 
    destory_drone_shop
  fi
else 
  install_ansible
fi 


if [ "${machine}" == 'Linux' ]; then
  if [ -f /bin/ansible ] || [ -f /usr/bin/ansible ] || [ -f /usr/local/bin/ansible ]; then
    if [ "${DESTROY}" == false ]; then
      configure-ansible-and-playbooks
    else
      destory_drone_shop
    fi
  else
    install_ansible
  fi
elif [ "${machine}" == 'Mac' ]; then
  if command -v ansible &> /dev/null; then
    if [ "${DESTROY}" == false ]; then
      configure-ansible-and-playbooks
    else
      destory_drone_shop
    fi
  else
    install_ansible
  fi
else
  echo "Unsupported OS. Please install Ansible manually."
  exit 1
fi
