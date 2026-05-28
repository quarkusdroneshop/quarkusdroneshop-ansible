FROM --platform=linux/amd64 fedora:41

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Faster + stable mirrors
RUN sed -i 's|^metalink=|#metalink=|g' /etc/yum.repos.d/fedora*.repo && \
    sed -i 's|^#baseurl=http://download.example/pub/fedora/linux|baseurl=https://download.fedoraproject.org/pub/fedora/linux|g' /etc/yum.repos.d/fedora*.repo

# Base packages
RUN dnf -y update && \
    dnf install -y \
        bind-utils \
        openssl \
        openssh-clients \
        gawk \
        wget \
        curl \
        python3 \
        python3-pip \
        git \
        bash-completion \
        python3-jmespath \
        tar \
        gzip \
        unzip \
        which \
        findutils \
        ansible-core \
        --setopt=install_weak_deps=False && \
    dnf clean all && \
    rm -rf /var/cache/dnf

# OpenShift CLI install
RUN curl -OL \
    https://raw.githubusercontent.com/nmushino/openshift-4-deployment-notes/master/pre-steps/configure-openshift-packages.sh && \
    chmod +x configure-openshift-packages.sh && \
    bash ./configure-openshift-packages.sh --install

# Helm install (WITHOUT tar extraction issue)
RUN curl -L https://get.helm.sh/helm-v3.21.0-linux-amd64.tar.gz \
    -o /tmp/helm.tar.gz && \
    python3 - <<EOF
import tarfile
tar = tarfile.open('/tmp/helm.tar.gz')
tar.extractall('/tmp')
tar.close()
EOF
RUN mv /tmp/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -rf /tmp/linux-amd64 /tmp/helm.tar.gz

# kubernetes.core
RUN ansible-galaxy collection install kubernetes.core

RUN mkdir -p /opt/workspace && \
    git config --global user.email "demo@quarkus.io" && \
    git config --global user.name "Quarkus"

COPY . /opt/workspace
COPY files/env.variables /root/

WORKDIR /opt/workspace

CMD ["/opt/workspace/files/quickstart.sh"]