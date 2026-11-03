# AMD64/ARM64 Release 与远端 Docker 部署

本仓库的 `Release` 工作流会同时构建 `linux/amd64` 和 `linux/arm64` Release 可执行文件，并将它们封装为 GHCR 多架构镜像。远端服务器执行 `docker pull` 时，Docker 会自动选择与服务器匹配的镜像。

支持的服务器架构：

| `uname -m` | Release 架构 | 常见服务器 |
|---|---|---|
| `x86_64`、`amd64` | `linux/amd64` | Intel、AMD 云服务器 |
| `aarch64`、`arm64` | `linux/arm64` | ARM、Ampere 云服务器 |

## 1. 本地维护并推送代码

```bash
git checkout main
git pull --rebase origin main

# 修改并验证代码后
git add .
git commit -m "描述本次修改"
git push origin main
```

普通分支推送只运行 CI，不发布 Release。确认 CI 通过后，用语义化版本标签触发发布：

```bash
git tag -a v1.2.3 -m "v1.2.3"
git push origin v1.2.3
```

也可以在 GitHub 的 **Actions → Release → Run workflow** 手动指定标签运行。生产部署不要启用 `simple_release`；该模式只生成 AMD64 镜像，自动部署 Job 会跳过它。

## 2. 准备生产服务器

在服务器确认架构：

```bash
uname -m
```

SSH 用户可以是 `root`，也可以是具有免交互 `sudo` 权限的普通用户。Docker 不存在时，脚本会通过 Docker 官方安装脚本安装 Engine 与 Compose 插件。服务器需要预装 `curl`。

建议创建仅用于 GitHub Actions 部署的 SSH 密钥，并将公钥加入服务器用户的 `~/.ssh/authorized_keys`：

```bash
ssh-keygen -t ed25519 -C "github-actions-sub2api"
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server
ssh-keyscan -H server.example.com
```

不要把私钥或服务器 `.env` 提交到 Git。

## 3. 配置 GitHub Environment

在仓库 **Settings → Secrets and variables → Actions → Variables** 添加仓库级变量：

| 类型 | 名称 | 内容 |
|---|---|---|
| Repository Variable | `ENABLE_PRODUCTION_DEPLOY` | `true` |
| Variable | `DEPLOY_PATH` | 可选，默认 `/opt/sub2api` |

然后在 **Settings → Environments** 创建名为 `production` 的环境。建议启用人工审批，并添加：

| 类型 | 名称 | 内容 |
|---|---|---|
| Secret | `DEPLOY_HOST` | 服务器域名或 IP |
| Secret | `DEPLOY_USER` | SSH 用户名，可以是 `root` |
| Secret | `DEPLOY_SSH_PORT` | 可选，默认 `22` |
| Secret | `DEPLOY_SSH_PRIVATE_KEY` | 完整、无口令的 OpenSSH 私钥 |
| Secret | `DEPLOY_SSH_KNOWN_HOSTS` | `ssh-keyscan -H 主机` 的完整输出 |
| Secret | `DEPLOY_ENV` | 可选，完整生产 `.env` 内容 |

`ENABLE_PRODUCTION_DEPLOY` 用于 Job 条件判断，必须是仓库级 Actions Variable。其他 Secrets 放在 `production` Environment 中。

未设置 `DEPLOY_ENV` 时，首次部署会自动生成 `POSTGRES_PASSWORD`、`JWT_SECRET` 和 `TOTP_ENCRYPTION_KEY`，并以 `0600` 权限保存到 `/opt/sub2api/.env`。后续发布保留已有配置和数据，只更新 `SUB2API_IMAGE`。

如果设置 `DEPLOY_ENV`，每次部署会先用 Secret 中的完整内容更新服务器 `.env`，然后将 `SUB2API_IMAGE` 设置为本次 Release 的不可变版本标签。

## 4. 发布与检查

推送 `v*` 标签后，工作流依次执行：

1. 构建前端和 AMD64/ARM64 Release 可执行文件；
2. 创建 GitHub Release；
3. 发布 `ghcr.io/<仓库所有者>/sub2api:<版本>` 多架构镜像；
4. 登录生产服务器并识别 CPU 架构；
5. 安装或检查 Docker；
6. 执行 `docker compose pull` 和 `docker compose up -d`。

服务器检查命令；以 `root` 登录时不需要 `sudo`：

```bash
cd /opt/sub2api
docker compose ps
docker compose logs -f sub2api
curl http://127.0.0.1:8080/health
```

验证实际拉取的镜像架构：

```bash
docker image inspect "$(docker compose images -q sub2api)" \
  --format '{{.Os}}/{{.Architecture}}'
```

在 `x86_64` 服务器上应输出 `linux/amd64`，在 ARM64 服务器上应输出 `linux/arm64`。

应用、PostgreSQL 与 Redis 数据保存在 Docker named volumes 中，更新应用镜像不会删除数据。首次启动若没有指定管理员账号，管理员邮箱和密码会输出到 `sub2api` 容器日志。

## 5. 回滚

将服务器 `.env` 中的 `SUB2API_IMAGE` 改为之前的不可变版本标签，然后重新启动：

```bash
cd /opt/sub2api
sed -i 's|^SUB2API_IMAGE=.*|SUB2API_IMAGE=ghcr.io/owner/sub2api:1.2.2|' .env
docker compose pull
docker compose up -d
```

数据库迁移可能无法向后兼容。生产发布前应备份 PostgreSQL 数据，并确认目标版本的迁移说明。
