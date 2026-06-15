# Lab 部署參考

## 既有 Namespace 重新部署

### 1. 讀取目前 Hosts
```bash
kubectl -n performance-test get ingress -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.rules[0].host}{"\n"}{end}'
kubectl -n performance-test2 get ingress -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.rules[0].host}{"\n"}{end}'
```

### 2. Build 與 Push Webapp Image
```bash
IMAGE_REPO='docker.io/isaac0815/jmeter-webapp'
IMAGE_TAG="$(date +%Y.%m.%d-%H%M%S)-reports-layout"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
podman build -f webapp/Dockerfile -t "$IMAGE" .
podman push "$IMAGE"
```

### 3. 重新部署 performance-test
```bash
./deploy_perf_stack.sh \
  --namespace performance-test \
  --helm-env lab \
  --report-host report.example.com \
  --grafana-host grafana.example.com \
  --webapp-host jmeter-web.example.com \
  --webapp-image-repository docker.io/isaac0815/jmeter-webapp \
  --webapp-image-tag "$IMAGE_TAG" \
  --telegraf-cluster-rbac true \
  --skip-dependency-build
```

### 4. 重新部署 performance-test2
```bash
./deploy_perf_stack.sh \
  --namespace performance-test2 \
  --helm-env lab \
  --report-host repor2.example.com \
  --grafana-host grafana2.example.com \
  --webapp-host jmeter-web2.example.com \
  --webapp-image-repository docker.io/isaac0815/jmeter-webapp \
  --webapp-image-tag "$IMAGE_TAG" \
  --telegraf-cluster-rbac false \
  --skip-dependency-build
```

### 5. 驗證
```bash
for ns in performance-test performance-test2; do
  echo "== $ns rollout =="
  kubectl -n "$ns" rollout status deploy/jmeter-webapp --timeout=180s
  echo "== $ns image =="
  kubectl -n "$ns" get deploy jmeter-webapp -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
  echo "== $ns ingress =="
  kubectl -n "$ns" get ingress -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.rules[0].host}{"\n"}{end}'
  echo
 done
```

## 全新部署

當 namespaces 尚不存在，或 prompt 明確表示這是首次 lab 部署時，使用這個流程。

### Primary Namespace 主 namespace
```bash
./deploy_perf_stack.sh \
  --namespace <primary-namespace> \
  --helm-env lab \
  --base-domain <domain> \
  --webapp-image-repository docker.io/isaac0815/jmeter-webapp \
  --webapp-image-tag "$IMAGE_TAG" \
  --telegraf-cluster-rbac true \
  --apply-env-resources
```

### Secondary Namespace 次要 namespace
```bash
./deploy_perf_stack.sh \
  --namespace <secondary-namespace> \
  --helm-env lab \
  --base-domain <domain> \
  --webapp-image-repository docker.io/isaac0815/jmeter-webapp \
  --webapp-image-tag "$IMAGE_TAG" \
  --telegraf-cluster-rbac false \
  --apply-env-resources
```

## 操作備註
- `deploy_perf_stack.sh` 已包含 `--reset-values`，因此升級時會把 env values 視為主要來源。
- 在這個 repo 裡，lab 一般不需要為 docker.io images 使用 image pull secrets。
- `telegraf-metrics-reader` 是 cluster-scoped 且共用的，只有 primary deployment 應建立 cluster-scoped telegraf RBAC。
- 既有 namespace 重新部署時，應保留目前的 ingress hosts，不要直接套用 values files 的預設值。
