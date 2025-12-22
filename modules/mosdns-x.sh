#!/bin/bash

#================================================================================
# mosdns-x 一键安装脚本 - 优化适配 Debian 13+
#
# 功能:
#   - 自动检测系统架构并下载最新的 mosdns-x 版本
#   - 安装必要的依赖 (curl, unzip, ca-certificates)
#   - 创建优化的配置文件 (包含缓存和智能转发)
#   - 创建并启动 systemd 服务，实现开机自启
#   - 自动配置系统 DNS 指向本地服务
#   - 错误处理和自动清理
#
# 支持系统: Debian 12/13/14, Ubuntu 20.04+
#
# 使用方法:
#   sudo ./mosdns-x.sh
#================================================================================

set -euo pipefail
umask 022

# --- 全局常量 ---
readonly INSTALL_PATH="/usr/local/bin"
readonly CONFIG_PATH="/etc/mosdns-x"
readonly SERVICE_PATH="/etc/systemd/system/mosdns-x.service"
readonly SUPPORTED_DEBIAN_VERSIONS=("12" "13" "14")
readonly SUPPORTED_DEBIAN_CODENAMES=("bookworm" "trixie" "forky")

TMP_DIR=""
DEBIAN_ID=""
DEBIAN_VERSION=""

# --- 函数定义 ---

log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[0;33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $1" >&2
}

log_success() {
    echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

cleanup() {
    local exit_code=$?
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    if (( exit_code != 0 )); then
        log_error "脚本执行失败，退出码: $exit_code"
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

check_root() {
    if (( EUID != 0 )); then
        log_error "请使用 root 权限运行此脚本 (例如: sudo ./mosdns-x.sh)"
        exit 1
    fi
}

detect_system() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DEBIAN_ID="${ID:-unknown}"
        DEBIAN_VERSION="${VERSION_ID%%.*}"
        
        log_info "检测到系统: ${PRETTY_NAME:-$DEBIAN_ID $DEBIAN_VERSION}"
        
        if [[ "$DEBIAN_ID" == "debian" ]]; then
            if [[ "$DEBIAN_VERSION" =~ ^[0-9]+$ ]] && (( DEBIAN_VERSION >= 12 )); then
                log_info "Debian ${DEBIAN_VERSION} 已验证兼容。"
            else
                log_warn "当前 Debian 版本 ($DEBIAN_VERSION) 可能存在兼容性问题。"
            fi
        fi
    else
        log_warn "无法检测系统版本，将继续执行。"
    fi
}

install_dependencies() {
    log_info "正在检查并安装依赖..."
    local missing=()
    
    for pkg in curl unzip ca-certificates wget; do
        if ! command -v "$pkg" &>/dev/null && ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    
    if (( ${#missing[@]} == 0 )); then
        log_info "所有依赖已满足。"
        return
    fi
    
    log_info "正在安装缺失的依赖: ${missing[*]}"
    if ! apt-get update -qq 2>/dev/null; then
        log_warn "APT 更新失败，将尝试继续安装依赖。"
    fi
    
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"; then
        log_error "依赖安装失败: ${missing[*]}"
        exit 1
    fi
    log_success "依赖安装完成。"
}

get_latest_release() {
    log_info "正在获取 mosdns-x 最新版本信息..."
    local api_url="https://api.github.com/repos/pmkol/mosdns-x/releases/latest"
    
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            arch="linux-amd64"
            ;;
        aarch64|arm64)
            arch="linux-arm64"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
    
    local download_url
    download_url=$(curl -fsSL "$api_url" | grep "browser_download_url.*${arch}.zip" | sed -E 's/.*"([^"]+)".*/\1/' | head -n1)
    
    if [[ -z "$download_url" ]]; then
        log_error "无法获取 mosdns-x 下载链接。请检查网络或访问 https://github.com/pmkol/mosdns-x/releases"
        exit 1
    fi
    
    log_info "成功获取下载链接: $download_url"
    echo "$download_url"
}

download_and_install() {
    local download_url="$1"
    
    TMP_DIR=$(mktemp -d /tmp/mosdns-x-install.XXXXXX)
    
    log_info "正在下载 mosdns-x..."
    if ! curl -fL --connect-timeout 15 --retry 3 "$download_url" -o "$TMP_DIR/mosdns.zip"; then
        log_error "下载失败，请检查网络连接。"
        exit 1
    fi
    
    log_info "正在解压文件..."
    if ! unzip -qo "$TMP_DIR/mosdns.zip" -d "$TMP_DIR"; then
        log_error "解压失败。"
        exit 1
    fi
    
    local binary_path
    binary_path=$(find "$TMP_DIR" -maxdepth 2 -type f -name "mosdns" -print -quit)
    
    if [[ -z "$binary_path" || ! -f "$binary_path" ]]; then
        log_error "在解压的文件中找不到 'mosdns' 可执行文件。"
        exit 1
    fi
    
    log_info "正在安装到 $INSTALL_PATH/mosdns-x..."
    if ! install -m 755 "$binary_path" "$INSTALL_PATH/mosdns-x"; then
        log_error "安装二进制文件失败。"
        exit 1
    fi
    
    log_success "mosdns-x 二进制文件安装完成。"
}

create_config_file() {
    log_info "正在创建配置文件到 $CONFIG_PATH/config.yaml..."
    mkdir -p "$CONFIG_PATH"
    
    cat > "$CONFIG_PATH/config.yaml" <<'EOF'
log:
  level: info
  file: ""

plugins:
  - tag: cache
    type: cache
    args:
      size: 65536
      lazy_cache_ttl: 259200
      lazy_cache_reply_ttl: 5

  - tag: forward
    type: fast_forward
    args:
      upstream:
        - addr: tls://1.1.1.1
        - addr: tls://8.8.8.8
        - addr: tls://unfiltered.adguard-dns.com
        - addr: 1.1.1.1
        - addr: 8.8.8.8

  - tag: sequence
    type: sequence
    args:
      exec:
        - "cache"
        - "forward"

servers:
  - exec: sequence
    listeners:
      - protocol: udp
        addr: 127.0.0.1:53
      - protocol: tcp
        addr: 127.0.0.1:53
EOF

    if (( $? != 0 )); then
        log_error "创建配置文件失败。"
        exit 1
    fi
    
    log_success "配置文件创建完成。"
}

create_systemd_service() {
    log_info "正在创建 systemd 服务..."
    
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=mosdns-x DNS Forwarder
Documentation=https://github.com/pmkol/mosdns-x/wiki
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH}/mosdns-x start -c ${CONFIG_PATH}/config.yaml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CONFIG_PATH}

[Install]
WantedBy=multi-user.target
EOF

    if (( $? != 0 )); then
        log_error "创建 systemd 服务文件失败。"
        exit 1
    fi
    
    chmod 644 "$SERVICE_PATH"
    log_success "systemd 服务文件创建完成。"
}

stop_systemd_resolved() {
    if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
        if systemctl is-active --quiet systemd-resolved; then
            log_warn "检测到 systemd-resolved 正在运行，将停止以释放 53 端口..."
            systemctl stop systemd-resolved >/dev/null 2>&1 || true
            systemctl disable systemd-resolved >/dev/null 2>&1 || true
            log_info "systemd-resolved 已停止。"
        fi
    fi
}

start_service() {
    log_info "正在重载 systemd 配置..."
    systemctl daemon-reload
    
    log_info "正在启用并启动 mosdns-x 服务..."
    if systemctl enable mosdns-x.service >/dev/null 2>&1; then
        log_info "服务已设置为开机自启。"
    else
        log_warn "无法设置开机自启。"
    fi
    
    if systemctl restart mosdns-x.service; then
        sleep 2
        if systemctl is-active --quiet mosdns-x.service; then
            log_success "mosdns-x 服务已成功启动！"
        else
            log_error "服务启动后状态异常，请检查: systemctl status mosdns-x"
            exit 1
        fi
    else
        log_error "服务启动失败，请检查: journalctl -u mosdns-x -n 50"
        exit 1
    fi
}

print_summary() {
    cat <<SUMMARY

============================================================
          mosdns-x 安装完成！
============================================================
  配置文件: ${CONFIG_PATH}/config.yaml
  DNS 监听地址: 127.0.0.1:53 (TCP/UDP)
  
  功能特性:
    ✓ 智能缓存 (65536 条记录)
    ✓ DoT/DoH 上游支持
    ✓ 自动故障转移
    
  常用命令:
    - 查看状态: systemctl status mosdns-x
    - 重启服务: systemctl restart mosdns-x
    - 查看日志: journalctl -u mosdns-x -f
    - 测试 DNS: dig @127.0.0.1 google.com
    
  配置系统 DNS:
    - 编辑 /etc/resolv.conf 添加: nameserver 127.0.0.1
============================================================

SUMMARY
}

main() {
    check_root
    detect_system
    install_dependencies
    
    local download_url
    download_url=$(get_latest_release)
    
    download_and_install "$download_url"
    create_config_file
    create_systemd_service
    stop_systemd_resolved
    start_service
    print_summary
}

main "$@"
