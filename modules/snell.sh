#!/bin/bash

#================================================================================
# Snell v5 一键安装脚本 - 优化适配 Debian 13+
#
# 功能概述:
#   - 自动检测系统架构并下载对应的 Snell v5 二进制文件
#   - 支持通过环境变量自定义 PSK、端口和 Snell 版本
#   - 自动创建配置文件与 systemd 服务，实现开机自启
#   - 提供详尽的日志输出，出现错误时自动清理临时文件
#
# 默认参数(可通过环境变量覆盖):
#   PSK  : IUmuU/NjIQhHPMdBz5WONA==
#   PORT : 53100
#   SNELL_VERSION : 5.0.1
#
# 支持系统: Debian 12/13/14, Ubuntu 20.04+
#
# 使用示例:
#   sudo PSK="your_psk" PORT=12345 ./snell.sh
#================================================================================

set -euo pipefail

readonly DEFAULT_PSK="IUmuU/NjIQhHPMdBz5WONA=="
readonly DEFAULT_PORT="53100"
readonly DEFAULT_VERSION="5.0.1"
readonly VERSION_FALLBACKS=("5.0.1" "5.0.0" "4.1.1" "4.1.0")
readonly INSTALL_PATH="/usr/local/bin"
readonly CONFIG_DIR="/etc/snell"
readonly SERVICE_FILE="/etc/systemd/system/snell.service"
readonly DOWNLOAD_BASE_URL="https://dl.nssurge.com/snell"
TMP_DIR=""
EXTRACTED_BINARY=""
DOWNLOADED_VERSION=""

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

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            echo "linux-amd64"
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

    TMP_DIR=$(mktemp -d /tmp/snell-install.XXXXXX)
    DOWNLOADED_VERSION=""
    EXTRACTED_BINARY=""

    local -a versions_to_try=("$requested_version")
    if [[ "$requested_version" == "$DEFAULT_VERSION" ]]; then
        local fallback
        for fallback in "${VERSION_FALLBACKS[@]}"; do
            if [[ "$fallback" != "$requested_version" ]]; then
                versions_to_try+=("$fallback")
            fi
        done
    fi

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
    local port="$2"

    log_info "正在写入配置文件: $CONFIG_DIR/snell-server.conf"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/snell-server.conf" <<CONFIG
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
CONFIG
    chmod 600 "$CONFIG_DIR/snell-server.conf"
}

setup_service() {
    log_info "正在创建 systemd 服务文件: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Snell v5 Proxy Server
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
    local version="$1"
    local psk="$2"
    local port="$3"

    cat <<SUMMARY
====================================================================
Snell v${version} 安装完成！
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
    require_root
    detect_system
    ensure_dependencies

    local psk="${PSK:-$DEFAULT_PSK}"
    local port="${PORT:-$DEFAULT_PORT}"
    local version="${SNELL_VERSION:-$DEFAULT_VERSION}"

    validate_psk "$psk"
    validate_port "$port"

    local platform
    platform=$(detect_arch)

    download_snell "$version" "$platform"
    local actual_version="${DOWNLOADED_VERSION:-$version}"

    install_binary
    write_config "$psk" "$port"
    setup_service
    print_summary "$actual_version" "$psk" "$port"
}

main "$@"
