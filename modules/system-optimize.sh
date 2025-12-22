#!/bin/bash

set -euo pipefail

# === 常量定义 ===
readonly CUSTOM_ZRAM_SCRIPT="/usr/local/sbin/custom-zram-setup.sh"
readonly SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/zramswap.service.d"
readonly SYSTEMD_OVERRIDE_FILE="${SYSTEMD_OVERRIDE_DIR}/override.conf"
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly SUPPORTED_DEBIAN_MAJOR_VERSIONS=("12" "13" "14")
readonly SUPPORTED_DEBIAN_CODENAMES=("bookworm" "trixie" "forky")

APT_UPDATED=0
DEBIAN_MAJOR_VERSION=""
DEBIAN_CODENAME=""
DEBIAN_ID=""

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

debug_log() {
    [[ "${DEBUG:-}" == "1" ]] && log "DEBUG: $1" "debug" >&2
}

# === 环境检测与包管理工具 ===
detect_debian_release() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DEBIAN_ID="${ID:-}"
        DEBIAN_CODENAME="${VERSION_CODENAME:-${DEBIAN_CODENAME:-}}"
        DEBIAN_MAJOR_VERSION="${VERSION_ID%%.*}"
    fi

    local id_like="${ID_LIKE:-}"
    if [[ "${DEBIAN_ID}" != "debian" && "${id_like}" != *debian* ]]; then
        log "检测到的系统并非Debian系，脚本仅在Debian 12/13上经过验证" "warn"
    fi

    if [[ -n "${DEBIAN_MAJOR_VERSION}" && ! "${DEBIAN_MAJOR_VERSION}" =~ ^[0-9]+$ ]]; then
        DEBIAN_MAJOR_VERSION=""
    fi

    if [[ -z "${DEBIAN_MAJOR_VERSION}" && -n "${DEBIAN_CODENAME}" ]]; then
        case "${DEBIAN_CODENAME}" in
            bookworm) DEBIAN_MAJOR_VERSION="12" ;;
            trixie)   DEBIAN_MAJOR_VERSION="13" ;;
            forky)    DEBIAN_MAJOR_VERSION="14" ;;
        esac
    fi

    local supported=0

    if [[ -n "${DEBIAN_MAJOR_VERSION}" ]]; then
        local version
        for version in "${SUPPORTED_DEBIAN_MAJOR_VERSIONS[@]}"; do
            if [[ "${DEBIAN_MAJOR_VERSION}" == "$version" ]]; then
                supported=1
                break
            fi
        done
    fi

    if (( !supported )) && [[ -n "${DEBIAN_CODENAME}" ]]; then
        local codename
        for codename in "${SUPPORTED_DEBIAN_CODENAMES[@]}"; do
            if [[ "${DEBIAN_CODENAME}" == "$codename" ]]; then
                supported=1
                break
            fi
        done
    fi

    if (( supported )); then
        log "检测到Debian ${DEBIAN_MAJOR_VERSION:-unknown}${DEBIAN_CODENAME:+ (${DEBIAN_CODENAME})}" "info"
    else
        log "当前系统版本 ${DEBIAN_MAJOR_VERSION:-unknown}${DEBIAN_CODENAME:+ (${DEBIAN_CODENAME})} 未在支持列表内 (${SUPPORTED_DEBIAN_MAJOR_VERSIONS[*]})." "warn"
    fi
}

ensure_apt_updated() {
    if (( APT_UPDATED )); then
        return 0
    fi

    log "刷新APT软件包索引..." "info"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        log "APT源更新失败，请检查网络或软件源配置。" "error"
        return 1
    fi
    APT_UPDATED=1
}

ensure_packages() {
    local pkg
    local -a missing=()

    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done

    (( ${#missing[@]} )) || return 0

    ensure_apt_updated || return 1

    log "安装缺失的依赖: ${missing[*]}" "info"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null 2>&1; then
        log "安装依赖失败: ${missing[*]}" "error"
        return 1
    fi
}

restore_timesyncd() {
    log "回退启用 systemd-timesyncd 服务" "warn"
    systemctl unmask systemd-timesyncd.service >/dev/null 2>&1 || true
    systemctl enable systemd-timesyncd.service >/dev/null 2>&1 || true
    systemctl start systemd-timesyncd.service >/dev/null 2>&1 || true
}

# === 辅助函数 ===
convert_to_mb() {
    local size="$1"
    size=$(echo "$size" | tr -d ' ')
    local value=$(echo "$size" | sed 's/[^0-9.]//g')
    
    case "${size^^}" in
        *G|*GB) awk "BEGIN {printf \"%.0f\", $value * 1024}" ;;
        *M|*MB) awk "BEGIN {printf \"%.0f\", $value}" ;;
        *K|*KB) awk "BEGIN {printf \"%.0f\", $value / 1024}" ;;
        *)      awk "BEGIN {printf \"%.0f\", $value / 1024 / 1024}" ;;
    esac
}

format_size() {
    local mb="$1"
    if (( mb >= 1024 )); then
        awk "BEGIN {gb=$mb/1024; printf (gb==int(gb)) ? \"%.0fGB\" : \"%.1fGB\", gb}"
    else
        echo "${mb}MB"
    fi
}

show_swap_status() {
    local swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
    echo "Swap配置: swappiness=$swappiness"
    
    local swap_output
    if ! swap_output=$(swapon --show 2>/dev/null | tail -n +2); then
        echo "Swap状态: 无活动设备"
        return
    fi
    
    if [[ -n "$swap_output" ]]; then
        echo "Swap状态:"
        while read -r device _ size used priority; do
            [[ -z "$device" ]] && continue
            if [[ "$device" == *"zram"* ]]; then
                echo "  - Zram: $device ($size, 已用$used, 优先级$priority)"
            else
                echo "  - 磁盘: $device ($size, 已用$used, 优先级$priority)"
            fi
        done <<< "$swap_output"
    else
        echo "Swap状态: 无活动设备"
    fi
}

# 彻底清理zram配置 - 增强版
cleanup_zram_completely() {
    debug_log "开始彻底清理zram"
    
    systemctl stop zramswap.service 2>/dev/null || true
    systemctl disable zramswap.service 2>/dev/null || true
    
    # 移除systemd override
    if [[ -f "$SYSTEMD_OVERRIDE_FILE" ]]; then
        debug_log "移除 systemd override 文件"
        rm -f "$SYSTEMD_OVERRIDE_FILE"
        rmdir --ignore-fail-on-non-empty "$SYSTEMD_OVERRIDE_DIR" 2>/dev/null
        systemctl daemon-reload
    fi
    
    # 移除自定义脚本
    [[ -f "$CUSTOM_ZRAM_SCRIPT" ]] && rm -f "$CUSTOM_ZRAM_SCRIPT"
    
    for dev in /dev/zram*; do
        if [[ -b "$dev" ]]; then
            swapoff "$dev" 2>/dev/null || true
            echo 1 > "/sys/block/$(basename "$dev")/reset" 2>/dev/null || true
            debug_log "重置设备: $dev"
        fi
    done
    
    modprobe -r zram 2>/dev/null || true
    
    [[ -f "/etc/default/zramswap" ]] && rm -f "/etc/default/zramswap" "/etc/default/zramswap.bak" 2>/dev/null || true
    
    sleep 1
    debug_log "zram清理完成"
}

# === 核心功能函数 ===
# CPU性能快速检测
benchmark_cpu_quick() {
    debug_log "开始CPU性能检测"
    local cores=$(nproc)
    
    local start_time=$(date +%s.%N)
    if ! timeout 10s bash -c 'dd if=/dev/zero bs=1M count=32 2>/dev/null | gzip -1 > /dev/null' 2>/dev/null; then
        log "CPU检测超时，使用保守配置" "warn"
        echo "weak"
        return
    fi
    local end_time=$(date +%s.%N)
    
    local duration cpu_score
    if command -v bc >/dev/null 2>&1; then
        duration=$(echo "$end_time - $start_time" | bc)
        [[ $(echo "$duration <= 0" | bc -l) -eq 1 ]] && duration="0.1"
        cpu_score=$(echo "scale=2; ($cores * 2) / $duration" | bc)
    else
        local start_int=${start_time%.*}
        local end_int=${end_time%.*}
        duration=$((end_int - start_int))
        [[ $duration -le 0 ]] && duration=1
        cpu_score=$(( (cores * 200) / duration / 100 ))
    fi
    
    debug_log "CPU核心数: $cores, 测试时间: ${duration}s, 得分: $cpu_score"
    
    if (( $(echo "$cpu_score < 3" | bc -l 2>/dev/null || echo 1) )); then
        echo "weak"
    elif (( $(echo "$cpu_score < 8" | bc -l 2>/dev/null || echo 1) )); then
        echo "moderate"  
    else
        echo "strong"
    fi
}

get_memory_category() {
    local mem_mb="$1"
    if (( mem_mb < 1024 )); then echo "low";
    elif (( mem_mb < 2048 )); then echo "medium";
    elif (( mem_mb < 4096 )); then echo "high";
    else echo "flagship"; fi
}

get_optimal_zram_config() {
    local mem_mb="$1" cpu_level="$2" cores="$3"
    local mem_category=$(get_memory_category "$mem_mb")
    debug_log "内存分类: $mem_category, CPU等级: $cpu_level, 核心数: $cores"
    
    case "$mem_category" in
        "low")      echo "zstd,single,2.0" ;;
        "medium")   echo "zstd,single,1.5" ;;
        "high")     if (( cores >= 4 )); then echo "zstd,multi,1.0"; else echo "zstd,single,1.0"; fi ;;
        "flagship") if (( cores >= 4 )); then echo "zstd,multi,0.6"; else echo "zstd,single,0.8"; fi ;;
        *)          log "未知配置组合，使用默认" "warn"; echo "zstd,single,1.0" ;;
    esac
}

# 设置系统参数（增强版）
set_system_parameters() {
    local mem_mb="$1"
    local zram_priority=100 disk_priority=10 swappiness
    
    if (( mem_mb <= 1024 )); then swappiness=90;
    elif (( mem_mb <= 2048 )); then swappiness=80;
    elif (( mem_mb <= 4096 )); then swappiness=70;
    else swappiness=60; fi
    
    debug_log "目标配置: zram优先级=$zram_priority, swappiness=$swappiness"
    
    local sysctl_file="/etc/sysctl.d/99-zram-optimize.conf"
    cat > "$sysctl_file" << EOF
# Zram优化配置 - 由系统优化脚本自动生成
vm.swappiness = $swappiness
vm.page-cluster = 0
kernel.zswap.enabled = 0
EOF
    
    sysctl -p "$sysctl_file" >/dev/null 2>&1 || debug_log "sysctl应用失败，可能部分参数不支持"

    # 运行时设置（确保立即生效）
    echo "$swappiness" > /proc/sys/vm/swappiness 2>/dev/null || true
    echo "0" > /proc/sys/vm/page-cluster 2>/dev/null || true
    [[ -f /sys/module/zswap/parameters/enabled ]] && echo "0" > /sys/module/zswap/parameters/enabled 2>/dev/null || true

    # 设置磁盘swap优先级
    local disk_swap_count=0
    local disk_swap_output
    if disk_swap_output=$(swapon --show 2>/dev/null | grep -v zram | tail -n +2); then
        while read -r disk_swap _; do
            [[ -n "$disk_swap" ]] || continue
            if swapoff "$disk_swap" 2>/dev/null && swapon "$disk_swap" -p "$disk_priority" 2>/dev/null; then
                ((disk_swap_count++))
            fi
        done <<< "$disk_swap_output"
    fi
    
    echo "$zram_priority,$swappiness,$disk_swap_count"
}

# 创建持久化的Zram配置脚本和Systemd服务
create_persistent_zram_setup() {
    local size_mb="$1" algorithm="$2" device_count="$3" priority="$4"
    
    debug_log "创建持久化配置: ${size_mb}MB, $algorithm, ${device_count}个设备, 优先级$priority"
    
    # 1. 创建自定义配置脚本
    cat > "$CUSTOM_ZRAM_SCRIPT" << EOF
#!/bin/bash
# 这个脚本由系统优化工具自动生成，用于在启动时配置Zram

# 停止并重置所有现有zram设备
for dev in \$(ls /sys/class/block | grep zram); do
    if [[ -e "/sys/class/block/\$dev/reset" ]]; then
        swapoff "/dev/\$dev" 2>/dev/null
        echo 1 > "/sys/class/block/\$dev/reset"
    fi
done

# 加载zram模块
modprobe zram num_devices=${device_count}

# 配置每个设备
per_device_mb=\$(( ${size_mb} / ${device_count} ))
for i in \$(seq 0 \$(( ${device_count} - 1 )) ); do
    dev="/dev/zram\$i"
    
    # 等待设备就绪
    for _ in \$(seq 1 10); do
        [[ -b "\$dev" ]] && break
        sleep 0.1
    done
    
    if [[ ! -b "\$dev" ]]; then
        echo "Error: \$dev not found." >&2
        exit 1
    fi

    echo "${algorithm}" > "/sys/block/zram\$i/comp_algorithm"
    echo "\${per_device_mb}M" > "/sys/block/zram\$i/disksize"
    mkswap "\$dev"
    swapon "\$dev" -p "${priority}"
done
EOF
    
    chmod +x "$CUSTOM_ZRAM_SCRIPT"
    
    # 2. 创建Systemd Override文件
    mkdir -p "$SYSTEMD_OVERRIDE_DIR"
    cat > "$SYSTEMD_OVERRIDE_FILE" << EOF
[Service]
# 清除旧的执行命令
ExecStart=
# 指定我们自己的配置脚本
ExecStart=${CUSTOM_ZRAM_SCRIPT}
EOF

    # 3. 重新加载systemd配置
    systemctl daemon-reload
    debug_log "Systemd override 创建成功"
}


# 主要的zram配置函数
setup_zram() {
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local cores=$(nproc)
    local mem_display=$(format_size "$mem_mb")
    
    echo "检测到: ${mem_display}内存, ${cores}核CPU"
    
    # 检查是否有冲突的zram-generator
    if [[ -f /etc/systemd/zram-generator.conf ]]; then
        log "检测到 zram-generator 配置文件，可能导致冲突。建议移除或禁用。" "warn"
        sleep 3
    fi
    
    local cpu_level
    cpu_level=$(benchmark_cpu_quick)
    echo "CPU性能: $cpu_level"
    
    local config=$(get_optimal_zram_config "$mem_mb" "$cpu_level" "$cores")
    local algorithm=$(echo "$config" | cut -d, -f1)
    local device_type=$(echo "$config" | cut -d, -f2)
    local multiplier=$(echo "$config" | cut -d, -f3)
    
    local target_size_mb
    target_size_mb=$(awk -v mem="$mem_mb" -v mult="$multiplier" 'BEGIN {printf "%.0f", mem * mult}')
    
    local device_count=1
    [[ "$device_type" == "multi" ]] && device_count=$((cores > 4 ? 4 : cores))
    
    echo "决策: 目标大小=$(format_size "$target_size_mb"), 算法=$algorithm, ${device_count}个设备"
    
    # 检查现有配置是否匹配
    local current_zram_mb=0
    local current_zram_devices=$(swapon --show 2>/dev/null | grep -c "zram" || true)
    
    if [[ "$current_zram_devices" -gt 0 ]]; then
        while read -r device _ size _; do
            [[ "$device" == *"zram"* ]] || continue
            current_zram_mb=$((current_zram_mb + $(convert_to_mb "$size")))
        done < <(swapon --show 2>/dev/null | grep zram)
        
        local min_acceptable=$((target_size_mb * 90 / 100))
        local max_acceptable=$((target_size_mb * 110 / 100))
        
        if (( current_zram_mb >= min_acceptable && 
              current_zram_mb <= max_acceptable && 
              current_zram_devices == device_count )); then
            echo "Zram: $(format_size "$current_zram_mb") (已按最优配置)"
            set_system_parameters "$mem_mb" >/dev/null
            show_swap_status
            return 0
        fi
    fi
    
    log "当前配置不匹配，开始重新配置..." "info"
    cleanup_zram_completely

    # 安装zram-tools以获取基础服务文件
    if ! ensure_packages zram-tools; then
        log "zram-tools 安装失败，无法继续自动配置" "error"
        return 1
    fi
    
    # 设置内核参数并获取优先级
    local params_result=$(set_system_parameters "$mem_mb")
    local priority=$(echo "$params_result" | cut -d, -f1)
    
    # 创建持久化配置
    create_persistent_zram_setup "$target_size_mb" "$algorithm" "$device_count" "$priority"
    
    # 启用并启动服务
    systemctl enable zramswap.service >/dev/null 2>&1
    if ! systemctl restart zramswap.service; then
        log "启动zramswap服务失败。请检查 'journalctl -u zramswap.service'" "error"
        return 1
    fi
    
    sleep 2 # 等待服务生效
    
    # 最终验证
    local final_zram_mb=0
    if ! swapon --show 2>/dev/null | grep -q "zram"; then
        log "Zram配置失败，设备未激活" "error"
        return 1
    fi
    while read -r device _ size _; do
        [[ "$device" == *"zram"* ]] || continue
        final_zram_mb=$((final_zram_mb + $(convert_to_mb "$size")))
    done < <(swapon --show 2>/dev/null | grep zram)

    echo "Zram: $(format_size "$final_zram_mb") ($algorithm, ${device_count}个设备, 优先级$priority)"
    show_swap_status
}

# 自动配置时区为 Asia/Shanghai
setup_timezone() {
    local target_tz="$DEFAULT_TIMEZONE"
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone)

    if [[ "$current_tz" == "$target_tz" ]]; then
        echo "时区: $current_tz (已是目标时区，无需更改)"
        return 0
    fi

    log "时区: 正在自动设置为 $target_tz..." "info"
    if timedatectl set-timezone "$target_tz" 2>/dev/null; then
        echo "时区: $target_tz (设置成功)"
        return 0
    fi

    log "timedatectl 设置失败，尝试使用传统方式更新时区" "warn"
    local zoneinfo_path="/usr/share/zoneinfo/${target_tz}"
    if [[ ! -f "$zoneinfo_path" ]]; then
        log "未找到时区文件: $zoneinfo_path" "error"
        return 1
    fi

    ln -sf "$zoneinfo_path" /etc/localtime
    echo "$target_tz" > /etc/timezone
    if command -v dpkg-reconfigure >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive dpkg-reconfigure tzdata >/dev/null 2>&1 || true
    fi
    echo "时区: $target_tz (通过备用方式设置成功)"
}

# 配置Chrony
setup_chrony() {
    if command -v chronyd &>/dev/null && systemctl is-active chrony &>/dev/null; then
        if chronyc tracking 2>/dev/null | grep -q "System clock synchronized.*yes"; then
            echo "时间同步: Chrony (已同步)"; return 0;
        fi
    fi
    
    for svc in systemd-timesyncd.service systemd-timesyncd; do
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
    done

    if ! ensure_packages chrony; then
        log "Chrony 安装失败" "error"
        restore_timesyncd
        return 1
    fi

    systemctl enable chrony.service >/dev/null 2>&1 || true
    if ! systemctl restart chrony.service >/dev/null 2>&1; then
        log "重启 Chrony 服务失败" "error"
        restore_timesyncd
        return 1
    fi

    # 等待 chrony 建立同步关系，最大等待约10秒
    local attempt=0
    while (( attempt < 5 )); do
        if systemctl is-active chrony.service >/dev/null 2>&1; then
            if ! command -v chronyc >/dev/null 2>&1 || chronyc tracking >/dev/null 2>&1; then
                break
            fi
        fi
        sleep 2
        ((attempt++))
    done

    if ! systemctl is-active chrony.service >/dev/null 2>&1; then
        log "Chrony启动失败，回退到 systemd-timesyncd" "error"
        restore_timesyncd
        return 1
    fi

    local sources_count=0
    if command -v chronyc >/dev/null 2>&1; then
        sources_count=$(chronyc sources 2>/dev/null | grep -c "^\^" || echo "0")
        chronyc makestep >/dev/null 2>&1 || true
    fi
    echo "时间同步: Chrony (${sources_count}个时间源)"
}

# === 主流程 ===
main() {
    [[ $EUID -eq 0 ]] || { log "需要root权限运行" "error"; exit 1; }

    detect_debian_release

    local wait_count=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        ((wait_count++))
        if (( wait_count > 6 )); then
            log "包管理器锁定超时，请检查是否有其他apt进程运行" "error"; exit 1;
        fi
        if (( wait_count == 1 )); then
            log "检测到包管理器被锁定，等待释放..." "warn"
        fi
        sleep 10
    done
    
    for cmd in awk swapon systemctl timedatectl; do
        command -v "$cmd" &>/dev/null || { log "缺少必要命令: $cmd" "error"; exit 1; }
    done
    
    if ! command -v bc &>/dev/null; then
        if ! ensure_packages bc; then
            log "bc安装失败，将使用备用计算方法" "warn"
        fi
    fi
    
    export SYSTEMD_PAGER="" PAGER=""
    
    log "🔧 开始全自动系统优化..." "info"
    
    echo
    setup_zram || log "Zram配置出现问题，请检查日志" "warn"
    
    echo
    setup_timezone || log "时区配置失败" "warn"
    
    echo  
    setup_chrony || log "时间同步配置失败" "warn"
    
    echo
    log "✅ 优化完成" "info"
}

# 错误处理
trap 'log "脚本在行号 $LINENO 处意外退出" "error"; exit 1' ERR

main "$@"
