# Ankole 单机 Docker Compose 部署

[English](README.md)

本 Compose 项目在一台 Linux 主机上运行生产版 Ankole。它包含 PostgreSQL、
数据库 migration、Worker key bootstrap、控制面、一个 Agent Computer Worker
和 Caddy HTTPS。

## 前置条件

- Linux `amd64` 或 `arm64` 主机。
- Docker Engine 和 Docker Compose plugin。
- 对外开放 `80` 和 `443` 端口。
- 指向该主机的域名；只在本机使用时也可以用 `ankole.localhost`。
- 根据 PostgreSQL、Agent Home 和模型负载准备足够的存储和内存。

Worker 会获得 `SYS_ADMIN`，并使用不受限的 seccomp 和 system-path profile。
强 bubblewrap 隔离需要这些权限。请把主机和 Worker 视为受信任的第一方计算边界。
不要把 Docker socket 暴露给 Worker。

## 准备配置

```sh
cd tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
```

生成三个独立的十六进制值：

```sh
openssl rand -hex 24
openssl rand -hex 32
openssl rand -hex 24
```

依次把它们写入 `.env` 的 `POSTGRES_PASSWORD`、`ANKOLE_SECRET_BASE` 和
`ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY`。请保留十六进制形式，因为它可以安全放入
数据库 URL 和 RuntimeFabric URL。

公网部署时，把 `ANKOLE_HOST` 设置为指向该主机的域名，并设置 `ACME_EMAIL`。
Caddy 会自动申请和续期公网 TLS certificate。防火墙和上游路由器必须允许
`80` 和 `443` 端口。

只在本机部署时使用：

```dotenv
ANKOLE_HOST=ankole.localhost
ACME_EMAIL=admin@example.com
```

Caddy 此时使用本地 CA。首次启动后复制 CA root certificate，并在每台客户端上
信任它：

```sh
docker compose cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./ankole-local-ca.crt
```

使用操作系统的 certificate 工具信任 `ankole-local-ca.crt`。生产设置流程使用
secure cookie，因此必须使用受信任的 HTTPS。

## 启动

```sh
docker compose pull
docker compose up -d
docker compose ps
```

Compose 会等待 PostgreSQL 就绪，执行所有待执行 migration，写入 Worker
authentication key，然后启动控制面。控制面 service 启动后，Worker 和 Caddy
会继续启动。

读取首次设置 activation code：

```sh
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

打开 `https://ANKOLE_HOST/setup`。输入 code，选择 Control Plane Plugin，然后
配置管理员 identity provider。

设置完成后，通过 Console 配置 provider、model profile、Agent Library
capability、Agent、channel binding 和 WorkerEnv secret。不要把 provider API key
放进 `.env`。

## 镜像策略和升级

默认使用 GitHub Container Registry 的 `main-latest` 镜像。RuntimeFabric 工作流
验证控制面和 Worker 镜像配对成功后，才会同时移动这两个 tag。

受控部署应在 `.env` 中同时设置 `ANKOLE_CONTROL_PLANE_IMAGE` 和
`ANKOLE_WORKER_IMAGE`，并使用同一组已验证镜像的不可变 digest。也可以固定
`ANKOLE_POSTGRESQL_IMAGE`。

升级前备份 PostgreSQL 和 Agent Home，然后执行：

```sh
docker compose pull
docker compose down
docker compose up -d --force-recreate
docker compose ps
```

`down` 会保留全部 named volume，但会在 migration 前停止旧应用。新启动会再次
运行 migration 和 bootstrap service，然后启动新控制面。单机升级会产生短暂
服务中断。回滚到旧镜像不会反向执行数据库 migration。如果旧应用还需要旧 schema，
请恢复数据库备份。

## 备份

创建 PostgreSQL archive：

```sh
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

停止 Ankole 后，使用 volume snapshot 或文件系统备份保护
`ankole_agents_data`。PostgreSQL 数据位于 `ankole_postgresql_data`。请在独立
主机上一起验证数据库和 Agent Home 恢复流程。

## 日常运维

```sh
# 查看 service
docker compose ps

# 查看全部实时日志
docker compose logs -f

# 查看单个 service
docker compose logs -f control-plane
docker compose logs -f worker

# 检查 PostgreSQL extension
docker compose exec postgresql \
  psql -U ankole -d ankole \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"

# 停止 service 并保留数据
docker compose down

# 再次启动
docker compose up -d
```

`docker compose down -v` 会删除 PostgreSQL、Agent Home 和 Caddy volume。
只有明确要永久删除数据，并且已有经过验证的备份时才能执行。

Compose 会在每个容器日志达到 20 MiB 时轮转，并保留五个文件。PostgreSQL 和
RuntimeFabric 位于 Docker internal network。只有 Caddy 会发布主机端口。

## 主要配置

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `ANKOLE_HOST` | 必填 | 对外 HTTPS 域名 |
| `POSTGRES_PASSWORD` | 必填 | 内置 PostgreSQL 密码 |
| `ANKOLE_SECRET_BASE` | 必填 | 应用 root secret |
| `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` | 必填 | Worker 共享认证 key |
| `ANKOLE_MAX_CONCURRENT_TURNS` | `9` | 单 Worker 最大并发 Turn |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | 控制面数据库连接池 |
| `ANKOLE_CONTROL_PLANE_IMAGE` | `main-latest` 镜像 | 控制面镜像或 digest |
| `ANKOLE_WORKER_IMAGE` | `main-latest` 镜像 | Worker 镜像或 digest |
| `ANKOLE_POSTGRESQL_IMAGE` | `main-latest` 镜像 | PostgreSQL 镜像或 digest |

## 故障排查

- `migrate` 退出时，执行 `docker compose logs migrate postgresql`。检查密码、
  已保留的数据库 volume 和剩余磁盘空间。
- 控制面没有启动时，执行
  `docker compose logs bootstrap-worker-auth-key control-plane`。
- Worker 反复重连时，确认首次启动后没有修改 `.env` 中的 Worker key。
- 浏览器拒绝设置流程时，检查 Caddy 日志、DNS、`80` 和 `443` 端口以及
  certificate 信任状态。
- 主机 kernel 拒绝 Worker security option 时，请使用受支持的 Linux Docker
  主机。没有等效 sandbox 时，不要删除隔离设置。
