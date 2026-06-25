#!/bin/bash

#================================================================================
# Snell v5/v6 一键安装脚本 - 优化适配 Debian 13+
#
# 功能概述:
#   - 自动检测系统架构并下载对应的 Snell v5/v6 二进制文件
#   - 支持通过环境变量或命令行自定义 PSK、端口和 Snell 版本
#   - 自动创建配置文件与 systemd 服务，实现开机自启
#   - 提供详尽的日志输出，出现错误时自动清理临时文件
#
# 默认参数(可通过环境变量覆盖):
#   PSK  : IUmuU/NjIQhHPMdBz5WONA==
#   PORT : 53100
#   SNELL_MAJOR   : 5 (可选: 5/6)
#   SNELL_VERSION : 5.0.1 (v6 beta 默认: 6.0.0b1)
#   LISTEN : 自定义监听地址 (默认: 0.0.0.0:${PORT})
#   DNS_IP_PREFERENCE : v6 可选 DNS 地址族偏好
#
# 支持系统: Debian 12/13/14, Ubuntu 20.04+
#
# 使用示例:
#   sudo PSK="your_psk" PORT=12345 ./snell.sh
#   sudo ./snell.sh --major 6
#================================================================================

set -euo pipefail

readonly DEFAULT_PSK="IUmuU/NjIQhHPMdBz5WONA=="
readonly DEFAULT_PORT="53100"
readonly DEFAULT_MAJOR="5"
readonly DEFAULT_V5_VERSION="5.0.1"
readonly DEFAULT_V6_VERSION="6.0.0b1"
readonly V5_VERSION_FALLBACKS=("5.0.1" "5.0.0" "4.1.1" "4.1.0")
readonly V6_VERSION_FALLBACKS=("6.0.0b1")
readonly INSTALL_PATH="/usr/local/bin"
readonly CONFIG_DIR="/etc/snell"
readonly SERVICE_FILE="/etc/systemd/system/snell.service"
readonly DOWNLOAD_BASE_URL="https://dl.nssurge.com/snell"
TMP_DIR=""
EXTRACTED_BINARY=""
DOWNLOADED_VERSION=""
SNELL_MAJOR="${SNELL_MAJOR:-}"
SELECTED_VERSION="${SNELL_VERSION:-}"

readonly DOWNLOAD_PREFIXES=("snell-server" "snell" "Snell-server" "Snell")
readonly DOWNLOAD_EXTENSIONS=("zip" "tar.gz")

log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
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

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "请使用 root 权限运行本脚本。"
        exit 1
    fi
}

detect_system() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        local os_id="${ID:-unknown}"
        local os_version="${VERSION_ID:-unknown}"
        log_info "检测到系统: ${PRETTY_NAME:-$os_id $os_version}"
        
        if [[ "$os_id" == "debian" ]]; then
            local debian_ver="${os_version%%.*}"
            if [[ "$debian_ver" =~ ^[0-9]+$ ]] && (( debian_ver >= 12 )); then
                log_info "Debian ${debian_ver} 已验证兼容。"
            fi
        fi
    fi
}

ensure_dependencies() {
    local missing=()
    local pkg

    for pkg in curl unzip tar ca-certificates; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        return
    fi

    if command -v apt-get &>/dev/null; then
        log_info "正在安装依赖: ${missing[*]}"
        if ! apt-get update -qq 2>/dev/null; then
            log_warn "APT 更新失败，将尝试继续安装依赖。"
        fi
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"; then
            log_error "依赖安装失败，请手动安装: ${missing[*]}"
            exit 1
        fi
    else
        log_error "未检测到 apt-get，请手动安装依赖: ${missing[*]}"
        exit 1
    fi
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        log_error "无效的端口号: $port (需为 1-65535 间的整数)"
        exit 1
    fi
}

validate_psk() {
    local psk="$1"
    if [[ -z "$psk" ]]; then
        log_error "PSK 不能为空。"
        exit 1
    fi
}

validate_dns_ip_preference() {
    local preference="$1"
    if [[ -z "$preference" ]]; then
        return
    fi
    case "$preference" in
        default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only)
            ;;
        *)
            log_error "无效的 DNS_IP_PREFERENCE: $preference"
            exit 1
            ;;
    esac
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "linux-amd64"
            ;;
        i386|i686)
            echo "linux-i386"
            ;;
        aarch64|arm64)
            echo "linux-aarch64"
            ;;
        armv7l|armv7)
            echo "linux-armv7l"
            ;;
        *)
            log_error "当前架构($arch)暂不受支持。"
            exit 1
            ;;
    esac
}

print_usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --major 5|6              选择 Snell 主版本 (默认: ${DEFAULT_MAJOR})
  --version VERSION        指定 Snell 服务端版本 (如: ${DEFAULT_V5_VERSION}, ${DEFAULT_V6_VERSION})
  -h, --help               显示本帮助信息

环境变量:
  PSK                      预共享密钥
  PORT                     监听端口
  SNELL_MAJOR              Snell 主版本 (5/6)
  SNELL_VERSION            Snell 服务端版本
  LISTEN                   自定义 listen 配置值
  DNS_IP_PREFERENCE        v6 DNS 地址族偏好: default/prefer-ipv4/prefer-ipv6/ipv4-only/ipv6-only

示例:
  sudo ./snell.sh
  sudo ./snell.sh --major 6
  sudo SNELL_MAJOR=6 PORT=53100 ./snell.sh
  sudo SNELL_VERSION=${DEFAULT_V6_VERSION} ./snell.sh
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --major)
                shift || { log_error "--major 选项缺少参数。"; exit 1; }
                SNELL_MAJOR="$1"
                ;;
            --major=*)
                SNELL_MAJOR="${1#*=}"
                ;;
            --version)
                shift || { log_error "--version 选项缺少参数。"; exit 1; }
                SELECTED_VERSION="$1"
                ;;
            --version=*)
                SELECTED_VERSION="${1#*=}"
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                print_usage
                exit 1
                ;;
        esac
        shift || break
    done
}

infer_major_from_version() {
    local version="$1"
    case "$version" in
        6.*) echo "6" ;;
        5.*|4.*) echo "5" ;;
        *)
            log_error "无法从版本号 ${version} 推断 Snell 主版本，请同时指定 --major 5|6。"
            exit 1
            ;;
    esac
}

choose_version() {
    if [[ -z "$SNELL_MAJOR" && -n "$SELECTED_VERSION" ]]; then
        SNELL_MAJOR="$(infer_major_from_version "$SELECTED_VERSION")"
    fi

    if [[ -z "$SNELL_MAJOR" && -t 0 ]]; then
        echo "请选择要安装的 Snell 版本："
        echo "1) Snell v5 稳定版 (${DEFAULT_V5_VERSION})"
        echo "2) Snell v6 Beta (${DEFAULT_V6_VERSION})"
        read -rp "请输入选项 [1-2，默认 1]: " choice
        case "${choice:-1}" in
            2) SNELL_MAJOR="6" ;;
            1) SNELL_MAJOR="5" ;;
            *)
                log_warn "无效选择，默认安装 Snell v5。"
                SNELL_MAJOR="5"
                ;;
        esac
    fi

    SNELL_MAJOR="${SNELL_MAJOR:-$DEFAULT_MAJOR}"
    case "$SNELL_MAJOR" in
        5)
            SELECTED_VERSION="${SELECTED_VERSION:-$DEFAULT_V5_VERSION}"
            ;;
        6)
            SELECTED_VERSION="${SELECTED_VERSION:-$DEFAULT_V6_VERSION}"
            log_warn "Snell v6 当前仍处于 Beta，请确保客户端与服务端版本保持同步。"
            ;;
        *)
            log_error "无效的 Snell 主版本: $SNELL_MAJOR (仅支持 5 或 6)"
            exit 1
            ;;
    esac
}

resolve_platform_candidates() {
    local platform="$1"
    case "$platform" in
        linux-amd64)
            echo "linux-amd64 linux-x86_64"
            ;;
        linux-aarch64)
            echo "linux-aarch64 linux-arm64"
            ;;
        *)
            echo "$platform"
            ;;
    esac
}

extract_archive() {
    local archive_path="$1"

    log_info "正在解压安装包..."
    case "$archive_path" in
        *.zip)
            if ! unzip -qo "$archive_path" -d "$TMP_DIR"; then
                log_error "解压 Snell 安装包失败 (${archive_path##*/})。"
                exit 1
            fi
            ;;
        *.tar.gz)
            if ! tar -xzf "$archive_path" -C "$TMP_DIR"; then
                log_error "解压 Snell 安装包失败 (${archive_path##*/})。"
                exit 1
            fi
            ;;
        *)
            log_error "不支持的安装包格式: ${archive_path##*/}"
            exit 1
            ;;
    esac

    local binary_path
    binary_path=$(find "$TMP_DIR" -maxdepth 5 -type f -name "snell-server" -print -quit)
    if [[ -z "$binary_path" ]]; then
        log_error "在安装包中未找到 snell-server 可执行文件。"
        exit 1
    fi

    EXTRACTED_BINARY="$binary_path"
}

download_snell() {
    local requested_version="$1"
    local platform="$2"
    local major="${3:-}"

    TMP_DIR=$(mktemp -d /tmp/snell-install.XXXXXX)
    DOWNLOADED_VERSION=""
    EXTRACTED_BINARY=""

    local -a versions_to_try=("$requested_version")
    local -a fallbacks=()
    case "$major" in
        6) fallbacks=("${V6_VERSION_FALLBACKS[@]}") ;;
        *) fallbacks=("${V5_VERSION_FALLBACKS[@]}") ;;
    esac

    local fallback
    for fallback in "${fallbacks[@]}"; do
        if [[ "$fallback" != "$requested_version" ]]; then
            versions_to_try+=("$fallback")
        fi
    done

    IFS=' ' read -r -a platform_candidates <<< "$(resolve_platform_candidates "$platform")"

    local version
    for version in "${versions_to_try[@]}"; do
        local platform_candidate
        for platform_candidate in "${platform_candidates[@]}"; do
            local prefix
            for prefix in "${DOWNLOAD_PREFIXES[@]}"; do
                local ext
                for ext in "${DOWNLOAD_EXTENSIONS[@]}"; do
                    local archive="${prefix}-v${version}-${platform_candidate}.${ext}"
                    local url="$DOWNLOAD_BASE_URL/$archive"
                    log_info "尝试下载 Snell v${version} (${platform_candidate}) -> ${archive}"
                    if curl -fL --connect-timeout 15 --retry 3 --silent --show-error -o "$TMP_DIR/$archive" "$url"; then
                        if [[ "$version" != "$requested_version" ]]; then
                            log_warn "指定版本 ${requested_version} 未能下载，已回退到 ${version}。"
                        fi
                        log_info "下载完成: ${archive}"
                        extract_archive "$TMP_DIR/$archive"
                        DOWNLOADED_VERSION="$version"
                        return
                    else
                        local status=$?
                        log_warn "下载失败 (URL: $url, curl 退出码: $status)"
                        rm -f "$TMP_DIR/$archive"
                    fi
                done
            done
        done
    done

    log_error "无法下载 Snell 安装包，请检查版本和架构是否正确。"
    exit 1
}

install_binary() {
    if [[ -z "$EXTRACTED_BINARY" || ! -f "$EXTRACTED_BINARY" ]]; then
        log_error "未找到解压后的 snell-server 二进制文件。"
        exit 1
    fi

    log_info "正在安装 snell-server 到 $INSTALL_PATH"
    install -m 755 "$EXTRACTED_BINARY" "$INSTALL_PATH/snell-server"
}

write_config() {
    local psk="$1"
    local listen="$2"
    local dns_ip_preference="$3"

    log_info "正在写入配置文件: $CONFIG_DIR/snell-server.conf"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/snell-server.conf" <<CONFIG
[snell-server]
listen = ${listen}
psk = ${psk}
CONFIG
    if [[ -n "$dns_ip_preference" ]]; then
        echo "dns-ip-preference = ${dns_ip_preference}" >> "$CONFIG_DIR/snell-server.conf"
    fi
    chmod 600 "$CONFIG_DIR/snell-server.conf"
}

setup_service() {
    local major="$1"
    log_info "正在创建 systemd 服务文件: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Snell v${major} Proxy Server
Documentation=https://manual.nssurge.com/others/snell.html
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH}/snell-server -c ${CONFIG_DIR}/snell-server.conf
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
ReadWritePaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
SERVICE
    chmod 644 "$SERVICE_FILE"

    if command -v systemctl &>/dev/null; then
        log_info "重载 systemd 配置并启用服务..."
        systemctl daemon-reload
        
        if systemctl enable snell.service >/dev/null 2>&1; then
            log_info "服务已设置为开机自启。"
        else
            log_warn "无法设置开机自启，但将尝试启动服务。"
        fi
        
        if systemctl restart snell.service; then
            sleep 2
            if systemctl is-active --quiet snell.service; then
                log_info "Snell 服务启动成功！"
            else
                log_warn "服务状态异常，请检查: systemctl status snell"
            fi
        else
            log_error "服务启动失败，请检查: journalctl -u snell -n 50"
            exit 1
        fi
    else
        log_warn "未检测到 systemctl，请手动管理 Snell 服务。"
    fi
}

print_summary() {
    local major="$1"
    local version="$2"
    local psk="$3"
    local port="$4"

    cat <<SUMMARY
====================================================================
Snell v${major} (${version}) 安装完成！
配置摘要:
  - 监听端口 : ${port}
  - 预共享密钥: ${psk}
  - 配置文件 : ${CONFIG_DIR}/snell-server.conf
  - 可执行文件: ${INSTALL_PATH}/snell-server
  - 服务名称 : snell.service

管理命令:
  systemctl status snell
  systemctl restart snell
  systemctl stop snell
  journalctl -u snell -f
====================================================================
SUMMARY
}

main() {
    parse_args "$@"
    choose_version

    require_root
    detect_system
    ensure_dependencies

    local psk="${PSK:-$DEFAULT_PSK}"
    local port="${PORT:-$DEFAULT_PORT}"
    local version="$SELECTED_VERSION"
    local listen="${LISTEN:-0.0.0.0:${port}}"
    local dns_ip_preference="${DNS_IP_PREFERENCE:-}"

    validate_psk "$psk"
    validate_port "$port"
    validate_dns_ip_preference "$dns_ip_preference"

    local platform
    platform=$(detect_arch)

    download_snell "$version" "$platform" "$SNELL_MAJOR"
    local actual_version="${DOWNLOADED_VERSION:-$version}"

    install_binary
    write_config "$psk" "$listen" "$dns_ip_preference"
    setup_service "$SNELL_MAJOR"
    print_summary "$SNELL_MAJOR" "$actual_version" "$psk" "$port"
}

main "$@"
