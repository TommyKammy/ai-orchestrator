# Build and push operator image
docker build -t executor-operator:latest -f Dockerfile.operator .
docker tag executor-operator:latest your-registry/executor-operator:v1.0.0
docker push your-registry/executor-operator:v1.0.0

# Build and push load balancer image
docker build -t executor-load-balancer:latest -f Dockerfile.loadbalancer .
docker tag executor-load-balancer:latest your-registry/executor-load-balancer:v1.0.0
docker push your-registry/executor-load-balancer:v1.0.0

# Build and push sandbox image
docker build -t executor-sandbox:latest -f executor/Dockerfile.sandbox executor/
docker tag executor-sandbox:latest your-registry/executor-sandbox:v1.0.0
docker push your-registry/executor-sandbox:v1.0.0

# OPA uses upstream image; apply manifest to deploy policy engine
kubectl apply -f opa-deployment.yaml
