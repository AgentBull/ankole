# Ankole 单机 Docker Compose 部署

[English](README.md)

本 Compose 项目在一台 Linux、macOS 或 Windows 主机上运行 Ankole 私有化部署实例。
Docker 必须能够运行 Linux `amd64` 或 `arm64` 容器。项目包含 PostgreSQL、
数据库 migration、控制面和 Caddy HTTPS。控制面通过 Docker socket 为每个需要
Worker 的 Agent 创建一个 Agent Computer Worker 容器。

站点是一套完整部署，可以包含多个租户。各租户拥有独立的人员、Agent、Brain 和外部
平台连接；站点管理员管理共享的提供商与基础设施。站点管理控制台默认位于
`/site-admin-console`。需要其他绝对路径时，在启动前设置
`ANKOLE_SITE_ADMIN_CONSOLE_PATH`，并将路径保存在运维配置中。普通用户通过所属租户域名或
OIDC 应用登录，不使用站点管理控制台。

## 前置条件

- 能运行 Linux `amd64` 或 `arm64` 容器的 Linux、macOS 或 Windows 主机。
- Docker Engine 和 Docker Compose plugin，或 Docker Desktop。
- 对外开放 `80` 和 `443` 端口。
- 指向该主机的域名；只在本机使用时也可以用 `ankole.localhost`。
- 根据 PostgreSQL、Agent 云盘，以及每个运行中的 Agent 各一个 Worker 容器，
  准备足够的主机存储和内存。

控制面会挂载 Docker socket。能访问该 socket 就等同于拥有主机的 root 权限；
请把主机视为受信任的第一方计算边界。Worker 容器不会获得 socket，
也没有额外的内核权限：每个容器是一个 Agent 的隔离边界。

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
openssl rand -hex 32
```

依次把它们写入 `.env` 的 `POSTGRES_PASSWORD`、`ANKOLE_SECRET_BASE` 和
`RELEASE_COOKIE`。请保留十六进制形式，因为它可以安全放入数据库 URL。

`RELEASE_COOKIE` 是本部署的 Erlang distribution cookie。公开发布的控制面镜像
内置同一个 cookie，每次拉取得到的都一样；沿用它就等于把这个 cookie 共享给
所有能拉取该镜像的人。控制面的节点只在回环地址上应答，因此它同时把 EPMD 和
distribution 端口绑定到回环接口。两者共同把一个部署的 Erlang 节点限制在本机。

把 `ANKOLE_DOCKER_GID` 设置为容器内看到的 Docker socket 所属组。控制面以非特权
用户运行，并通过这个组访问 socket。在 Linux 上，从宿主读取：

```sh
stat -c %g /var/run/docker.sock
```

macOS 上的 Docker Desktop 交给容器的 socket 属组总是 `0`，与宿主显示的无关，
所以在那里设置 `ANKOLE_DOCKER_GID=0`。

Docker socket 不在 `/var/run/docker.sock` 时，设置 `ANKOLE_DOCKER_SOCKET`。

公网部署时，把 `ANKOLE_HOST` 设置为指向该主机的域名，并设置 `ACME_EMAIL`。
Caddy 会自动申请和续期公网 TLS 证书。防火墙和上游路由器必须允许
`80` 和 `443` 端口。

只在本机部署时使用：

```dotenv
ANKOLE_HOST=ankole.localhost
ACME_EMAIL=admin@example.com
```

Caddy 此时使用本地 CA。首次启动后复制 CA 根证书，并在每台客户端上
信任它：

```sh
docker compose cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./ankole-local-ca.crt
```

使用操作系统的证书工具信任 `ankole-local-ca.crt`。生产设置流程使用
secure cookie，因此必须使用受信任的 HTTPS。

`worker-providers.yaml` 声明初始 Docker provider。其 YAML 配置设置网络、环境变量、
停止宽限期和空闲回收，不设 CPU 与内存上限，所以每个 Worker 容器可以用满宿主的全部
CPU 与内存。要限制每个 Worker 容器，在 `config` 文本中加上 `cpus` 与 `memoryMiB`，
例如写在 `network` 下面：

```yaml
    config: |
      socket: /var/run/docker.sock
      network: ankole_workers
      cpus: 2
      memoryMiB: 4096
```

只有 provider 表为空时才读取种子。首次启动后，在 Console 的设置区编辑 provider；
新的上限在控制面替换空闲 Worker 时生效。密钥在独立字段中加密保存。Agent 创建后
不能更换 provider。

每个 Agent 有挂载到 `/workspace` 的本地独享持久卷，以及挂载到 `/var/cache/ankole` 的
独立缓存卷。更换容器保留两个卷，重建只删除缓存；删除 Agent 时，先确认容器消失，
再删除两个卷。Worker 以 uid 1000 运行，没有 sudo。

## 启动

```sh
docker compose pull
docker compose up -d
docker compose ps
```

Compose 会等待 PostgreSQL、数据库 migration 和 Agent Home 迁移服务全部成功，
然后启动控制面和 Caddy。此时还没有 Worker 容器：创建 Agent 时，控制面为它创建 Worker，并在
创建时拉取 Worker 镜像。

读取首次设置 activation code：

```sh
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

打开 `https://ANKOLE_HOST/setup`。输入 code，选择 Control Plane Plugin，然后
配置管理员的身份源。

设置完成后，通过 Console 配置模型提供商、模型档案、Agent Library 能力、
Agent、聊天渠道绑定和 WorkerEnv 密钥。不要把模型提供商的 API key
放进 `.env`。

## Worker 容器

每个 Worker 容器的名称是 `ankole-ankole-<hash>-<generation>`，并带有标签
`ankole.installation=ankole`、`ankole.provider=docker` 和
`ankole.agent-uid=<Agent UID>`。它加入
`ankole_workers` 网络，因此能访问控制面和互联网（浏览器、网页抓取与安装软件包），
但不能访问只在内部网络 `ankole_backend` 上的 PostgreSQL。在云虚拟机上，请把实例
元数据的 hop limit 设为 1，或对容器屏蔽 `169.254.169.254`，使 Worker 拿不到这台
机器的凭据。Compose 不管理这些容器：控制面负责创建、
删除它们，Console 的 Workers 页面显示它们的状态。

空闲的 Worker 默认继续运行。在 Worker provider 的 YAML 中设置
`idleReleaseAfter`（例如 `15m`）后，控制面会删除空闲的容器，并保留 Agent Home
与缓存卷。Agent 再次需要 Worker 时，新容器挂回这两个卷。重建只删除缓存卷；
删除 Agent 时，控制面确认它的容器全部消失后才删除两个卷。

安装标签 `ANKOLE_WORKER_INSTALLATION`（默认 `ankole`）是 Worker 容器与 Agent 卷的
名称和标签的一部分。名称为 1–20 个字符，只接受小写字母、数字和连字符，首尾必须是
字母或数字；例如 `e2e-1011b01` 合法。首次启动后不能修改。标签变了，控制面会新建空的 Agent Home 卷，
也看不到正在运行的 Worker，可能为同一个 Agent 再启动一个 Worker。

## 镜像策略和升级

默认固定控制面 `2.0.0-alpha.5` 和 `compose.yaml` 中的 PostgreSQL digest。
这是预发布版本。控制面镜像指定相同源码 revision 的 Worker 镜像。
请使用同一发布版本的部署文件和镜像；`main-latest` 可能指向启动契约不匹配的旧版本。

PostgreSQL 容器使用 `C.utf8`，空卷首次初始化为 UTF8。更新镜像或配置不会转换
现有数据库编码。先检查 `SHOW server_encoding`；SQL_ASCII 旧库需要另行执行
[备份、转换与恢复](../../devkit/postgres-for-ankole/README.md)，不能直接修改编码标记。

受控部署应在 `.env` 中把 `ANKOLE_CONTROL_PLANE_IMAGE` 设置为不可变 digest。
这个 digest 同时固定 Worker 镜像。也可以固定 `ANKOLE_POSTGRESQL_IMAGE`。
升级前检查 `.env` 中这两个覆盖值；已有覆盖值的优先级高于新版部署文件的默认值。

从早期未配置 `RELEASE_COOKIE` 的部署升级时，需先在 `.env` 中补齐该变量（缺少 `RELEASE_COOKIE` 时，
第一条 `docker compose` 命令就会停止并提示该变量名）：

```sh
printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
```

升级前备份 PostgreSQL、文件存储、全部 Agent Home 与原部署密钥。
新 PostgreSQL 镜像提供 `pg_search` 0.25.11；须在启动新控制面前更新数据库内的扩展 SQL。
然后执行：

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps
```

`stop` 会在 migration 前停止旧应用并保留网络。两个迁移服务都成功后，新控制面才会
启动。后续升级时，每个 Agent 的 Worker 会重新连接控制面；镜像变化时，在 Worker
空闲后替换。单机升级会产生短暂服务中断。回滚镜像不会反向执行数据库 migration；
旧应用需要旧 schema 时，须恢复数据库备份。
扩展与已加载库的版本检查见[数据库镜像升级说明](../../devkit/postgres-for-ankole/README.md)。

从池化 Worker 版本升级时，`migrate-agent-homes` 先停止所有挂载旧卷
`ankole_agents_data` 的容器，再把仍然存在的每个 Agent 的目录复制到它的独享卷，修正
属主为 uid 1000，并在旧卷记录完成状态。旧版本删除 Agent 时没有删除它的 Home；迁移
跳过这些孤立目录并保留旧卷。迁移前须预留与旧卷用量相同的空闲空间。
复制失败会让服务失败，控制面不会启动。再次执行 `docker compose up` 会重试未完成的
复制，已完成的目录不会再次覆盖。

每个 Worker 内的 `/agents/<agent_uid>` 是指向 `/workspace` 的符号链接。用户文件、
会话文件和 Job 工作区留在 Agent Home。控制面的共享 Agent 云盘位于 `files_data`。
从没有云盘的版本升级后，把已安装 Skill、Automation Job 脚本和待发送的旧版附件一次性导入云盘：

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm -v ankole_agents_data:/agents control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

导入不会覆盖云盘已有文件，并会报告无法读取的文件。确认待发送附件已全部转换，并处理导入报告中列出的缺失附件（旧版发送需等待转换完成）。确认迁移后的 Agent Home 与导入
报告无误后，才执行 `docker volume rm ankole_agents_data` 删除旧卷。

## 备份

禁用 Agent，等正在进行的工作结束。保持控制面运行，正常停止并删除 Worker
容器，等待控制面记录实例消失后，再停控制面。仅停止 Compose 不会结束 Worker；
所有 Home 写者停止后才能备份。另在密钥管理系统保留原 `ANKOLE_SECRET_BASE`，
恢复时用它解密 provider 与未结清 generation 的凭据。

保持 PostgreSQL 运行，创建归档：

```sh
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

停止 Ankole 后，使用卷快照或文件系统备份保护 `ankole_files_data` 卷。
PostgreSQL 数据位于 `ankole_postgresql_data`。PostgreSQL 记录了
`ankole_files_data` 中的云盘文件，所以两者要一起备份和恢复。
还要备份名为 `ankole-<installation>-<Agent hash>` 的各 Agent Home 卷；
名称以 `-cache` 结尾的卷不需要备份。请在独立主机上一起验证数据库、共享文件存储
和 Agent Home 的恢复流程。

## 日常运维

```sh
# 查看 service 状态
docker compose ps

# 查看 Worker 容器
docker ps -a --filter label=ankole.installation=ankole

# 查看全部 Compose service 的实时日志
docker compose logs -f

# 查看单个 service
docker compose logs -f control-plane

# 查看单个 Worker
docker logs -f CONTAINER_NAME

# 检查 PostgreSQL extension
docker compose exec postgresql \
  psql -U ankole -d ankole \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"

# 停止 service 并保留数据
docker ps -aq --filter label=ankole.installation=ankole | xargs -r docker rm -f
docker compose down

# 再次启动
docker compose up -d
```

执行 `docker compose down` 前，先删除 Worker 容器：只要还有 Worker 容器连接在
`ankole_workers` 网络上，Compose 就无法删除这个网络。
控制面会在 Agent 需要时重新创建 Worker。

`docker compose down -v` 会删除 PostgreSQL、文件存储和 Caddy 卷。
只有明确要永久删除数据，并且已有经过验证的备份时才能执行。

Compose 会在每个容器日志达到 20 MiB 时轮转，并保留五个文件。PostgreSQL 位于
Docker internal network。只有 Caddy 会发布主机端口。

## 主要配置

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `ANKOLE_HOST` | 必填 | 对外 HTTPS 域名 |
| `POSTGRES_PASSWORD` | 必填 | 内置 PostgreSQL 密码 |
| `ANKOLE_SECRET_BASE` | 必填 | 应用 root secret |
| `RELEASE_COOKIE` | 必填 | 本部署的 Erlang distribution cookie |
| `ANKOLE_DOCKER_GID` | 必填 | Docker socket 的所属组 |
| `ANKOLE_DOCKER_SOCKET` | `/var/run/docker.sock` | 主机上的 Docker socket |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | 控制面数据库连接池 |
| `ANKOLE_WORKER_INSTALLATION` | `ankole` | Worker 容器与 Agent 卷名称中的标签；首次启动后不能修改 |
| `ANKOLE_CONTROL_PLANE_IMAGE` | `2.0.0-alpha.5` 镜像 | 控制面镜像或 digest；它指定 Worker 镜像 |
| `ANKOLE_POSTGRESQL_IMAGE` | `compose.yaml` 中的 digest | PostgreSQL 镜像或 digest |

## 故障排查

- `migrate` 退出时，执行 `docker compose logs migrate postgresql`。检查密码、
  已保留的数据库卷和剩余磁盘空间。
- `control-plane` 没有启动时，执行 `docker compose logs control-plane`。
- Console 设置清单的 Worker 步骤未完成，或 Workers 页面显示某个 Worker 的最近错误为
  `docker_unreachable` 时，控制面无法使用 Docker socket。如果原因中是权限错误，说明
  `ANKOLE_DOCKER_GID` 不是容器内看到的该 socket 的所属组（macOS 上的 Docker Desktop
  为 `0`）。
- Agent 的 Worker 没有就绪时，打开 Console 的 Workers 页面，页面会显示该 Worker
  容器最新的原因和日志行；也可以执行 `docker logs CONTAINER_NAME`。
- 浏览器拒绝设置流程时，检查 Caddy 日志、DNS、`80` 和 `443` 端口以及
  证书信任状态。
