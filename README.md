# devsecops-blog

## docker dev

```sh
docker compose up --build

curl -I localhost:3000
# HTTP/1.1 200 OK
# Vary: Origin
# Content-Type: text/html
# Cache-Control: no-cache
# Etag: W/"410-dc8GlWxr3oBZmjjsxWHBp1xIoCk"
# Date: Fri, 12 Jun 2026 11:42:57 GMT
# Connection: keep-alive
# Keep-Alive: timeout=5
```


Now you can access the app in `http://54.160.201.251:3000/`

NOTE: The `PORTS` column in `docker p`s shows how ports inside the container are exposed to your host machine.
For example, for our `frontend`:
```yml
PORTS
0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp, 5173/tcp
```

Here's what each part means.
1) `0.0.0.0:3000->3000/tcp`
Host port 3000 is forwarded to port 3000 inside the container over TCP. Accessible from any IPv4 interface on your machine.

2) `[::]:3000->3000/tcp`
The same mapping for IPv6. Accessible on port 3000 via IPv6 addresses.

3) `5173/tcp`
The container exposes port 5173, but it is not published to the host. Other containers on the same Docker network may be able to use it, but your host cannot connect to it directly.


### Visual representation
```yml
                Host machine
         +-----------------------+
         |                       |
Browser -> localhost:3000        |
         |        |              |
         |        v              |
         +-----------------------+
                  |
                  | port mapping
                  v
         +-----------------------+
         | Docker container      |
         |                       |
         | 3000/tcp  <--- app    |
         | 5173/tcp  <--- exposed only internally
         +-----------------------+
```

## frontend

```js
// frontend/vite.config.js 

import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0', // only controls where Vite listens.
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://backend:5000', // controls where Vite forwards API requests
        changeOrigin: true,
      },
    },
  },
  preview: {
    host: '0.0.0.0',
    port: 3000,
  },
});
```

Test:
```sh
docker compose exec frontend wget -qO- http://backend:5000/api/health
# {"status":"ok","message":"Jerney API is vibing ✨"}%
```

## db

```sh
docker compose exec postgres psql -U jerney_user -d jerney_db
# psql (16.14)
# Type "help" for help.

# jerney_db=# \dt
#             List of relations
#  Schema |   Name   | Type  |    Owner    
# --------+----------+-------+-------------
#  public | comments | table | jerney_user
#  public | posts    | table | jerney_user
```

## nginx (production setup)

With Nginx, we don't run `npm run dev`. Instead, we build the app once: `npm run build`.
This produces sth like:
```yml
dist/
  index.html
  assets/
```

Then we copy those files into the Nginx image:
```Dockerfile
COPY --from=build /app/dist /usr/share/nginx/html
```
At runtime, Nginx simply serves those static files. There's no file watching or live recompilation.

Basically, in production:
- `npm run build`
- Nginx serves optimized static assets
- No source-code volumes needed
- Smaller, more secure, and more efficient runtime image

NOTE: `npm ci` requires a `package-lock.json`
For production images, `npm ci` is better - than `npm install`, because it gives reproducible installs.


```sh
curl -i localhost
# HTTP/1.1 200 OK
# Server: nginx/1.31.1
# ...
```

## ECR

Login
```sh
aws ecr get-login-password --region $AWS_REGION | \
docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
```

```sh
docker build -f backend/Dockerfile -t jerney-backend ./backend
docker build -f frontend/Dockerfile -t jerney-frontend ./frontend

docker tag jerney-backend:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-backend:latest
docker tag jerney-frontend:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-frontend:latest

docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-backend:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-frontend:latest

```

## EKS

```sh
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --nodes 1 \
  --node-type t3.small \
  --managed \
  --spot

# ❌ DELETE the cluster ❌
# eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION

aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
```

### ddx
ERR:
```sh
host not found in upstream "backend" in /etc/nginx/conf.d/default.conf:9
```

Nginx is trying to proxy to a DNS name called `backend`, but Kubernetes cannot resolve `backend` in the `jerney` namespace.

You probably need the `nginx upstream` to use the Kubernetes Service name, e.g.:
```sh
kubectl get svc -n jerney
# NAME              TYPE           CLUSTER-IP       EXTERNAL-IP
# jerney-backend    ClusterIP      10.100.100.106   <none>  
```
In `frontend/nginx.conf`:
```nginx
proxy_pass http://jerney-backend:PORT;
```

Investigate the frontend image:
```sh
kubectl run nginx-debug \
  -n jerney \
  --rm -it \
  --restart=Never \
  --image=865274826587.dkr.ecr.us-east-1.amazonaws.com/jerney-frontend:v2 \
  -- sh

cat /etc/nginx/conf.d/default.conf
nginx -T
ls -la /etc/nginx/conf.d/
```

### pg
For fastest progress, we'll use ephemeral Postgres storage.
```yml
# k8s/postgres.yaml

volumes:
  - name: postgres-data
    emptyDir: {}
```
`emptyDir`: The DB data lives inside the running Postgres pod's temporary volume. It will disappear if the Postgres pod is deleted/recreated.

Verify:
```sh
POSTGRES_POD=$(kubectl get pod -n jerney -l app=jerney-postgres -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it $POSTGRES_POD -n jerney -- \
  psql -U jerney_user -d jerney_db

# jerney_db=# \dt
#             List of relations
#  Schema |   Name   | Type  |    Owner    
# --------+----------+-------+-------------
#  public | comments | table | jerney_user
#  public | posts    | table | jerney_user

```

## StatefulSet with a PVC

### EBS CSI driver
The Container Storage Interface (CSI) driver is the plugin that teaches Kubernetes how to talk to AWS EBS.
```yml
StatefulSet
     │
     ▼
Creates PVC
     │
     ▼
StorageClass (gp3)
     │
     ▼
EBS CSI Driver
     │
     ▼
AWS EC2 API
     │
     ▼
Creates an EBS volume
     │
     ▼
Creates a PV and binds it to the PVC
     │
     ▼
Mounts the volume into your Pod
```

AWS recommends installing [the EBS CSI driver](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html) as an EKS add-on.
```sh
# Check whether OIDC exists:
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve

# Create the IAM service account for the EBS CSI controller:
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve

# Install the EKS add-on:
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --service-account-role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole \
  --force

# verify
eksctl get addon \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --name aws-ebs-csi-driver

kubectl get pods -n kube-system \
  -l app.kubernetes.io/name=aws-ebs-csi-driver


```

## Helm

```sh
# check rendered YAML before applying
mkdir -p helm/jerney/templates

helm template jerney ./charts/jerney

# install
helm install jerney ./charts/jerney \
  --namespace jerney \
  --create-namespace

# or simply:
helm upgrade --install jerney ./charts/jerney \
  -n jerney \
  --create-namespace

helm list

# upgrade after changes:
helm upgrade jerney ./charts/jerney -n jerney

# check
kubectl get all,pvc,storageclass -n jerney
kubectl get all -n jerney

# uninstall
# helm uninstall jerney -n jerney ❌
helm uninstall jerney -n default
```


```sh
helm template jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml

# If it renders cleanly, install with dev values
helm upgrade --install jerney ./charts/jerney \
  -n jerney \
  --create-namespace \
  -f charts/jerney/values-dev.yaml
```

## NetworkPolicy

Our current topology is effectively:
```yml
                Internet
                    │
                    ▼
          LoadBalancer (frontend)
                    │
                    ▼
              frontend pod
                    │
                    ▼
              backend pod
                    │
                    ▼
              postgres pod

AND ALSO...

Any Pod ───────────────────────────────► Postgres ✅
Any Pod ───────────────────────────────► Backend ✅
Backend ───────────────────────────────► Frontend ✅
Frontend ──────────────────────────────► Postgres ✅
```

Next we'll lock down traffic inside the namespace.
> The goal is simple: frontend can talk to backend, backend can talk to Postgres, and random pods cannot directly hit the database.

Important: **NetworkPolicy** only works if your EKS networking supports it. With AWS VPC CNI, you may need network policy support enabled, or use a CNI like Calico/Cilium.

```sh
kubectl get networkpolicy -n jerney
kubectl describe networkpolicy jerney-network-policy -n jerney
```

Launch a throwaway pod:
```sh
kubectl run attacker \
  --image=nicolaka/netshoot \
  --rm -it \
  -n jerney \
  -- /bin/bash


attacker:~# nc -zv jerney-pg 5432
# Connection to jerney-pg (192.168.25.97) 5432 port [tcp/postgresql] succeeded!

# ⚠️ That pod was never supposed to have database access, but it does.
```


```sh
aws eks update-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name vpc-cni \
  --configuration-values '{"enableNetworkPolicy":"true"}' \
  --resolve-conflicts OVERWRITE

# restart the CNI pods:
kubectl rollout restart daemonset aws-node -n kube-system
kubectl rollout status daemonset aws-node -n kube-system

# verify the network policy agent appears:
kubectl get pods -n kube-system -l k8s-app=aws-node
kubectl describe daemonset aws-node -n kube-system | grep -i policy -A5

```
One more important detail: 
AWS notes NetworkPolicies apply to Pods that are part of a controller like a Deployment; standalone Pods may not be enforced the same way. So for a better attacker test, use a Deployment:

```sh
kubectl create deployment attacker \
  --image=nicolaka/netshoot \
  -n jerney \
  -- sleep infinity

kubectl exec -it deploy/attacker -n jerney -- nc -zv -w 5 jerney-pg 5432
# nc: connect to jerney-pg (192.168.25.97) port 5432 (tcp) timed out: Operation in progress
# command terminated with exit code 1

# cleanup
kubectl delete deployment attacker -n jerney
```

```sh
attacker:~# nc -zv jerney-pg 5432
# nc: connect to jerney-pg (192.168.25.97) port 5432 (tcp) failed: Operation timed out
```

## ingress

### install AWS Load Balancer Controller

```sh
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve

curl -o iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

rm iam_policy.json

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# verify
kubectl get deployment -n kube-system aws-load-balancer-controller
```
### Deploy

`alb.ingress.kubernetes.io/scheme: internet-facing` makes an external ALB, and `alb.ingress.kubernetes.io/target-type: ip` routes traffic directly to pods.

```sh
helm upgrade jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml

# get the ALB address
kubectl get ingress -n jerney

# get one IP:
dig +short $ALB | head -n1
```


## MiSK

### .dockerignore

Why it helps

Without a `.dockerignore`, when Docker executes:
```Dockerfile
COPY . .
```
it sends everything in the build context to the Docker daemon, including things like:

- node_modules/
- .git/
- log files
- build artifacts
- local environment files

This can:
- 🚀 Slow down builds.
- 📦 Make the build context unnecessarily large.
- 🔄 Cause unnecessary cache invalidation.
- 🔒 Accidentally copy sensitive files into images.
