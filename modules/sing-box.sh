#!/bin/bash

#================================================================================
# sing-box 一键安装脚本 - 优化适配 Debian 13+
#
# 功能:
#   - 自动检测系统架构并下载最新的 sing-box 版本
#   - 安装必要的依赖
#   - 创建优化的配置文件 (Shadowsocks 2022)
#   - 创建并启动 systemd 服务，实现开机自启
#   - 错误处理和自动清理
#
# 支持系统: Debian 12/13/14, Ubuntu 20.04+
#
# 使用方法:
#   sudo ./sing-box.sh
#   或通过环境变量自定义配置:
#   sudo PORT=8388 PASSWORD="your_password" ./sing-box.sh
#================================================================================

set -euo pipefail
umask 022

# --- 全局常量 ---
readonly INSTALL_PATH="/usr/local/bin"
readonly CONFIG_DIR="/etc/sing-box"
readonly SERVICE_FILE="/etc/systemd/system/sing-box.service"
readonly SUPPORTED_DEBIAN_VERSIONS=("12" "13" "14")
readonly DEFAULT_PORT="59271"
readonly DEFAULT_PASSWORD="IUmuU/NjIQhHPMdBz5WONA=="
readonly DEFAULT_METHOD="2022-blake3-aes-128-gcm"

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
        log_error "请使用 root 权限运行此脚本 (例如: sudo ./sing-box.sh)"
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
    
    for pkg in curl tar ca-certificates jq; do
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

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armv7)
            echo "armv7"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

get_latest_release() {
    log_info "正在获取 sing-box 最新版本信息..." >&2
    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    
    local arch
    arch=$(detect_arch)
    
    local api_response download_url version
    api_response=$(curl -fsSL "$api_url")
    download_url=$(echo "$api_response" | jq -r ".assets[] | select(.name | contains(\"linux-${arch}\") and endswith(\".tar.gz\")) | .browser_download_url" | head -n1)
    version=$(echo "$api_response" | jq -r '.tag_name' | sed 's/^v//')
    
    if [[ -z "$download_url" ]]; then
        log_error "无法获取 sing-box 下载链接。请检查网络或访问 https://github.com/SagerNet/sing-box/releases"
        exit 1
    fi
    
    log_info "成功获取下载链接 (版本 $version): $download_url" >&2
    echo "$download_url"
}

download_and_install() {
    local download_url="$1"
    
    TMP_DIR=$(mktemp -d /tmp/sing-box-install.XXXXXX)
    
    log_info "正在下载 sing-box..."
    if ! curl -fL --connect-timeout 15 --retry 3 "$download_url" -o "$TMP_DIR/sing-box.tar.gz"; then
        log_error "下载失败，请检查网络连接。"
        exit 1
    fi
    
    log_info "正在解压文件..."
    if ! tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR"; then
        log_error "解压失败。"
        exit 1
    fi
    
    local binary_path
    binary_path=$(find "$TMP_DIR" -type f -name "sing-box" -executable -print -quit)
    
    if [[ -z "$binary_path" || ! -f "$binary_path" ]]; then
        log_error "在解压的文件中找不到 'sing-box' 可执行文件。"
        exit 1
    fi
    
    log_info "正在安装到 $INSTALL_PATH/sing-box..."
    if ! install -m 755 "$binary_path" "$INSTALL_PATH/sing-box"; then
        log_error "安装二进制文件失败。"
        exit 1
    fi
    
    # 验证安装
    if "$INSTALL_PATH/sing-box" version >/dev/null 2>&1; then
        local installed_version
        installed_version=$("$INSTALL_PATH/sing-box" version | head -n1 | awk '{print $3}')
        log_success "sing-box ${installed_version} 安装完成。"
    else
        log_error "sing-box 安装验证失败。"
        exit 1
    fi
}

create_config_file() {
    local port="${PORT:-$DEFAULT_PORT}"
    local password="${PASSWORD:-$DEFAULT_PASSWORD}"
    local method="${METHOD:-$DEFAULT_METHOD}"
    
    log_info "正在创建配置文件到 $CONFIG_DIR/config.json..."
    mkdir -p "$CONFIG_DIR"
    
    cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "DIRECT",
      "listen": "::",
      "listen_port": ${port},
      "method": "${method}",
      "password": "${password}",
      "multiplex": {
        "enabled": true,
        "padding": true
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": ["bittorrent"],
        "action": "route",
        "outbound": "block"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      },
      {
        "inbound": ["DIRECT"],
        "outbound": "direct",
        "action": "route",
        "network": ["tcp", "udp"]
      }
    ]
  }
}
EOF

    if (( $? != 0 )); then
        log_error "创建配置文件失败。"
        exit 1
    fi
    
    chmod 600 "$CONFIG_DIR/config.json"
    log_success "配置文件创建完成。"
    
    # 验证配置
    if "$INSTALL_PATH/sing-box" check -c "$CONFIG_DIR/config.json" >/dev/null 2>&1; then
        log_info "配置文件验证通过。"
    else
        log_error "配置文件验证失败，请检查配置。"
        exit 1
    fi
}

create_systemd_service() {
    log_info "正在创建 systemd 服务..."
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH}/sing-box run -c ${CONFIG_DIR}/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${CONFIG_DIR}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

    if (( $? != 0 )); then
        log_error "创建 systemd 服务文件失败。"
        exit 1
    fi
    
    chmod 644 "$SERVICE_FILE"
    log_success "systemd 服务文件创建完成。"
}

start_service() {
    log_info "正在重载 systemd 配置..."
    systemctl daemon-reload
    
    log_info "正在启用并启动 sing-box 服务..."
    if systemctl enable sing-box.service >/dev/null 2>&1; then
        log_info "服务已设置为开机自启。"
    else
        log_warn "无法设置开机自启。"
    fi
    
    if systemctl restart sing-box.service; then
        sleep 2
        if systemctl is-active --quiet sing-box.service; then
            log_success "sing-box 服务已成功启动！"
        else
            log_error "服务启动后状态异常，请检查: systemctl status sing-box"
            exit 1
        fi
    else
        log_error "服务启动失败，请检查: journalctl -u sing-box -n 50"
        exit 1
    fi
}

print_summary() {
    local port="${PORT:-$DEFAULT_PORT}"
    local password="${PASSWORD:-$DEFAULT_PASSWORD}"
    local method="${METHOD:-$DEFAULT_METHOD}"
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    
    cat <<SUMMARY

============================================================
          sing-box 安装完成！
============================================================
  配置文件: ${CONFIG_DIR}/config.json
  服务类型: Shadowsocks 2022
  
  连接信息:
    - 服务器地址: ${server_ip}
    - 端口: ${port}
    - 加密方法: ${method}
    - 密码: ${password}
    
  功能特性:
    ✓ Shadowsocks 2022 协议
    ✓ 多路复用支持
    ✓ BT 流量拦截
    ✓ 私有 IP 直连
    
  常用命令:
    - 查看状态: systemctl status sing-box
    - 重启服务: systemctl restart sing-box
    - 查看日志: journalctl -u sing-box -f
    - 验证配置: sing-box check -c ${CONFIG_DIR}/config.json
    
  客户端配置示例:
    服务器: ${server_ip}:${port}
    密码: ${password}
    加密: ${method}
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
    start_service
    print_summary
}

main "$@"
