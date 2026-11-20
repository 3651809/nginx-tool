# nginx-tool

在 Debian 上源码编译安装 nginx 并做生产环境基线配置的一键脚本。一个文件，带交互菜单，可反复执行。

```bash
bash <(curl -fsSL https://gh-proxy.org/https://github.com/3651809/nginx-tool/blob/main/install_nginx.sh)
```

不求覆盖所有发行版，只解决一件事：**从干净的 Debian 到一台可以直接放站点的 nginx**，装的每一步都能查、能修、能卸。

---

## 特性

- **跟随官方最新版**：每次 `install` 自动查 nginx.org，稳定版出了新补丁直接升上去，不用改脚本；也能锁定具体版本
- **源码编译**，不依赖发行版仓库里那个版本偏旧、模块被裁剪的 nginx
- **幂等**：重复执行不会重复编译，配置按版本号升级，站点配置永远不覆盖
- **多镜像下载**：华为云 / 搜狐 / 官方三源，自动测速择优，主源挂掉自动换下一个，下载后校验 tar 包
- **升级前先看改了什么**：从官方 CHANGES 抓当前版本的条目打印出来，再决定升不升
- **能回滚**：每次升级把旧二进制留在 `backup/`，菜单里一键切回去
- **生产基线**：日志按天切割保留 14 天、内核参数、句柄上限、`server_tokens` 关闭、`/healthz` 健康检查
- **体检**：只读检查，输出 `✓ / ! / ✗`，能定位到具体哪一项、怎么修
- **证书一条龙**：Cloudflare / 阿里云 / 腾讯云 / 华为云 DNS 验证，或 HTTP 验证，带自动续签
- **一键卸载**：删干净，删之前先打包留档
- **不会误删**：`rm -rf` 前校验 `nginx.conf` 里的标记，目录不是本脚本建的就拒绝

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 13 (trixie)，Debian 12 亦可 |
| 权限 | root |
| 内存 | 512MB 以上（低于 2GB 且编译内置 OpenSSL 时自动降并行度） |
| 网络 | 拉脚本要能访问 `gh-proxy.org` 或 jsDelivr；下载源码要能访问 `nginx.org` 或 `mirrors.huaweicloud.com`、`mirrors.sohu.com` 中任意一个 |

第一次运行会自动：换国内 apt 源（原文件备份）→ 装编译依赖 → 下载源码 → 编译 → 装服务。

---

## 运行方式

### 1. 在线一键运行（推荐）

```bash
bash <(curl -fsSL https://gh-proxy.org/https://github.com/3651809/nginx-tool/blob/main/install_nginx.sh)
```

只检查语法、不执行：

```bash
bash -n <(curl -fsSL https://gh-proxy.org/https://github.com/3651809/nginx-tool/blob/main/install_nginx.sh)
```

> 不要用 `curl ... | bash`。管道会把脚本本身喂给 stdin，交互菜单里的输入就读不到了。

上面地址不通时换下面任意一条：

```bash
# jsDelivr，要用 fastly. 前缀，cdn. 前缀国内不通；@main 最长缓存 12 小时
bash <(curl -fsSL https://fastly.jsdelivr.net/gh/3651809/nginx-tool@main/install_nginx.sh)

# 源码包，不经过任何 CDN
cd /tmp && rm -rf nginx-tool-main && curl -fsSL https://codeload.github.com/3651809/nginx-tool/tar.gz/main | tar xz && bash nginx-tool-main/install_nginx.sh
```

### 2. 下载后运行

```bash
git clone https://github.com/3651809/nginx-tool.git
cd nginx-tool
bash install_nginx.sh
```

> Windows 上编辑过这个文件会变成 CRLF，脚本会检测到并自动转成 LF 后重新执行。

### 3. 命令行直连（自动化 / 无终端）

```bash
bash install_nginx.sh install     # 安装或升级
bash install_nginx.sh repair      # 修复
bash install_nginx.sh doctor      # 体检
bash install_nginx.sh status      # 运行状态
bash install_nginx.sh uninstall   # 卸载
bash install_nginx.sh help        # 帮助
```

---

## 交互菜单

```
  ▎ nginx 1.30.7  ·  管理控制台
  ──────────────────────────────────────────────────────────
    ●  运行中  pid 4242  ·  /home/nginx  ·  通道 stable · 源 自动测速

  ╭───────────────────────────────────────────────────────╮
  │  安装 / 更新 · 查最新版 · 编译 · 生产基线 · 开机自启  │
  │  版本通道 · stable / mainline / 锁定具体版本          │
  │  镜像源 · 自动测速 / 指定 / 自定义                    │
  │  修复 · 重建配置、权限、服务                          │
  │  体检 · 只读检查，不改动任何东西                      │
  │  运行状态 · 版本、进程、端口监听                      │
  │  证书管理 · 申请 · 续签 · 到期查看                    │
  │  查看日志 · access / error                            │
  │  重载 / 重启 · 改完配置用重载                         │
  │  回滚 · 切回之前备份的二进制                          │
  │  备份配置 · 打包 conf 目录                            │
  │  外网访问排查 · 端口、防火墙、公网 IP                 │
  │  卸载 · 停服务，清掉本脚本装的全部内容                │
  │  退出                                                 │
  ╰──────────────────────────── ↑↓ 移动   ↵ 确认   q 退出 ╯
```

方向键移动，回车确认，`q` 返回；也支持直接按数字。

---

## 装到哪里

| 内容 | 路径 |
|---|---|
| 编译与运行文件 | `/home/nginx/install` |
| 主配置 | `/home/nginx/conf/nginx.conf` |
| 站点配置 | `/home/nginx/conf/conf.d/*.conf` |
| 日志 | `/home/nginx/logs/{access,error}.log` |
| 证书 | `/home/nginx/cert/<域名>/` |
| 配置备份 | `/home/nginx/backup/<时间戳>/`（保留最近 10 份） |
| 旧二进制 | `/home/nginx/backup/nginx-<版本>.bin`（升级时自动留） |
| 工具设置 | `/home/nginx/tool.conf`（版本通道 / 镜像源） |
| 证书工具 | `/home/nginx/acme` |
| systemd 单元 | `/etc/systemd/system/nginx.service` |
| 日志切割 | `/etc/logrotate.d/nginx-custom` |
| 内核参数 | `/etc/sysctl.d/99-nginx.conf` |
| 句柄上限 | `/etc/security/limits.d/nginx.conf` |

站点配置放在 `conf.d/*.conf`，**升级脚本不会覆盖它**。想改 `nginx.conf` 本身，用 `FORCE_CONF=1` 显式覆盖，覆盖前会自动备份。

---

## 环境变量

| 变量 | 作用 |
|---|---|
| `NGINX_CHANNEL=stable` | `install` 的目标版本通道：`stable`（默认，跟随官方稳定版）/ `mainline`（主线版）/ 具体版本号如 `1.30.7` |
| `NGINX_MIRROR=auto` | 源码镜像源：`auto`（默认，测速择优）/ 具体镜像地址 |
| `BUNDLED_OPENSSL=1` | 源码编译 OpenSSL 1.1.1w，不用系统 OpenSSL 3.x |
| `FORCE_REBUILD=1` | `install` 时强制重新编译（版本相同也重编） |
| `FORCE_CONF=1` | `install` / `repair` 时覆盖已有 `nginx.conf` |
| `FORCE_YES=1` | `uninstall` 时跳过确认，直接删 |

环境变量优先级高于菜单里存下的 `/home/nginx/tool.conf`。

```bash
FORCE_REBUILD=1 bash install_nginx.sh install
FORCE_YES=1 bash install_nginx.sh uninstall
```

---

## 版本通道

菜单 → 版本通道，选一次就记住，写进 `/home/nginx/tool.conf`：

| 选项 | 行为 |
|---|---|
| `stable` | 每次 `install` 查官方稳定版，有补丁就升（生产推荐） |
| `mainline` | 每次 `install` 查官方主线版，新特性优先 |
| 锁定版本 | 固定编某个版本号，不再自动跟 |
| 查看最新 | 只查不装，显示两个通道当前版本和已装版本 |

命令行临时覆盖：

```bash
NGINX_CHANNEL=mainline bash install_nginx.sh install
NGINX_CHANNEL=1.30.7 bash install_nginx.sh install
```

`mainline` 主线版变更比 `stable` 频繁，生产环境建议留在 `stable`。

---

## 镜像源

菜单 → 镜像源：

| 选项 | 行为 |
|---|---|
| 自动测速 | 每次 `install` 对各源发 HEAD 测延迟，最快的先用，其余依次做后备（推荐） |
| 华为云 / 搜狐 / 官方 | 指定主源，其余仍做后备 |
| 自定义 | 填自己的镜像地址（内网镜像、私有仓库），其余仍做后备 |
| 测速 | 立刻测一遍，看各源现在多快 |

内置三个源（2026-11 实测均可下载）：

```
https://mirrors.huaweicloud.com/nginx
https://mirrors.sohu.com/nginx
https://nginx.org/download
```

腾讯云、阿里云、清华、中科大没有 nginx 目录，未纳入。下载前先用 `curl -I` 预检，连不通的源直接跳过，不会在死源上干等超时；下完校验 tar 包，防止镜像返回 HTML 错误页。

---

## 升级

菜单 → 安装 / 更新，或直接：

```bash
bash install_nginx.sh install
```

流程：查官方版本 → 和已装版本比对 → 选下载源 → **打印本版 CHANGES** → 下载、编译、替换二进制 → 重启服务 → 清理源码目录。

- 版本相同则跳过编译，只重建配置，几秒结束
- 版本不同会先把官方 `CHANGES-<x.y>` 里这个版本的条目打印出来，看清修了什么再往下走
- 编译期间服务不停（旧二进制改名腾位置，进程继续跑旧 inode），只有最后 `restart` 那一刻切换
- 换二进制后必须 `restart` 而不是 `reload`：`reload` 只让 master 重读配置，工作进程仍跑旧二进制，版本不会变
- 新二进制版本校验不过会自动回滚；`restart` 失败会打印回滚命令，旧二进制备份在 `/home/nginx/backup/nginx-<旧版本>.bin`

### 回滚

菜单 → 回滚，列出 `backup/` 下的所有旧二进制，选中确认后会：

1. 把当前二进制也存一份（回滚完还能再滚回来）
2. 换上新选的二进制
3. `restart` 并校验版本

只换二进制，配置不动——如果配置文件本身不兼容旧版本，得另外从 `backup/<时间戳>/` 恢复。

指定版本 / 走主线版：

```bash
NGINX_CHANNEL=mainline bash install_nginx.sh install   # 升到最新主线版
NGINX_CHANNEL=1.30.7 bash install_nginx.sh install     # 锁定具体版本
```

体检（`doctor`）里的「版本」一节会联网比对官方稳定版，落后会提示升级。网络不通时跳过比对，不影响其它检查。

---

## 证书

菜单 → 证书管理 → 申请证书，五步走完：

1. 填域名（`example.com` 或 `api.example.com`，原样填浏览器地址栏里那个）
2. 选范围：只签这一个 / 连所有子域名一起签
3. 选验证方式：HTTP（推荐）或 DNS
4. HTTP 方式准备验证目录；DNS 方式选服务商填 API key
5. 签发并装到 `/home/nginx/cert/<域名>/`

**泛域名按根域名签**：填 `api.example.com` 选「连所有子域名」时，签的是 `example.com` + `*.example.com`，不是 `*.api.example.com`。后者只能盖三级域名，日常用不上。

nginx 里引用（路径固定，续签后自动生效，这两行不用再改）：

```nginx
ssl_certificate     /home/nginx/cert/example.com/fullchain.pem;
ssl_certificate_key /home/nginx/cert/example.com/privkey.pem;
```

续签：acme.sh 每天 03:00 检查，到期前自动续，续完自动 `systemctl reload nginx`。

---

## 常用操作

```bash
# 改完配置先测再重载
/home/nginx/install/sbin/nginx -t && systemctl reload nginx

# 看日志
tail -f /home/nginx/logs/error.log

# 体检
bash install_nginx.sh doctor

# 服务起不来：先看诊断输出
systemctl status nginx
journalctl -u nginx -n 50
```

`reload` 依赖 `/home/nginx/run/nginx.pid`，pid 文件丢了 `reload` 必失败，用「修复」重建即可。

---

## 排障

| 现象 | 处理 |
|---|---|
| 外网打不开、本机能访问 | 云厂商安全组没放行 80/443，走「外网访问排查」逐层定位 |
| `nginx: [emerg] bind() to 0.0.0.0:80 failed` | 80 被别的进程占了，`ss -lntp \| grep :80` 看是谁 |
| `reload` 失败 | pid 文件缺失或路径不一致，执行「修复」 |
| 配置语法错误 | `nginx -t` 有具体行号，改完再 reload |
| 编译卡住 / 内存不足 | 加 swap，或设 `BUNDLED_OPENSSL=0` 用系统 OpenSSL |
| 证书签发失败 | 日志末尾有原因；HTTP 验证要确认域名已解析且 80 可达，否则改用 DNS |

---

## 卸载

菜单 → 卸载，或 `bash install_nginx.sh uninstall`。

会清掉：`/home/nginx` 整个目录、systemd 单元、日志切割 / 内核参数 / 句柄上限配置、acme.sh 的定时任务、`nginx` 系统用户。

不动：apt 装的软件包、其它程序、系统防火墙规则。

删除前会把 `conf` / `cert` / `backup` 打包到 `/root/nginx-uninstall-<时间戳>.tar.gz`（权限 600，含私钥），要恢复就解回 `/home/nginx` 再重新安装。

---

## 说明

- 脚本只用 bash + 常见系统命令，不依赖 Python / Node
- 所有改动都在上面那张路径表里，不碰 `/usr/local`、不装第三方 apt 源
- 编译参数见脚本 `build_nginx()`，要加模块直接改那个数组
