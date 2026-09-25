#!/usr/bin/env bash
# Exposes the app at http://fsl-challenge.me on this machine.
#
# Both steps need root, which is the only reason this is a script rather than a
# documented kubectl command: binding port 80 and writing /etc/hosts are
# privileged operations.
#
#   ./k8s/expose-local.sh        # add hosts entry, then bind :80 (stays running)
#
# Ctrl-C stops the forward. The /etc/hosts line is left in place; remove it with
#   sudo sed -i '' '/fsl-challenge\.me/d' /etc/hosts
set -euo pipefail

HOST_NAME="fsl-challenge.me"
CONTEXT="minikube"

if grep -qE "^[^#]*[[:space:]]${HOST_NAME}([[:space:]]|$)" /etc/hosts; then
  echo "hosts entry for ${HOST_NAME}: already present"
else
  echo "adding '127.0.0.1 ${HOST_NAME}' to /etc/hosts (needs sudo)"
  printf '127.0.0.1\t%s\n' "${HOST_NAME}" | sudo tee -a /etc/hosts >/dev/null
fi

# sudo resets HOME, so kubectl would look for root's kubeconfig. Point it back at
# the invoking user's config explicitly.
echo "binding 127.0.0.1:80 -> ingress-nginx controller (needs sudo; Ctrl-C to stop)"
echo "then open http://${HOST_NAME}"
exec sudo env "KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}" \
  kubectl --context="${CONTEXT}" port-forward \
  -n ingress-nginx svc/ingress-nginx-controller 80:80 --address 127.0.0.1
