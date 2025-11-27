#!/bin/bash

cmd=$(readlink -f "${BASH_SOURCE[0]}")
patch_dir=${cmd%/*}
cat <&0 > ${patch_dir}/all.yaml

microk8s kubectl -n ais-xnat kustomize --enable-helm ${patch_dir} && rm ${patch_dir}/all.yaml
