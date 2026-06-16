
```sh
docker compose run --rm --entrypoint sh tf

k get nodes

kubectl create deployment nginx --image=nginx:latest
kgp -w

kubectl expose deployment nginx \
  --port=80 \
  --target-port=80 \
  --type=LoadBalancer \
  --name=nginx-lb

kubectl get svc nginx-lb -w
```

alb controller
```sh
# verify
# if you see 2/2 => AWS Load Balancer Controller is now Terraform-managed and healthy.
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer


helm uninstall aws-load-balancer-controller -n kube-system
```

Current Terraform milestone:
- EKS cluster
- VPC/subnets
- Managed node group
- Helm/Kubernetes providers
- AWS Load Balancer Controller IRSA
- AWS Load Balancer Controller Helm release


Since our app depends on AWS Secrets Manager, next highest-ROI add-on to move into Terraform: `External Secrets Operator + its IAM role`

```sh
# verify
kubectl get pods -n external-secrets
kubectl get sa external-secrets -n external-secrets -o yaml | grep role-arn -A1

# external-secrets pods Running
# service account annotated with IAM role
```

# MiSK
```sh
git push --force origin main

terraform force-unlock 678ee348-a78e-e4c7-23f5-c2fcd618b128
```
