---
title: 从 1.0 升级到 2.0
description: 将 1.x 自托管站点平滑升级至 2.0——完成数据库、独享 Worker、Agent 主目录与控制面云盘迁移，并验证回退与恢复路径。
section: Guides
order: 313
---

本指南面向从 1.0 及后续 1.x 版本升级至 2.0 的自托管部署站点。本次跨大版本升级需要安排停机维护窗口：必须先停止旧版本的全部写入进程，再运行新版本的迁移流程。注意，数据库迁移不可逆，无法仅靠切回旧版容器镜像撤销变更。

在正式生产环境动手前，请务必先用真实备份在隔离测试环境中完整演练一遍——尤其是运行早期 1.x 版本、包含自定义部署编排或手工改动过数据库 Schema 的站点。

## 升级后改变什么

| 1.x 旧版形态 | 2.0 新版形态 | 所需运维操作 |
| --- | --- | --- |
| 共享池化 Worker、共用 `/agents` 目录 | 每个 Agent 独享一台 Worker 及专属 `/workspace` | 迁移或接管旧版主目录（Home），并指派 WorkerProvider |
| 存放在主目录内的已安装 Skill 与自动化脚本 | 统一迁入控制面云盘的 `skills/` 与 `automation/` 目录 | 执行一次性历史文件导入命令 |
| Worker 本地临时保存的 Codex 状态 | `/workspace/.codex` 持久化保存线程，`/var/cache/ankole/codex` 存放可重建缓存 | 保留主目录存储，并为 Worker 单独挂载缓存盘 |
| 进程内脚本沙箱与双镜像部署 | 独立无状态的 `ankole-function-runtime`（`control-plane`、`worker`、`function-runtime` 三镜像同版本协同） | 补充 `ANKOLE_FUNCTION_RUNTIME_TOKEN` 密钥，并同步升级三套同版本镜像 |
| 无租户概念的单库数据与配置 | 存量数据统一归入 `default` 租户；Pod / Base 存储要求 **PostgreSQL 18+**（支持可选的 `BASE_DB_URLS` 独立分片库） | 先将数据库升级至 PostgreSQL 18+，再沿用原主密钥执行 Schema 与加密配置迁移 |
| `LocalPassword` 本地密码登录与单一管理组 | 全面采用无密码认证（`SiteCredential` `email_otp` + 企业 SSO），并拆分租户级 `pod_admin` 与站点级 `siteadmin` | 通过凭证冲突预检，配妥 SMTP（`authn.email.mail` 或 `mix ankole.authn.mail.put`）或企业 SSO，并核对各租户 Pod 管理员 |
| 挂载在 `/console` 的管理后台 | 迁至 `/site-admin-console`（或由 `ANKOLE_SITE_ADMIN_CONSOLE_PATH` 指定）的站点管理控制台 | 同步更新浏览器书签与反向代理路由规则 |

若你的 1.x 站点此前已启用独享 Worker 或控制面云盘，只需按需执行尚未覆盖的迁移步骤即可；切勿用全新空白存储卷直接覆盖原有的主目录或云盘数据。

## 升级前准备

1. 详细记录当前版本号、目标 2.0 版本号、各容器镜像 Digest、Docker Compose 项目名或 Helm Release 名称、安装环境标识（Installation）、存储卷 / PVC 名称及现有提供商配置。**`control-plane`、`worker` 与 `function-runtime` 三套镜像必须构建自同一次源码提交（Revision）**；官方控制面镜像已内置对应版本的 Worker 镜像引用。
2. 妥善保留原有的 `ANKOLE_SECRET_BASE`、数据库访问凭据及部署配置文件，并为新增的 `RELEASE_COOKIE` 与 `ANKOLE_FUNCTION_RUNTIME_TOKEN` 分别生成独立的随机十六进制密钥。**升级过程中严禁更换 `ANKOLE_SECRET_BASE`**，否则新版本将无法解密存量凭据与加密配置。
3. 在停止旧版服务之前，先在现网环境中逐项排查并清零所有会阻断 Ecto 迁移的硬性预检问题：
   - **系统保留权限组重名冲突（`siteadmin` 与 `pod_admin`）**：检查特权租户下是否已有自建的 `siteadmin` 组，以及任意租户下是否已有自建的 `pod_admin` 组（尤其不能是 `computed` 动态计算组）；如有重名，请在升级前先行改名。2.0 将这两个名称收归系统保留，存在冲突会直接中止迁移。倘若迁移完成后发现某租户缺少活跃管理员，可通过 `mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG` 应急恢复（省略 `--tenant` 参数则在特权租户中恢复 `siteadmin`）。
   - **无密码登录凭证冲突预检（`Ankole.CredentialUpgrade.preflight!/1`）**：在执行不可逆的凭证转换前，迁移程序会先跑一遍只读预检——凡发现未离职清退（活跃或暂停态）的人类主体缺少有效登录邮箱、同一租户内存在两个保留主体共用同一个规范化登录邮箱，或单个主体名下挂有多个登录邮箱，预检都会立即报错终止迁移。遇到报错请先回到 1.x 环境修正异常账号数据后再试。升级会统一吊销旧版基于密码的浏览器登录会话（能够唯一映射回原浏览器凭证的离线 OIDC 会话会保留授权凭证，其余会话需重新登录授权）。原本依赖 `LocalPassword` 密码登录的站点**必须**配妥 SMTP 发信（通过 Console 的 `authn.email.mail`，或命令行 `mix ankole.authn.mail.put FILE.json` / `Ankole.Release.put_authn_mail/1`）或企业 SSO，确保自动转为邮箱验证码（`email_otp`）的用户能够顺利登录。
   - **Console 授权规则中的 CEL `resource` 变量清理**：升级后重写为 `site_console:*` / `tenant_console:*` 的旧版控制台授权规则，其 CEL `condition` 表达式中不得再引用 `resource` 变量；若存在引用了 `resource` 的自定义条件，请在升级前先行清理或改写。
4. 切断外部新请求接入并暂停所有计划任务，停用全部 Agent，等待所有在途任务自然收尾；随后正常停止全部旧版 Worker（含已暂停实例），最后停止所有旧版控制面副本。注意，切勿通过删除 Agent 的方式来关停 Worker。
5. 确认数据库实例已运行在 **PostgreSQL 18+** 上（满足 `server_version_num >= 180000`，`shared_preload_libraries` 已加载 `pg_search`，且 `pg_search` 与 `vector` 扩展均正常可用）。将 PostgreSQL 数据库（含 `BASE_DB_URLS` 中配置的所有独立分片库）、存量文件存储、全部 Agent 主目录及部署密钥一并完整备份，并一直保留至新版登录验证、租户成员核对与 OIDC 联通测试全部通过为止。建议先在还原出的数据库副本上实测一遍 2.0 迁移，以准确预估停机窗口时长。此外，使用 Docker Compose 复制旧版主目录时，宿主机磁盘需额外留出至少等同于旧共享卷已用空间的剩余容量。完整备份流程见 [备份与还原](../backup-and-restore/)。

除结构迁移外，2.0 迁移脚本还会使用新格式重新加密租户级身份源配置、拆分旧版共用的 Slack / Teams 凭证，并联网核验外部平台应用身份。因此，执行迁移的环境必须同时具备原 `ANKOLE_SECRET_BASE` 密钥、真实有效的外部平台凭据以及访问对应外部平台的网络连通性。若中途报错，请根据日志提示修复配置后原位重试，切勿手工将旧密文直接搬运粘贴到新的配置作用域下。

## Docker Compose 升级

获取目标版本的官方 [Compose 部署文件](https://github.com/AgentBull/ankole/tree/main/tools/deploy/docker-compose)（含 `compose.yaml`、`worker-providers.yaml` 与 `migrate-agent-homes.sh`）。保留原有的 `.env` 文件与 Compose 项目名称，将 `ANKOLE_CONTROL_PLANE_IMAGE` 与 `ANKOLE_FUNCTION_RUNTIME_IMAGE` 锁定为目标版本对应的镜像标签或 Digest（控制面镜像已自带匹配的 Worker 镜像引用），设置好 `ANKOLE_DOCKER_GID`，并保持原有的 `ANKOLE_WORKER_INSTALLATION` 不变。

下方命令示例默认采用本地文件系统（`fs`）存储云盘；若你的站点使用 S3 对象存储，请参照 [云盘存储配置](../drive-storage/) 准备好覆盖编排文件，并在后续每一条 `docker compose` 命令（含文件导入步骤）中带上完全一致的 `-f` 参数组合。

若现有 `.env` 中尚未配置 `RELEASE_COOKIE` 或 `ANKOLE_FUNCTION_RUNTIME_TOKEN`，请先运行以下命令补齐：

```sh
grep -q '^RELEASE_COOKIE=' .env || printf 'RELEASE_COOKIE=%s\n' "$(openssl rand -hex 32)" >> .env
grep -q '^ANKOLE_FUNCTION_RUNTIME_TOKEN=' .env || printf 'ANKOLE_FUNCTION_RUNTIME_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env
```

首次导入的默认 Worker 提供商配置必须带有 `legacy_agents: true`，且其 `provider_id` 须与主目录迁移服务的 `WORKER_PROVIDER` 环境变量保持一致（官方编排文件统一设为 `docker`）。注意，种子文件仅在数据库中提供商表为空时导入一次，此后直接修改本地 YAML 文件不会自动同步更新数据库记录。

2.0 依赖 **PostgreSQL 18+**（搭配 `pg_search` 0.25.11 与 `vector` 扩展）。若当前数据库版本低于 PostgreSQL 18，请先完成 PostgreSQL 大版本升级，再按顺序执行以下扩展升级与服务拉起命令：

```sh
docker compose pull
docker compose stop
docker compose up -d postgresql
docker compose exec postgresql psql -U ankole -d ankole -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_search UPDATE TO '0.25.11'"
docker compose up -d --force-recreate
docker compose ps -a migrate migrate-agent-homes
docker compose logs migrate migrate-agent-homes
```

其中，`migrate` 服务负责执行数据库 Schema 与加密配置迁移；`migrate-agent-homes` 服务则会先关停仍挂载着旧共享卷的容器，将现存各 Agent 的主目录逐一复制到各自的独享卷中，并将文件属主统一修正为 `uid 1000`。只有当这两个一次性迁移服务全部以成功状态退出后，新版控制面才会正式启动。主目录复制过程带有幂等完成标记，中途失败后重试不会覆盖已迁移完毕的目录；若环境中本就没有旧共享卷，该步骤会直接正常退出。

控制面启动后请继续保持各 Agent 处于停用状态。如果旧版尚未启用控制面云盘，需先放宽旧共享卷的读取权限，再运行历史文件导入命令（下例基于默认 Compose 项目名编写；若使用了自定义项目名，请将 `ankole_agents_data` 替换为实际的旧共享卷名）：

```sh
docker compose run --rm --no-deps --user root --entrypoint chmod \
  -v ankole_agents_data:/agents control-plane -R a+rX /agents
docker compose run --rm --no-deps -v ankole_agents_data:/agents:ro control-plane \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

该导入命令会将旧主目录中已安装的 Skill、自动化脚本及尚未发出的旧版发件箱（Outbox）附件复制到控制面云盘，且不会覆盖云盘上已有的同名路径；常规用户数据文件、Session 工作区与后台任务工作区则继续留在各 Agent 的新主目录内。请妥善留存控制台打印的导入报告，针对报告中标为 `Skipped` 的条目或缺失 `main.ts` 的自动化任务逐一修复后，可安全地再次运行导入命令补齐。在完成全部文件抽检与恢复演练前，请勿删除旧共享卷。

## Kubernetes / Helm 升级

1. 将旧版控制面与池化 Worker 的 Deployment 副本数均缩容至 `0`，等待所有旧 Pod 优雅退出并彻底消失——严禁附加 `--grace-period=0` 强制杀除 Pod。
2. 确认外置或集群内置数据库已升级至 **PostgreSQL 18+**。若采用了 `secrets.existingSecret`（如 `ankole-bootstrap`），在执行 `helm upgrade` 前请确保该 Secret 中除原有的 `ANKOLE_SECRET_BASE` 与 `DATABASE_URL` 外，已补齐 `RELEASE_COOKIE` 与 `ANKOLE_FUNCTION_RUNTIME_TOKEN`：

```sh
kubectl -n ankole patch secret ankole-bootstrap --type merge -p "$(printf '{"stringData":{"RELEASE_COOKIE":"%s","ANKOLE_FUNCTION_RUNTIME_TOKEN":"%s"}}' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)")"
```

   （注意：仅针对 `ankole-bootstrap` 中尚不存在的键执行补齐，切勿覆盖已有值。）
3. 保留原有的共享 Agent 主目录 PVC，将 `worker.agents.persistence.existingClaim` 指向该 PVC，同时维持原有的 `worker.installation` 与 Helm Release 名称不变。若内置 PostgreSQL 数据直接存放在存储卷根目录下，请保持原有的 `postgresql.pgdata` 路径（如 `/var/lib/pgsql/18/data`）不变，避免因挂载子路径变动而使数据库看起来变为空库。
4. 在拉起新版控制面之前，先修正旧共享主目录 PVC 内的文件属主与目录权限。以下命令适用于允许 Pod 内 `root` 用户执行 `chown` 的存储后端（请将 `OLD_AGENTS_PVC` 替换为实际 PVC 名称）：

```sh
kubectl -n ankole run ankole-agent-home-prepare --rm -i --restart=Never \
  --image=busybox:1.37 --overrides='{"apiVersion":"v1","spec":{
    "containers":[{"name":"prepare","image":"busybox:1.37",
      "securityContext":{"runAsUser":0},
      "command":["sh","-ec","chown -R 1000:1000 /agents; chmod 2777 /agents; chmod -R a+rX /agents"],
      "volumeMounts":[{"name":"agents","mountPath":"/agents"}]}],
    "volumes":[{"name":"agents","persistentVolumeClaim":{"claimName":"OLD_AGENTS_PVC"}}]}}'
```

默认开启 `root_squash` 的 NFS 服务端不允许从容器内直接执行上述 `chown`——此时需登录 NFS 服务端宿主机预先调整好文件权限，并提供允许 Worker `root` 写入及修改属主的导出挂载，或直接在存储层将全部访问映射为 `uid/gid 1000`。若使用配置了 `uid/gid 1000` 接入点（Access Point）的 AWS EFS，则存量文件天然匹配权限，无需执行此步转换。更多存储细节见 [WorkerProvider 与缓存盘](../worker-providers/)。

在 `values-production.yaml` 中填入版本严格对齐的 `controlPlane.image` 与 `functionRuntime.image` Digest（仅当需要显式覆盖内置默认引用时，才需额外指定同版本的 `worker.image`），配妥[云盘后端](../drive-storage/)与上述旧 PVC 引用，然后依次运行以下命令（示例假设命名空间与 Release 名称均为 `ankole`，且设置了 `fullnameOverride: ankole`）：

```sh
helm upgrade ankole ./tools/deploy/helm/ankole-agent \
  --namespace ankole --values values-production.yaml \
  --set files.importAgentHomeClaim=OLD_AGENTS_PVC --wait --timeout 15m
kubectl -n ankole exec deployment/ankole-control-plane -c control-plane -- \
  /app/bin/ankole eval 'Ankole.Upgrade202610.import_agent_home("/agents")'
```

控制面 Deployment 采用 `Recreate` 更新策略，新 Pod 启动时会先由 `db-migrate` 初始化容器完成数据库迁移。在历史文件导入彻底完成前，请继续保持所有 Agent 处于停用状态。核对导入报告确认无误后，去掉 `--set files.importAgentHomeClaim=OLD_AGENTS_PVC` 参数再执行一次 `helm upgrade` 以卸载控制面上的临时导入挂载——但切记保留该旧主目录 PVC 本身，因为各独享 Worker Pod 仍需继续挂载使用它。若你的集群采用了自定义 Release 名、命名空间或 Deployment 名称，请相应替换命令中的对象名。完整 Chart 参数说明见 [Helm 部署说明](https://github.com/AgentBull/ankole/blob/main/tools/deploy/helm/ankole-agent/README.zh-Hans.md)。

## 验证与失败恢复

- **核对控制面资产**：登录新版站点管理控制台，检查 `default` 租户下的存量 Agent、身份源提供商、信号路由绑定及历史任务是否完整就位。确认每个存量 Agent 均已成功指派 `WorkerProvider`（全局默认提供商仅对后续新建的 Agent 生效）。
- **单点灰度实测**：先单独启用一个测试 Agent，实际触发一轮文件读写与后台任务，逐一验证原主目录文件读取、Codex 历史线程恢复、已导入的 Skill 与自动化脚本调用，以及云盘文件上传下载与聊天附件收发；全部验证通过后，再分批重新启用其余 Agent 与定时计划任务。
- **迁移中途报错处置**：一旦迁移失败，请保持旧版控制面处于关停状态，查看 Docker Compose 的 `migrate` 日志或 Kubernetes 的 `db-migrate` 容器日志；按报错提示修正缺失密钥、失效外部凭据、保留组名冲突或存储挂载权限后，使用同一目标版本重新运行迁移。
- **清理孤儿主目录**：文件导入报告中会单独列出早期已删除 Agent 遗留在磁盘上的孤儿目录，导入脚本不会为它们反向重建新 Agent；人工核实目录内确无需要保留的历史产物后，再行清理。
- **执行完整回退**：如需回退至升级前的 1.x 版本，必须先停止所有新版控制面、`ankole-function-runtime` 副本与全部 Worker，随后将升级前备份的 PostgreSQL 数据库（含所有已配置的 `BASE_DB_URLS` 分片库）、文件存储、Agent 主目录、部署配置及原密钥**成套同步还原**，最后再拉起旧版镜像。单纯执行 `helm rollback` 或回退容器镜像版本，既无法撤销不可逆的无密码凭证转换与数据库 Schema 变更，也无法保留升级窗口后新产生的未导出数据。

升级完成后的日常节点管理、存储扩容与容灾演练，请参阅 [工作节点](../worker-management/)、[云盘存储配置](../drive-storage/) 与 [灾难恢复](../disaster-recovery/)。
