#!/bin/bash
# nginx 生产级部署与运维脚本（Debian 13 trixie）
#
#   直接执行，终端里选菜单：   bash install_nginx.sh
#   命令行直连（脚本/自动化）：  bash install_nginx.sh install|repair|doctor|status|uninstall
#
# 运行时统一用 bash install_nginx.sh。用 ./install_nginx.sh 时，若文件被 Windows
# 存成 CRLF，内核会因为 shebang 末尾的 \r 直接报 bad interpreter，脚本自身无法补救。
#
if [ -z "${NGX_LF_OK:-}" ] && head -c 8192 "$0" 2>/dev/null | od -An -c | grep -qF '\r'; then printf '\033[33m[提示]\033[0m 检测到 Windows 换行符（CRLF），自动转成 Unix 格式后重新执行\n'; sed -i 's/\r$//' "$0" 2>/dev/null || true; NGX_LF_OK=1 exec bash "$0" "$@" ; fi  # 必须单行，行尾注释用于吞掉 CRLF 的 \r

set -euo pipefail

INTERRUPTED=0
trap 'rc=$?; [ "$INTERRUPTED" = "1" ] && exit 130; printf "\n  \033[31m✗\033[0m \033[31m第 %s 行出错，退出码 %s\033[0m\n" "$LINENO" "$rc" >&2' ERR

# ============================================================
# 可调参数（只改这一段，下面逻辑不用动）
# ============================================================
NGINX_VERSION=1.30.6
OPENSSL_VERSION=1.1.1w
ZLIB_VERSION=1.2.13

BUNDLED_OPENSSL=${BUNDLED_OPENSSL:-0}   # 0=系统 OpenSSL 3.x/zlib  1=源码编译 1.1.1w
FORCE_REBUILD=${FORCE_REBUILD:-0}       # 1=install 时强制重新编译
FORCE_CONF=${FORCE_CONF:-0}             # 1=install/repair 时覆盖已有配置

BASE=/home/nginx
INSTALL_DIR=$BASE/install
BUILD_DIR=$BASE/build
LOGS_DIR=$BASE/logs
CONF_DIR=$BASE/conf
CERT_DIR=$BASE/cert
RUN_DIR=$BASE/run
CACHE_DIR=$BASE/cache
BACKUP_DIR=$BASE/backup
ACME_HOME=$BASE/acme
ACME_SH=$ACME_HOME/acme.sh
VHOST_DIR=$CONF_DIR/conf.d

NGINX_USER=nginx
NGINX_BIN=$INSTALL_DIR/sbin/nginx
SERVICE_FILE=/etc/systemd/system/nginx.service
LOGROTATE_FILE=/etc/logrotate.d/nginx-custom
SYSCTL_FILE=/etc/sysctl.d/99-nginx.conf
LIMITS_FILE=/etc/security/limits.d/nginx.conf
MARKER="managed-by: install_nginx.sh"
CONF_VERSION=3                          # 配置模板版本，升级模板时 +1，安装时自动覆盖旧版

MIRROR_NGINX=https://mirrors.huaweicloud.com/nginx
MIRROR_APT=mirrors.huaweicloud.com

N_FAIL=0
N_WARN=0
N_OK=0

# ============================================================
# 输出与终端
# ============================================================
C_RST=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RED=$'\033[31m'
C_GRN=$'\033[32m'
C_YEL=$'\033[33m'
C_CYN=$'\033[36m'
C_GRY=$'\033[90m'
C_WHT=$'\033[0;37m'
C_SEL=$'\033[1;30;46m'       # 选中行：黑字 + 青底
C_TTL=$'\033[1;97m'          # 标题用亮白

# 可见宽度：按 UTF-8 字节流判断。
# 中日韩文字与全角标点（E3..E9、EF 开头）记 2 列，箭头 / 制表符 / 几何图形（E2 开头）
# 和 2 字节字符记 1 列。画框对齐全靠它。
dw() {
  local s i=0 w=0 c1
  s=$(printf '%s' "${1-}" | sed 's/\x1b\[[0-9;]*m//g')
  local -a by=()
  read -r -a by <<< "$(printf '%s' "$s" | od -An -tu1 -v | tr '\n' ' ')"
  local n=${#by[@]}
  while [ "$i" -lt "$n" ]; do
    c1=${by[i]}
    if [ "$c1" -lt 128 ]; then
      w=$((w + 1)); i=$((i + 1))
    elif [ "$c1" -lt 224 ]; then
      w=$((w + 1)); i=$((i + 2))
    elif [ "$c1" -lt 240 ]; then
      if { [ "$c1" -ge 227 ] && [ "$c1" -le 233 ]; } || [ "$c1" -eq 239 ]; then
        w=$((w + 2))
      else
        w=$((w + 1))
      fi
      i=$((i + 3))
    else
      w=$((w + 2)); i=$((i + 4))
    fi
  done
  printf '%s' "$w"
}

# 画横线，$1=宽度
rule() { local i out=""; for ((i = 0; i < ${1:-60}; i++)); do out+="─"; done; printf '%s' "$out"; }

# 方块面板：顶边、内容行、底边，宽度自定，右侧带竖线
panel_top() {
  local w=${1:-62} title=${2:-}
  if [ -n "$title" ]; then
    local tw
    tw=$(dw "$title")
    printf '  %s╭─%s %s%s%s %s%s╮%s\n' "$C_GRY" "$C_RST" "$C_TTL" "$title" "$C_RST" \
      "$C_GRY" "$(rule $((w - tw - 3)))" "$C_RST"
  else
    printf '  %s╭%s╮%s\n' "$C_GRY" "$(rule "$w")" "$C_RST"
  fi
}
panel_line() {
  local plain=${1-} colored=${2-} w=${3:-62} need
  [ -n "$colored" ] || colored=$plain
  need=$(( w - 2 - $(dw "$plain") ))
  [ "$need" -lt 0 ] && need=0
  printf '  %s│%s %s%*s %s│%s\n' "$C_GRY" "$C_RST" "$colored" "$need" "" "$C_GRY" "$C_RST"
}
panel_bot() {
  printf '  %s╰%s╯%s\n' "$C_GRY" "$(rule "${1:-62}")" "$C_RST"
}

# 面板里的一行键值：暗色键补齐到 KVW 列，值竖排对齐
KVW=10
kv() {
  local k=${1-} v=${2-} need
  need=$(( KVW - $(dw "$k") ))
  [ "$need" -lt 2 ] && need=2
  printf '%s%s%s%*s%s' "$C_DIM" "$k" "$C_RST" "$need" "" "$v"
}

# 一次画完整个面板，宽度按最长一行自适应
panel_box() {
  local title=${1-}; shift
  local -a lines=("$@")
  local w=0 l lw tw
  for l in "${lines[@]}"; do
    lw=$(dw "$l")
    [ "$lw" -gt "$w" ] && w=$lw
  done
  tw=$(dw "$title")
  [ "$tw" -gt "$w" ] && w=$tw
  w=$(( w + 3 ))
  panel_top "$w" "$title"
  for l in "${lines[@]}"; do panel_line "$l" "" "$w"; done
  panel_bot "$w"
}

# 流水线步骤标题，自动编号：▎ 01  配置 apt 源
STEP_NO=0
log() {
  STEP_NO=$((STEP_NO + 1))
  printf '\n  %s▎%s %s%02d%s  %s%s%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$STEP_NO" "$C_RST" \
    "$C_BOLD" "$*" "$C_RST"
}

# 页面标题条：左侧色块 + 标题，右侧可选说明，下面一条细线
page_head() {
  local t=${1-} s=${2-} w=58 need
  printf '\n  %s▎%s %s%s%s' "$C_CYN" "$C_RST" "$C_TTL" "$t" "$C_RST"
  if [ -n "$s" ]; then
    need=$(( w - 2 - $(dw "$t") - $(dw "$s") ))
    [ "$need" -lt 1 ] && need=1
    printf '%*s%s%s%s' "$need" "" "$C_DIM" "$s" "$C_RST"
  fi
  printf '\n  %s%s%s\n' "$C_GRY" "$(rule "$w")" "$C_RST"
}

sec() { printf '\n  %s▎%s %s%s%s\n' "$C_CYN" "$C_RST" "$C_BOLD" "$*" "$C_RST"; }

# 收尾的绿色结果行，不占步骤编号
done_msg() { printf '\n  %s✓%s  %s%s%s%s\n' "$C_GRN" "$C_RST" "$C_GRN" "$C_BOLD" "$*" "$C_RST"; }

info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }

# 选项行 + 说明行：编号亮色、说明暗色，交互流程里统一用这两个
opt() { printf '    %s%s)%s %s\n' "$C_CYN" "${1-}" "$C_RST" "${2-}"; }
dsc() { printf '       %s%s%s\n' "$C_DIM" "$*" "$C_RST"; }
ok()   { printf '  %s✓%s  %s\n' "$C_GRN" "$C_RST" "$*"; N_OK=$((N_OK + 1)); }
warn() { printf '  %s!%s  %s%s%s\n' "$C_YEL" "$C_RST" "$C_YEL" "$*" "$C_RST"; N_WARN=$((N_WARN + 1)); }
fail() { printf '  %s✗%s  %s%s%s\n' "$C_RED" "$C_RST" "$C_RED" "$*" "$C_RST"; N_FAIL=$((N_FAIL + 1)); }
die()  { printf '\n  %s✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }

# 长任务转圈：命令输出收进临时文件，失败时回放尾部
spin() {
  local label=$1; shift
  if [ ! -t 1 ]; then
    "$@"
    return $?
  fi
  local logf pid rc=0 i=0 start
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  logf=$(mktemp)
  "$@" >"$logf" 2>&1 </dev/null &
  pid=$!
  start=$SECONDS
  printf '\033[?25l'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s  %s%s%s  %s%ss%s\033[K' \
      "$C_CYN" "${frames[i%10]}" "$C_RST" \
      "$C_BOLD" "$label" "$C_RST" \
      "$C_DIM" "$((SECONDS - start))" "$C_RST"
    i=$((i + 1))
    sleep 0.12
  done
  wait "$pid" || rc=$?
  printf '\r\033[K\033[?25h'
  if [ "$rc" -ne 0 ]; then
    printf '  %s✗%s  %s\n' "$C_RED" "$C_RST" "$label"
    tail -n 15 "$logf" | sed 's/^/      /'
    rm -f "$logf"
    return "$rc"
  fi
  printf '  %s✓%s  %s  %s%ss%s\n' "$C_GRN" "$C_RST" "$label" "$C_DIM" "$((SECONDS - start))" "$C_RST"
  rm -f "$logf"
}

# 去掉粘贴/复制带进来的 \r 与首尾空白，避免 Windows 剪贴板污染后续逻辑
trim() { local s=${1-}; s=${s%$'\r'}; printf '%s' "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# 终端收尾：正常结束、Ctrl+C、kill 都要把光标和颜色还原，否则终端会变成无光标
on_exit() {
  printf '\033[?25h\033[0m'
}

on_interrupt() {
  INTERRUPTED=1
  trap - ERR INT TERM
  printf '\033[?25h\033[0m'
  local i
  if [ "${MENU_ACTIVE:-0}" = "1" ]; then
    for ((i = 0; i < ${MENU_LINES:-1}; i++)); do
      printf '\033[K\n'
    done
    MENU_ACTIVE=0
  else
    printf '\033[K\n'
  fi
  printf '  %s已中断%s  %s终端已恢复，未完成的步骤重跑一次即可%s\n' "$C_YEL" "$C_RST" "$C_DIM" "$C_RST"
  printf '\n'
  exit 130
}

trap on_exit EXIT
trap on_interrupt INT TERM

# 读一个按键，返回 up / down / enter / esc / eof / 字符本身
read_key() {
  local k rest
  if ! IFS= read -rsn1 k; then
    echo eof
    return 0
  fi
  if [ "$k" = $'\x1b' ]; then
    if ! IFS= read -rsn2 -t 0.05 rest; then
      echo esc
      return 0
    fi
    case "$rest" in
      '[A'|'OA') echo up ;;
      '[B'|'OB') echo down ;;
      '[C'|'OC') echo right ;;
      '[D'|'OD') echo left ;;
      *) echo esc ;;
    esac
    return 0
  fi
  if [ -z "$k" ]; then
    echo enter
  else
    echo "$k"
  fi
}

# 方向键菜单，选中项下标写入 MENU_RESULT；取消返回非零
#   参数：select_menu "底部提示" "标题|说明" "标题" ...
#   非终端环境（管道/CI）自动退回数字输入
MENU_RESULT=255
MENU_ACTIVE=0
MENU_LINES=0

select_menu() {
  local hint=${1:-}; shift
  local items=("$@")
  local n=${#items[@]}
  local cur=0 i choice key
  local -a labels=() descs=()
  local cw=0 w tmp

  MENU_RESULT=255

  if [ "$n" -eq 0 ]; then
    return 255
  fi

  # 拆 "标题|说明"，同时算出内容区宽度（CJK 按两列算）
  for i in "${!items[@]}"; do
    labels[$i]=${items[$i]%%|*}
    if [ "${items[$i]}" = "${labels[$i]}" ]; then
      descs[$i]=""
      w=$(( 2 + $(dw "${labels[$i]}") ))
    else
      descs[$i]=${items[$i]#*|}
      w=$(( 2 + $(dw "${labels[$i]}") + 3 + $(dw "${descs[$i]}") ))
    fi
    [ "$w" -gt "$cw" ] && cw=$w
  done
  w=$(( cw + 2 ))          # 框内宽度

  if [ ! -t 0 ]; then
    for i in "${!items[@]}"; do
      if [ -n "${descs[$i]}" ]; then
        echo "  $((i + 1))) ${labels[$i]}  ${descs[$i]}"
      else
        echo "  $((i + 1))) ${labels[$i]}"
      fi
    done
    read -r -p "请输入编号: " choice || return 255
    if ! echo "$choice" | grep -qE '^[0-9]+$'; then
      return 255
    fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
      return 255
    fi
    MENU_RESULT=$((choice - 1))
    return 0
  fi

  local N=$(( n + 2 ))     # 上边框 + 选项 + 下边框
  printf '\033[?25l'
  for ((i = 0; i < N; i++)); do printf '\n'; done
  printf '\033[%dA' "$N"
  MENU_ACTIVE=1
  MENU_LINES=$N

  while true; do
    # 上边框
    printf '\r  %s╭%s╮%s\033[K\n' "$C_GRY" "$(rule "$w")" "$C_RST"
    # 选项：每行拼成一个字符串再整体打印，宽度只算一次，避免各分支算法不一致
    for i in "${!items[@]}"; do
      local plain pad line
      if [ -n "${descs[$i]}" ]; then
        plain="  ${labels[$i]} · ${descs[$i]}"
      else
        plain="  ${labels[$i]}"
      fi
      if [ "$i" -eq "$cur" ]; then
        pad=$(( w - 2 - $(dw "$plain") ))
        [ "$pad" -lt 0 ] && pad=0
        line="${C_SEL} ${plain} $(printf '%*s' "$pad" '')${C_RST}"
      else
        pad=$(( w - 1 - $(dw "$plain") ))
        [ "$pad" -lt 0 ] && pad=0
        if [ -n "${descs[$i]}" ]; then
          line="  ${C_WHT}${labels[$i]}${C_RST} ${C_DIM}· ${descs[$i]}${C_RST} $(printf '%*s' "$pad" '')"
        else
          line="  ${C_WHT}${labels[$i]}${C_RST} $(printf '%*s' "$pad" '')"
        fi
      fi
      printf '\r  %s│%s%s%s│%s\033[K\n' "$C_GRY" "$C_RST" "$line" "$C_GRY" "$C_RST"
    done
    # 下边框，提示文案右对齐嵌在里面
    local hw=0 d
    if [ -n "$hint" ]; then
      hw=$(dw "$hint")
      d=$(( w - hw - 2 ))
      [ "$d" -lt 0 ] && d=0
      printf '\r  %s╰%s%s %s %s╯%s\033[K\n' "$C_GRY" "$(rule "$d")" "$C_RST$C_DIM" "$hint" "$C_GRY" "$C_RST"
    else
      printf '\r  %s╰%s╯%s\033[K\n' "$C_GRY" "$(rule "$w")" "$C_RST"
    fi
    printf '\033[%dA' "$N"

    key=$(read_key)
    case "$key" in
      up)    cur=$(( (cur - 1 + n) % n )) ;;
      down)  cur=$(( (cur + 1) % n )) ;;
      enter)
        menu_leave
        MENU_RESULT=$cur
        return 0
        ;;
      q|Q|eof|esc)
        menu_leave
        return 255
        ;;
      [1-9])
        # 菜单超过 9 项时，"1" 可能想按的是 10/11，等一下看有没有第二位
        if [ "$n" -ge 10 ] && [ "$key" = "1" ]; then
          local k2
          if IFS= read -rsn1 -t 0.35 k2; then
            if [[ "$k2" =~ ^[0-9]$ ]] && [ "$((10#$key$k2))" -le "$n" ]; then
              key="${key}${k2}"
            fi
          fi
        fi
        if [ "$key" -le "$n" ]; then
          cur=$((key - 1))
          menu_leave
          MENU_RESULT=$cur
          return 0
        fi
        ;;
    esac
  done
}

# 光标落到菜单块下方并恢复显示，清掉最后一行避免残影
# 退出菜单绘制区：把光标移到框的下一行，保留整张菜单不上卷
menu_leave() {
  printf '\033[%dB\r' "${MENU_LINES:-1}"
  printf '\033[?25h'
  MENU_ACTIVE=0
}

usage() {
  cat <<'EOF'
用法: bash install_nginx.sh           不带参数运行，进入交互菜单
      bash install_nginx.sh [命令]    命令行直连，供脚本/自动化调用

命令:
  install    安装或更新。编译 + 生产基线配置 + 日志切割 + 内核调优 + 启动
  repair     修复。重建缺失的目录/配置/用户/systemd，清理失效 pid，重启服务
  doctor     体检。只读检查，输出 OK/WARN/FAIL，不改任何东西
  status     查看运行状态
  uninstall  卸载。停服务，清理本脚本装的所有内容（会二次确认）
  help       显示本帮助

环境变量:
  BUNDLED_OPENSSL=1   install 时源码编译 OpenSSL 1.1.1w（默认用系统 OpenSSL 3.x）
  FORCE_REBUILD=1     install 时强制重新编译
  FORCE_CONF=1        install/repair 时覆盖已有 nginx.conf
  FORCE_YES=1         uninstall 时跳过确认，直接删（脚本/自动化用）
EOF
}

# ============================================================
# 基础动作
# ============================================================
setup_apt() {
  log "配置 apt 源与依赖"
  local f=/etc/apt/sources.list.d/debian.sources
  [ -f "$f" ] || f=/etc/apt/sources.list
  [ -f "$f" ] || die "找不到 apt 源文件"

  if grep -q "$MIRROR_APT" "$f"; then
    info "已是国内源，跳过替换"
  else
    cp "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i "s|deb.debian.org|${MIRROR_APT}|g; s|security.debian.org|${MIRROR_APT}|g" "$f"
    info "已切换为 ${MIRROR_APT}（原文件已备份）"
  fi

  export DEBIAN_FRONTEND=noninteractive
  spin "更新软件包索引" apt-get update -qq
  spin "安装编译依赖" apt-get install -y --no-install-recommends \
    build-essential libpcre2-dev zlib1g-dev libssl-dev libaio-dev \
    openssl wget curl aria2 ca-certificates logrotate git cron
}

setup_dirs() {
  log "创建目录"
  mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$LOGS_DIR" "$CONF_DIR" \
           "$CERT_DIR" "$RUN_DIR" "$CACHE_DIR" "$BACKUP_DIR" "$VHOST_DIR"
  chmod 700 "$CERT_DIR"
  info "$BASE"
}

# 多源回退下载，并用 tar 校验，防止镜像返回 HTML 错误页
fetch() {
  local out="$1"; shift
  if [ -s "$out" ] && tar -tzf "$out" >/dev/null 2>&1; then
    info "已存在，跳过 $out"
    return 0
  fi
  local url name
  for url in "$@"; do
    name=$(basename "$out")
    rm -f "$out"
    if command -v aria2c >/dev/null 2>&1; then
      spin "下载 $name" aria2c -x16 -s16 -k1M -q --allow-overwrite=true --auto-file-renaming=false \
        --connect-timeout=15 --timeout=30 --max-tries=2 \
        -d "$(dirname "$out")" -o "$name" "$url" || true
    else
      spin "下载 $name" wget -c --tries=2 --timeout=30 -q -O "$out" "$url" || true
    fi
    if tar -tzf "$out" >/dev/null 2>&1; then
      return 0
    fi
    warn "校验失败，换下一个源"
  done
  die "所有下载源均失败: $out"
}

download_sources() {
  log "下载源码"
  cd "$BUILD_DIR"

  fetch "nginx-${NGINX_VERSION}.tar.gz" \
    "${MIRROR_NGINX}/nginx-${NGINX_VERSION}.tar.gz" \
    "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"

  if [ "$BUNDLED_OPENSSL" = "1" ]; then
    # openssl 1.1.1 已归档到 old/1.1.1/，国内镜像站均未镜像该目录
    fetch "openssl-${OPENSSL_VERSION}.tar.gz" \
      "https://www.openssl.org/source/old/1.1.1/openssl-${OPENSSL_VERSION}.tar.gz" \
      "https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-${OPENSSL_VERSION}.tar.gz" &
    local p_ssl=$!
    fetch "zlib-${ZLIB_VERSION}.tar.gz" \
      "https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz" \
      "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" &
    local p_zlib=$!
    wait "$p_ssl" || die "openssl 源码下载失败"
    wait "$p_zlib" || die "zlib 源码下载失败"
  fi
}

build_nginx() {
  if [ -x "$NGINX_BIN" ] && [ "$FORCE_REBUILD" != "1" ]; then
    log "nginx 已安装，跳过编译（FORCE_REBUILD=1 可强制重编）"
    return 0
  fi

  download_sources

  log "解压源码"
  cd "$BUILD_DIR"
  rm -rf "nginx-${NGINX_VERSION}"
  tar -zxf "nginx-${NGINX_VERSION}.tar.gz"
  if [ "$BUNDLED_OPENSSL" = "1" ]; then
    rm -rf "openssl-${OPENSSL_VERSION}" "zlib-${ZLIB_VERSION}"
    tar -zxf "openssl-${OPENSSL_VERSION}.tar.gz"
    tar -zxf "zlib-${ZLIB_VERSION}.tar.gz"
  fi

  log "执行 configure"
  cd "$BUILD_DIR/nginx-${NGINX_VERSION}"
  local opts=(
    --prefix="$INSTALL_DIR"
    --sbin-path="$INSTALL_DIR/sbin/nginx"
    --conf-path="$CONF_DIR/nginx.conf"
    --error-log-path="$LOGS_DIR/error.log"
    --http-log-path="$LOGS_DIR/access.log"
    --pid-path="$RUN_DIR/nginx.pid"
    --lock-path="$RUN_DIR/nginx.lock"
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_realip_module
    --with-http_addition_module
    --with-http_sub_module
    --with-http_dav_module
    --with-http_flv_module
    --with-http_mp4_module
    --with-http_gunzip_module
    --with-http_gzip_static_module
    --with-http_auth_request_module
    --with-http_random_index_module
    --with-http_secure_link_module
    --with-http_stub_status_module
    --with-mail
    --with-mail_ssl_module
    --with-stream
    --with-stream_ssl_module
    --with-stream_realip_module
    --with-threads
    --with-file-aio
    --with-pcre-jit
  )
  if [ "$BUNDLED_OPENSSL" = "1" ]; then
    opts+=(
      --with-openssl="$BUILD_DIR/openssl-${OPENSSL_VERSION}"
      --with-zlib="$BUILD_DIR/zlib-${ZLIB_VERSION}"
    )
  fi
  spin "configure（模块与依赖检查）" ./configure "${opts[@]}"

  local jobs mem_mb
  jobs=$(nproc)
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [ "$BUNDLED_OPENSSL" = "1" ] && [ "$mem_mb" -lt 2048 ] && [ "$jobs" -gt 2 ]; then
    jobs=2
    info "内存 ${mem_mb}MB，并行度降为 2"
  fi

  log "编译 nginx（-j${jobs}）"
  spin "make -j${jobs}" make -j"$jobs"
  log "安装二进制"
  spin "安装到 ${INSTALL_DIR}" make install
}

# nginx 自带配置（mime.types 等）缺失时补齐，源码目录没了就从 tar 包恢复
ensure_conf() {
  log "检查 nginx 自带配置"
  local src="$BUILD_DIR/nginx-${NGINX_VERSION}/conf"
  local f missing=0

  for f in mime.types fastcgi_params scgi_params uwsgi_params; do
    if [ ! -f "$CONF_DIR/$f" ]; then
      missing=1
    fi
  done
  if [ "$missing" = "0" ]; then
    info "自带配置齐全"
    return 0
  fi

  if [ ! -d "$src" ]; then
    if [ ! -f "$BUILD_DIR/nginx-${NGINX_VERSION}.tar.gz" ]; then
      download_sources
    fi
    info "从 tar 包恢复 conf/"
    tar -zxf "$BUILD_DIR/nginx-${NGINX_VERSION}.tar.gz" -C "$BUILD_DIR" \
      "nginx-${NGINX_VERSION}/conf" || true
  fi
  [ -d "$src" ] || die "无法获取 nginx 自带配置目录"

  for f in mime.types fastcgi_params scgi_params uwsgi_params koi-utf koi-win win-utf; do
    if [ ! -f "$CONF_DIR/$f" ] && [ -f "$src/$f" ]; then
      cp "$src/$f" "$CONF_DIR/$f"
      info "补齐 $f"
    fi
  done
}

# ============================================================
# 配置生成
# ============================================================
write_nginx_conf() {
  cat > "$CONF_DIR/nginx.conf" <<'NGINXCONF'
# managed-by: install_nginx.sh
# config-version: 2
user  @USER@;
worker_processes  auto;
worker_rlimit_nofile  65535;

error_log  @BASE@/logs/error.log  warn;
pid        @BASE@/run/nginx.pid;

events {
    worker_connections  10240;
    multi_accept        on;
    use                 epoll;
}

http {
    # include 的相对路径基于 --prefix（@BASE@/install），与 conf 目录不在一处，故统一用绝对路径
    include       @BASE@/conf/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for" '
                      'rt=$request_time urt=$upstream_response_time';

    access_log  @BASE@/logs/access.log  main  buffer=32k flush=5s;

    sendfile              on;
    tcp_nopush            on;
    tcp_nodelay           on;
    keepalive_timeout     65;
    keepalive_requests    1000;
    server_tokens         off;
    client_max_body_size  50m;
    client_header_timeout 15s;
    client_body_timeout   60s;
    send_timeout          60s;

    # 静态文件句柄缓存，减少系统调用
    open_file_cache          max=10000 inactive=30s;
    open_file_cache_valid    60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors   on;

    gzip              on;
    gzip_min_length   1k;
    gzip_comp_level   5;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_types        text/plain text/css text/xml application/json
                      application/javascript application/xml+rss image/svg+xml;

    # 以下 SSL 参数作为 conf.d 内 https server 的默认值
    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache         shared:SSL:10m;
    ssl_session_timeout       1d;
    ssl_session_tickets       off;

    client_body_temp_path  @BASE@/cache/client_body;
    proxy_temp_path        @BASE@/cache/proxy;
    fastcgi_temp_path      @BASE@/cache/fastcgi;
    uwsgi_temp_path        @BASE@/cache/uwsgi;
    scgi_temp_path         @BASE@/cache/scgi;

    include @BASE@/conf/conf.d/*.conf;
}
NGINXCONF
  sed -i "s|@BASE@|$BASE|g; s|@USER@|$NGINX_USER|g" "$CONF_DIR/nginx.conf"
}

write_default_vhost() {
  cat > "$VHOST_DIR/default.conf" <<'DEFAULTCONF'
# managed-by: install_nginx.sh
# config-version: 3
server {
    listen       80 default_server;
    server_name  _;

    root   @BASE@/install/html;
    index  index.html index.htm;

    access_log @BASE@/logs/access.log main;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # HTTP 方式申请证书时的验证路径，必须放在隐藏文件规则之前
    location ^~ /.well-known/acme-challenge/ {
        root @BASE@/cert/webroot;
        default_type text/plain;
    }

    # Let's Encrypt 等验证路径必须放行，否则会被下面的隐藏文件规则拦掉
    location ^~ /.well-known/ {
        allow all;
    }

    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    location = /nginx-status {
        stub_status;
        allow 127.0.0.1;
        deny  all;
        access_log off;
    }

    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2)$ {
        expires 7d;
        access_log off;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
DEFAULTCONF
  sed -i "s|@BASE@|$BASE|g" "$VHOST_DIR/default.conf"
}

# 判断某个配置是否需要（重新）生成：
# 不存在、不是本脚本生成的、强制覆盖、或版本低于当前模板 → 需要
need_rebuild() {
  local f=$1 ver
  if [ ! -f "$f" ]; then
    return 0
  fi
  if ! grep -q "$MARKER" "$f"; then
    return 0
  fi
  if [ "$FORCE_CONF" = "1" ]; then
    return 0
  fi
  ver=$(sed -n 's/.*config-version: *\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
  if [ -z "$ver" ]; then
    return 0
  fi
  if [ "$ver" -lt "$CONF_VERSION" ]; then
    return 0
  fi
  return 1
}

setup_conf() {
  log "生成配置"
  local conf=$CONF_DIR/nginx.conf
  local vhost=$VHOST_DIR/default.conf

  if need_rebuild "$conf"; then
    if [ -f "$conf" ]; then
      info "配置模板升级到 v${CONF_VERSION}（旧版已备份）"
    fi
    write_nginx_conf
    info "已写入 nginx.conf"
  else
    info "nginx.conf 已是最新（v${CONF_VERSION}），保留"
  fi

  if need_rebuild "$vhost"; then
    write_default_vhost
    info "已写入 conf.d/default.conf"
  else
    info "default.conf 已是最新，保留"
  fi

  chown -R root:root "$CONF_DIR"
  chmod 644 "$conf" "$vhost"
  chmod 755 "$VHOST_DIR"
}

# ============================================================
# 用户 / 权限 / 服务
# ============================================================
setup_user() {
  log "配置运行用户"
  if id -u "$NGINX_USER" >/dev/null 2>&1; then
    info "用户 $NGINX_USER 已存在"
  else
    useradd -r -s /usr/sbin/nologin -d "$BASE" "$NGINX_USER"
    info "已创建用户 $NGINX_USER"
  fi

  # BASE 必须可被 nginx 用户进入，否则静态文件返回 403
  chmod 755 "$BASE"
  chown -R "$NGINX_USER:$NGINX_USER" "$LOGS_DIR" "$RUN_DIR" "$CACHE_DIR"
  if [ -d "$INSTALL_DIR/html" ]; then
    chown -R "$NGINX_USER:$NGINX_USER" "$INSTALL_DIR/html"
  fi
  chown root:root "$CONF_DIR" "$NGINX_BIN"
  chmod 755 "$NGINX_BIN"
  info "权限设置完成"
}

# 主进程已死但 pid 文件还在时，reload 会失败，先清掉
fix_pid() {
  if [ -f "$RUN_DIR/nginx.pid" ]; then
    local pid
    pid=$(cat "$RUN_DIR/nginx.pid" 2>/dev/null || echo "")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$RUN_DIR/nginx.pid"
      info "已清理失效 pid 文件"
    else
      info "pid 文件有效（$pid）"
    fi
  fi
}

write_service_unit() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=nginx ${NGINX_VERSION} (custom build)
Documentation=https://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=${RUN_DIR}/nginx.pid
ExecStartPre=${NGINX_BIN} -t -q
ExecStart=${NGINX_BIN}
ExecReload=${NGINX_BIN} -s reload
ExecStop=-/bin/kill -s QUIT \$MAINPID
TimeoutStopSec=5
KillMode=mixed
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

# 服务起不来时一次把关键信息打全，避免用户再去逐个翻日志
diagnose() {
  echo
  sec "启动失败诊断"

  info "nginx -t"
  "$NGINX_BIN" -t 2>&1 | sed 's/^/      /' || true

  info "error.log 最后 20 行"
  if [ -f "$LOGS_DIR/error.log" ]; then
    tail -n 20 "$LOGS_DIR/error.log" | sed 's/^/      /' || true
  else
    info "  文件不存在：$LOGS_DIR/error.log"
  fi

  info "systemd 状态"
  systemctl --no-pager --lines=0 status nginx 2>&1 | sed -n '1,5p' | sed 's/^/      /' || true

  if command -v journalctl >/dev/null 2>&1; then
    info "journalctl 最后 20 行"
    journalctl -u nginx -n 20 --no-pager 2>/dev/null | sed 's/^/      /' || true
  fi

  info "端口占用"
  local busy
  busy=$(ss -lntp 2>/dev/null | grep -E ':(80|443)\s' || true)
  if [ -n "$busy" ]; then
    printf '%s\n' "$busy" | sed 's/^/      /'
  else
    info "  80 / 443 没有被占用"
  fi

  info "目录属主与权限"
  ls -ld "$BASE" "$LOGS_DIR" "$RUN_DIR" "$CACHE_DIR" 2>/dev/null | sed 's/^/      /' || true
}

setup_service() {
  log "配置 systemd 服务"
  write_service_unit
  systemctl daemon-reload
  systemctl enable nginx >/dev/null 2>&1

  if systemctl is-active --quiet nginx; then
    # reload 依赖 pid 文件，缺失时必然失败，直接 restart 更可靠
    if [ -f "$RUN_DIR/nginx.pid" ] && systemctl reload nginx 2>/dev/null; then
      info "服务已 reload（配置平滑生效）"
    else
      info "pid 文件缺失或 reload 失败，改用 restart"
      if ! systemctl restart nginx; then
        diagnose
        die "nginx 重启失败，原因见上方诊断"
      fi
      info "服务已重启"
    fi
  else
    if ! systemctl start nginx; then
      diagnose
      die "nginx 启动失败，原因见上方诊断"
    fi
    info "服务已启动"
  fi

  check_pid_file
}

check_pid_file() {
  local i
  for i in 1 2 3 4 5; do
    if [ -f "$RUN_DIR/nginx.pid" ]; then
      return 0
    fi
    sleep 1
  done
  local dirs
  echo
  warn "pid 文件没有生成：$RUN_DIR/nginx.pid"
  info "配置里实际生效的 pid 指令："
  dirs=$("$NGINX_BIN" -T 2>/dev/null | grep -E '^[[:space:]]*pid[[:space:]]' || true)
  if [ -n "$dirs" ]; then
    printf '%s\n' "$dirs" | sed 's/^/      /'
  else
    info "  配置里没有 pid 指令"
  fi
  info "磁盘上找到的 pid 文件："
  dirs=$(find "$BASE" -maxdepth 4 -name '*.pid' 2>/dev/null || true)
  if [ -n "$dirs" ]; then
    printf '%s\n' "$dirs" | sed 's/^/      /'
  else
    info "  一个都没有，reload 会失败，执行「修复」重建目录与用户"
  fi
}

# ============================================================
# 生产基线：日志切割 / 内核参数 / 句柄限制
# ============================================================
setup_logrotate() {
  log "配置日志切割"
  cat > "$LOGROTATE_FILE" <<EOF
${LOGS_DIR}/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    create 0640 ${NGINX_USER} ${NGINX_USER}
    postrotate
        ${NGINX_BIN} -s reopen >/dev/null 2>&1 || true
    endscript
}
EOF
  chmod 644 "$LOGROTATE_FILE"
  if logrotate -d "$LOGROTATE_FILE" >/dev/null 2>&1; then
    info "已写入 $LOGROTATE_FILE（按天切割，保留 14 天，压缩）"
  else
    info "已写入 $LOGROTATE_FILE"
  fi
}

setup_sysctl() {
  log "配置内核参数"
  cat > "$SYSCTL_FILE" <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
fs.file-max = 1000000
EOF
  chmod 644 "$SYSCTL_FILE"
  if sysctl --system >/dev/null 2>&1; then
    info "已应用 $SYSCTL_FILE"
  else
    info "已写入 $SYSCTL_FILE（容器环境可能不允许应用，重启后生效）"
  fi
}

setup_limits() {
  log "配置文件句柄上限"
  cat > "$LIMITS_FILE" <<EOF
${NGINX_USER}  soft  nofile  65535
${NGINX_USER}  hard  nofile  65535
EOF
  chmod 644 "$LIMITS_FILE"
  info "已写入 $LIMITS_FILE"
}

# 改配置前先备份，出错能回滚
backup_conf() {
  if [ -z "$(ls -A "$CONF_DIR" 2>/dev/null)" ]; then
    return 0
  fi
  local dir="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  cp -a "$CONF_DIR/." "$dir/" 2>/dev/null || true
  info "配置已备份到 $dir"
  # 只保留最近 10 份
  local old
  old=$(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | sort -r | tail -n +11 || true)
  if [ -n "$old" ]; then
    echo "$old" | xargs -r rm -rf
  fi
}

# ============================================================
# 证书管理（acme.sh + Let's Encrypt + Cloudflare DNS）
# ============================================================
acme_installed() {
  [ -x "$ACME_SH" ]
}

acme_init() {
  if acme_installed; then
    return 0
  fi
  local tmp repo email
  email=${1:-admin@localhost}
  tmp=$(mktemp -d)

  for repo in "https://gitee.com/neilpang/acme.sh.git" \
              "https://github.com/acmesh-official/acme.sh.git"; do
    if git clone --depth 1 "$repo" "$tmp/acme" >/dev/null 2>&1; then
      break
    fi
    rm -rf "$tmp/acme"
  done
  if [ ! -d "$tmp/acme" ]; then
    rm -rf "$tmp"
    fail "下载 acme.sh 失败"
    info "git 不可用，或服务器连不上 gitee / github"
    return 1
  fi

  if ! ( cd "$tmp/acme" && ./acme.sh --install --home "$ACME_HOME" -m "$email" >/dev/null 2>&1 ); then
    rm -rf "$tmp"
    fail "安装 acme.sh 失败"
    info "$ACME_HOME 可能不可写"
    return 1
  fi
  rm -rf "$tmp"

  # acme.sh 默认 CA 已改为 ZeroSSL，这里显式切回 Let's Encrypt
  "$ACME_SH" --home "$ACME_HOME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

# 把签好的证书复制到固定路径，并注册续签后的 reload 钩子
acme_install_cert() {
  local domain=$1
  local dir=$CERT_DIR/$domain
  mkdir -p "$dir"
  chmod 700 "$CERT_DIR" "$dir"

  info "正在把证书复制到固定目录..."
  if ! "$ACME_SH" --home "$ACME_HOME" --install-cert -d "$domain" \
      --key-file       "$dir/privkey.pem" \
      --fullchain-file "$dir/fullchain.pem" \
      --reloadcmd      "systemctl reload nginx"; then
    fail "证书部署失败，检查 $dir 是否可写"
    return 1
  fi
  chmod 600 "$dir/privkey.pem"
  chmod 644 "$dir/fullchain.pem"
  ok "证书文件已就位：$dir/"
}

# 按服务商录入 API 凭证，成功后环境变量已就绪
acme_read_creds() {
  local provider=$1 v1 v2 v3
  case "$provider" in
    1)
      info "Cloudflare API Token"
      info "获取：登录 CF → 右上头像 → My Profile → API Tokens → Create Token"
      info "      模板 Edit zone DNS → Zone Resources 选根域名 → Create Token"
      echo
      read -r -s -p "    粘贴 Token（输入不显示）: " v1 || return 1
      v1=$(trim "$v1")
      echo
      if [ -z "$v1" ]; then
        warn "Token 不能为空"
        return 1
      fi
      export CF_Token="$v1"
      unset CF_Account_ID CF_Zone_ID 2>/dev/null || true
      ok "已收到，共 ${#v1} 个字符"
      ;;
    2)
      info "阿里云 AccessKey"
      info "建议用 RAM 子账号，只授予 AliyunDNSFullAccess 权限"
      info "获取：控制台 → 右上头像 → AccessKey 管理 → 创建 AccessKey"
      echo
      read -r -p "    AccessKey ID: " v1 || return 1
      v1=$(trim "$v1")
      read -r -s -p "    AccessKey Secret（输入不显示）: " v2 || return 1
      v2=$(trim "$v2")
      echo
      if [ -z "$v1" ] || [ -z "$v2" ]; then
        warn "两项都不能为空"
        return 1
      fi
      export Ali_Key="$v1" Ali_Secret="$v2"
      ok "已收到"
      ;;
    3)
      info "腾讯云 DNSPod Token"
      info "注意：是 DNSPod 的 Token，不是腾讯云的 SecretId / SecretKey"
      info "获取：DNSPod 控制台 → 用户中心 → 密钥管理 → 创建密钥"
      echo
      read -r -p "    Token ID: " v1 || return 1
      v1=$(trim "$v1")
      read -r -s -p "    Token Key（输入不显示）: " v2 || return 1
      v2=$(trim "$v2")
      echo
      if [ -z "$v1" ] || [ -z "$v2" ]; then
        warn "两项都不能为空"
        return 1
      fi
      export DP_Id="$v1" DP_Key="$v2"
      ok "已收到"
      ;;
    4)
      info "华为云需要三项，都在「我的凭证」页面里"
      info "地址：控制台右上角账号名 → 我的凭证"
      echo
      read -r -p "    IAM 用户名: " v1 || return 1
      v1=$(trim "$v1")
      read -r -s -p "    IAM 密码（输入不显示）: " v2 || return 1
      v2=$(trim "$v2")
      echo
      read -r -p "    账号名（页面上单独一栏，不是用户名）: " v3 || return 1
      v3=$(trim "$v3")
      if [ -z "$v1" ] || [ -z "$v2" ] || [ -z "$v3" ]; then
        warn "三项都不能为空"
        return 1
      fi
      export HUAWEICLOUD_Username="$v1"
      export HUAWEICLOUD_Password="$v2"
      export HUAWEICLOUD_DomainName="$v3"
      ok "已收到"
      ;;
  esac
  return 0
}

# HTTP 方式验证：准备 webroot 目录
acme_http_prepare() {
  mkdir -p "$CERT_DIR/webroot/.well-known/acme-challenge"
  chmod -R 755 "$CERT_DIR/webroot"
  chown -R "$NGINX_USER:$NGINX_USER" "$CERT_DIR/webroot" 2>/dev/null || true

  if ! grep -q 'acme-challenge' "$VHOST_DIR/default.conf" 2>/dev/null; then
    echo
    warn "default.conf 里没有 acme-challenge 规则"
    info "如果站点是你自己写的 server 块，需要在那块里也加："
    echo
    printf '        location ^~ /.well-known/acme-challenge/ {\n'
    printf '            root %s;\n' "$CERT_DIR/webroot"
    printf '        }\n'
    echo
  fi
  ok "验证目录已就绪：$CERT_DIR/webroot"
}

# 二级公共后缀：这些后缀算一个整体，根域名要往回多取一段
TWO_LEVEL_TLD="com.cn net.cn org.cn gov.cn edu.cn ac.cn com.hk com.tw com.mo co.uk org.uk ac.uk co.jp co.kr com.au net.au org.au com.sg"

# 取可注册的根域名：api.example.com → example.com，txy.502302.xyz → 502302.xyz
# 用于泛域名和注册邮箱，避免签成 *.api.example.com 这种没人用的三级泛域名
root_domain() {
  local d=${1-} n last2
  d=${d%.}
  n=$(printf '%s' "$d" | awk -F. '{print NF}')
  if [ "$n" -le 2 ]; then
    printf '%s' "$d"
    return 0
  fi
  last2=$(printf '%s' "$d" | awk -F. '{print $(NF-1)"."$NF}')
  case " $TWO_LEVEL_TLD " in
    *" $last2 "*)
      printf '%s' "$d" | awk -F. '{print $(NF-2)"."$(NF-1)"."$NF}'
      ;;
    *)
      printf '%s' "$last2"
      ;;
  esac
}

# 注册邮箱用的域名，规则同上
registrable_hint() { root_domain "${1-}"; }

acme_issue() {
  STEP_NO=0
  page_head "申请证书" "Let's Encrypt · 90 天有效 · 到期自动续"
  echo
  info "1. 申请免费证书，90 天有效"
  info "2. 自动验证这个域名确实是你的"
  info "3. 装到固定目录，续签后 nginx 配置不用再改"
  echo
  read -r -p "  按回车开始，Ctrl+C 取消..." _ || return 0

  # ---------- 1/5 域名 ----------
  log "填要签证书的域名"
  info "填浏览器地址栏里实际访问的那个域名，一个域名签一张证书"
  echo
  info "example.com       主域名，就填这个"
  info "api.example.com   子域名，原样填进来"
  echo
  info "开头不要带 http:// 或 https://，结尾不要带路径"
  local domain
  read -r -p "    域名: " domain || return 0
  domain=$(trim "$domain")
  domain=${domain#http://}
  domain=${domain#https://}
  domain=${domain%%/*}
  domain=${domain%.}
  if [ -z "$domain" ]; then
    warn "域名不能为空"
    return 1
  fi
  if ! printf '%s' "$domain" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$'; then
    warn "格式不对，只填域名本身，例如 api.example.com"
    return 1
  fi

  # ---------- 2/5 证书范围 ----------
  # 泛域名一律落在根域名上：填 txy.502302.xyz 时签 *.502302.xyz，
  # 而不是 *.txy.502302.xyz —— 后者只能盖三级域名，日常用不上
  local root
  root=$(root_domain "$domain")
  log "这张证书管哪些域名"
  if [ "$root" != "$domain" ]; then
    info "${domain} 的根域名是 ${root}，泛域名按根域名签"
    echo
  fi
  opt 1 "只签 ${domain}"
  dsc "一张证书只管这一个域名，绝大多数情况选这个"
  echo
  opt 2 "连所有子域名一起签  *.${root}"
  if [ "$root" = "$domain" ]; then
    dsc "a.${root}、b.${root} 全都能用"
  else
    dsc "${root} 下所有二级域名都能用，包括 ${domain}"
  fi
  dsc "代价：只能用 DNS 验证，还要填服务商的 API key"
  echo
  local scope is_wild="n"
  read -r -p "    请选择 [1]: " scope || return 0
  scope=$(trim "$scope")
  if [ "${scope:-1}" = "2" ]; then
    is_wild="y"
  fi

  # 真正写进证书的名字：泛域名用根域名，单域名就用填的那个
  local issue_name=$domain
  if [ "$is_wild" = "y" ]; then
    issue_name=$root
  fi

  # ---------- 3/5 验证方式 ----------
  log "怎么证明这个域名是你的"
  local method provider=""
  if [ "$is_wild" = "y" ]; then
    info "泛域名只能用 DNS 验证，已自动选定"
    info "要签的名字：${issue_name} 和 *.${issue_name}"
    info "接着会问服务商和 API key"
    method="dns"
  else
    opt 1 "HTTP 验证（推荐）"
    dsc "不需要任何 key，也不用碰 DNS 面板"
    dsc "脚本在网站目录放一个文件，对方能访问就算验证通过："
    dsc "http://${domain}/.well-known/acme-challenge/xxxx"
    dsc "前提：${domain} 已解析到这台服务器，80 端口外网能访问"
    echo
    opt 2 "DNS 验证"
    dsc "在服务商那边临时加一条 TXT 记录来证明，需要服务商 API key"
    dsc "适用：域名还没解析过来，或 80 端口暂时打不开"
    echo
    local m
    read -r -p "    请选择 [1]: " m || return 0
    m=$(trim "$m")
    if [ "${m:-1}" = "2" ]; then
      method="dns"
    else
      method="http"
    fi
  fi

  # ---------- 4/5 凭证或目录 ----------
  if [ "$method" = "http" ]; then
    log "准备验证目录"
    acme_http_prepare
  else
    log "选域名服务商，填 API key"
    opt 1 "Cloudflare"
    opt 2 "阿里云"
    opt 3 "腾讯云 DNSPod"
    opt 4 "华为云"
    echo
    read -r -p "    请选择 [1]: " provider || return 0
    provider=$(trim "$provider")
    provider=${provider:-1}
    if ! printf '%s' "$provider" | grep -qE '^[1-4]$'; then
      warn "编号无效"
      return 1
    fi
    echo
    if ! acme_read_creds "$provider"; then
      return 1
    fi
  fi

  # ---------- 5/5 签发 ----------
  log "开始签发，预计 1~2 分钟"
  info "期间不要关闭窗口；中途 Ctrl+C 会留下半成品记录，重跑一次即可"
  if ! acme_init "admin@$(registrable_hint "$domain")"; then
    return 1
  fi
  if [ ! -x "$ACME_SH" ]; then
    fail "安装后找不到 $ACME_SH"
    info "检查 $ACME_HOME 是否可写，或手动执行 acme.sh --install"
    return 1
  fi
  ok "签发工具已就绪"

  local -a args
  local dnsname
  if [ "$method" = "http" ]; then
    args=(--issue --webroot "$CERT_DIR/webroot" --server letsencrypt -d "$issue_name")
    info "正在写入验证文件并等待 Let's Encrypt 校验..."
  else
    case "$provider" in
      1) dnsname="dns_cf" ;;
      2) dnsname="dns_ali" ;;
      3) dnsname="dns_dp" ;;
      4) dnsname="dns_huaweicloud" ;;
    esac
    args=(--issue --dns "$dnsname" --server letsencrypt -d "$issue_name")
    if [ "$is_wild" = "y" ]; then
      args+=(-d "*.${issue_name}")
    fi
    info "正在添加 DNS 验证记录并等待生效..."
  fi

  local logf
  logf=$(mktemp)
  if ! "$ACME_SH" --home "$ACME_HOME" "${args[@]}" >"$logf" 2>&1; then
    fail "签发失败"
    echo
    info "日志最后 20 行："
    tail -n 20 "$logf" | sed 's/^/      /'
    echo
    info "按这个顺序排查："
    if [ "$method" = "http" ]; then
      info "1. ${domain} 有没有解析到这台服务器：ping ${domain}"
      info "2. 80 端口外网能不能访问（用「外网访问排查」）"
      info "3. 自己的 server 块里有没有 acme-challenge 规则"
      info "4. 域名还没解析的话，改用 DNS 验证重试"
    else
      info "1. key 是否复制完整、权限是否正确"
      info "2. 域名在服务商那边解析是否正常"
      info "3. 服务器能不能出外网 443："
      info "   curl -I --max-time 10 https://acme-v02.api.letsencrypt.org/directory"
    fi
    rm -f "$logf"
    return 1
  fi
  rm -f "$logf"
  ok "验证通过，证书已签发"

  if ! acme_install_cert "$issue_name"; then
    return 1
  fi

  local -a done_lines=()
  if [ "$is_wild" = "y" ]; then
    done_lines+=("$(kv 覆盖 "${issue_name} 和 *.${issue_name}")")
  else
    done_lines+=("$(kv 覆盖 "${issue_name}")")
  fi
  done_lines+=("$(kv 证书 "${CERT_DIR}/${issue_name}/fullchain.pem")")
  done_lines+=("$(kv 私钥 "${CERT_DIR}/${issue_name}/privkey.pem")")
  done_lines+=("$(kv 续签 "每天自动检查，续完自动 reload")")

  echo
  panel_box "签发完成" "${done_lines[@]}"
  echo
  info "在 https 那个 server 块里加两行："
  echo
  printf '      ssl_certificate     %s\n' "${CERT_DIR}/${issue_name}/fullchain.pem;"
  printf '      ssl_certificate_key %s\n' "${CERT_DIR}/${issue_name}/privkey.pem;"
  echo
  info "然后执行 systemctl reload nginx"
  info "路径固定，续签后自动生效，这两行永远不用再改"
}

# 读证书实际覆盖的域名，空格分隔；目录名看不出泛域名盖了哪些名字时用
cert_sans() {
  openssl x509 -noout -ext subjectAltName -in "${1}/fullchain.pem" 2>/dev/null \
    | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' | paste -sd' ' -
}

acme_list() {
  page_head "证书列表" "到期时间 · 剩余天数"

  local found=0 d name end_date end_ts now_ts days sans
  now_ts=$(date +%s)
  for d in "$CERT_DIR"/*/; do
    if [ ! -f "$d/fullchain.pem" ]; then
      continue
    fi
    found=1
    name=$(basename "$d")
    end_date=$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)
    if [ -z "$end_date" ]; then
      warn "$name  无法读取有效期"
      continue
    fi
    end_ts=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
    days=$(( (end_ts - now_ts) / 86400 ))
    if [ "$days" -lt 0 ]; then
      fail "$name  已过期  $(date -d "$end_date" '+%Y-%m-%d' 2>/dev/null)"
    elif [ "$days" -lt 15 ]; then
      warn "$name  剩余 ${days} 天  ← 即将到期，检查自动续签"
    else
      ok "$name  剩余 ${days} 天  ${C_DIM}到期 $(date -d "$end_date" '+%Y-%m-%d' 2>/dev/null)${C_RST}"
    fi
    # 泛域名证书的目录名是根域名，看不出它到底盖了哪些名字，补一行覆盖范围
    sans=$(cert_sans "$d")
    if printf '%s' "$sans" | grep -qF '*'; then
      dsc "覆盖 ${sans}"
    fi
  done

  if [ "$found" = "0" ]; then
    info "暂无证书，选「申请证书」签第一张"
  fi
}

acme_renew() {
  page_head "手动续签" "强制续一次，验证流程是否通"
  if ! acme_installed; then
    warn "acme.sh 未安装，先申请一张证书"
    return 1
  fi

  local d name n_ok=0 n_bad=0
  for d in "$CERT_DIR"/*/; do
    if [ ! -f "$d/fullchain.pem" ]; then
      continue
    fi
    name=$(basename "$d")
    if "$ACME_SH" --home "$ACME_HOME" --renew -d "$name" --force >/dev/null 2>&1; then
      ok "$name  续签成功"
      n_ok=$((n_ok + 1))
    else
      fail "$name  续签失败，查看 $ACME_HOME/acme.sh.log"
      n_bad=$((n_bad + 1))
    fi
  done

  echo
  if [ "$n_ok" = "0" ] && [ "$n_bad" = "0" ]; then
    info "没有可续签的证书"
    return 0
  fi
  panel_box "续签结果" \
    "$(kv 成功 "${C_GRN}${n_ok}${C_RST} 个")" \
    "$(kv 失败 "${C_RED}${n_bad}${C_RST} 个")"
}

acme_cron() {
  page_head "自动续签" "每天检查，到期自动续"
  if ! acme_installed; then
    warn "acme.sh 未安装，先申请一张证书"
    return 1
  fi
  if ! command -v crontab >/dev/null 2>&1; then
    fail "系统没有 crontab"
    info "先安装：apt-get install -y cron"
    return 1
  fi

  if crontab -l 2>/dev/null | grep -qF "$ACME_HOME"; then
    ok "cron 任务已存在"
    crontab -l 2>/dev/null | grep -F "$ACME_HOME" | sed 's/^/      /'
    return 0
  fi

  ( crontab -l 2>/dev/null; echo "0 3 * * * \"$ACME_SH\" --cron --home \"$ACME_HOME\" > /dev/null" ) | crontab -
  ok "已添加：每天 03:00 检查，到期前自动续"
  info "续签后自动 reload nginx，路径不变"
}

acme_snippet() {
  page_head "nginx 引用片段" "复制到 server 块里用"

  local names=() d name
  for d in "$CERT_DIR"/*/; do
    if [ -f "$d/fullchain.pem" ]; then
      names+=("$(basename "$d")")
    fi
  done

  if [ "${#names[@]}" -eq 0 ]; then
    warn "还没有证书，先申请"
    return 0
  fi

  if ! select_menu "↑↓ 移动   ↵ 确认   q 返回" "${names[@]}"; then
    return 0
  fi
  name=${names[$MENU_RESULT]}

  local sans
  sans=$(cert_sans "$CERT_DIR/$name")
  echo
  info "把下面两行放进对应的 server 块（listen 443 ssl 那个）："
  if printf '%s' "$sans" | grep -qF '*'; then
    info "这张证书覆盖 ${sans}，任何一个子域名的 server 块都指向同一对文件"
  fi
  echo
  printf '      ssl_certificate     %s\n' "${CERT_DIR}/${name}/fullchain.pem;"
  printf '      ssl_certificate_key %s\n' "${CERT_DIR}/${name}/privkey.pem;"
  echo
  info "证书路径固定，续签后自动生效，这两行不用再改"
}

do_cert_menu() {
  while true; do
    page_head "证书管理" "Let's Encrypt · 自动续签"

    if ! select_menu "↑↓ 移动   ↵ 确认   q 返回" \
      "申请证书|Cloudflare / 阿里云 / 腾讯云 / 华为云 / HTTP" \
      "查看证书列表|到期时间 · 剩余天数" \
      "手动续签|强制续一次，验证流程是否通" \
      "配置自动续签|每天检查，到期自动续" \
      "显示引用片段|复制到 nginx 配置里用" \
      "返回上级"; then
      return 0
    fi

    echo
    case "$MENU_RESULT" in
      0) acme_issue || true ;;
      1) acme_list || true ;;
      2) acme_renew || true ;;
      3) acme_cron || true ;;
      4) acme_snippet || true ;;
      5) return 0 ;;
    esac
    echo
    read -r -p "按回车返回..." _ || return 0
  done
}

# ============================================================
# 命令: install
# ============================================================
do_install() {
  STEP_NO=0
  setup_apt
  setup_dirs
  build_nginx
  ensure_conf
  backup_conf
  setup_conf
  setup_user
  fix_pid
  setup_service
  setup_logrotate
  setup_sysctl
  setup_limits

  done_msg "安装完成"
  local ver
  ver=$("$NGINX_BIN" -v 2>&1 | tr -d '\n')
  panel_box "nginx ${NGINX_VERSION} 已就绪" \
    "$(kv 二进制 "$NGINX_BIN")" \
    "$(kv 主配置 "$CONF_DIR/nginx.conf")" \
    "$(kv 站点配置 "$VHOST_DIR/*.conf")" \
    "$(kv 日志 "$LOGS_DIR/  按天切割，保留 14 天")" \
    "$(kv 证书 "$CERT_DIR/")" \
    "$(kv 备份 "$BACKUP_DIR/")" \
    "$(kv 健康检查 "http://127.0.0.1/healthz")" \
    "$(kv 管理 "systemctl {start|stop|restart|reload|status} nginx")" \
    "$(kv 版本 "$ver")"
  echo
  do_doctor || true
}

# ============================================================
# 命令: repair
# ============================================================
do_repair() {
  STEP_NO=0
  log "修复模式"

  if [ ! -x "$NGINX_BIN" ]; then
    warn "nginx 二进制不存在：$NGINX_BIN"
    info "无法原地修复，转入完整安装"
    do_install
    return 0
  fi

  setup_dirs
  ensure_conf
  backup_conf
  setup_conf
  setup_user
  fix_pid
  setup_service
  setup_logrotate

  done_msg "修复完成"
  info "配置 / 权限 / 服务按当前模板重建，站点配置未改动"
  echo
  do_doctor || true
}

# ============================================================
# 命令: doctor（只读）
# ============================================================
check_perm() {
  local path=$1 want=$2 label=$3 mode
  if [ ! -d "$path" ]; then
    fail "$label 目录不存在：$path"
    return 0
  fi
  mode=$(stat -c '%a' "$path" 2>/dev/null || echo "?")
  if [ -n "$want" ] && [ "$mode" != "$want" ]; then
    fail "$label 权限 $mode，应为 $want：$path"
  else
    ok "$label $mode  $path"
  fi
}

do_doctor() {
  N_FAIL=0
  N_WARN=0
  N_OK=0
  local cver=""
  page_head "nginx 体检" "只读检查 · 不改动任何东西"

  sec "二进制"
  if [ -x "$NGINX_BIN" ]; then
    ok "$NGINX_BIN"
    info "$("$NGINX_BIN" -v 2>&1)"
  else
    fail "不存在或不可执行：$NGINX_BIN"
  fi

  sec "配置"
  if [ -f "$CONF_DIR/nginx.conf" ]; then
    cver=$(sed -n 's/.*config-version: *\([0-9][0-9]*\).*/\1/p' "$CONF_DIR/nginx.conf" | head -1)
    if [ -z "$cver" ]; then
      warn "配置无版本标记（旧版模板）→ 执行「安装 / 更新」升级到 v${CONF_VERSION}"
    elif [ "$cver" -lt "$CONF_VERSION" ]; then
      warn "配置版本 v${cver}，最新 v${CONF_VERSION} → 执行「安装 / 更新」升级"
    else
      ok "配置版本 v${cver}"
    fi

    if "$NGINX_BIN" -t -q 2>/dev/null; then
      ok "nginx.conf 语法通过"
    else
      fail "nginx.conf 语法错误"
      "$NGINX_BIN" -t 2>&1 | sed 's/^/         /' || true
    fi
  else
    fail "缺少 $CONF_DIR/nginx.conf"
  fi

  local f
  for f in mime.types fastcgi_params scgi_params uwsgi_params; do
    if [ -f "$CONF_DIR/$f" ]; then
      ok "$f"
    else
      warn "缺少 $CONF_DIR/$f"
    fi
  done

  if ls "$VHOST_DIR"/*.conf >/dev/null 2>&1; then
    ok "conf.d 站点 $(ls "$VHOST_DIR"/*.conf 2>/dev/null | wc -l) 个"
  else
    warn "conf.d 下没有站点配置"
  fi

  sec "用户与权限"
  if id -u "$NGINX_USER" >/dev/null 2>&1; then
    ok "用户 $NGINX_USER 存在"
  else
    fail "用户 $NGINX_USER 不存在"
  fi
  check_perm "$BASE" 755 "BASE"
  check_perm "$LOGS_DIR" "" "logs"
  check_perm "$RUN_DIR" "" "run"
  check_perm "$CACHE_DIR" "" "cache"

  sec "systemd 与服务"
  if [ -f "$SERVICE_FILE" ]; then
    ok "unit 文件存在"
    if grep -q "ExecStart=${NGINX_BIN}$" "$SERVICE_FILE"; then
      ok "ExecStart 指向 $NGINX_BIN"
    else
      fail "ExecStart 路径与当前二进制不一致"
    fi
  else
    fail "缺少 $SERVICE_FILE"
  fi

  if systemctl is-active --quiet nginx 2>/dev/null; then
    ok "服务运行中"
    local mainpid pidfile
    mainpid=$(systemctl show -p MainPID --value nginx 2>/dev/null || echo 0)
    if [ -f "$RUN_DIR/nginx.pid" ]; then
      pidfile=$(cat "$RUN_DIR/nginx.pid" 2>/dev/null || echo "")
      if [ "$pidfile" = "$mainpid" ]; then
        ok "pid 文件与主进程一致（$mainpid）"
      else
        fail "pid 文件($pidfile) 与主进程($mainpid) 不一致"
      fi
    else
      fail "pid 文件缺失，reload 会失败：$RUN_DIR/nginx.pid"
    fi
  else
    fail "服务未运行"
  fi

  sec "生产基线"
  if [ -f "$LOGROTATE_FILE" ]; then
    ok "日志切割已配置"
  else
    warn "日志切割未配置，日志会无限增长"
  fi
  if [ -f "$SYSCTL_FILE" ]; then
    ok "内核参数已配置"
  else
    warn "内核参数未配置"
  fi
  if [ -f "$LIMITS_FILE" ]; then
    ok "句柄上限已配置"
  else
    warn "句柄上限未配置"
  fi
  if grep -q 'server_tokens\s*off' "$CONF_DIR/nginx.conf" 2>/dev/null; then
    ok "版本号已隐藏"
  else
    warn "server_tokens 未关闭，响应头会暴露版本"
  fi

  sec "监听与响应"
  if ss -lntp 2>/dev/null | grep -qE ':80\s'; then
    ok "80 端口监听中"
  else
    warn "80 端口未监听"
  fi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/healthz 2>/dev/null) || code=000
  if [ "$code" = "200" ]; then
    ok "健康检查 /healthz 返回 200"
  elif [ -z "$cver" ] || [ "${cver:-0}" -lt "$CONF_VERSION" ]; then
    warn "健康检查 /healthz 返回 $code（配置未升级，升级后才有该端点）"
  else
    warn "健康检查返回 $code"
  fi

  echo
  local verdict
  if [ "$N_FAIL" -eq 0 ] && [ "$N_WARN" -eq 0 ]; then
    verdict="${C_GRN}${C_BOLD}全部通过${C_RST}"
  elif [ "$N_FAIL" -eq 0 ]; then
    verdict="${C_YEL}${N_WARN} 项警告${C_RST} ${C_DIM}· 可执行「修复」${C_RST}"
  else
    verdict="${C_RED}${C_BOLD}${N_FAIL} 项失败${C_RST} ${C_DIM}· ${N_WARN} 项警告 · 执行「修复」${C_RST}"
  fi

  panel_box "体检结果" \
    "$(kv 通过 "${C_GRN}${N_OK}${C_RST} 项")" \
    "$(kv 警告 "${C_YEL}${N_WARN}${C_RST} 项")" \
    "$(kv 失败 "${C_RED}${N_FAIL}${C_RST} 项")" \
    "$(kv 结论 "$verdict")"

  if [ "$N_FAIL" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ============================================================
# 命令: status
# ============================================================
do_status() {
  if [ ! -x "$NGINX_BIN" ]; then
    page_head "运行状态"
    warn "未安装：$NGINX_BIN 不存在"
    info "回主菜单选「安装 / 更新」开始编译"
    return 1
  fi

  page_head "运行状态" "版本 · 进程 · 端口"

  local ver state pid
  ver=$("$NGINX_BIN" -v 2>&1 | sed 's/nginx version: //')
  if systemctl is-active --quiet nginx 2>/dev/null; then
    pid=$(systemctl show -p MainPID --value nginx 2>/dev/null || echo "?")
    state="${C_GRN}运行中${C_RST}  ${C_DIM}pid ${pid}${C_RST}"
  else
    state="${C_YEL}已停止${C_RST}"
  fi

  panel_box "nginx" \
    "$(kv 版本 "$ver")" \
    "$(kv 状态 "$state")" \
    "$(kv 二进制 "$NGINX_BIN")" \
    "$(kv 主配置 "$CONF_DIR/nginx.conf")" \
    "$(kv 站点 "$VHOST_DIR")" \
    "$(kv 日志 "$LOGS_DIR/")"

  echo
  sec "端口监听"
  if ss -lntp 2>/dev/null | grep -qE ':(80|443)\s'; then
    ss -lntp 2>/dev/null | grep -E ':(80|443)\s' | sed 's/^/  /'
  else
    warn "未监听 80 / 443"
  fi
}

# ============================================================
# 运维: 外网访问排查
# ============================================================
do_netcheck() {
  STEP_NO=0
  page_head "外网访问排查" "逐层定位打不开的原因"

  local code pubip is_tencent=0 listening=0

  log "端口监听"
  if ss -lntp 2>/dev/null | grep -qE ':80\s'; then
    listening=1
    ss -lntp 2>/dev/null | grep -E ':(80|443)\s' | sed 's/^/    /'
  else
    warn "80 未监听 → 服务没起来，或监听地址不是 0.0.0.0"
  fi

  log "本机回环访问"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1/ 2>/dev/null) || code=000
  info "http://127.0.0.1/  →  HTTP ${code}"

  log "公网 IP"
  pubip=$(curl -s -m 5 http://metadata.tencentyun.com/latest/meta-data/public-ipv4 2>/dev/null || true)
  if [ -n "$pubip" ]; then
    is_tencent=1
    info "${pubip}  （腾讯云 CVM）"
  else
    pubip=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || true)
    info "${pubip:-未获取到（可能无法访问外网）}"
  fi

  if [ -n "$pubip" ]; then
    log "本机经公网 IP 访问"
    local pcode
    pcode=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://${pubip}/" 2>/dev/null) || pcode=000
    info "http://${pubip}/  →  HTTP ${pcode}"
    code=$pcode
  fi

  log "系统防火墙"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw status | sed 's/^/    /'
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --list-all 2>/dev/null | sed 's/^/    /'
  else
    local rules
    rules=$(iptables -S INPUT 2>/dev/null | grep -vE '^-P INPUT ACCEPT$' | head -10 || true)
    if [ -z "$rules" ]; then
      info "无自定义规则，默认放行"
    else
      echo "$rules" | sed 's/^/    /'
    fi
  fi

  log "站点文件"
  if [ -d "$INSTALL_DIR/html" ]; then
    ls -l "$INSTALL_DIR/html" 2>/dev/null | head -6 | sed 's/^/    /'
  else
    warn "$INSTALL_DIR/html 不存在"
  fi
  if [ -f "$INSTALL_DIR/html/index.html" ]; then
    info "index.html 存在（$(stat -c%s "$INSTALL_DIR/html/index.html" 2>/dev/null || echo "?") 字节）"
  else
    warn "没有 index.html → 访问 / 会 403 或 404"
  fi

  log "根路径实际返回"
  local body
  body=$(curl -s -m 5 http://127.0.0.1/ 2>/dev/null) || body=""
  if [ -n "$body" ]; then
    printf '%s\n' "$body" | head -3 | sed 's/^/    /'
  else
    info "无响应"
  fi

  sec "结论"
  if [ "$listening" = "0" ]; then
    fail "80 端口没有监听 → nginx 没在跑，跟外网无关"
    info "处理：选「修复」或「重载 / 重启」，再看 error.log"
  elif [ "$code" = "000" ]; then
    fail "80 在监听，但走公网 IP 打不通 → 系统防火墙拦截"
    info "处理：ufw allow 80/tcp  或  iptables -I INPUT -p tcp --dport 80 -j ACCEPT"
  elif [ "$code" = "200" ]; then
    ok "服务器本机经公网 IP 可访问，nginx 正常"
    if [ "$is_tencent" = "1" ]; then
      warn "外网打不开 → 腾讯云安全组未放行 80 端口（最常见）"
      info "处理：控制台 → 云服务器 → 安全组 → 入站规则 → 放行 TCP:80、TCP:443"
    else
      warn "外网打不开 → 检查云厂商安全组 / 网络 ACL"
    fi
  else
    warn "返回 HTTP ${code}，服务在但页面有问题"
    info "处理：选「查看日志」看 error.log"
  fi
}

# ============================================================
# 运维: 查看日志
# ============================================================
do_view_logs() {
  page_head "查看日志"

  if ! select_menu "↑↓ 移动   ↵ 确认   q 返回" \
    "access.log|访问日志，谁来了、返回什么状态码" \
    "error.log|错误日志，出问题先看这个"; then
    return 0
  fi

  local f=$LOGS_DIR/access.log
  if [ "$MENU_RESULT" = "1" ]; then
    f=$LOGS_DIR/error.log
  fi

  page_head "$(basename "$f")" "最后 50 行"
  if [ -f "$f" ]; then
    tail -n 50 "$f" | sed 's/^/  /'
  else
    warn "文件不存在：$f"
  fi
}

# ============================================================
# 运维: 重载 / 重启
# ============================================================
do_reload() {
  page_head "重载 / 重启"

  if ! select_menu "↑↓ 移动   ↵ 确认   q 返回" \
    "reload|平滑重载，连接不断，改完配置用这个" \
    "restart|完全重启，连接会断，进程卡死时用"; then
    return 0
  fi

  echo
  if ! "$NGINX_BIN" -t -q 2>/dev/null; then
    fail "配置校验失败，已中止"
    "$NGINX_BIN" -t 2>&1 | sed 's/^/      /' || true
    return 1
  fi
  ok "配置校验通过"

  if [ "$MENU_RESULT" = "1" ]; then
    if systemctl restart nginx; then ok "已重启"; else fail "重启失败，看 error.log"; fi
  else
    if systemctl reload nginx; then ok "已重载"; else fail "重载失败，看 error.log"; fi
  fi
}

# ============================================================
# 运维: 备份配置
# ============================================================
do_backup() {
  page_head "备份配置"
  local dir="$BACKUP_DIR/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  cp -a "$CONF_DIR/." "$dir/" 2>/dev/null || true
  ok "已备份到 $dir"
  echo
  info "现有备份："
  ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | head -10 | sed 's|.*/|    &|' | sed 's|/$||' || echo "    无"
}

# ============================================================
# 运维: 一键卸载
# ============================================================
do_uninstall() {
  local ans keep ts archive confirm
  STEP_NO=0
  page_head "卸载 nginx" "会清掉本脚本装的全部内容"

  panel_box "将删除" \
    "$(kv 数据目录 "$BASE")" \
    "          └ 二进制 / 配置 / 日志 / 证书 / 备份 / acme.sh" \
    "$(kv 服务单元 "$SERVICE_FILE")" \
    "$(kv 日志切割 "$LOGROTATE_FILE")" \
    "$(kv 内核参数 "$SYSCTL_FILE")" \
    "$(kv 句柄限制 "$LIMITS_FILE")" \
    "$(kv 定时任务 "acme.sh 每天自动续签")" \
    "$(kv 系统用户 "$NGINX_USER")"
  echo
  info "不会动：apt 装的软件包、其它程序、系统防火墙规则"
  echo

  if [ "${FORCE_YES:-0}" != "1" ]; then
    read -r -p "  确认卸载请输入 yes（直接回车取消）: " ans || return 0
    confirm=$(trim "${ans-}")
    if [ "$confirm" != "yes" ]; then
      info "已取消，什么都没删"
      return 0
    fi
    echo
    read -r -p "  先把 配置 / 证书 / 备份 打包到 /root 留档？[Y/n]: " keep || return 0
    keep=$(trim "${keep-}")
  else
    keep="y"
  fi

  if [ "${keep:-y}" != "n" ] && [ "${keep:-y}" != "N" ]; then
    ts=$(date +%Y%m%d-%H%M%S)
    archive=/root/nginx-uninstall-${ts}.tar.gz
    log "打包留档"
    if [ -d "$BASE" ]; then
      local -a items=()
      local sub
      for sub in conf cert backup; do
        [ -d "$BASE/$sub" ] && items+=("$sub") || true
      done
      if [ "${#items[@]}" -gt 0 ]; then
        tar -czf "$archive" -C "$BASE" "${items[@]}" 2>/dev/null || true
      fi
    fi
    if [ -s "$archive" ]; then
      chmod 600 "$archive" 2>/dev/null || true
      ok "$archive  （$(du -h "$archive" | cut -f1)，含私钥，权限 600）"
    else
      warn "没打包成功，继续删除。证书会一起没，后面要重新申请"
      archive=""
    fi
  fi

  log "停止并禁用服务"
  systemctl stop nginx 2>/dev/null || true
  systemctl disable nginx 2>/dev/null || true
  ok "服务已停止并取消开机自启"

  log "删除 systemd 单元"
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed nginx 2>/dev/null || true
  ok "$SERVICE_FILE"

  log "删除日志切割 / 内核调优 / 句柄限制"
  rm -f "$LOGROTATE_FILE" "$SYSCTL_FILE" "$LIMITS_FILE"
  sysctl --system >/dev/null 2>&1 || true
  ok "logrotate / sysctl.d / limits.d 已清理"

  log "移除证书自动续签任务"
  if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -qF "$ACME_HOME"; then
    crontab -l 2>/dev/null | grep -vF "$ACME_HOME" | crontab - 2>/dev/null || true
    ok "已移除"
  else
    info "没有相关任务，跳过"
  fi

  log "删除数据目录"
  if [ -z "${BASE:-}" ] || [ "$BASE" = "/" ]; then
    fail "BASE 变量异常（'${BASE:-}'），拒绝删除"
    return 1
  fi
  local skip_dir=0
  if [ -d "$BASE" ]; then
    if [ -f "$CONF_DIR/nginx.conf" ] && ! grep -q "$MARKER" "$CONF_DIR/nginx.conf" 2>/dev/null; then
      warn "$CONF_DIR/nginx.conf 里没有 $MARKER 标记"
      info "这个目录可能不是本脚本建的"
      echo
      read -r -p "         确认要删请输入 delete: " ans || skip_dir=1
      if [ "$(trim "${ans-}")" != "delete" ]; then
        skip_dir=1
      fi
    fi
    if [ "$skip_dir" = "1" ]; then
      info "已跳过，$BASE 原样保留"
    else
      rm -rf "$BASE"
      ok "$BASE 已删除"
    fi
  else
    info "$BASE 不存在，跳过"
  fi

  log "删除系统用户"
  if id "$NGINX_USER" >/dev/null 2>&1; then
    if command -v pgrep >/dev/null 2>&1 && pgrep -u "$NGINX_USER" >/dev/null 2>&1; then
      warn "用户 $NGINX_USER 还有进程在跑，先保留"
    elif userdel "$NGINX_USER" 2>/dev/null; then
      groupdel "$NGINX_USER" 2>/dev/null || true
      ok "用户 $NGINX_USER 已删除"
    else
      warn "用户 $NGINX_USER 删不掉，需要时手动执行：userdel $NGINX_USER"
    fi
  else
    info "用户 $NGINX_USER 不存在，跳过"
  fi

  log "回收端口"
  if ss -lntp 2>/dev/null | grep -qE ':(80|443)\s'; then
    warn "80 / 443 还有别的程序在监听（不是 nginx，未处理）"
    ss -lntp 2>/dev/null | grep -E ':(80|443)\s' | sed 's/^/       /'
  else
    ok "80 / 443 已释放"
  fi

  echo
  local -a tail_lines=()
  if [ -n "${archive:-}" ]; then
    tail_lines+=("$(kv 留档 "$archive")")
    tail_lines+=("$(kv 恢复 "解开放回 $BASE，再执行「安装 / 更新」")")
  fi
  tail_lines+=("$(kv 重装 "重新执行本脚本即可")")
  panel_box "卸载完成" "${tail_lines[@]}"
}

# ============================================================
# 交互菜单
# ============================================================
menu_status_line() {
  if [ ! -x "$NGINX_BIN" ]; then
    printf '%s●%s  未安装' "$C_GRY" "$C_RST"
    return 0
  fi
  local pid
  if systemctl is-active --quiet nginx 2>/dev/null; then
    pid=$(systemctl show -p MainPID --value nginx 2>/dev/null || echo "?")
    printf '%s●%s  %s运行中%s  %spid %s%s' "$C_GRN" "$C_RST" "$C_GRN" "$C_RST" "$C_DIM" "$pid" "$C_RST"
  else
    printf '%s●%s  %s已安装，未运行%s' "$C_YEL" "$C_RST" "$C_YEL" "$C_RST"
  fi
}

interactive_menu() {
  while true; do
    page_head "nginx ${NGINX_VERSION}  ·  管理控制台"
    printf '    %s  %s·%s  %s%s%s\n' "$(menu_status_line)" "$C_DIM" "$C_RST" "$C_DIM" "$BASE" "$C_RST"
    echo

    if ! select_menu "↑↓ 移动   ↵ 确认   q 退出" \
      "安装 / 更新|编译 · 生产基线 · 日志切割 · 开机自启" \
      "修复|重建配置、权限、服务" \
      "体检|只读检查，不改动任何东西" \
      "运行状态|版本、进程、端口监听" \
      "证书管理|申请 · 续签 · 到期查看" \
      "查看日志|access / error" \
      "重载 / 重启|改完配置用重载" \
      "备份配置|打包 conf 目录" \
      "外网访问排查|端口、防火墙、公网 IP" \
      "卸载|停服务，清掉本脚本装的全部内容" \
      "退出"; then
      echo
      return 0
    fi

    echo
    case "$MENU_RESULT" in
      0) do_install ;;
      1) do_repair ;;
      2) do_doctor || true ;;
      3) do_status || true ;;
      4) do_cert_menu || true ;;
      5) do_view_logs || true ;;
      6) do_reload || true ;;
      7) do_backup || true ;;
      8) do_netcheck || true ;;
      9) do_uninstall || true ;;
      10) info "已退出"; return 0 ;;
    esac

    echo
    if [ -t 0 ]; then
      printf '  %s按回车返回菜单%s' "$C_DIM" "$C_RST"
      read -r _ || return 0
      printf '\n'
    fi
  done
}

# ============================================================
# 入口
# ============================================================
main() {
  local arg1=${1:-}

  case "$arg1" in
    help|-h|--help)
      usage
      return 0
      ;;
  esac

  [ "$(id -u)" = "0" ] || die "请用 root 运行"

  # 不带参数：有终端就进菜单，无终端（管道/CI）直接安装
  if [ $# -eq 0 ]; then
    if [ -t 0 ]; then
      interactive_menu
    else
      do_install
    fi
    return 0
  fi

  case "$arg1" in
    install)   do_install ;;
    repair)    do_repair ;;
    doctor)    do_doctor || exit 1 ;;
    status)    do_status || exit 1 ;;
    uninstall) do_uninstall ;;
    *)
      echo "未知命令: ${arg1}" >&2
      echo
      usage
      exit 1
      ;;
  esac
}

main "$@"
