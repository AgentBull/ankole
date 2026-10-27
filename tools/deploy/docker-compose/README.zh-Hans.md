# Ankole 单机 Docker Compose 部署

[English](README.md)

本 Compose 项目可在单台 Linux、macOS 或 Windows 主机上运行一套完整的 Ankole 私有化部署（宿主机 Docker 须支持运行 Linux `amd64` 或 `arm64` 容器）。项目编排了 PostgreSQL、数据库迁移任务、控制面与 Caddy HTTPS 网关；控制面则通过 Docker 套接字（socket）按需为每个 Agent 创建独立的 Agent Computer Worker 容器。

一个站点对应一套完整部署，内部可承载多个租户；各租户拥有独立的人员、Agent、Brain 与外部平台集成，而站点管理员统一管理共享的基础设施与运行方。站点管理控制台默认挂载在 `/site-admin-console`；如需改为其他绝对路径，请在启动前设置 `ANKOLE_SITE_ADMIN_CONSOLE_PATH` 并妥善保存在运维配置中。普通成员通过所属租户域名或 OIDC 应用登录，不访问站点管理控制台。

## 前置条件

- 支持运行 Linux `amd64` 或 `arm64` 容器的 Linux、macOS 或 Windows 主机。
- 已安装 Docker Engine（含 Docker Compose 插件）或 Docker Desktop。
- 对外开放 TCP `80` 与 `443` 端口。
- 解析到该主机的域名；仅在本机访问时也可使用 `ankole.localhost`。
- 充足的磁盘与内存，能够同时承载 PostgreSQL、Agent 云盘，以及每个活跃 Agent 各自的 Worker 容器。

控制面容器会挂载宿主机的 Docker 套接字。由于访问该套接字等同于拥有宿主机 `root` 权限，请将宿主机视为受信任的第一方计算边界。Worker 容器不会挂载该套接字，也不具备任何额外内核特权——每个容器本身就是单个 Agent 的隔离边界。

## 准备配置

```sh
cd tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
```

生成四个彼此独立的十六进制随机密钥：

```sh
openssl rand -hex 24
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

将它们依次填入 `.env` 中的 `POSTGRES_PASSWORD`、`ANKOLE_SECRET_BASE`、`RELEASE_COOKIE` 与 `ANKOLE_FUNCTION_RUNTIME_TOKEN`。请保持十六进制格式，以便无需转义即可安全嵌入数据库连接 URL。

`RELEASE_COOKIE` 是当前部署的分布式 Erlang Cookie。公开发布的控制面镜像内置相同的默认值；若不替换，任何能拉取该镜像的人都拥有相同的 Cookie。与此同时，控制面将 EPMD 与分布式端口均绑定在回环地址 `127.0.0.1` 上，使 Erlang 节点仅在本机内部监听和应答。

将 `ANKOLE_DOCKER_GID` 设为容器视角下 Docker 套接字所属的用户组 ID，使以非特权用户运行的控制面能够访问该套接字。在 Linux 宿主机上可执行以下命令查看：

```sh
stat -c %g /var/run/docker.sock
```

macOS 上的 Docker Desktop 挂载进容器的套接字属组固定为 `0`（与宿主机上显示的属组无关），因此 macOS 请直接设置 `ANKOLE_DOCKER_GID=0`。若宿主机套接字路径不是 `/var/run/docker.sock`，请同时设置 `ANKOLE_DOCKER_SOCKET`。

面向公网部署时，将 `ANKOLE_HOST` 设为指向该主机的域名并填写 `ACME_EMAIL`，由 Caddy 自动申请和续期公网 TLS 证书（防火墙与上游路由器须放行 `80` 与 `443` 端口）。

仅在本机部署时可使用：

```dotenv
ANKOLE_HOST=ankole.localhost
ACME_EMAIL=admin@example.com
```

此时 Caddy 会使用内置的本地证书颁发机构（CA）签发证书。首次启动后，请将根证书导出并在每台访问端设备的系统证书库中添加信任：

```sh
docker compose cp \
  caddy:/data/caddy/pki/authorities/local/root.crt \
  ./ankole-local-ca.crt
```

生产环境的初始化流程使用带 `Secure` 标记的 Cookie，浏览器仅在受信任的 HTTPS 连接下才会发送该 Cookie。

`worker-providers.yaml` 定义了初始的本地 Docker 运行方（Worker Provider），包含容器网络、环境变量、停止宽限期与空闲回收策略。默认配置未限制 CPU 与内存，因此单个 Worker 容器可使用整机的全部资源。如需限制单个 Worker 的配额，可在 `config` 下补充 `cpus` 与 `memoryMiB`：

```yaml
    config: |
      socket: /var/run/docker.sock
      network: ankole_workers
      cpus: 2
      memoryMiB: 4096
```

控制面仅在首次启动且运行方数据表为空时导入该种子文件。首次启动后，请在控制台的设置页面调整运行方配置；新的资源上限会在控制面下次替换空闲 Worker 时生效。运行方凭据保存在独立的加密字段中，且每个 Agent 在创建后绑定所选运行方，不可中途切换。

每个 Agent 都拥有挂载在 `/workspace` 的独享持久化卷，以及挂载在 `/var/cache/ankole` 的独立缓存卷。替换容器实例会保留这两个卷；重建 Worker 仅清空缓存卷；删除 Agent 时，控制面会在确认容器已退出后一并删除这两个卷。Worker 内部负载以 `uid 1000` 运行，不具备 `sudo` 权限。

## 启动服务

```sh
docker compose pull
docker compose up -d
docker compose ps
```

Compose 会依次等待 PostgreSQL 就绪、数据库迁移完成以及 Agent Home 迁移服务执行成功，随后再启动控制面和 Caddy。初始状态下不会启动任何 Worker 容器：只有在创建 Agent 时，控制面才会拉取配套的 Worker 镜像并按需创建容器。

从控制面日志中查看首次设置的激活码：

```sh
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
```

在浏览器中打开 `https://ANKOLE_HOST/setup`，输入激活码，勾选需要启用的控制面插件（Control Plane Plugin），并配置管理员身份认证源。

完成初始化后，即可在控制台中配置模型提供商、模型档案、Agent Library 能力、Agent、聊天渠道绑定与 `WorkerEnv` 密钥。请勿将模型提供商的 API 密钥写入 `.env`。

## Function Runtime 网络隔离

Function Runtime 与控制面共用 `ankole_functions` 网桥，可通过该网桥回连控制面；PostgreSQL 则单独位于内部网络 `ankole_backend` 中。Helm 部署通过 Kubernetes `NetworkPolicy` 封禁私网与云元数据网段，而单机 Compose 依赖 Docker 网桥隔离；若运行在公有云虚拟机上，请将实例元数据服务的跳数限制（Hop Limit）设为 `1`，或通过宿主机防火墙禁止容器网段访问 `169.254.169.254`。

## Worker 容器管理

每个 Worker 容器命名为 `ankole-ankole-<hash>-<generation>`，附带标签 `ankole.installation=ankole`、`ankole.provider=docker` 与 `ankole.agent-uid=<Agent UID>`。容器接入 `ankole_workers` 网络，可访问控制面及公网（用于无头浏览器、网页抓取与软件包安装），但无法触达仅挂在 `ankole_backend` 内部网络上的 PostgreSQL。在云主机上同样请将元数据跳数限制设为 `1` 或拦截容器访问 `169.254.169.254`，防止 Worker 读取宿主机的云实例凭据。这些容器不归 Compose 托管，而是由控制面直接创建和销毁，并在控制台的 Workers 页面展示实时状态。

默认情况下，空闲的 Worker 容器会保持运行。若在运行方 YAML 中设置 `idleReleaseAfter`（如 `15m`），控制面会在空闲超时后销毁容器，同时保留 Agent Home 卷与缓存卷；当该 Agent 再次需要执行任务时，新拉起的容器会重新挂回这两个卷。重建 Worker 仅删除缓存卷；删除 Agent 时，控制面会在其所有容器完全退出后删除这两个卷。

安装标识 `ANKOLE_WORKER_INSTALLATION`（默认 `ankole`）会拼入 Worker 容器名、Agent 卷名及容器标签中，长度须为 1–20 个字符，仅允许小写字母、数字和连字符，且首尾必须为字母或数字（例如 `e2e-1011b01`）。首次启动后切勿修改该值：一旦更改，控制面会新建空白的 Agent Home 卷，且无法识别仍在运行的旧容器，从而可能为同一个 Agent 重复启动第二个 Worker。

## 镜像策略和升级

`compose.yaml` 默认固定使用预发布版控制面 `2.0.0-alpha.24`（内置同一源码版本的 Worker 镜像引用）以及固定的 PostgreSQL 镜像摘要（digest）。升级或部署时，请确保配置文件与镜像来自同一发布版本；`main-latest` 等浮动标签可能指向启动契约不同的旧版本。

PostgreSQL 容器采用 `C.utf8` 区域设置，使全新空卷初始化为 `UTF8` 编码。升级镜像或修改配置不会转换已有数据库的编码：升级前请先检查 `SHOW server_encoding`，若旧库仍为 `SQL_ASCII`，请按[数据库备份、转换与恢复流程](../../devkit/postgres-for-ankole/README.md)迁移，切勿直接修改系统表编码标记。

对于受控生产环境，建议在 `.env` 中将 `ANKOLE_CONTROL_PLANE_IMAGE` 固定为不可变的 `sha256` 摘要（这会一并锁定配套的 Worker 镜像），也可同时固定 `ANKOLE_POSTGRESQL_IMAGE`。每次升级前请先核对 `.env` 中的这两项覆盖配置，因为 `.env` 的优先级高于新版 `compose.yaml` 中的默认值。

若从早期未配置 `RELEASE_COOKIE` 的部署升级，请先向 `.env` 补充该变量（缺少 `RELEASE_COOKIE` 时，`docker compose` 会直接报错退出并提示该变量名）：

```sh
printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
```

每次升级前请完整备份 PostgreSQL、文件存储、所有 Agent Home 卷以及 `.env` 密钥。当前 PostgreSQL 镜像内置 `pg_search` `0.25.11`，启动新版控制面前须先在数据库内升级扩展 SQL：

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps
```

`docker compose stop` 会在执行迁移前停掉旧版控制面，同时保留 Docker 网络使在途 Worker 不断网；待两个迁移服务全部成功后，新版控制面才会启动。升级完成后，各 Agent 的 Worker 会自动重连，镜像变更的旧 Worker 则会在空闲后自动替换。单机升级期间会有短暂服务中断。回退旧版镜像不会反向撤销已执行的数据库迁移；若旧版应用依赖旧表结构，请使用升级前的数据库备份进行恢复。扩展与动态库版本核验方法详见[数据库镜像说明](../../devkit/postgres-for-ankole/README.md)。

从早期共享池化 Worker 版本升级时，`migrate-agent-homes` 服务会先停止所有挂载旧卷 `ankole_agents_data` 的容器，再将每个现存 Agent 的主目录复制到各自的独享卷、将属主统一改为 `uid 1000`，并在旧卷内写入完成标记（已删除 Agent 遗留的孤立目录会被跳过，旧卷本身予以保留）。执行前请确保宿主机剩余磁盘空间不少于 `ankole_agents_data` 的已用容量。若任一目录复制失败，迁移服务会报错退出并阻止控制面启动；修复后再次运行 `docker compose up` 会仅重试未完成的目录，不会覆盖已迁移完成的数据。

在每个 Worker 内部，`/agents/<agent_uid>` 是指向 `/workspace` 的符号链接，用户文件、会话文件与 Job 工作区均保留在 Agent Home 中；控制面的共享 Agent 云盘则存放在 `files_data` 卷中。若从尚未引入云盘的旧版本升级，请一次性运行以下命令，将已安装的 Skill、Automation Job 脚本及待发送的旧版附件导入云盘：

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm -v ankole_agents_data:/agents control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

导入操作不会覆盖云盘中已有的同名文件，并会列出无法读取的文件路径。由于旧版待发消息需要等待附件转换完成后才能发出，请核实待发附件已全部转换并处理报告中列出的缺失附件；确认迁移后的 Agent Home 与导入报告均无异常后，再执行 `docker volume rm ankole_agents_data` 删除旧卷。

## 数据备份

执行一致性备份前，请先在控制台中停用各 Agent 并等待在途任务结束；随后在保持控制面运行的前提下正常停止并移除所有 Worker 容器，待控制面记录实例已下线后再停止控制面（仅执行 `docker compose stop` 不会停止 Worker 容器）。确认所有 Agent Home 写入进程均已退出后再开始备份，并在密钥管理系统中妥善保管原始 `ANKOLE_SECRET_BASE`，以便恢复后解密运行方凭据及未结清代次的凭据。

保持 PostgreSQL 运行并导出自定义格式归档：

```sh
docker compose exec -T postgresql \
  pg_dump -U ankole -d ankole -Fc \
  > "ankole-$(date +%Y%m%d).dump"
```

在 Ankole 停止状态下，通过卷快照或文件系统级备份保存 `ankole_files_data` 卷。PostgreSQL 数据位于 `ankole_postgresql_data` 中，并记录着 `ankole_files_data` 内所有云盘文件的索引引用，因此两者必须成对备份、成对恢复。同时请备份所有名为 `ankole-<installation>-<Agent hash>` 的 Agent Home 卷（以 `-cache` 结尾的缓存卷无需备份），并定期在独立主机上演练数据库、共享文件存储与 Agent Home 的联合恢复。

## 日常运维

```sh
# 查看服务状态
docker compose ps

# 查看 Worker 容器
docker ps -a --filter label=ankole.installation=ankole

# 查看全部 Compose 服务的实时日志
docker compose logs -f

# 查看单个服务日志
docker compose logs -f control-plane

# 查看单个 Worker 日志
docker logs -f CONTAINER_NAME

# 检查 PostgreSQL 扩展版本
docker compose exec postgresql \
  psql -U ankole -d ankole \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_search', 'vector') ORDER BY extname"

# 停止服务并保留持久化数据
docker ps -aq --filter label=ankole.installation=ankole | xargs -r docker rm -f
docker compose down

# 重新启动服务
docker compose up -d
```

执行 `docker compose down` 前请先清理所有 Worker 容器：只要仍有 Worker 容器连接在 `ankole_workers` 网络上，Docker 就无法卸载该网络。重新启动后，控制面会在 Agent 需要时自动重建 Worker 容器。

`docker compose down -v` 会一并删除 PostgreSQL、文件存储与 Caddy 持久化卷；除非确认要永久清空数据且已备好经过验证的备份，否则切勿执行。

Compose 会在单个容器日志达到 20 MiB 时自动轮转并保留最近 5 个文件；PostgreSQL 仅接入内部网络，整套编排只有 Caddy 对宿主机暴露端口。

## 主要配置

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `ANKOLE_HOST` | 必填 | 对外提供服务的 HTTPS 域名 |
| `POSTGRES_PASSWORD` | 必填 | 内置 PostgreSQL 密码 |
| `ANKOLE_SECRET_BASE` | 必填 | 应用根密钥 |
| `RELEASE_COOKIE` | 必填 | 当前部署的分布式 Erlang Cookie |
| `ANKOLE_DOCKER_GID` | 必填 | 容器内看到的 Docker 套接字属组 ID |
| `ANKOLE_DOCKER_SOCKET` | `/var/run/docker.sock` | 宿主机 Docker 套接字路径 |
| `ANKOLE_DATABASE_POOL_SIZE` | `10` | 控制面数据库连接池大小 |
| `ANKOLE_WORKER_INSTALLATION` | `ankole` | Worker 容器与 Agent 卷名称中的安装标识；首次启动后切勿修改 |
| `ANKOLE_CONTROL_PLANE_IMAGE` | `2.0.0-alpha.24` 镜像 | 控制面镜像或摘要（同时决定配套的 Worker 镜像） |
| `ANKOLE_FUNCTION_RUNTIME_TOKEN` | 必填 | 控制面与函数运行时共享的内部鉴权令牌 |
| `ANKOLE_FUNCTION_RUNTIME_IMAGE` | 同版本发布镜像 | 无状态 Applet 后端与程序执行运行时镜像 |
| `ANKOLE_POSTGRESQL_IMAGE` | `compose.yaml` 中的摘要 | PostgreSQL 镜像或摘要 |

## 故障排查

- **`migrate` 异常退出**：执行 `docker compose logs migrate postgresql`，排查数据库密码、历史遗留数据库卷及磁盘剩余空间。
- **`control-plane` 未能启动**：执行 `docker compose logs control-plane` 查看启动报错。
- **控制台初始化向导中的 Worker 步骤未就绪，或 Workers 页面报错 `docker_unreachable`**：控制面无法访问 Docker 套接字。若报错信息提示权限不足，说明 `ANKOLE_DOCKER_GID` 与容器视角下的套接字属组不一致（macOS Docker Desktop 请设为 `0`）。
- **某个 Agent 的 Worker 迟迟无法就绪**：打开控制台的 Workers 页面查看该容器的最新状态原因与日志尾部，或直接运行 `docker logs CONTAINER_NAME`。
- **浏览器无法完成初始化设置**：检查 Caddy 日志、域名解析、`80`/`443` 端口连通性以及本地根证书信任状态。
