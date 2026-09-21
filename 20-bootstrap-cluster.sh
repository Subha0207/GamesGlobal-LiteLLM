#!/usr/bin/env bash
# Points kubectl at the cluster and installs the two controllers LiteLLM needs:
# the AWS Load Balancer Controller (creates the ALB that exposes the UI) and
# metrics-server (feeds the HPA).
source "$(dirname "$0")/lib.sh"

need kubectl; need helm; need aws

REGION="$(tf_out region)"
CLUSTER="$(tf_out cluster_name)"
VPC_ID="$(tf_out vpc_id)"
ALB_ROLE_ARN="$(tf_out alb_controller_role_arn)"

log "Updating kubeconfig for $CLUSTER"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"
kubectl get nodes

log "Installing the AWS Load Balancer Controller"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update >/dev/null

kubectl apply -f \
  https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-string serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ALB_ROLE_ARN" \
  --set externalManagedTags="{Owner,c7n-created-by,c7n-created-by-id,c7n-created-date}" \
  --set enableBackendSecurityGroup=false \
  --wait

log "Installing metrics-server (for the HPA)"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system --wait

log "Cluster bootstrapped"
kubectl -n kube-system get deploy aws-load-balancer-controller metrics-server
