FROM --platform=linux/amd64 fedora:latest

RUN dnf makecache && \
    dnf install -y \
        bind-utils \
        openssl \
        openssh-clients \
        gawk \
        wget \
        curl \
        python3-pip \
        git \
        bash-completion \
        python3-jmespath \
        ansible \
        --setopt=install_weak_deps=False && \
    dnf clean all && \
    rm -rf /var/cache/yum

# OpenShift tools install
RUN curl -OL \
    https://raw.githubusercontent.com/nmushino/openshift-4-deployment-notes/master/pre-steps/configure-openshift-packages.sh && \
    chmod +x configure-openshift-packages.sh && \
    bash -x ./configure-openshift-packages.sh --install

# Install helm WITHOUT tar extraction
RUN curl -L \
    https://get.helm.sh/helm-v3.21.0-linux-amd64.tar.gz \
    -o /tmp/helm.tar.gz && \
    mkdir -p /tmp/helm && \
    cd /tmp/helm && \
    python3 -c "import tarfile; tar = tarfile.open('/tmp/helm.tar.gz'); tar.extractall('/tmp/helm')" && \
    mv /tmp/helm/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -rf /tmp/helm /tmp/helm.tar.gz

# Ansible kubernetes.core plugin
RUN git clone https://github.com/ansible-collections/kubernetes.core.git && \
    mkdir -p /root/.ansible/plugins/modules && \
    cp kubernetes.core/plugins/action/k8s.py \
       /root/.ansible/plugins/modules/

RUN mkdir -p /opt/workspace && \
    git config --global user.email "demo@quarkus.io" && \
    git config --global user.name "Quarkus"

COPY . /opt/workspace
COPY files/env.variables /root/

WORKDIR /opt/workspace

CMD ["/opt/workspace/files/quickstart.sh"]