export CLUSTER_NAME=nkp-mgmt-shiv
export NAMESPACE=kommander
export AWS_ID=
export AWS_SECRET=

kubectl create secret generic ${CLUSTER_NAME}-loki-obj-creds \
-n ${NAMESPACE} \
--from-literal=AWS_ACCESS_KEY_ID=${AWS_ID} \
--from-literal=AWS_SECRET_ACCESS_KEY=${AWS_SECRET}
