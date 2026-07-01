#!/usr/bin/env bash
#
# Debian 13 (Trixie) 一键初始化脚本
# 功能：
#   1. 安装必要基础软件包 (wget/curl/sudo/vim/ca-certificates 等)
#   2. 安装并启用 chrony 做时间同步（禁用 systemd-timesyncd 避免冲突）
#   3. 开启 BBR + fq 拥塞控制 + IP 转发 (/etc/sysctl.d/99-bbr.conf)
#   4. 修改 /etc/resolv.conf 为公共 DNS，并锁定防止被覆盖
#
# 使用方法：
#   sudo bash init-debian13.sh
#
set -euo pipefail

# ---------- 输出函数 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- 检查 root 权限 ----------
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此脚本 (sudo bash $0)"
    exit 1
fi

# ---------- 检查系统 ----------
if ! grep -qi "trixie\|debian" /etc/os-release 2>/dev/null; then
    warn "未检测到 Debian 系统，脚本仍会尝试继续执行"
fi

# ==========================================================
# 1. 安装基础软件包
# ==========================================================
info "更新软件源并安装基础软件包..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y \
    wget \
    curl \
    sudo \
    vim \
    nano \
    ca-certificates \
    gnupg \
    lsb-release \
    net-tools \
    dnsutils \
    unzip \
    tar \
    chrony \
    cron

info "基础软件包安装完成"

# ==========================================================
# 2. 时间同步：启用 chrony，禁用 systemd-timesyncd
# ==========================================================
info "配置 chrony 时间同步..."

CHRONY_CONF="/etc/chrony/chrony.conf"
if [[ -f "$CHRONY_CONF" ]]; then
    cp -n "$CHRONY_CONF" "${CHRONY_CONF}.bak.$(date +%s)" || true
fi

cat > "$CHRONY_CONF" <<'EOF'
# 使用 pool.ntp.org 官方池
pool pool.ntp.org iburst

driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1.0 3
EOF

# 禁用 systemd-timesyncd，避免和 chrony 抢占时钟
if systemctl is-enabled systemd-timesyncd &>/dev/null; then
    systemctl disable --now systemd-timesyncd || true
fi

systemctl enable --now chrony
systemctl restart chrony

sleep 2
info "chrony 状态："
chronyc tracking || warn "chrony 尚未完全同步，稍后可手动执行: chronyc tracking"

# ==========================================================
# 3. 开启 BBR + fq + IP 转发
# ==========================================================
info "配置内核参数 (BBR + fq + ip_forward)..."

# 加载 bbr 内核模块（Debian 内核默认已编译，一般无需额外操作）
modprobe tcp_bbr 2>/dev/null || warn "tcp_bbr 模块加载失败，可能已内置或内核不支持"

SYSCTL_FILE="/etc/sysctl.d/99-bbr.conf"
cat > "$SYSCTL_FILE" <<'EOF'
# ---- 拥塞控制: BBR + fq ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- IP 转发（网关/代理/容器场景需要） ----
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sysctl --system >/dev/null

info "验证 BBR 是否生效："
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
sysctl net.ipv4.ip_forward

if lsmod | grep -q bbr; then
    info "tcp_bbr 模块已加载"
else
    warn "未在 lsmod 中检测到 bbr 模块（部分内核已默认内置，不一定异常）"
fi

# ==========================================================
# 4. 修改 /etc/resolv.conf
# ==========================================================
info "配置 /etc/resolv.conf..."

RESOLV_CONF="/etc/resolv.conf"

# 如果 resolv.conf 是 systemd-resolved 的软链接，需要先解除
if [[ -L "$RESOLV_CONF" ]]; then
    warn "检测到 /etc/resolv.conf 是符号链接，正在解除并替换为静态文件"
    # 停用 resolved 对 resolv.conf 的接管（若存在该服务）
    if systemctl is-active systemd-resolved &>/dev/null; then
        systemctl disable --now systemd-resolved || true
    fi
    rm -f "$RESOLV_CONF"
fi

# 解锁（若之前脚本运行过并加了 immutable 属性）
chattr -i "$RESOLV_CONF" 2>/dev/null || true

cat > "$RESOLV_CONF" <<'EOF'
# Managed by init-debian13.sh
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF

# 加锁防止被 NetworkManager / dhclient / resolved 等覆盖
chattr +i "$RESOLV_CONF" 2>/dev/null && info "已锁定 /etc/resolv.conf（chattr +i）防止被覆盖" \
    || warn "无法锁定 /etc/resolv.conf（文件系统可能不支持 chattr）"

# ==========================================================
# 完成
# ==========================================================
echo
info "======================================"
info " 初始化完成！"
info "======================================"
info "时间同步: $(systemctl is-active chrony)"
info "BBR 状态: $(sysctl -n net.ipv4.tcp_congestion_control)"
info "IP转发  : $(sysctl -n net.ipv4.ip_forward)"
info "DNS     : $(cat $RESOLV_CONF | grep nameserver | tr '\n' ' ')"
echo
info "如需修改 resolv.conf，请先执行: chattr -i /etc/resolv.conf"
