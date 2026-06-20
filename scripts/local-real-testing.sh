#!/bin/bash
# vim: filetype=bash

set -ex
cd "$(dirname "$0")/.."

TEST_NAMESPACE=test-tcpg-01
TEST_VALUES=./chart/values.local.yaml

set +x
read -rp "This will delete namespace '$TEST_NAMESPACE' and reinstall tcpg. Continue? [y/N] " reply
[[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
set -x

kubectl delete namespace $TEST_NAMESPACE || true

kubectl create namespace $TEST_NAMESPACE

helm upgrade --install \
    tcpg-test \
    ./chart \
    -n $TEST_NAMESPACE \
    --values $TEST_VALUES
