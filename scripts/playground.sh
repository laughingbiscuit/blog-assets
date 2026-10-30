#!/bin/sh
set -ve

containerlab deploy -c -t lab.clab.yml

until docker exec clab-oak-client kubectl get node k3s-1 >/dev/null 2>&1; do
  sleep 5
done

docker exec clab-oak-client kubectl wait \
  --for=condition=Ready node/k3s-1 --timeout=300s

docker exec clab-oak-client kubectl get nodes -A -o wide
