---
title: 安装部署
description: 使用 Docker Compose 在单机部署 Ankole，或使用公开 Helm Chart 部署到 Kubernetes。
section: Getting started
order: 3
---

一套 Ankole 生产部署包含控制面、一个或多个 Agent Computer Worker、PostgreSQL 和持久化的 Agent Home 存储。支持两种部署包：

- **Docker Compose**，面向单台 Linux 主机。它打包了 PostgreSQL、migration、Worker key 引导、一个 Worker 和 Caddy HTTPS。
- **Helm**，面向 Kubernetes。它支持内置或外部的 PostgreSQL，并要求 Agent Home 使用共享的 `ReadWriteMany` 存储。

两种部署包都从 GitHub Container Registry 拉取最新的已验证镜像：

```text
ghcr.io/agentbull/ankole-agent-control-plane:main-latest
ghcr.io/agentbull/ankole-agent-computer-worker:main-latest
ghcr.io/agentbull/ankole-postgres-for-ankole:main-latest
```

控制面和 Worker 的 tag 会一起移动，并且只在发布工作流验证 RuntimeFabric 镜像对成功之后才移动。要受控地发布，请把两个 Ankole 镜像固定到同一镜像对的 digest。

## 使用 Docker Compose 单机部署

主机必须是 Linux `amd64` 或 `arm64`，已安装 Docker Engine 和 Docker Compose 插件，有持久化的本地存储，并且 `80`、`443` 端口可用。

克隆仓库并准备部署配置：

```bash
git clone https://github.com/AgentBull/ankole.git
cd ankole/tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
```

生成三个彼此独立的十六进制值：

```bash
openssl rand -hex 24
openssl rand -hex 32
openssl rand -hex 24
```

把它们依次写入 `.env` 的 `POSTGRES_PASSWORD`、`ANKOLE_SECRET_BASE` 和 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`。把 `ANKOLE_HOST` 设为指向该主机的域名，并设置 `ACME_EMAIL`。不要把 provider API key 放进这个文件——请在 Ankole Console 里配置。

启动：

```bash
docker compose pull
docker compose up -d
docker compose ps
```

Compose 会等待 PostgreSQL 就绪，执行所有待执行的 migration，写入 Worker 认证 key，然后启动控制面、Worker 和 Caddy。

读取首次设置的 activation code：

```bash
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

打开 `https://<ANKOLE_HOST>/setup`。当主机有公网域名解析时，Caddy 会自动申请并续期证书。只在本地使用 `ankole.localhost` 时，请按[完整 Compose 部署说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/docker-compose/README.zh-Hans.md)信任 Caddy 的本地 CA。生产设置流程必须使用受信任的 HTTPS。

### Compose 的运维和升级

升级前先备份数据库：

```bash
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

然后做一次有短暂服务中断的升级：

```bash
docker compose pull
docker compose down
docker compose up -d --force-recreate
docker compose ps
```

`docker compose down` 会保留命名卷。`docker compose down -v` 会删除 PostgreSQL、Agent Home 和 Caddy 的数据——只有在确实要永久删除数据、并且已经有一份经过验证的备份时，才能使用 `-v`。

## 使用 Helm 部署到 Kubernetes

公开 Chart 在 [`tools/deploy/helm/ankole-agent`](https://github.com/AgentBull/ankole/tree/main/tools/deploy/helm/ankole-agent)。它要求 Kubernetes 1.27 或更高版本、Helm 3 或更高版本、Linux `amd64` 或 `arm64` 节点、一个 HTTPS Ingress，以及 Agent Home 使用的 RWX StorageClass 或已有的 RWX PVC。

Chart 默认安装内置 PostgreSQL：

```yaml
postgresql:
  enabled: true
```

改用外部数据库时设置：

```yaml
postgresql:
  enabled: false

secrets:
  existingSecret: ankole-bootstrap
```

这个外部 Secret 必须提供 `ANKOLE_SECRET_BASE`、`DATABASE_URL` 和 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`。启用内置 PostgreSQL 时，还必须提供 `POSTGRES_PASSWORD`。[完整 Helm 部署说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.zh-Hans.md)给出了准确的 Secret 命令和生产环境 values 文件。

values 文件和 Secret 都就绪后，安装：

```bash
helm upgrade --install ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole \
  --create-namespace \
  --values values-production.yaml \
  --wait \
  --timeout 15m
```

Chart 通过 init container 执行数据库 migration 和 Worker key 引导。两件事都成功之后，控制面才会启动。

### PostgreSQL 要求

内置 PostgreSQL 已经带了所需的软件包。外部服务器必须运行 PostgreSQL 18 或更高版本，预加载 `pg_search`，并让应用数据库的 owner 能使用 `pg_search` 和 `vector`：

```sql
SHOW server_version_num;
SHOW shared_preload_libraries;

SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_search', 'vector')
ORDER BY name;
```

`server_version_num` 不得低于 `180000`，`shared_preload_libraries` 必须包含 `pg_search`。每次升级前都要备份 PostgreSQL 和 Agent Home——Helm 回滚不会反向执行数据库 migration。

## 首次产品设置

Helm 部署从控制面日志读取 activation code：

```bash
kubectl -n ankole logs deployment/ankole-control-plane \
  -c control-plane | grep "SETUP ACTIVATION CODE"
```

打开 HTTPS `/setup` 页面，输入 code，选择 Control Plane Plugin，然后配置管理员 identity provider。之后通过 Console 配置 provider、model profile、Agent、Signal binding、Agent Library capability 和 WorkerEnv secret。

身份步骤会显示这套部署的登录回调地址——由控制面收到的请求 origin 加 Provider ID 组成，形如 `https://<域名>/sessions/oidc/<provider-id>/callback`。跳转登录之前，先把它登记到 identity provider 的开发者后台；provider 只接受登记过的回调地址。这个地址要能被浏览器访问，所以它必须是 TLS 终止的入口地址，而不是集群内部地址。填错的凭据会在这一步被 provider 拒绝并原地报错，不会把你带到 provider 的错误页。

Agent Computer 需要 `SYS_ADMIN`、不受限的 seccomp profile 和未遮蔽的 `/proc`，才能获得强 bubblewrap 隔离。Compose 和 Helm 部署包已经带上了这些设置。请把 Worker 节点视为受信任的第一方计算边界。
