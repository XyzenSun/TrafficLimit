#!/bin/bash

# 流量监控脚本安装器

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认配置
DEFAULT_WORK_DIR="/opt/TrafficLimit"
# 请根据实际情况修改下载 URL
DOWNLOAD_URL="${TRAFFIC_MONITOR_URL:-https://raw.githubusercontent.com/XyzenSun/TrafficLimit/refs/heads/main/traffic_monitor.sh}"
TEMP_DIR="/tmp/traffic_monitor_install_$$"

# 打印带颜色的消息
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# 错误处理函数
handle_error() {
    print_message "$RED" "错误: $1"
    cleanup
    exit 1
}

# 清理临时文件
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# 设置陷阱以确保清理
trap cleanup EXIT

# 检查是否以 root 用户运行
check_root() {
    if [ "$EUID" -ne 0 ]; then
        handle_error "此脚本必须以 root 用户身份运行。请使用: sudo $0"
    fi
}

# 检查必要的命令
check_requirements() {
    local required_commands=("curl" "wget")
    local download_command=""
    
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            download_command="$cmd"
            break
        fi
    done
    
    if [ -z "$download_command" ]; then
        handle_error "需要 curl 或 wget 来下载文件。请先安装其中之一。"
    fi
    
    echo "$download_command"
}

# 下载 traffic_monitor.sh
download_script() {
    local download_cmd=$1
    local target_file="$TEMP_DIR/traffic_monitor.sh"
    
    # 如果 URL 还是默认值，提醒用户
    if [[ "$DOWNLOAD_URL" == *"your-repo"* ]]; then
        print_message "$YELLOW" "注意：下载 URL 尚未配置，将尝试使用本地文件"
    else
        print_message "$GREEN" "正在从 $DOWNLOAD_URL 下载 traffic_monitor.sh..."
    fi
    
    mkdir -p "$TEMP_DIR" || handle_error "无法创建临时目录"
    
    case "$download_cmd" in
        curl)
            if ! curl -fsSL "$DOWNLOAD_URL" -o "$target_file"; then
                # 如果从网络下载失败，尝试使用本地文件
                if [ -f "./traffic_monitor.sh" ]; then
                    print_message "$YELLOW" "从网络下载失败，使用本地文件..."
                    cp "./traffic_monitor.sh" "$target_file" || handle_error "无法复制本地文件"
                else
                    handle_error "下载失败，且未找到本地文件"
                fi
            fi
            ;;
        wget)
            if ! wget -q "$DOWNLOAD_URL" -O "$target_file"; then
                # 如果从网络下载失败，尝试使用本地文件
                if [ -f "./traffic_monitor.sh" ]; then
                    print_message "$YELLOW" "从网络下载失败，使用本地文件..."
                    cp "./traffic_monitor.sh" "$target_file" || handle_error "无法复制本地文件"
                else
                    handle_error "下载失败，且未找到本地文件"
                fi
            fi
            ;;
    esac
    
    # 验证下载的文件
    if [ ! -f "$target_file" ] || [ ! -s "$target_file" ]; then
        handle_error "下载的文件无效或为空"
    fi
    
    print_message "$GREEN" "下载完成！"
}

# 交互式选择工作目录
select_work_directory() {
    local work_dir=""
    
    print_message "$GREEN" "\n=== 工作目录配置 ==="
    echo "流量监控脚本需要一个工作目录来存储配置文件和日志。"
    echo "默认工作目录: $DEFAULT_WORK_DIR"
    echo ""
    
    while true; do
        read -p "是否要自定义工作目录？(y/n): " choice
        case "$choice" in
            [Yy]*)
                while true; do
                    read -p "请输入自定义工作目录的绝对路径: " custom_dir
                    # 验证路径格式
                    if [[ "$custom_dir" =~ ^/[^[:space:]]+$ ]]; then
                        # 去除末尾的斜杠（如果有）
                        work_dir="${custom_dir%/}"
                        break
                    else
                        print_message "$RED" "无效的路径格式。请输入以 / 开头的绝对路径，且不包含空格。"
                    fi
                done
                break
                ;;
            [Nn]*)
                work_dir="$DEFAULT_WORK_DIR"
                break
                ;;
            *)
                print_message "$YELLOW" "请输入 y 或 n"
                ;;
        esac
    done
    
    print_message "$GREEN" "选择的工作目录: $work_dir"
    echo "$work_dir"
}

# 创建配置文件
create_config_file() {
    local work_dir=$1
    local config_file="$work_dir/work_dir.conf"
    
    print_message "$GREEN" "正在创建配置文件..."
    
    # 创建工作目录（如果不存在）
    if ! mkdir -p "$work_dir"; then
        handle_error "无法创建工作目录: $work_dir"
    fi
    
    # 写入工作目录配置
    if ! echo "$work_dir" > "$config_file"; then
        handle_error "无法写入配置文件: $config_file"
    fi
    
    # 设置配置文件权限
    chmod 644 "$config_file" || handle_error "无法设置配置文件权限"
    
    # 如果不是默认目录，也在默认目录创建配置文件指向实际目录
    if [ "$work_dir" != "$DEFAULT_WORK_DIR" ]; then
        if mkdir -p "$DEFAULT_WORK_DIR" 2>/dev/null; then
            echo "$work_dir" > "$DEFAULT_WORK_DIR/work_dir.conf" 2>/dev/null || true
            chmod 644 "$DEFAULT_WORK_DIR/work_dir.conf" 2>/dev/null || true
        fi
    fi
    
    print_message "$GREEN" "配置文件已创建: $config_file"
}

# 安装脚本
install_script() {
    local work_dir=$1
    local source_file="$TEMP_DIR/traffic_monitor.sh"
    local target_file="$work_dir/traffic_monitor.sh"
    
    print_message "$GREEN" "正在安装脚本..."
    
    # 创建工作目录
    if ! mkdir -p "$work_dir"; then
        handle_error "无法创建工作目录: $work_dir"
    fi
    
    # 复制脚本到工作目录
    if ! cp "$source_file" "$target_file"; then
        handle_error "无法复制脚本到工作目录"
    fi
    
    # 设置执行权限
    if ! chmod +x "$target_file"; then
        handle_error "无法设置脚本执行权限"
    fi
    
    # 设置目录权限
    chmod 755 "$work_dir" || handle_error "无法设置工作目录权限"
    
    print_message "$GREEN" "脚本已安装到: $target_file"
}

# 运行脚本
run_script() {
    local work_dir=$1
    local script_path="$work_dir/traffic_monitor.sh"
    
    print_message "$GREEN" "\n=== 准备运行流量监控脚本 ==="
    echo "脚本路径: $script_path"
    echo ""
    
    read -p "是否立即运行流量监控脚本进行初始配置？(y/n): " run_choice
    
    if [[ "$run_choice" =~ ^[Yy]$ ]]; then
        print_message "$GREEN" "正在启动流量监控脚本..."
        echo ""
        
        # 运行脚本
        if ! "$script_path"; then
            print_message "$RED" "脚本运行出错，请检查错误信息"
            return 1
        fi
    else
        print_message "$YELLOW" "您可以稍后手动运行: $script_path"
    fi
}

# 显示安装摘要
show_summary() {
    local work_dir=$1
    
    print_message "$GREEN" "\n=== 安装完成 ==="
    echo "工作目录: $work_dir"
    echo "配置文件: $work_dir/work_dir.conf"
    echo "脚本位置: $work_dir/traffic_monitor.sh"
    echo ""
    echo "您可以使用以下命令管理流量监控："
    echo "  - 运行脚本: $work_dir/traffic_monitor.sh"
    echo "  - 查看日志: tail -f $work_dir/traffic_monitor.log"
    echo "  - 查看配置: cat $work_dir/traffic_monitor_config.txt"
    echo ""
}

# 主函数
main() {
    print_message "$GREEN" "=== 流量监控脚本安装器 ==="
    echo ""
    
    # 检查 root 权限
    check_root
    
    # 检查必要的命令
    download_cmd=$(check_requirements)
    
    # 下载脚本
    download_script "$download_cmd"
    
    # 选择工作目录
    work_dir=$(select_work_directory)
    
    # 创建配置文件
    create_config_file "$work_dir"
    
    # 安装脚本
    install_script "$work_dir"
    
    # 显示安装摘要
    show_summary "$work_dir"
    
    # 运行脚本
    run_script "$work_dir"
    
    print_message "$GREEN" "\n安装过程完成！"
}

# 执行主函数
main "$@"