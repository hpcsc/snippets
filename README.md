# Snippets

Snippets/scripts that I use often but don't belong to a particular repo

## scripts/export-kube-config.sh

### Usage

`./scripts/export-kube-config.sh [minikube|...]`

### What does it do

Extract a specific kube config context, replace any file reference with equivalent base64 encoded (.e.g. `.clusters[0].cluster.certificate-authority` is replaced with `.clusters[0].cluster.certificate-authority-data`).

This is useful in case you need a portable kube config with all necessary data embeded, e.g. when configuring a CI agent
