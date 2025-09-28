#!/usr/bin/env bash
#
# If not running under bash, re-exec with bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

# Fail fast on CRLF (Windows) endings, which can also trigger odd parse errors
case "$(head -c 2 "$0" | od -An -t x1 | tr -d ' ')" in
  *0d0a) echo "ERROR: Windows line endings detected. Run: dos2unix '$0'"; exit 2;;
esac

#
# makekubeconfig.sh
# ----------------------------------------------------
# Purpose:

mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
sudo chown 1000:1000 ~/.kube/config
command -v kubectl && ls -l /usr/local/bin/kubectl
kubectl get node -o wide

