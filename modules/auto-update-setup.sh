#!/bin/bash

set -euo pipefail
umask 022

readonly UPDATE_SCRIPT_PATH="/usr/local/sbin/system-auto-update.sh"
readonly LOG_FILE="/var/log/system-auto-update.log"
readonly DEFAULT_CRON_SCHEDULE="0 2 * * 0"
readonly CRON_JOB_COMMENT="# winter auto-update"
readonly SUPPORTED_DEBIAN_MAJOR_VERSIONS=("12" "13" "14")
readonly SUPPORTED_DEBIAN_CODENAMES=("bookworm" "trixie" "forky")
readonly CRON_SERVICE_NAME="cron"

APT_UPDATED=0
DEBIAN_ID=""
DEBIAN_MAJOR_VERSION=""
DEBIAN_CODENAME=""

log() {
    local msg="$1" level="${2:-info}"
    local color
    case "$level" in
        info)    color="\033[0;36m" ;;
        warn)    color="\033[0;33m" ;;
        error)   color="\033[0;31m" ;;
        success) color="\033[0;32m" ;;
        *)       color="\033[0m" ;;
    esac
    echo -e "${color}[$(date '+%H:%M:%S')] $msg\033[0m" >&2
}

ensure_root() {
    if (( EUID != 0 )); then
        log "此脚本需要 root 权限运行，请使用 sudo 或切换至 root。" "error"
        exit 1
    fi
}

detect_debian_release() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DEBIAN_ID="${ID:-}"
        DEBIAN_CODENAME="${VERSION_CODENAME:-}"
        DEBIAN_MAJOR_VERSION="${VERSION_ID%%.*}"
    fi

    local id_like="${ID_LIKE:-}"
    if [[ "${DEBIAN_ID}" != "debian" && "${id_like}" != *debian* ]]; then
        log "检测到的系统并非 Debian 系，脚本仅在 Debian 12/13 上验证。" "warn"
    fi

    if [[ -z "$DEBIAN_MAJOR_VERSION" && -n "$DEBIAN_CODENAME" ]]; then
        case "$DEBIAN_CODENAME" in
            bookworm) DEBIAN_MAJOR_VERSION="12" ;;
            trixie)   DEBIAN_MAJOR_VERSION="13" ;;
            forky)    DEBIAN_MAJOR_VERSION="14" ;;
        esac
    fi

    local supported=0 version codename
    if [[ -n "$DEBIAN_MAJOR_VERSION" ]]; then
        for version in "${SUPPORTED_DEBIAN_MAJOR_VERSIONS[@]}"; do
            if [[ "$version" == "$DEBIAN_MAJOR_VERSION" ]]; then
                supported=1
                break
            fi
        done
    fi

    if (( !supported )) && [[ -n "$DEBIAN_CODENAME" ]]; then
        for codename in "${SUPPORTED_DEBIAN_CODENAMES[@]}"; do
            if [[ "$codename" == "$DEBIAN_CODENAME" ]]; then
                supported=1
                break
            fi
        done
    fi

    if (( supported )); then
        log "检测到 Debian ${DEBIAN_MAJOR_VERSION:-unknown}${DEBIAN_CODENAME:+ (${DEBIAN_CODENAME})}。" "info"
    else
        log "当前系统版本 ${DEBIAN_MAJOR_VERSION:-unknown}${DEBIAN_CODENAME:+ (${DEBIAN_CODENAME})} 未列入官方支持范围。" "warn"
    fi
}

ensure_systemd() {
    if [[ ! -d /run/systemd/system ]]; then
        log "未检测到 systemd 运行环境，无法管理 Cron 服务。" "error"
        exit 1
    fi
}

ensure_apt_updated() {
    if (( APT_UPDATED )); then
        return 0
    fi
    log "刷新 APT 软件源索引..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        log "APT 更新失败，请检查网络或软件源配置。" "error"
        return 1
    fi
    APT_UPDATED=1
}

ensure_packages() {
    local pkg missing=()
    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    (( ${#missing[@]} )) || return 0

    ensure_apt_updated || return 1
    log "安装缺失的依赖: ${missing[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null; then
        log "安装依赖失败: ${missing[*]}" "error"
        return 1
    fi
}

ensure_cron_service() {
    log "检查 Cron 服务..."
    ensure_packages cron || return 1

    if ! systemctl is-enabled --quiet "$CRON_SERVICE_NAME" 2>/dev/null; then
        log "启用 Cron 服务并设置开机自启。" "info"
        systemctl enable "$CRON_SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    if ! systemctl is-active --quiet "$CRON_SERVICE_NAME"; then
        log "启动 Cron 服务..." "warn"
        systemctl start "$CRON_SERVICE_NAME"
    fi

    if systemctl is-active --quiet "$CRON_SERVICE_NAME"; then
        log "Cron 服务运行正常。" "success"
    else
        log "Cron 服务无法启动，请检查 systemctl 状态。" "error"
        return 1
    fi
}

create_update_script() {
    log "创建系统自动更新执行脚本..."
    install -d -m 755 "$(dirname "$UPDATE_SCRIPT_PATH")"
    install -d -m 755 "$(dirname "$LOG_FILE")"

    cat > "$UPDATE_SCRIPT_PATH" <<'EOS'
#!/bin/bash
set -euo pipefail

readonly LOG_FILE="/var/log/system-auto-update.log"
readonly APT_OPTIONS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

handle_kernel_update_and_reboot() {
    local current_kernel latest_kernel
    current_kernel=$(uname -r)
    latest_kernel=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n1)

    if [[ -n "$latest_kernel" && "$latest_kernel" != "$current_kernel" ]]; then
        log_to_file "检测到新内核版本 ($latest_kernel)，系统将在1分钟后重启以应用更新。"
        sync
        sleep 60
        systemctl reboot || reboot
    fi
}

log_to_file "======== 开始系统自动更新 ========"
log_to_file "更新软件包列表 (apt-get update)..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1

log_to_file "执行系统升级 (apt-get dist-upgrade)..."
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS >>"$LOG_FILE" 2>&1

handle_kernel_update_and_reboot

log_to_file "清理无用的软件包 (apt-get autoremove)..."
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >>"$LOG_FILE" 2>&1

log_to_file "清理旧的软件包缓存 (apt-get autoclean)..."
DEBIAN_FRONTEND=noninteractive apt-get autoclean -qq >>"$LOG_FILE" 2>&1

log_to_file "======== 系统自动更新完成 ========"
EOS

    chmod 755 "$UPDATE_SCRIPT_PATH"
    log "更新脚本已写入 $UPDATE_SCRIPT_PATH" "success"
}

prompt_cron_schedule() {
    local use_default custom_schedule cron_schedule
    read -p "是否使用默认更新时间 (每周日凌晨2点)? [Y/n]: " -r use_default
    if [[ "$use_default" =~ ^[Nn]$ ]]; then
        log "请输入自定义 Cron 表达式 (分 时 日 月 周)。" "info"
        while true; do
            read -p "请输入: " -r custom_schedule
            if [[ "$custom_schedule" =~ ^[0-9*,/-]+[[:space:]][0-9*,/-]+[[:space:]][0-9*,/-]+[[:space:]][0-9*,/-]+[[:space:]][0-9*,/-]+$ ]]; then
                cron_schedule="$custom_schedule"
                break
            fi
            log "Cron 表达式格式无效，请重新输入。" "error"
        done
    else
        cron_schedule="$DEFAULT_CRON_SCHEDULE"
    fi
    printf '%s' "$cron_schedule"
}

setup_cron_job() {
    log "配置 Cron 定时任务..."
    local cron_schedule

    if crontab -l 2>/dev/null | grep -q "$UPDATE_SCRIPT_PATH"; then
        local overwrite
        read -p "检测到已有自动更新任务，是否覆盖? [y/N]: " -r overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            log "保留现有 Cron 任务。" "warn"
            return 0
        fi
    fi

    cron_schedule=$(prompt_cron_schedule)
    local tmp_cron
    tmp_cron=$(mktemp)

    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT_PATH" | grep -v "$CRON_JOB_COMMENT" >"$tmp_cron" || true
    {
        echo "$CRON_JOB_COMMENT"
        echo "$cron_schedule $UPDATE_SCRIPT_PATH"
    } >>"$tmp_cron"

    if crontab "$tmp_cron"; then
        log "Cron 定时任务配置完成。" "success"
    else
        log "导入 Cron 配置失败。" "error"
        rm -f "$tmp_cron"
        return 1
    fi
    rm -f "$tmp_cron"
}

show_summary() {
    echo
    log "---------- 自动更新配置摘要 ----------"
    if [[ -x "$UPDATE_SCRIPT_PATH" ]]; then
        echo -e "  \033[0;32m✓\033[0m 更新脚本: $UPDATE_SCRIPT_PATH"
    else
        echo -e "  \033[0;31m✗\033[0m 更新脚本: 未找到"
    fi

    if systemctl is-active --quiet "$CRON_SERVICE_NAME"; then
        echo -e "  \033[0;32m✓\033[0m Cron 服务: 运行中"
    else
        echo -e "  \033[0;31m✗\033[0m Cron 服务: 未运行"
    fi

    local cron_line
    cron_line=$(crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT_PATH" || true)
    if [[ -n "$cron_line" ]]; then
        echo -e "  \033[0;32m✓\033[0m 定时任务: 已配置 ($cron_line)"
    else
        echo -e "  \033[0;31m✗\033[0m 定时任务: 未配置"
    fi

    echo -e "  \033[0;36mⓘ\033[0m 日志文件: $LOG_FILE"
    echo
    log "常用命令:" "info"
    echo "  - 查看任务: crontab -l"
    echo "  - 编辑任务: crontab -e"
    echo "  - 手动执行: sudo $UPDATE_SCRIPT_PATH"
    echo "  - 查看日志: sudo tail -f $LOG_FILE"
    echo "  - 移除任务: (crontab -l | grep -v '$UPDATE_SCRIPT_PATH' | crontab -)"
    echo
}

main() {
    trap 'log "脚本执行中发生错误，请检查输出与日志。" "error"' ERR
    ensure_root
    detect_debian_release
    ensure_systemd
    ensure_cron_service
    create_update_script
    setup_cron_job
    show_summary
    log "所有配置已完成！" "success"
}

main "$@"
