#!/bin/bash

set -euo pipefail
umask 022

#--- 全局常量 ---
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MODULE_BASE_URL="https://raw.githubusercontent.com/nnversace/VPS/main/modules"
readonly TEMP_DIR="$(mktemp -d /tmp/debian-setup-modules.XXXXXX)"
readonly LOG_FILE="/var/log/debian-custom-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary_custom.txt"
readonly DEFAULT_COLUMNS=80

#--- 模块定义 ---
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区, 时间同步)"
    ["auto-update-setup"]="自动更新系统配置"
    ["mosdns-x"]="MosDNS-X DNS 加速服务"
    ["sing-box"]="sing-box 代理服务器 (SS 2022)"
    ["snell"]="Snell v5/v6 代理服务器安装"
)

# 预定义的推荐执行顺序，未在 MODULES 中的条目会被忽略
readonly MASTER_ORDER_DEFAULT=(
    system-optimize
    auto-update-setup
    mosdns-x
    sing-box
    snell
)

#--- 执行状态 ---
EXECUTED_MODULES=()
FAILED_MODULES=()
SELECTED_MODULES=()
CLI_SELECTED_MODULES=()
declare -A MODULE_EXEC_TIME=()
declare -a MASTER_MODULE_ORDER=()
TOTAL_START_TIME=0

#--- 运行选项 ---
RUN_ALL_MODULES=false
AUTO_APPROVE=false
SKIP_NETWORK_CHECK=false

#--- 颜色定义 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

#--- 日志函数 ---
log() {
    local msg="$1"
    local level="${2:-info}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "info")    echo -e "${GREEN}✅ [INFO] $msg${NC}" ;;
        "warn")    echo -e "${YELLOW}⚠️  [WARN] $msg${NC}" ;;
        "error")   echo -e "${RED}❌ [ERROR] $msg${NC}" ;;
        "success") echo -e "${GREEN}🎉 [SUCCESS] $msg${NC}" ;;
        *)          echo -e "${GREEN}✅ [INFO] $msg${NC}" ;;
    esac

    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

#--- 分隔线 ---
print_line() {
    local cols="${COLUMNS:-}"

    if [[ -z "$cols" ]]; then
        if command -v tput &>/dev/null; then
            cols=$(tput cols 2>/dev/null || true)
        fi
    fi

    if [[ -z "$cols" || ! "$cols" =~ ^[0-9]+$ ]]; then
        cols=$DEFAULT_COLUMNS
    fi

    printf '%*s\n' "$cols" '' | tr ' ' '='
}

#--- 错误处理 ---
cleanup() {
    local exit_code=$?

    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi

    if (( exit_code != 0 )); then
        log "脚本异常退出，请检查日志: $LOG_FILE" "error"
    fi

    exit $exit_code
}
trap cleanup EXIT INT TERM

#--- 工具函数 ---
build_master_order() {
    if (( ${#MASTER_MODULE_ORDER[@]} > 0 )); then
        return
    fi

    local -A seen=()
    local module

    for module in "${MASTER_ORDER_DEFAULT[@]}"; do
        if [[ -n "${MODULES[$module]+x}" ]]; then
            MASTER_MODULE_ORDER+=("$module")
            seen["$module"]=1
        else
            log "跳过未定义的模块: $module" "warn"
        fi
    done

    for module in "${!MODULES[@]}"; do
        if [[ -z "${seen[$module]+x}" ]]; then
            MASTER_MODULE_ORDER+=("$module")
        fi
    done
}

print_usage() {
    build_master_order
    cat <<EOF
用法: $SCRIPT_NAME [选项]

选项:
  -a, --all                按推荐顺序执行所有模块
  -m, --modules LIST       仅执行指定模块 (逗号分隔，如: system-optimize,snell)
  -y, --yes                自动确认所有交互提示
      --skip-network-check 跳过网络连通性检查
  -h, --help               显示本帮助信息

可用模块:
EOF

    for module in "${MASTER_MODULE_ORDER[@]}"; do
        printf '  - %-18s %s\n' "$module" "${MODULES[$module]}"
    done
}

parse_args() {
    while (($#)); do
        case "$1" in
            -a|--all)
                RUN_ALL_MODULES=true
                ;;
            -m|--modules)
                local value
                local modules_list=()
                if [[ "$1" == *=* ]]; then
                    value="${1#*=}"
                else
                    shift || { log "--modules 选项缺少参数。" "error"; exit 1; }
                    value="$1"
                fi
                IFS=',' read -r -a modules_list <<< "$value"
                CLI_SELECTED_MODULES+=("${modules_list[@]}")
                ;;
            -y|--yes)
                AUTO_APPROVE=true
                ;;
            --skip-network-check)
                SKIP_NETWORK_CHECK=true
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                log "检测到未知选项: $1" "warn"
                ;;
            *)
                log "忽略的位置参数: $1" "warn"
                ;;
        esac
        shift || break
    done
}

confirm_execution() {
    local prompt="${1:-确认并开始执行? [Y/n]: }"
    if $AUTO_APPROVE; then
        log "自动确认已启用，跳过提示: $prompt"
        return 0
    fi
    read -p "$prompt" -r choice
    choice=${choice:-Y}
    [[ "$choice" =~ ^[Yy]$ ]]
}

#--- 基础检查 ---
check_system() {
    log "执行系统环境预检查..."
    if (( EUID != 0 )); then
        log "此脚本需要 root 权限才能运行。" "error"
        exit 1
    fi

    if [[ -f /etc/debian_version ]]; then
        local debian_ver
        debian_ver=$(cut -d'.' -f1 /etc/debian_version 2>/dev/null || echo "0")
        if [[ "$debian_ver" =~ ^[0-9]+$ ]] && (( debian_ver >= 12 )); then
            log "检测到 Debian ${debian_ver}，系统版本符合要求。"
        elif (( debian_ver < 12 )); then
            log "此脚本推荐在 Debian 12 或更高版本上运行，当前版本可能不完全兼容。" "warn"
        fi
    else
        log "无法确定 Debian 版本，继续执行可能存在兼容性问题。" "warn"
    fi
    log "系统检查通过。"
}

#--- 网络检查 ---
check_network() {
    if $SKIP_NETWORK_CHECK; then
        log "已跳过网络连接检查。" "warn"
        return
    fi

    log "检查网络连接..."
    build_master_order
    local test_module="${MASTER_MODULE_ORDER[0]:-}"

    if [[ -z "$test_module" ]]; then
        log "未找到可用模块用于测试，跳过网络检测。" "warn"
        return
    fi

    local test_url="${MODULE_BASE_URL}/${test_module}.sh"
    if curl -fsI --connect-timeout 5 --max-time 10 "$test_url" >/dev/null; then
        log "网络连接正常。"
        return
    fi

    log "无法访问 $test_url，网络可能存在问题。" "warn"

    if $AUTO_APPROVE; then
        log "已启用自动确认，将在网络异常情况下继续执行。" "warn"
        return
    fi

    read -p "网络检测失败，是否继续执行? [y/N]: " -r choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log "用户取消操作，退出。" "warn"
        exit 0
    fi
    log "用户选择在网络异常情况下继续执行。" "warn"
}

#--- 安装基础依赖 ---
install_dependencies() {
    log "检查并安装基础依赖..."
    local missing_packages=()
    for pkg in curl wget git jq rsync sudo; do
        if ! command -v "$pkg" &>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done

    if (( ${#missing_packages[@]} > 0 )); then
        log "正在安装缺失的依赖: ${missing_packages[*]}"
        local apt_updated=0
        if apt-get update -qq; then
            apt_updated=1
        else
            log "更新软件包列表失败" "warn"
        fi

        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"; then
            if (( apt_updated == 0 )) && apt-get update -qq && \
                DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"; then
                log "缺失依赖安装在第二次尝试时成功。" "warn"
            else
                log "依赖安装失败，请手动安装后重试。" "error"
                exit 1
            fi
        fi
    fi
    log "基础依赖已满足。"
}

#--- 模块选择 ---
select_modules() {
    log "选择要部署的模块"
    build_master_order

    local user_selected_modules=()

    if $RUN_ALL_MODULES; then
        user_selected_modules=("${MASTER_MODULE_ORDER[@]}")
        log "选择模式: 全部安装 (命令行参数)"
    elif (( ${#CLI_SELECTED_MODULES[@]} > 0 )); then
        local module
        for module in "${CLI_SELECTED_MODULES[@]}"; do
            if [[ -n "${MODULES[$module]+x}" ]]; then
                user_selected_modules+=("$module")
            elif [[ "$module" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                user_selected_modules+=("$module")
                log "模块 $module 未在内置列表中找到描述，将直接尝试执行。" "warn"
            else
                log "忽略无效模块名称: $module" "warn"
            fi
        done
        if (( ${#user_selected_modules[@]} == 0 )); then
            log "命令行未提供有效模块，将进入交互选择模式。" "warn"
        else
            log "已根据命令行选择模块: ${user_selected_modules[*]}"
        fi
    fi

    if (( ${#user_selected_modules[@]} == 0 )); then
        echo
        print_line
        echo "部署模式选择："
        echo "1) 🚀 全部安装 (按推荐顺序安装所有模块)"
        echo "2) 🎯 自定义选择 (按需选择模块)"
        echo

        read -p "请选择模式 [1-2]: " -r mode_choice

        case "$mode_choice" in
            1)
                user_selected_modules=("${MASTER_MODULE_ORDER[@]}")
                log "选择模式: 全部安装"
                ;;
            2)
                echo "可用模块："
                local i=1
                local module_keys=()
                for module in "${MASTER_MODULE_ORDER[@]}"; do
                    printf "%d) %-18s %s\n" "$i" "$module" "${MODULES[$module]}"
                    module_keys+=("$module")
                    ((i++))
                done

                echo "请输入要安装的模块编号 (用空格分隔, 如: 1 3 5):"
                read -r selection

                for num in $selection; do
                    if [[ "$num" =~ ^[1-9][0-9]*$ ]]; then
                        local index=$((num - 1))
                        if [[ -n "${module_keys[$index]+x}" ]]; then
                            user_selected_modules+=("${module_keys[$index]}")
                        else
                            log "跳过超出范围的编号: $num" "warn"
                        fi
                    else
                        log "跳过无效编号: $num" "warn"
                    fi
                done
                ;;
            *)
                log "无效选择，默认执行全部安装。" "warn"
                user_selected_modules=("${MASTER_MODULE_ORDER[@]}")
                ;;
        esac
    fi

    local final_selection=()
    local -A seen=()
    local module
    for module in "${MASTER_MODULE_ORDER[@]}"; do
        local selected
        for selected in "${user_selected_modules[@]}"; do
            if [[ "$module" == "$selected" && -z "${seen[$module]+x}" ]]; then
                final_selection+=("$module")
                seen[$module]=1
                break
            fi
        done
    done

    for module in "${user_selected_modules[@]}"; do
        if [[ -z "${seen[$module]+x}" ]]; then
            final_selection+=("$module")
            seen[$module]=1
        fi
    done

    if (( ${#final_selection[@]} == 0 )); then
        log "未选择任何有效模块，退出。" "warn"
        exit 0
    fi

    SELECTED_MODULES=("${final_selection[@]}")
}

#--- 下载模块 ---
download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local download_url="${MODULE_BASE_URL}/${module}.sh"
    local local_module_file="${SCRIPT_DIR}/modules/${module}.sh"

    log "正在下载模块: $module"

    if curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 \
        "$download_url" -o "$module_file"; then
        if [[ -s "$module_file" ]] && head -1 "$module_file" | grep -q "#!/bin/bash"; then
            chmod +x "$module_file"
            return 0
        fi
        log "模块 $module 下载内容无效，尝试使用本地副本。" "warn"
    else
        log "模块 $module 下载失败，尝试使用本地副本。" "warn"
    fi

    if [[ -f "$local_module_file" ]]; then
        if cp "$local_module_file" "$module_file" 2>/dev/null; then
            if [[ -s "$module_file" ]] && head -1 "$module_file" | grep -q "#!/bin/bash"; then
                chmod +x "$module_file"
                return 0
            fi
        fi
    fi

    log "模块 $module 下载失败 (URL: $download_url)。" "error"
    return 1
}

#--- 执行模块 ---
execute_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local module_desc="${MODULES[$module]:-$module}"

    log "执行模块: $module_desc"

    local start_time end_time duration exec_result=0
    start_time=$(date +%s)

    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在: $module" "error"
        exec_result=1
    else
        bash "$module_file" || exec_result=$?
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))
    MODULE_EXEC_TIME[$module]=$duration

    if (( exec_result == 0 )); then
        EXECUTED_MODULES+=("$module")
        log "模块 $module 执行成功 (耗时 ${duration}s)。" "success"
    else
        FAILED_MODULES+=("$module")
        log "模块 $module 执行失败 (耗时 ${duration}s)。" "error"
    fi
}

#--- 生成摘要 ---
generate_summary() {
    log "生成部署摘要..."

    local total_time=$(( $(date +%s) - TOTAL_START_TIME ))
    local summary module duration description

    summary=$(cat <<EOF
============================================================
           Debian 系统定制部署摘要
============================================================
- 部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
- 总耗时: ${total_time} 秒
- 主机名: $(hostname)
- 系统: $(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"')
- IP 地址: $(hostname -I | awk '{print $1}')

--- 执行统计 ---
- ✅ 成功模块 (${#EXECUTED_MODULES[@]}): ${EXECUTED_MODULES[*]:-}
- ❌ 失败模块 (${#FAILED_MODULES[@]}): ${FAILED_MODULES[*]:-}

--- 模块耗时详情 ---
EOF
)
    for module in "${SELECTED_MODULES[@]}"; do
        duration="${MODULE_EXEC_TIME[$module]:-N/A}"
        description="${MODULES[$module]:-}"
        if [[ -n "$description" ]]; then
            summary+=$'\n'"- ${module} (${description}): ${duration}s"
        else
            summary+=$'\n'"- ${module}: ${duration}s"
        fi
    done
    summary+=$'\n\n'"--- 文件位置 ---\n- 日志文件: $LOG_FILE\n- 摘要文件: $SUMMARY_FILE"
    summary+=$'\n'"============================================================"

    echo -e "\n$summary"
    echo -e "$summary" > "$SUMMARY_FILE" 2>/dev/null || true

    log "摘要已保存至: $SUMMARY_FILE"
}

#--- 主程序 ---
main() {
    parse_args "$@"

    mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$SUMMARY_FILE")" 2>/dev/null || true
    : > "$LOG_FILE"
    TOTAL_START_TIME=$(date +%s)

    if [[ -t 1 ]]; then
        clear
    fi
    print_line
    echo "Debian 系统定制部署脚本"
    print_line

    check_system
    check_network
    install_dependencies

    select_modules

    echo
    local plan_display=()
    local module
    for module in "${SELECTED_MODULES[@]}"; do
        if [[ -n "${MODULES[$module]+x}" ]]; then
            plan_display+=("$module(${MODULES[$module]})")
        else
            plan_display+=("$module")
        fi
    done
    log "最终执行计划: ${plan_display[*]}"
    if ! confirm_execution "确认并开始执行? [Y/n]: "; then
        log "用户取消操作，退出。" "warn"
        exit 0
    fi

    print_line
    log "开始执行 ${#SELECTED_MODULES[@]} 个模块..."
    print_line

    for module in "${SELECTED_MODULES[@]}"; do
        echo
        if download_module "$module"; then
            execute_module "$module"
        else
            FAILED_MODULES+=("$module")
        fi
    done

    generate_summary

    echo
    log "所有任务已完成！" "success"
    echo "部分配置可能需要重启系统才能完全生效，建议执行: reboot"
}

main "$@"
