#!/bin/bash
# Helm post-renderer script for kustomize patches
# Used with: helm install ... --post-renderer ./kustomize.sh

cmd=$(readlink -f "${BASH_SOURCE[0]}")
patch_dir=${cmd%/*}
cat <&0 > ${patch_dir}/all.yaml

kubectl -n ais-xnat kustomize --enable-helm ${patch_dir} && rm ${patch_dir}/all.yaml
