---
title: 安装部署
description: 使用 Docker Compose 在单机部署 Ankole，或使用公开 Helm Chart 部署到 Kubernetes。
section: Operations
order: 3
---

一套 Ankole 生产部署包含控制面、一个或多个 Agent Computer Worker、PostgreSQL
和持久化 Agent Home。请选择一种受支持的部署包：

- **Docker Compose** 用于单台 Linux 主机。它包含 PostgreSQL、migration、
  Worker key bootstrap、一个 Worker 和 Caddy HTTPS。
- **Helm** 用于 Kubernetes。它支持内置或外部 PostgreSQL，并要求 Agent Home
  使用共享 `ReadWriteMany` 存储。

两种部署默认使用 GitHub Container Registry 中最新的已验证镜像：

```text
ghcr.io/agentbull/ankole-agent-control-plane:main-latest
ghcr.io/agentbull/ankole-agent-computer-worker:main-latest
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

发布工作流验证 RuntimeFabric 镜像配对成功后，才会同时移动控制面和 Worker tag。
受控生产发布应把两个 Ankole 镜像固定到同一组镜像的 digest。

## 使用 Docker Compose 单机部署

主机必须是 Linux `amd64` 或 `arm64`，已安装 Docker Engine 和 Docker Compose
plugin，并且有持久化本地存储和可用的 `80`、`443` 端口。

克隆仓库并准备部署配置：

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole/tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
```

生成三个独立的十六进制值：

```bash
openssl rand -hex 24
openssl rand -hex 32
openssl rand -hex 24
```

依次把它们写入 `.env` 的 `POSTGRES_PASSWORD`、`ANKOLE_SECRET_BASE` 和
`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`。把 `ANKOLE_HOST` 设置为指向该主机的
域名，并设置 `ACME_EMAIL`。不要把 provider API key 放进该文件；请在 Ankole
Console 中配置。

启动：

```bash
docker compose pull
docker compose up -d
docker compose ps
```

Compose 会等待 PostgreSQL 就绪，执行所有待执行 migration，写入 Worker
authentication key，然后启动控制面、Worker 和 Caddy。

读取首次设置 activation code：

```bash
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

打开 `https://<ANKOLE_HOST>/setup`。公网域名解析到当前主机后，Caddy 会自动
申请和续期 certificate。只在本机使用 `ankole.localhost` 时，请按照
[完整 Compose 部署说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/docker-compose/README.zh-Hans.md)
信任 Caddy 的本地 CA。生产设置流程必须使用受信任的 HTTPS。

### Compose 运维和升级

升级前创建数据库备份：

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

然后进行一次有短暂服务中断的升级：

```bash
docker compose pull
docker compose down
docker compose up -d --force-recreate
docker compose ps
```

`docker compose down` 会保留 named volume。`docker compose down -v` 会删除
PostgreSQL、Agent Home 和 Caddy 数据。只有明确要永久删除数据，并且已有经过
验证的备份时才能使用 `-v`。

## 使用 Helm 部署到 Kubernetes

公开 Chart 位于
[`tools/deploy/helm/ankole-agent`](https://github.com/AgentBull/ankole/tree/main/tools/deploy/helm/ankole-agent)。
它要求 Kubernetes 1.27 或更高版本、Helm 3 或更高版本、Linux `amd64` 或
`arm64` 节点、HTTPS Ingress，以及 Agent Home 使用的 RWX StorageClass 或已有
RWX PVC。

Chart 默认安装内置 PostgreSQL：

```yaml
postgresql:
  enabled: true
```

使用外部数据库时设置：

```yaml
postgresql:
  enabled: false

secrets:
  existingSecret: ankole-bootstrap
```

外部 Secret 必须提供 `ANKOLE_SECRET_BASE`、`DATABASE_URL` 和
`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`。启用内置 PostgreSQL 时还必须提供
`POSTGRES_PASSWORD`。[完整 Helm 部署说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.zh-Hans.md)
提供了准确的 Secret 命令和生产 values 文件。

准备好 values 文件和 Secret 后安装：

```bash
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --create-namespace \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

Chart 通过 init container 执行数据库 migration 和 Worker key bootstrap。两个
操作都成功后，控制面才会启动。

### PostgreSQL 要求

内置 PostgreSQL 已包含必需软件包。外部服务器必须运行 PostgreSQL 18 或更高
版本，preload `pg_search`，并让应用数据库 owner 可以使用 `pg_search` 和
`vector`：

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` 必须不小于 `180000`，`shared_preload_libraries` 必须包含
`pg_search`。每次升级前备份 PostgreSQL 和 Agent Home。Helm rollback 不会反向
执行数据库 migration。

## 首次产品设置

Helm 部署从控制面日志读取 activation code：

```bash
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

打开 HTTPS `/setup` 页面，输入 code，选择 Control Plane Plugin，然后配置管理员
identity provider。再通过 Console 配置 provider、model profile、Agent、Signal
binding、Agent Library capability 和 WorkerEnv secret。

Agent Computer 需要 `SYS_ADMIN`、不受限的 seccomp profile 和 unmasked `/proc`，
才能使用强 bubblewrap 隔离。Compose 和 Helm 部署包已经包含这些设置。请把 Worker
节点视为受信任的第一方计算边界。
