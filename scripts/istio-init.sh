#!/usr/bin/env bash

set -e

if [[ ! -x "$(command -v kubectl)" ]]; then
    echo "kubectl not found"
    exit 1
fi

if [[ ! -x "$(command -v helm)" ]]; then
    echo "helm not found"
    exit 1
fi

VERSION=1.9.3
REPO_ROOT=$(git rev-parse --show-toplevel)

echo "version is --->${VERSION}"
echo "REPO_ROOT--> ${REPO_ROOT}"

curl -sL https://istio.io/downloadIstio | ISTIO_VERSION=${VERSION} sh -

#helm template ${REPO_ROOT}/istio-${VERSION}/manifests/charts/istio-operator > ${REPO_ROOT}/istio/operator/manifests.yaml
cd ..

cd scripts/istio-1.9.3/manifests/charts
echo "Istio operator ${VERSION} manifests generation starting"

helm template istio-operator > ${REPO_ROOT}/istio/operator/manifests.yaml
rm -rf ${REPO_ROOT}/istio-${VERSION}

echo "Istio operator ${VERSION} manifests updated"
 
