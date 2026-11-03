# ARM64 Release 与远端 Docker 部署

本仓库的 `Release` 工作流会构建 `linux/arm64` Release 可执行文件，并把它封装进 GHCR 多架构镜像。启用远端部署后，每次发布 `v*` 标签都会在 Release 成功后自动连接 ARM64 服务器，安装 Docker（如果尚未安装），然后更新容器。

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

也可以在 GitHub 的 **Actions → Release → Run workflow** 手动指定标签运行。

不要为生产 ARM64 部署启用 `simple_release`；该模式只生成 x86_64 镜像，部署 Job 会自动跳过它。

## 2. 准备 ARM64 服务器

支持运行 ARM64 Linux 的服务器，SSH 用户需要具有免交互 `sudo` 权限。部署程序会校验 `uname -m` 为 `aarch64` 或 `arm64`。Docker 不存在时，脚本通过 Docker 官方安装脚本安装 Engine 与 Compose 插件。

在服务器上添加仅用于部署的 SSH 公钥：

```bash
ssh-keygen -t ed25519 -C "github-actions-sub2api"
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server
ssh-keyscan -H server.example.com
```

请把私钥安全保存到 GitHub Secret，完成后从日常电脑删除该部署私钥也可以。不要把私钥或服务器 `.env` 提交到 Git。

## 3. 配置 GitHub Environment

先在仓库 **Settings → Secrets and variables → Actions → Variables** 添加仓库级变量 `ENABLE_ARM64_DEPLOY=true`。然后在 **Settings → Environments** 创建 `arm64-production`；建议为该环境启用审批规则，并添加其余配置：

| 类型 | 名称 | 内容 |
|---|---|---|
| Repository Variable | `ENABLE_ARM64_DEPLOY` | `true` |
| Variable | `ARM64_DEPLOY_PATH` | 可选，默认 `/opt/sub2api` |
| Secret | `ARM64_HOST` | 服务器域名或 IP |
| Secret | `ARM64_USER` | SSH 用户名 |
| Secret | `ARM64_SSH_PORT` | 可选，默认 `22` |
| Secret | `ARM64_SSH_PRIVATE_KEY` | 完整 OpenSSH 私钥 |
| Secret | `ARM64_SSH_KNOWN_HOSTS` | `ssh-keyscan -H 主机` 的完整输出 |
| Secret | `ARM64_DEPLOY_ENV` | 可选，完整生产 `.env` 内容 |

注意：`ENABLE_ARM64_DEPLOY` 用在 Job 条件判断中，因此应设置为仓库级 Actions Variable；其余值可以放在 `arm64-production` Environment 中。若 Environment 设置了人工审批，Release 仍会先正常发布，部署 Job 等待批准。

未设置 `ARM64_DEPLOY_ENV` 时，首次部署会自动生成 `POSTGRES_PASSWORD`、`JWT_SECRET` 与 `TOTP_ENCRYPTION_KEY`，并以 `0600` 权限保存到 `/opt/sub2api/.env`。后续发布保留该文件，只更新 `SUB2API_IMAGE`。若提供 `ARM64_DEPLOY_ENV`，每次部署都会用 Secret 中的完整内容替换服务器 `.env`，适合集中管理配置。

## 4. 发布与检查

推送 `v*` 标签后，工作流依次执行：

1. 构建前端和 ARM64 Release 可执行文件；
2. 创建 GitHub Release，并发布 `ghcr.io/<仓库所有者>/sub2api:<版本>`；
3. 登录远端服务器；
4. 安装或检查 Docker；
5. 执行 `docker compose pull` 和 `docker compose up -d`。

服务器检查命令：

```bash
cd /opt/sub2api
sudo docker compose ps
sudo docker compose logs -f sub2api
curl http://127.0.0.1:8080/health
```

应用、PostgreSQL 与 Redis 数据都保存在 Docker named volumes 中，更新应用镜像不会删除数据。首次启动若没有指定管理员账号，管理员邮箱和密码会输出到 `sub2api` 容器日志，请立即保存并修改密码。

## 5. 回滚

将服务器 `.env` 中的 `SUB2API_IMAGE` 改为之前的不可变版本标签，然后重新启动：

```bash
cd /opt/sub2api
sudo sed -i 's|^SUB2API_IMAGE=.*|SUB2API_IMAGE=ghcr.io/owner/sub2api:1.2.2|' .env
sudo docker compose pull
sudo docker compose up -d
```

数据库迁移可能无法向后兼容。生产发布前应备份 PostgreSQL 数据，并确认目标版本的迁移说明。
