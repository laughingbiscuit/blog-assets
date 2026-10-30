#!/bin/sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd $DIR
rm -f kubeconfig.yaml
containerlab deploy -c -t lab.clab.yml

for node in k3s-1 k3s-2 k3s-3; do
  echo "Waiting for $node..."
  until docker exec clab-oak-client kubectl wait \
    --for=condition=Ready "node/$node" --timeout=5s >/dev/null 2>&1; do
    sleep 3
  done
done

docker exec clab-oak-client kubectl get nodes -A -o wide
