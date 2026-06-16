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

docker tag jerney-backend:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-backend:v1
docker tag jerney-frontend:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-frontend:v1

docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-backend:v1
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/jerney-frontend:v1

```

## EKS

```sh
source .env

eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --version 1.35 \
  --nodes 1 \
  --node-type t3.medium \
  --managed \
  --spot

# ❌ DELETE the cluster ❌
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION

aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# in case the node goes down (we're using spot instance to save cost)
# fire up another one immediately:
eksctl create nodegroup \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --node-type t3.medium \
  --nodes 1 \
  --managed \
  -- spot
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
helm uninstall jerney -n jerney
# release "jerney" uninstalled
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

# verify 2/2
kubectl get deployment -n kube-system aws-load-balancer-controller

helm list -n kube-system
# NAME                            NAMESPACE     REVISION   UPDATED                   STATUS      CHART                                APP VERSION
# aws-load-balancer-controller    kube-system   1          2026-06-15 19:42:26 UTC   deployed    aws-load-balancer-controller-3.4.0   v3.4.0

helm history aws-load-balancer-controller -n kube-system
# REVISION        UPDATED                         STATUS          CHART                                   APP VERSION     DESCRIPTION
# 1               Mon Jun 15 19:42:26 2026        deployed        aws-load-balancer-controller-3.4.0      v3.4.0          Install complete
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

## HPA

```sh
# render
helm template jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml

# deploy
helm upgrade jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml

# check
kubectl get pods -n jerney
kubectl get hpa -n jerney
kubectl describe hpa jerney-backend -n jerney
kubectl describe hpa jerney-frontend -n jerney
```


```sh
kubectl scale deployment jerney-frontend --replicas=1 -n jerney

kubectl get hpa jerney-frontend -n jerney
```

## rolling updates and rollbacks (with Helm)
We'll add explicit rolling update settings to frontend/backend, deploy them through Helm, then simulate both a good rollout and a bad rollout so rollback becomes real rather than theoretical.

```sh
# deploy
helm upgrade jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml

# watch rollout
kubectl rollout status deployment/jerney-frontend -n jerney
kubectl rollout status deployment/jerney-backend -n jerney

# check strategy
kubectl describe deployment jerney-frontend -n jerney | grep -A5 Strategy

# simulate a bad rollout:
helm upgrade jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml \
  --set frontend.image=nginx:does-not-exist

# watch
kubectl get pods -n jerney -w
kubectl rollout status deployment/jerney-frontend -n jerney

# You should see the new pod fail with image pull errors, 
# while the old frontend pod stays running because: `maxUnavailable: 0`

```

Now rollback:
```sh
helm history jerney -n jerney
# REVISION        UPDATED                     STATUS          CHART           DESCRIPTION                                                               
# 1               Sun Jun 14 17:57:13 2026    superseded      jerney-0.1.0    Release "jerney" failed: 1 error occurred:                                
#                                                                                      * networkpolicies.networking....    
# 2               Sun Jun 14 18:31:05 2026    superseded      jerney-0.1.0    1.0.0           Upgrade complete
# 3               Sun Jun 14 18:32:34 2026    deployed        jerney-0.1.0    1.0.0           Upgrade complete


# 👉 roll back to revision 2:
helm rollback jerney 2 -n jerney

helm history jerney -n jerney
# ...
# 4               Sun Jun 14 18:54:19 2026     deployed        jerney-0.1.0    1.0.0           Rollback to 2 

# watch it recover:
kubectl get pods -n jerney -w
```

What we just proved: 👇
```yml
bad image deployed
  ↓
new ReplicaSet cannot become ready
  ↓
old frontend pod stays running because maxUnavailable=0
  ↓
service remains available
  ↓
helm rollback returns chart values/manifests to revision 2
```

📢 Important lesson: 
Helm marked `revision 3` as deployed because Kubernetes accepted the manifests. Helm does not automatically know the rollout failed unless we use `--wait`.

```sh
helm upgrade jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml \
  --set frontend.image=nginx:does-not-exist \
  --wait \
  --timeout 2m
```
Better production command (this should become `the default deploy command`)
`--atomic` means: if the upgrade fails, Helm automatically rolls back.
```sh
helm upgrade --install jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml \
  --set frontend.image=nginx:does-not-exist \
  --wait \
  --atomic \
  --timeout 5m

# Error: UPGRADE FAILED: release jerney failed, and has been rolled back due to atomic being set: context deadline exceeded

# 5           Sun Jun 14 19:06:34 2026        pending-upgrade jerney-0.1.0      Preparing upgrade

# 👇

# 5           Sun Jun 14 19:06:34 2026        failed          jerney-0.1.0      Upgrade "jerney" failed: context deadline exceeded                        
# 6           Sun Jun 14 19:11:35 2026        deployed        jerney-0.1.0      Rollback to 4
```

That is exactly the behavior we wanted to see.
```sh
revision 4 = known good release
revision 5 = attempted bad upgrade with nginx:does-not-exist
revision 5 = failed because --wait timed out
revision 6 = automatic rollback to revision 4 because --atomic was set
```

What Helm did for us:
```yml
bad upgrade attempted
  ↓
new frontend pod never became ready
  ↓
--wait kept watching until timeout
  ↓
--atomic triggered rollback
  ↓
release returned to previous good state
```

Check final state:
```sh
kubectl get pods -n jerney
# frontend image
kubectl get deployment jerney-frontend -n jerney -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

curl -I http://jerney.54.83.241.104.nip.io
```

🎉🎉🎉 We've now covered `zero-downtime rolling updates` + `safe automatic rollback`.

## canary deployment

```sh
helm get values jerney -n jerney

```

50/50
```sh
helm upgrade jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml \
  --set canary.stableWeight=50 \
  --set canary.canaryWeight=50 \
  --wait \
  --atomic \
  --timeout 5m
```

```sh
kubectl run curltest \               
  --image=nicolaka/netshoot \
  --rm -it \
  -n jerney \
  -- sh

# inside the c 👇
curl -s http://jerney-frontend | grep -o '/assets/index-[^"]*\.js'
# /assets/index-DYab1QoI.js

curl -s http://jerney-frontend-canary | grep -o '/assets/index-[^"]*\.js'
# /assets/index-C5SBYYg_.js

curl -s http://jerney-frontend/assets/index-DYab1QoI.js | grep -o "Welcome to Jerney\|Start your Jerney"
# Welcome to Jerney

curl -s http://jerney-frontend-canary/assets/index-C5SBYYg_.js | grep -o "Welcome to Jerney\|Start your Jerney"
# Start your Jerney

```

```sh
for i in {1..50}; do
  curl -s -H "Cache-Control: no-cache" \
  "http://jerney.52.202.99.105.nip.io/?t=$i" \
  | grep -E "Welcome to Jerney|Start your Jerney"
done
```

## RDS

```sh
export VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

echo $VPC_ID

export NODE_SG=$(aws ec2 describe-security-groups \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:aws:eks:cluster-name,Values=$CLUSTER_NAME" \
  --query "SecurityGroups[0].GroupId" \
  --output text)

echo $NODE_SG

# create an RDS security group
export RDS_SG=$(aws ec2 create-security-group \
  --region "$AWS_REGION" \
  --group-name jerney-rds-sg \
  --description "Allow PostgreSQL from EKS nodes" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" \
  --output text)

echo $RDS_SG

# allow EKS nodes to connect to RDS:
aws ec2 authorize-security-group-ingress \
  --region "$AWS_REGION" \
  --group-id "$RDS_SG" \
  --protocol tcp \
  --port 5432 \
  --source-group "$NODE_SG"
```

Get private subnets and create DB subnet group:
```sh
aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[*].[SubnetId,MapPublicIpOnLaunch,AvailabilityZone]" \
  --output table

PRIVATE_SUBNETS=(${=$(aws ec2 describe-subnets \
  --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[?MapPublicIpOnLaunch==`false`].SubnetId' \
  --output text)})

print -l $PRIVATE_SUBNETS

aws rds create-db-subnet-group \
  --region "$AWS_REGION" \
  --db-subnet-group-name jerney-rds-subnets \
  --db-subnet-group-description "Private subnets for Jerney RDS" \
  --subnet-ids $PRIVATE_SUBNETS
```
Create RDS PostgreSQL
```sh
aws rds create-db-instance \
  --region "$AWS_REGION" \
  --db-instance-identifier jerney-pg \
  --db-instance-class db.t4g.micro \
  --engine postgres \
  --engine-version 16 \
  --allocated-storage 20 \
  --storage-type gp3 \
  --master-username jerney_user \
  --master-user-password "$RDS_PASSWORD" \
  --db-name jerney_db \
  --vpc-security-group-ids "$RDS_SG" \
  --db-subnet-group-name jerney-rds-subnets \
  --no-publicly-accessible \
  --backup-retention-period 1 \
  --deletion-protection

# wait
aws rds wait db-instance-available \
  --region "$AWS_REGION" \
  --db-instance-identifier jerney-pg

# change password -----
aws rds modify-db-instance \
  --region "$AWS_REGION" \
  --db-instance-identifier jerney-pg \
  --master-user-password 'ChangeM3' \
  --apply-immediately

# wait until available
aws rds wait db-instance-available \
  --region "$AWS_REGION" \
  --db-instance-identifier jerney-pg
```

Get endpoint:
```sh
export RDS_ENDPOINT=$(aws rds describe-db-instances \
  --region "$AWS_REGION" \
  --db-instance-identifier jerney-pg \
  --query "DBInstances[0].Endpoint.Address" \
  --output text)

echo $RDS_ENDPOINT
```

Test from inside the cluster
```sh
kubectl run pgtest \
  --image=postgres:16-alpine \
  --rm -it \
  -n jerney \
  --env="RDS_ENDPOINT=$RDS_ENDPOINT" \
  -- sh

# inside:
psql "postgresql://jerney_user:ChangeM3@${RDS_ENDPOINT}:5432/jerney_db"

#TODO:
# psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory
#         Is the server running locally and accepting connections on that socket?
```


Deploy
```sh
# inspect env variables:
kubectl get deploy jerney-backend -n jerney -o yaml | grep -A40 "env:"

# debug mode
helm upgrade --install jerney ./charts/jerney \
  -n jerney \
  --create-namespace \
  -f charts/jerney/values-dev.yaml \
  --set-string externalDatabase.host="$RDS_ENDPOINT" \
  --set-string externalDatabase.password="$RDS_PASSWORD" \
  --wait \
  --timeout 10m \
  --debug

# prod mode
helm upgrade jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml \
  --set externalDatabase.host="$RDS_ENDPOINT" \
  --set externalDatabase.password="$RDS_PASSWORD" \
  --wait \
  --atomic \
  --timeout 2m
```

### RDS cleanup
If deletion protection is enabled, run this first:
```sh
aws rds modify-db-instance \
  --region "$AWS_REGION" \
  --db-instance-identifier jerney-pg \
  --no-deletion-protection \
  --apply-immediately

```

Cleanup
```sh
# chmod +x delete-rds.sh

export AWS_REGION=us-east-1 ./delete-rds.sh
```

## DB SECRET

### existingSecret
Helm uses a secret that already exists and doesn't need to know the password value.

Change backend DB_PASSWORD to 👇:
```yml
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ default (printf "%s-secret" .Values.externalDatabase.name) .Values.externalDatabase.existingSecret }}
      key: POSTGRES_PASSWORD

```
It's actually recommend to avoid the one-liner above. Make the logic explicit; it's much easier to read and maintain:
```yml
{{- if .Values.externalDatabase.existingSecret }}
name: {{ .Values.externalDatabase.existingSecret }}
{{- else }}
name: {{ .Values.externalDatabase.name }}-secret
{{- end }}
```

Create the secret outside Helm:
```sh
kubectl create secret generic jerney-ext-db-secret \
  -n jerney \
  --from-literal=POSTGRES_PASSWORD="$RDS_PASSWORD"
```

Then deploy without passing password:
```sh
# kubectl create namespace jerney

helm upgrade --install jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml \
  --set-string externalDatabase.host="$RDS_ENDPOINT" \
  --wait
```

### AWS Secrets Manager + External Secrets Operator

The flow 👇
```yml
AWS Secrets Manager
  ↓
External Secrets Operator
  ↓
ExternalSecret
  ↓
Kubernetes Secret
  ↓
backend DB_PASSWORD
```
ESO's AWS provider supports Secrets Manager, and EKS should use IRSA so the ESO pod can read AWS secrets without static AWS keys.

1) Create secret in AWS Secrets Manager
```sh
aws secretsmanager create-secret \
  --region "$AWS_REGION" \
  --name jerney/dev/rds \
  --secret-string '{"POSTGRES_PASSWORD":"ChangeM3"}'

# {
#     "ARN": "arn:aws:secretsmanager:us-east-1:865274826587:secret:jerney/dev/rds-sAWbjI",
#     "Name": "jerney/dev/rds",
#     "VersionId": "61de0187-1e0d-4ba6-ac89-f1552aa09fc7"
# }

# If it already exists -----
aws secretsmanager put-secret-value \
  --region "$AWS_REGION" \
  --secret-id jerney/dev/rds \
  --secret-string '{"POSTGRES_PASSWORD":"ChangeM3"}'

```

2) Install ESO
```sh
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait
```

3) Create IAM policy for ESO
```sh
cat > /tmp/eso-secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:jerney/dev/rds-*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name JerneyESOSecretsPolicy \
  --policy-document file:///tmp/eso-secrets-policy.json

```

4) Give ESO access through IRSA
```sh
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --approve

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace external-secrets \
  --name external-secrets \
  --role-name JerneyExternalSecretsRole \
  --attach-policy-arn arn:aws:iam::$AWS_ACCOUNT_ID:policy/JerneyESOSecretsPolicy \
  --override-existing-serviceaccounts \
  --approve
```
Restart ESO so it uses the annotated service account:
```sh
kubectl rollout restart deployment external-secrets -n external-secrets
kubectl rollout status deployment external-secrets -n external-secrets
```

5) Add `SecretStore` & `ExternalSecret`

6) Update `values.yaml`
```yml
externalDatabase:
  existingSecret: jerney-ext-db-secret

externalSecrets:
  enabled: true
  name: jerney-rds-password
  secretStoreName: aws-secrets-manager
  region: us-east-1
  awsSecretName: jerney/dev/rds
```


7) Deploy without passing password
```sh
helm upgrade --install jerney ./charts/jerney \
  -n jerney \
  -f charts/jerney/values-dev.yaml \
  --set-string externalDatabase.host="$RDS_ENDPOINT" \
  --set-string externalSecrets.region="$AWS_REGION" \
  --wait \
  --atomic \
  --timeout 5m

# check
kubectl get secretstore,externalsecret -n jerney
kubectl describe externalsecret jerney-rds-password -n jerney
kubectl get secret jerney-ext-db-secret -n jerney
```

✅ Now Helm no longer receives, renders, or stores the DB password.

## GHA

The flow:
```yml
                 Push / PR
                      │
                      ▼
              GitHub Actions CI
                      │
      ┌───────────────┼────────────────┐
      │               │                │
      ▼               ▼                ▼
  Lint & Test    Security Scan    Helm Validation
      │               │                │
      └───────────────┼────────────────┘
                      ▼
              Build Docker images
                      │
                      ▼
             Push images to ECR
                      │
                      ▼
          (Later) Argo CD deploys them
```

❌❌❌ Never put long-lived AWS credentials into GitHub. ❌❌❌

```yml
GitHub Actions
        │
        │  OIDC token
        ▼
AWS IAM Role
        │
 AssumeRoleWithWebIdentity
        │
        ▼
Temporary credentials
        │
        ▼
Push to ECR
```

The workflow never stores AWS keys. Instead:
- GitHub proves its identity to AWS using OIDC.
- AWS verifies the token.
- AWS issues temporary credentials (typically valid for about an hour).
- Those credentials are used to push images.

Create GitHub OIDC provider in AWS. If it already exists, that's fine.
```sh
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Create trust policy
```sh
cat > /tmp/github-actions-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/main"
        }
      }
    }
  ]
}
EOF

# Create IAM role:
aws iam create-role \
  --role-name GitHubActionsJerneyECRRole \
  --assume-role-policy-document file:///tmp/github-actions-trust-policy.json
```

Create ECR push policy
```sh
cat > /tmp/github-actions-ecr-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories"
      ],
      "Resource": [
        "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/jerney-backend",
        "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/jerney-frontend"
      ]
    }
  ]
}
EOF

# attach it
aws iam put-role-policy \
  --role-name GitHubActionsJerneyECRRole \
  --policy-name GitHubActionsJerneyECRPushPolicy \
  --policy-document file:///tmp/github-actions-ecr-policy.json

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
