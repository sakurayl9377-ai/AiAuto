# CodeMate 后端部署教程

本文档说明如何把 `backend` 授权服务器上传到 GitHub，并在 Linux 服务器上一键安装、更新和配置 Nginx 反向代理。

推荐部署方式：Docker Compose + Nginx + HTTPS。

## 1. 上传到 GitHub

在本地项目根目录执行：

```powershell
git init
git add .
git commit -m "initial codemate backend"
git branch -M main
git remote add origin https://github.com/你的用户名/你的仓库名.git
git push -u origin main
```

如果你只想上传后端和部署脚本，至少需要包含这些文件：

```text
backend/
scripts/deploy-license-server.sh
docs/license-server-deploy.md
```

不要提交服务器运行数据和密钥：

```text
backend/.env
backend/data/
backend/node_modules/
```

## 2. 服务器准备

建议使用 Ubuntu 22.04/24.04 或 Debian 12。先登录服务器：

```bash
ssh root@你的服务器IP
```

安装基础工具：

```bash
apt update
apt install -y git curl ca-certificates openssl nginx
```

如果服务器没有 Docker，一键部署脚本会自动安装 Docker。也可以提前安装：

```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

## 3. 一键安装部署

把下面变量换成你的 GitHub 仓库地址和域名。

有域名和 Nginx 的推荐写法：

```bash
REPO_URL=https://github.com/你的用户名/你的仓库名.git \
BRANCH=main \
APP_DIR=/opt/codemate-license-server \
HOST_PORT=8086 \
PUBLIC_BASE_URL=https://license.example.com \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库名/main/scripts/deploy-license-server.sh)"
```

只有 IP 测试时也可以先这样：

```bash
REPO_URL=https://github.com/你的用户名/你的仓库名.git \
BRANCH=main \
APP_DIR=/opt/codemate-license-server \
HOST_PORT=8086 \
PUBLIC_BASE_URL=http://你的服务器IP:8086 \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库名/main/scripts/deploy-license-server.sh)"
```

脚本会自动完成：

- 安装 Docker 和 Docker Compose 插件
- 拉取 GitHub 仓库到 `/opt/codemate-license-server`
- 生成 `backend/.env`
- 自动生成 `ADMIN_TOKEN`
- 启动 `codemate-license-server` 容器

部署完成后会输出：

```text
Admin URL: https://license.example.com/admin
Health URL: https://license.example.com/health
Admin Token: xxxxxxxxxx
```

首次打开 `/admin` 会创建管理员账号和密码。`ADMIN_TOKEN` 主要用于 API 或脚本管理，要保密。

## 4. Docker Compose 说明

容器内部端口默认是 `8787`，服务器本机映射端口默认是 `8086`。

`.env` 位置：

```text
/opt/codemate-license-server/backend/.env
```

典型内容：

```env
PORT=8787
HOST_PORT=8086
ADMIN_TOKEN=自动生成的一长串随机值
DB_PATH=/app/data/licenses.db
PUBLIC_BASE_URL=https://license.example.com
```

数据库文件位置：

```text
/opt/codemate-license-server/backend/data/licenses.db
```

请定期备份整个目录：

```text
/opt/codemate-license-server/backend/data
```

## 5. Nginx 反向代理配置

假设域名是 `license.example.com`，后端容器映射在本机 `127.0.0.1:8086`。

创建配置：

```bash
nano /etc/nginx/sites-available/codemate-license-server.conf
```

写入：

```nginx
server {
    listen 80;
    server_name license.example.com;

    client_max_body_size 2m;

    location / {
        proxy_pass http://127.0.0.1:8086;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 30s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
```

启用配置：

```bash
ln -sf /etc/nginx/sites-available/codemate-license-server.conf /etc/nginx/sites-enabled/codemate-license-server.conf
nginx -t
systemctl reload nginx
```

现在可以访问：

```text
http://license.example.com/health
http://license.example.com/admin
```

## 6. 配置 HTTPS

推荐使用 Certbot：

```bash
apt install -y certbot python3-certbot-nginx
certbot --nginx -d license.example.com
```

按提示输入邮箱并同意自动跳转 HTTPS。成功后访问：

```text
https://license.example.com/health
https://license.example.com/admin
```

检查自动续期：

```bash
certbot renew --dry-run
```

HTTPS 生效后，确认 `.env` 里的 `PUBLIC_BASE_URL` 是 HTTPS：

```bash
cd /opt/codemate-license-server/backend
nano .env
docker compose restart
```

应该类似：

```env
PUBLIC_BASE_URL=https://license.example.com
```

## 7. 防火墙建议

如果使用 Nginx 代理，公网只需要开放 `80` 和 `443`。

Ubuntu UFW 示例：

```bash
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw enable
ufw status
```

云服务器安全组也要放行：

```text
TCP 22
TCP 80
TCP 443
```

测试阶段如果直接访问 `http://服务器IP:8086`，还需要临时放行：

```text
TCP 8086
```

正式走 Nginx 后，建议关闭公网 `8086`。

## 8. 常用运维命令

进入后端目录：

```bash
cd /opt/codemate-license-server/backend
```

查看容器：

```bash
docker compose ps
```

查看日志：

```bash
docker compose logs -f
```

重启服务：

```bash
docker compose restart
```

更新代码并重新构建：

```bash
cd /opt/codemate-license-server
git pull --ff-only origin main
cd backend
docker compose up -d --build
```

也可以重新执行一键部署命令，脚本会自动拉取最新代码并保留已有 `ADMIN_TOKEN`。

备份数据库：

```bash
mkdir -p /root/codemate-backups
tar -czf /root/codemate-backups/codemate-data-$(date +%Y%m%d-%H%M%S).tar.gz \
  -C /opt/codemate-license-server/backend data
```

## 9. 客户端填写地址

客户端授权服务器地址填写：

```text
https://license.example.com
```

如果只是 IP 测试：

```text
http://你的服务器IP:8086
```

不要在客户端地址末尾加 `/admin` 或 `/api`。

## 10. API 简单测试

健康检查：

```bash
curl https://license.example.com/health
```

使用 `ADMIN_TOKEN` 创建授权码：

```bash
ADMIN_TOKEN="$(grep '^ADMIN_TOKEN=' /opt/codemate-license-server/backend/.env | cut -d= -f2-)"

curl -X POST https://license.example.com/api/licenses/create \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"plan":"pro","maxActivations":1}'
```

## 11. 排错

Nginx 配置检查：

```bash
nginx -t
systemctl status nginx
journalctl -u nginx -n 100 --no-pager
```

后端容器日志：

```bash
cd /opt/codemate-license-server/backend
docker compose logs -f
```

确认本机端口可访问：

```bash
curl http://127.0.0.1:8086/health
```

确认 Docker Compose 可用：

```bash
docker compose version
```

如果 `/admin` 登录后反复掉线，通常是 HTTPS 代理头不对，确认 Nginx 配置里有：

```nginx
proxy_set_header X-Forwarded-Proto $scheme;
```

本项目后端已经设置了 `trust proxy`，走 HTTPS 反代时会自动给后台登录 Cookie 加 `Secure`。
