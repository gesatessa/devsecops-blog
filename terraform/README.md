
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
# verify 2/2
kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl get pods -n kube-system | grep aws-load-balancer


helm uninstall aws-load-balancer-controller -n kube-system
```
