# Ankole Helm Chart

[English](README.md)

本 Chart 部署开源版 Ankole 控制面和 Agent Computer Worker。它也可以部署
Ankole PostgreSQL 18 镜像。该镜像已包含 `pg_search` 和 `vector`。

## 前置条件

- Kubernetes 1.27 或更高版本。
- Helm 3 或更高版本。
- Linux `amd64` 或 `arm64` 节点池。
- 为 Agent Home 提供 `ReadWriteMany` StorageClass 或已有 RWX PVC。
- 为首次设置和 Console 浏览器流程提供 HTTPS Ingress。
- 根据模型负载提供足够的 CPU、内存和存储。

Worker security context 会添加 `SYS_ADMIN`，设置 `procMount: Unmasked`，并使用
不受限的 seccomp profile。请先确认集群准入策略允许这些设置。

## 使用内置 PostgreSQL 安装

先创建 namespace 和 bootstrap Secret。显式创建 Secret 可以避免首次安装失败后，
PostgreSQL PVC 保留旧密码，而下一次安装生成了新密码。

```sh
kubectl create namespace ankole

POSTGRES_PASSWORD="$(openssl rand -hex 24)"
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
ANKOLE_WORKER_AUTH_KEY="$(openssl rand -hex 24)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=${ANKOLE_WORKER_AUTH_KEY}" \
  --from-literal="DATABASE_URL=ecto://ankole:${POSTGRES_PASSWORD}@ankole-postgresql:5432/ankole"

unset POSTGRES_PASSWORD ANKOLE_SECRET_BASE ANKOLE_WORKER_AUTH_KEY
```

创建 `values-production.yaml`：

```yaml
fullnameOverride: ankole

secrets:
  existingSecret: ankole-bootstrap

controlPlane:
  publicHost: ankole.example.com

worker:
  agents:
    persistence:
      storageClass: nfs-rwx
      size: 100Gi

postgresql:
  enabled: true
  persistence:
    storageClass: standard
    size: 50Gi

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: ankole.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ankole-tls
      hosts:
        - ankole.example.com
```

替换域名、Ingress 配置和 StorageClass 名称。`fullnameOverride` 会把 PostgreSQL
Service 名称固定为 `ankole-postgresql`，与 Secret 中的地址一致。

安装：

```sh
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

迁移 init container 会创建两个必需的 PostgreSQL extension，并执行所有待执行的
Ecto migration。下一个 init container 会把部署提供的 Worker key 写入
AppConfigure。两个操作都成功后，控制面才会启动。

## 使用外部 PostgreSQL 安装

外部数据库必须是 PostgreSQL 18 或更高版本。它必须 preload `pg_search`，并且
应用数据库 owner 必须能使用 `pg_search` 和 `vector`。

安装前，在 `DATABASE_URL` 实际指向的服务器上执行：

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` 必须不小于 `180000`，`shared_preload_libraries` 必须包含
`pg_search`。

创建 Secret：

```sh
ANKOLE_SECRET_BASE="$(openssl rand -hex 32)"
ANKOLE_WORKER_AUTH_KEY="$(openssl rand -hex 24)"

kubectl -n ankole create secret generic ankole-bootstrap \
  --from-literal="ANKOLE_SECRET_BASE=${ANKOLE_SECRET_BASE}" \
  --from-literal="ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY=${ANKOLE_WORKER_AUTH_KEY}" \
  --from-literal="DATABASE_URL=ecto://ankole:REPLACE_ME@postgres.example.com:5432/ankole"

unset ANKOLE_SECRET_BASE ANKOLE_WORKER_AUTH_KEY
```

在 `values-production.yaml` 中设置：

```yaml
secrets:
  existingSecret: ankole-bootstrap

postgresql:
  enabled: false
```

然后执行与内置数据库方案相同的 Helm 安装命令。

## 首次设置

等待所有 workload：

```sh
kubectl -n ankole get pods
kubectl -n ankole rollout status deployment/ankole-control-plane --timeout=10m
kubectl -n ankole rollout status deployment/ankole-worker --timeout=10m
```

从控制面日志读取 activation code：

```sh
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

打开 `https://ankole.example.com/setup`，输入 code，选择 Control Plane Plugin，
然后配置管理员 identity provider。生产镜像使用 secure cookie，因此浏览器设置
流程必须使用 HTTPS。

设置完成后，通过 Console 配置 provider、model profile、Agent Library
capability、Agent、channel binding 和 WorkerEnv secret。不要把 provider API key
写进 Helm values。

## 镜像策略和升级

默认镜像是：

```text
ghcr.io/agentbull/ankole-agent-control-plane:main-latest
ghcr.io/agentbull/ankole-agent-computer-worker:main-latest
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

`main-latest` 跟随最近一次成功的 GitHub 发布。受控生产升级前，请解析并记录控制面
和 Worker digest，然后在同一个 values 文件版本中同时修改：

```yaml
controlPlane:
  image:
    digest: sha256:CONTROL_PLANE_DIGEST

worker:
  image:
    digest: sha256:WORKER_DIGEST
```

不要组合来自不同源码 revision 的控制面和 Worker digest。RuntimeFabric 会检查
协议版本，但相同源码 revision 还能保证完整运行时契约一致。

每次升级前备份 PostgreSQL 和 Agent Home，然后执行：

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

新控制面 Pod 会先执行 migration。Helm rollback 不会反向执行数据库 migration。
如果应用回滚还需要 schema 回滚，请恢复数据库备份。

Chart 对单个控制面 Pod 和 Worker 都使用 `Recreate`。升级会产生短暂服务中断，
但旧控制面不会在新版本修改数据库 schema 时继续运行。

## 存储和备份

Agent Home 是权威的 Worker 文件状态。Chart 强制使用 RWX PVC，并挂载到
`/agents`。Chart 创建的 Agent Home PVC 带有 Helm `keep` policy，因此
`helm uninstall` 不会删除它。

内置 PostgreSQL StatefulSet 在删除或缩容后保留 PVC。请单独备份数据库：

```sh
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  pg_dump -U ankole -d ankole -Fc > "ankole-$(date +%Y%m%d).dump"
```

同时使用存储供应商的 snapshot 机制保护 PostgreSQL 和 Agent Home volume。
请在独立安装中验证恢复流程。

## 日常运维

```sh
# 查看 workload
kubectl -n ankole get deployments,statefulsets,pods,pvc,ingress

# 控制面日志
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane -f

# Worker 日志
kubectl -n ankole logs deployment/ankole-worker -c worker -f

# 控制面 Pod 卡住时查看 migration 日志
kubectl -n ankole logs POD_NAME -c db-migrate

# 检查 PostgreSQL readiness 和 extension
kubectl -n ankole exec statefulset/ankole-postgresql -- \
  psql -U ankole -d ankole -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"
```

## 主要配置

| 配置 | 默认值 | 用途 |
| --- | --- | --- |
| `secrets.existingSecret` | 空 | 已有 bootstrap Secret |
| `controlPlane.image.tag` | `main-latest` | 可移动的 GitHub 镜像通道 |
| `controlPlane.image.digest` | 空 | 固定控制面镜像 |
| `controlPlane.publicHost` | `ankole.example.com` | Phoenix 对外域名 |
| `worker.image.digest` | 空 | 固定 Worker 镜像 |
| `worker.replicaCount` | `1` | Worker 进程数量 |
| `worker.agents.persistence.existingClaim` | 空 | 已有 RWX Agent Home PVC |
| `worker.agents.persistence.storageClass` | 空 | RWX StorageClass |
| `postgresql.enabled` | `true` | 部署内置 PostgreSQL |
| `postgresql.persistence.enabled` | `true` | 持久化内置 PostgreSQL |
| `ingress.enabled` | `false` | 创建 Ingress |

设置 `secrets.existingSecret` 后，Secret 必须包含：

- `ANKOLE_SECRET_BASE`
- `DATABASE_URL`
- `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`
- 使用内置 PostgreSQL 时还需要 `POSTGRES_PASSWORD`

没有设置已有 Secret 时，Chart 可以在安装时生成缺少的 secret，并在正常升级时
保留它们。生产恢复场景使用显式 secret 管理更安全。

## 故障排查

- Worker PVC 一直 Pending，通常表示 StorageClass 不支持 `ReadWriteMany`。
- `db-migrate` init container 卡住，通常表示 `DATABASE_URL` 错误、PostgreSQL
  尚未就绪，或者缺少必需 extension。
- Worker 正在运行但一直没有 ready，通常表示 RuntimeFabric key 错误，或者
  Worker 无法访问控制面 Service 的 `6010` 端口。
- 输入 activation code 后设置页面又回到原状态，通常表示 HTTPS 连接不受信任。
  请检查 Ingress certificate 和转发后的 host。
- Worker security context 被准入策略拒绝，表示集群不允许当前隔离设置。请使用
  专用受信任 Worker 节点池，或者使用经过批准的等效 sandbox profile。
