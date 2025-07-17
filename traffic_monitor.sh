#!/bin/bash

# 流量监控脚本 - 改进版本
# 版本：2.4 (移除容错范围，优化流量限制提示)

# 检查是否以root用户运行
check_root_user() {
    if [ "$EUID" -ne 0 ]; then
        echo "错误：此脚本必须以root用户身份运行"
        echo "请使用: sudo $0 或切换到root用户后执行"
        exit 1
    fi
}

# 在脚本开始时立即检查root权限
check_root_user

# 默认工作目录
DEFAULT_WORK_DIR="/opt/TrafficLimit"

# 查找工作目录配置文件的函数
find_work_dir() {
    # 1. 首先检查环境变量
    if [ -n "$TRAFFIC_MONITOR_WORK_DIR" ] && [ -d "$TRAFFIC_MONITOR_WORK_DIR" ]; then
        echo "$TRAFFIC_MONITOR_WORK_DIR"
        return 0
    fi
    
    # 2. 检查默认位置是否有配置文件
    local default_config="$DEFAULT_WORK_DIR/work_dir.conf"
    if [ -f "$default_config" ] && [ -r "$default_config" ]; then
        local configured_dir=$(cat "$default_config" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
        if [ -n "$configured_dir" ] && [ -d "$configured_dir" ]; then
            echo "$configured_dir"
            return 0
        fi
    fi
    
    # 3. 检查常见位置的配置文件
    local common_dirs=("/opt/TrafficLimit" "/etc/traffic_monitor" "/usr/local/traffic_monitor")
    for dir in "${common_dirs[@]}"; do
        local config_file="$dir/work_dir.conf"
        if [ -f "$config_file" ] && [ -r "$config_file" ]; then
            local configured_dir=$(cat "$config_file" 2>/dev/null | tr -d '\n\r' | sed 's/[[:space:]]*$//')
            if [ -n "$configured_dir" ] && [ -d "$configured_dir" ]; then
                echo "$configured_dir"
                return 0
            fi
        fi
    done
    
    # 4. 如果都没找到，使用默认目录
    echo "$DEFAULT_WORK_DIR"
}

# 获取工作目录
WORK_DIR=$(find_work_dir)
WORK_DIR_CONFIG="$WORK_DIR/work_dir.conf"

CONFIG_FILE="$WORK_DIR/traffic_monitor_config.txt"
LOG_FILE="$WORK_DIR/traffic_monitor.log"
SCRIPT_PATH="$WORK_DIR/traffic_monitor.sh"
LOCK_FILE="$WORK_DIR/traffic_monitor.lock"

# 日志清理配置
LOG_MAX_SIZE_MB=50          # 日志文件最大大小（MB）
LOG_KEEP_DAYS=30           # 保留日志天数
LOG_BACKUP_COUNT=5         # 保留的备份日志文件数量

# 设置时区为上海（东八区）
export TZ='Asia/Shanghai'

# 日志记录函数
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp $message" | tee -a "$LOG_FILE" >&2
}

# 获取文件大小（MB）
get_file_size_mb() {
    local file="$1"
    if [ -f "$file" ]; then
        local size_bytes=$(stat -c%s "$file" 2>/dev/null || echo "0")
        echo "scale=2; $size_bytes / 1024 / 1024" | bc
    else
        echo "0"
    fi
}

# 日志轮转函数
rotate_log_file() {
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_file="${LOG_FILE}.${timestamp}"
    
    # 创建备份
    if mv "$LOG_FILE" "$backup_file"; then
        log_message "日志文件已轮转: $backup_file"
        
        # 压缩备份文件以节省空间
        if command -v gzip >/dev/null 2>&1; then
            gzip "$backup_file" && log_message "备份日志已压缩: ${backup_file}.gz"
        fi
    else
        log_message "警告: 日志轮转失败"
        return 1
    fi
}

# 清理旧的日志备份文件
cleanup_old_log_backups() {
    local log_dir=$(dirname "$LOG_FILE")
    local log_basename=$(basename "$LOG_FILE")
    
    # 清理超过保留天数的备份文件
    if [ "$LOG_KEEP_DAYS" -gt 0 ]; then
        find "$log_dir" -name "${log_basename}.*" -type f -mtime +$LOG_KEEP_DAYS -delete 2>/dev/null || true
    fi
    
    # 限制备份文件数量
    if [ "$LOG_BACKUP_COUNT" -gt 0 ]; then
        local backup_files
        backup_files=$(find "$log_dir" -name "${log_basename}.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +$((LOG_BACKUP_COUNT + 1)) | cut -d' ' -f2-)
        if [ -n "$backup_files" ]; then
            echo "$backup_files" | xargs rm -f 2>/dev/null || true
        fi
    fi
}

# 主日志清理函数
cleanup_logs() {
    # 检查日志文件是否存在
    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi
    
    # 获取当前日志文件大小
    local current_size_mb
    current_size_mb=$(get_file_size_mb "$LOG_FILE")
    
    # 检查是否需要轮转（基于文件大小）
    if [ "$(echo "$current_size_mb > $LOG_MAX_SIZE_MB" | bc)" -eq 1 ]; then
        log_message "日志文件大小 ${current_size_mb}MB 超过限制 ${LOG_MAX_SIZE_MB}MB，开始轮转"
        rotate_log_file
    fi
    
    # 清理旧的备份文件
    cleanup_old_log_backups
}

# 错误处理函数
handle_error() {
    local error_msg="$1"
    local error_code="${2:-1}"
    log_message "错误: $error_msg"
    exit "$error_code"
}

# 安全的数值比较函数
safe_numeric_compare() {
    local num1="$1"
    local operator="$2"
    local num2="$3"
    
    # 验证输入是否为有效数字
    if ! [[ "$num1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$num2" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        handle_error "数值比较参数无效: $num1 $operator $num2"
    fi
    
    local result
    case "$operator" in
        ">")
            result=$(echo "$num1 > $num2" | bc -l)
            ;;
        "<")
            result=$(echo "$num1 < $num2" | bc -l)
            ;;
        ">=")
            result=$(echo "$num1 >= $num2" | bc -l)
            ;;
        "<=")
            result=$(echo "$num1 <= $num2" | bc -l)
            ;;
        "==")
            result=$(echo "$num1 == $num2" | bc -l)
            ;;
        *)
            handle_error "不支持的比较操作符: $operator"
            ;;
    esac
    
    # bc返回1表示真，0表示假
    [ "$result" -eq 1 ]
}

log_message "-----------------------------------------------------"
log_message "当前版本：2.4 (移除容错范围，优化流量限制提示 - 仅关机模式)"

# 检查和安装必要软件包
check_and_install_packages() {
    local packages=("vnstat" "bc" "iproute2")
    local need_install=false

    for package in "${packages[@]}"; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            log_message "$package 未安装，将进行安装..."
            need_install=true
            break
        fi
    done

    if $need_install; then
        log_message "正在更新软件包列表..."
        if ! apt-get update; then
            handle_error "更新软件包列表失败，请检查网络连接和系统状态"
        fi

        for package in "${packages[@]}"; do
            if ! dpkg -s "$package" >/dev/null 2>&1; then
                log_message "正在安装 $package..."
                if apt-get install -y "$package"; then
                    log_message "$package 安装成功"
                else
                    handle_error "$package 安装失败，请手动检查并安装"
                fi
            fi
        done
    else
        log_message "所有必要的软件包已安装"
    fi

    # 获取 vnstat 版本
    local vnstat_version
    if vnstat_version=$(vnstat --version 2>&1 | head -n 1); then
        log_message "vnstat 版本: $vnstat_version"
    else
        handle_error "无法获取vnstat版本信息"
    fi

    # 检查 vnstatd 服务状态
    check_vnstatd_service
}

# 检查 vnstatd 服务状态
check_vnstatd_service() {
    log_message "检查 vnstatd 服务状态..."
    
    # 检查服务是否存在
    if ! systemctl list-unit-files | grep -q "vnstat.service"; then
        handle_error "vnstat.service 服务不存在，请检查vnstat安装"
    fi
    
    # 检查服务是否正在运行
    if ! systemctl is-active --quiet vnstat.service; then
        log_message "vnstatd 服务未运行，正在启动..."
        if ! systemctl start vnstat.service; then
            handle_error "无法启动 vnstatd 服务"
        fi
        log_message "vnstatd 服务已启动"
    else
        log_message "vnstatd 服务正在运行"
    fi
    
    # 检查服务是否已启用（开机自启）
    if ! systemctl is-enabled --quiet vnstat.service; then
        log_message "vnstatd 服务未设置开机自启，正在启用..."
        if ! systemctl enable vnstat.service; then
            handle_error "无法启用 vnstatd 服务开机自启"
        fi
        log_message "vnstatd 服务已设置为开机自启"
    else
        log_message "vnstatd 服务已启用开机自启"
    fi
}

# 检查配置和定时任务
check_existing_setup() {
    if [ -s "$CONFIG_FILE" ]; then
        if source "$CONFIG_FILE" 2>/dev/null; then
            log_message "配置已存在"
            if crontab -l 2>/dev/null | grep -q "$SCRIPT_PATH --run"; then
                log_message "每分钟一次的定时任务已在执行"
            else
                log_message "警告：定时任务未找到，可能需要重新设置"
            fi
            return 0
        else
            log_message "配置文件格式错误，需要重新配置"
            return 1
        fi
    else
        return 1
    fi
}

# 读取配置
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        if source "$CONFIG_FILE" 2>/dev/null; then
            # 验证必要的配置变量
            if [ -z "$TRAFFIC_MODE" ] || [ -z "$TRAFFIC_PERIOD" ] || [ -z "$TRAFFIC_LIMIT" ] ||
               [ -z "$MAIN_INTERFACE" ]; then
                handle_error "配置文件缺少必要参数"
            fi
            
            # 设置默认值（如果配置文件中没有）
            CHECK_INTERVAL=${CHECK_INTERVAL:-60}
            LOG_MAX_SIZE_MB=${LOG_MAX_SIZE_MB:-50}
            LOG_KEEP_DAYS=${LOG_KEEP_DAYS:-30}
            LOG_BACKUP_COUNT=${LOG_BACKUP_COUNT:-5}
            
            return 0
        else
            handle_error "配置文件读取失败"
        fi
    else
        return 1
    fi
}

# 写入配置
write_config() {
    if ! cat > "$CONFIG_FILE" << EOF
TRAFFIC_MODE=$TRAFFIC_MODE
TRAFFIC_PERIOD=$TRAFFIC_PERIOD
TRAFFIC_LIMIT=$TRAFFIC_LIMIT
PERIOD_START_DAY=${PERIOD_START_DAY:-1}
MAIN_INTERFACE=$MAIN_INTERFACE
CHECK_INTERVAL=${CHECK_INTERVAL:-60}
LOG_MAX_SIZE_MB=${LOG_MAX_SIZE_MB:-50}
LOG_KEEP_DAYS=${LOG_KEEP_DAYS:-30}
LOG_BACKUP_COUNT=${LOG_BACKUP_COUNT:-5}
EOF
    then
        handle_error "配置文件写入失败"
    fi
    log_message "配置已更新"
}

# 显示当前配置
show_current_config() {
    log_message "当前配置:"
    log_message "流量统计模式: $TRAFFIC_MODE"
    log_message "流量统计周期: $TRAFFIC_PERIOD"
    log_message "周期起始日: ${PERIOD_START_DAY:-1}"
    log_message "流量限制: $TRAFFIC_LIMIT GB"
    log_message "限制模式: 自动关机"
    log_message "主要网络接口: $MAIN_INTERFACE"
    log_message "流量计算间隔: ${CHECK_INTERVAL:-60} 秒"
    log_message "日志文件最大大小: ${LOG_MAX_SIZE_MB:-50} MB"
    log_message "日志保留天数: ${LOG_KEEP_DAYS:-30} 天"
    log_message "日志备份文件数量: ${LOG_BACKUP_COUNT:-5} 个"
}

# 检测主要网络接口
get_main_interface() {
    local main_interface
    
    # 尝试通过默认路由获取主接口
    if main_interface=$(ip route | grep default | awk '{print $5}' | head -n1 2>/dev/null); then
        if [ -n "$main_interface" ] && ip link show "$main_interface" >/dev/null 2>&1; then
            read -p "检测到的主要网络接口是: $main_interface, 按Enter使用此接口，或输入新的接口名称: " new_interface
            if [ -n "$new_interface" ]; then
                if ip link show "$new_interface" >/dev/null 2>&1; then
                    main_interface=$new_interface
                else
                    log_message "输入的接口无效，将使用检测到的接口: $main_interface"
                fi
            fi
            echo "$main_interface"
            return 0
        fi
    fi
    
    # 尝试通过UP状态接口获取
    if main_interface=$(ip link | grep 'state UP' | awk -F': ' '{print $2}' | head -n1 2>/dev/null); then
        if [ -n "$main_interface" ]; then
            echo "$main_interface"
            return 0
        fi
    fi
    
    # 手动选择接口
    while true; do
        log_message "无法自动检测主要网络接口"
        log_message "可用的网络接口有："
        if ! ip -o link show | awk -F': ' '{print $2}'; then
            handle_error "无法获取网络接口列表"
        fi
        read -p "请从上面的列表中选择一个网络接口: " main_interface
        if [ -n "$main_interface" ] && ip link show "$main_interface" >/dev/null 2>&1; then
            break
        else
            log_message "无效的接口，请重新选择"
        fi
    done
    
    echo "$main_interface"
}

# 配置流量统计模式
configure_traffic_mode() {
    while true; do
        log_message "请选择流量统计模式："
        echo "1. 只计算出站流量"
        echo "2. 只计算进站流量"
        echo "3. 出进站流量都计算"
        echo "4. 出站和进站流量只取大"
        read -p "请输入选择 (1-4): " mode_choice
        case $mode_choice in
            1) TRAFFIC_MODE="out"; break ;;
            2) TRAFFIC_MODE="in"; break ;;
            3) TRAFFIC_MODE="total"; break ;;
            4) TRAFFIC_MODE="max"; break ;;
            *) echo "无效输入，请重新选择" ;;
        esac
    done
}

# 配置流量统计周期
configure_traffic_period() {
    read -p "请选择流量统计周期 (m/q/y，默认为m): " period_choice
    case $period_choice in
        q) TRAFFIC_PERIOD="quarterly" ;;
        y) TRAFFIC_PERIOD="yearly" ;;
        m|"") TRAFFIC_PERIOD="monthly" ;;
        *) 
            echo "无效输入，使用默认值：monthly"
            TRAFFIC_PERIOD="monthly"
            ;;
    esac
}

# 配置周期起始日
configure_period_start_day() {
    read -p "请输入周期起始日 (1-31，默认为1): " PERIOD_START_DAY
    if [[ -z "$PERIOD_START_DAY" ]] || ! [[ "$PERIOD_START_DAY" =~ ^([1-9]|[12][0-9]|3[01])$ ]]; then
        echo "输入无效或为空，使用默认值：1"
        PERIOD_START_DAY=1
    fi
}

# 配置流量限制
configure_traffic_limits() {
    echo ""
    echo "流量限制设置提示："
    echo "建议将流量限制设置为略小于真实值，以预留缓冲空间"
    echo "推荐计算公式：流量限制 = 每月总流量 - (流量间隔秒数 × 峰值带宽Mbps ÷ 8 ÷ 1024)"
    echo "例如：每月1000GB，流量间隔60秒，峰值带宽100Mbps"
    echo "      流量限制 = 1000 - (60 × 100 ÷ 8 ÷ 1024) ≈ 999.27 GB"
    echo ""
    
    while true; do
        read -p "请输入流量限制 (GB，建议比实际限额略小): " TRAFFIC_LIMIT
        if [[ "$TRAFFIC_LIMIT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            break
        else
            echo "无效输入，请输入一个有效的数字"
        fi
    done
}

# 配置流量计算时间间隔
configure_check_interval() {
    echo ""
    echo "配置流量计算时间间隔："
    echo "较短的间隔可以更精确地监控流量，但会增加系统负载"
    echo "推荐值：60秒（适合大多数场景）"
    echo "注意：此间隔也将作为日志清理检测间隔"
    echo ""
    
    while true; do
        read -p "请输入流量计算时间间隔 (秒，默认60): " input_interval
        if [[ -z "$input_interval" ]]; then
            CHECK_INTERVAL=60
            break
        elif [[ "$input_interval" =~ ^[0-9]+$ ]] && [ "$input_interval" -gt 0 ] && [ "$input_interval" -le 31536000 ]; then
            CHECK_INTERVAL=$input_interval
            break
        else
            echo "无效输入，请输入一个1到31536000之间的正整数"
        fi
    done
    
    log_message "流量计算间隔设置为: ${CHECK_INTERVAL}秒"
}

# 配置日志清理参数
configure_log_cleanup() {
    echo "配置日志清理参数："
    
    # 配置日志文件最大大小
    while true; do
        read -p "请输入日志文件最大大小 (MB，默认50): " input_size
        if [[ -z "$input_size" ]]; then
            LOG_MAX_SIZE_MB=50
            break
        elif [[ "$input_size" =~ ^[0-9]+$ ]] && [ "$input_size" -gt 0 ]; then
            LOG_MAX_SIZE_MB=$input_size
            break
        else
            echo "无效输入，请输入一个正整数"
        fi
    done
    
    # 配置日志保留天数
    while true; do
        read -p "请输入日志保留天数 (默认30天，0表示不限制): " input_days
        if [[ -z "$input_days" ]]; then
            LOG_KEEP_DAYS=30
            break
        elif [[ "$input_days" =~ ^[0-9]+$ ]]; then
            LOG_KEEP_DAYS=$input_days
            break
        else
            echo "无效输入，请输入一个非负整数"
        fi
    done
    
    # 配置备份文件数量
    while true; do
        read -p "请输入保留的备份日志文件数量 (默认5个，0表示不限制): " input_count
        if [[ -z "$input_count" ]]; then
            LOG_BACKUP_COUNT=5
            break
        elif [[ "$input_count" =~ ^[0-9]+$ ]]; then
            LOG_BACKUP_COUNT=$input_count
            break
        else
            echo "无效输入，请输入一个非负整数"
        fi
    done
    
    log_message "日志清理配置完成"
}

# 初始配置函数
initial_config() {
    log_message "正在检测主要网络接口..."
    MAIN_INTERFACE=$(get_main_interface)

    configure_traffic_mode
    configure_traffic_period
    configure_period_start_day
    configure_check_interval
    configure_traffic_limits
    configure_log_cleanup
    
    log_message "限制模式固定为：流量超限后自动关机"
    write_config
}

# 修复的日期计算函数
get_period_start_date() {
    local current_date=$(date +%Y-%m-%d)
    local current_month=$(date +%m)
    local current_year=$(date +%Y)
    local current_day=$(date +%d)
    
    case $TRAFFIC_PERIOD in
        monthly)
            # 处理月份边界情况
            local target_month="$current_month"
            local target_year="$current_year"
            
            if [ "$current_day" -lt "$PERIOD_START_DAY" ]; then
                # 需要回到上个月
                if [ "$current_month" -eq 1 ]; then
                    target_month=12
                    target_year=$((current_year - 1))
                else
                    target_month=$(printf "%02d" $((current_month - 1)))
                fi
            fi
            
            # 获取目标月份的最后一天
            local last_day_of_month
            if ! last_day_of_month=$(date -d "${target_year}-${target_month}-01 +1 month -1 day" +%d 2>/dev/null); then
                handle_error "无法计算月份最后一天"
            fi
            
            # 如果起始日大于该月最后一天，使用最后一天
            local actual_start_day="$PERIOD_START_DAY"
            if [ "$PERIOD_START_DAY" -gt "$last_day_of_month" ]; then
                actual_start_day="$last_day_of_month"
            fi
            
            echo "${target_year}-${target_month}-$(printf "%02d" $actual_start_day)"
            ;;
        quarterly)
            # 计算当前季度的第一个月
            local quarter_month=$((((current_month - 1) / 3) * 3 + 1))
            local target_quarter_month="$quarter_month"
            local target_year="$current_year"
            
            # 判断是否需要回到上个季度
            if [ "$current_month" -eq "$quarter_month" ] && [ "$current_day" -lt "$PERIOD_START_DAY" ]; then
                # 当前是季度第一个月，但日期小于起始日，回到上个季度
                target_quarter_month=$((quarter_month - 3))
                if [ "$target_quarter_month" -le 0 ]; then
                    target_quarter_month=$((target_quarter_month + 12))
                    target_year=$((current_year - 1))
                fi
            elif [ "$current_month" -gt "$quarter_month" ]; then
                # 当前不是季度第一个月，使用当前季度
                target_quarter_month="$quarter_month"
            fi
            
            # 处理日期边界
            local target_month_str=$(printf "%02d" $target_quarter_month)
            local last_day_of_month
            if ! last_day_of_month=$(date -d "${target_year}-${target_month_str}-01 +1 month -1 day" +%d 2>/dev/null); then
                handle_error "无法计算季度月份最后一天"
            fi
            
            local actual_start_day="$PERIOD_START_DAY"
            if [ "$PERIOD_START_DAY" -gt "$last_day_of_month" ]; then
                actual_start_day="$last_day_of_month"
            fi
            
            echo "${target_year}-${target_month_str}-$(printf "%02d" $actual_start_day)"
            ;;
        yearly)
            local target_year="$current_year"
            
            # 如果当前是1月且日期小于起始日，回到去年
            if [ "$current_month" -eq 1 ] && [ "$current_day" -lt "$PERIOD_START_DAY" ]; then
                target_year=$((current_year - 1))
            fi
            
            # 处理2月29日的情况
            local actual_start_day="$PERIOD_START_DAY"
            if [ "$PERIOD_START_DAY" -eq 29 ] && [ "$((target_year % 4))" -ne 0 ]; then
                actual_start_day=28
            fi
            
            echo "${target_year}-01-$(printf "%02d" $actual_start_day)"
            ;;
        *)
            handle_error "不支持的统计周期: $TRAFFIC_PERIOD"
            ;;
    esac
}

# 获取流量使用情况
get_traffic_usage() {
    local start_date
    if ! start_date=$(get_period_start_date); then
        handle_error "无法计算周期起始日期"
    fi
    
    # 将日志输出重定向到stderr，避免影响函数返回值
    log_message "流量统计周期开始于: $start_date"
    
    # 验证网络接口是否存在
    if ! ip link show "$MAIN_INTERFACE" >/dev/null 2>&1; then
        handle_error "网络接口 $MAIN_INTERFACE 不存在"
    fi
    
    # 首先确保接口在 vnstat 数据库中
    if ! vnstat --iflist | grep -q "$MAIN_INTERFACE"; then
        log_message "接口 $MAIN_INTERFACE 不在 vnstat 数据库中，正在添加..."
        if ! vnstat --add -i "$MAIN_INTERFACE" >/dev/null 2>&1; then
            log_message "警告: 无法添加接口到 vnstat 数据库"
        fi
        # 等待一下让 vnstat 初始化
        sleep 2
    fi
    
    # 获取vnstat输出
    local vnstat_output
    if ! vnstat_output=$(vnstat -i "$MAIN_INTERFACE" --begin "$start_date" --oneline b 2>&1); then
        # 如果失败，尝试不带日期参数获取
        log_message "无法获取指定日期的数据，尝试获取所有可用数据..."
        if ! vnstat_output=$(vnstat -i "$MAIN_INTERFACE" --oneline b 2>&1); then
            handle_error "无法获取网络接口 $MAIN_INTERFACE 的流量数据: $vnstat_output"
        fi
    fi
    
    # 验证vnstat输出格式
    if [ -z "$vnstat_output" ]; then
        log_message "警告: vnstat返回空数据，可能还没有收集到流量信息"
        echo "0"
        return 0
    fi
    
    # 检查是否是错误消息
    if echo "$vnstat_output" | grep -q "Error\|error"; then
        log_message "vnstat 错误: $vnstat_output"
        echo "0"
        return 0
    fi
    
    local field_count
    field_count=$(echo "$vnstat_output" | tr ';' '\n' | wc -l)
    if [ "$field_count" -lt 11 ]; then
        log_message "警告: vnstat输出格式异常，字段数量: $field_count"
        log_message "vnstat输出: $vnstat_output"
        echo "0"
        return 0
    fi
    
    # 提取流量数据
    local usage_bytes
    case $TRAFFIC_MODE in
        out)   
            usage_bytes=$(echo "$vnstat_output" | cut -d';' -f10)
            ;;
        in)    
            usage_bytes=$(echo "$vnstat_output" | cut -d';' -f9)
            ;;
        total) 
            usage_bytes=$(echo "$vnstat_output" | cut -d';' -f11)
            ;;
        max)
            local rx=$(echo "$vnstat_output" | cut -d';' -f9)
            local tx=$(echo "$vnstat_output" | cut -d';' -f10)
            
            # 验证数据有效性
            if ! [[ "$rx" =~ ^[0-9]+$ ]] || ! [[ "$tx" =~ ^[0-9]+$ ]]; then
                handle_error "vnstat返回的流量数据格式无效"
            fi
            
            if [ "$rx" -gt "$tx" ]; then
                usage_bytes=$rx
            else
                usage_bytes=$tx
            fi
            ;;
        *)
            handle_error "不支持的流量统计模式: $TRAFFIC_MODE"
            ;;
    esac

    # 验证流量数据
    if ! [[ "$usage_bytes" =~ ^[0-9]+$ ]]; then
        handle_error "获取的流量数据无效: $usage_bytes"
    fi

    # 转换为GB（精确计算）
    local usage_gb
    if ! usage_gb=$(echo "scale=6; $usage_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null); then
        handle_error "流量数据转换失败"
    fi
    
    echo "$usage_gb"
}

# 检查并执行关机
check_and_limit_traffic() {
    local current_usage
    current_usage=$(get_traffic_usage)
    
    # 检查返回值是否有效
    if [ -z "$current_usage" ] || ! [[ "$current_usage" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_message "警告: 获取的流量数据无效，跳过本次检查"
        return 0
    fi
    
    log_message "当前使用流量: $current_usage GB，流量限制: $TRAFFIC_LIMIT GB"
    
    # 使用安全的数值比较
    if safe_numeric_compare "$current_usage" ">" "$TRAFFIC_LIMIT"; then
        log_message "警告：流量已超限！系统将在 1 分钟后自动关机"
        
        # 检查是否有紧急停止文件
        if [ -f "$WORK_DIR/emergency_stop" ]; then
            log_message "检测到紧急停止文件，取消关机操作"
            return 0
        fi
        
        # 执行关机命令
        if ! shutdown -h +1 "Traffic limit exceeded. System will shut down in 1 minute." 2>/dev/null; then
            log_message "警告：关机命令执行失败，可能需要管理员权限"
        fi
    else
        log_message "流量正常，取消所有已计划的关机任务"
        # 取消可能存在的关机任务
        shutdown -c 2>/dev/null || true
    fi
}

# 将秒数转换为cron表达式
seconds_to_cron() {
    local seconds=$1
    
    if [ "$seconds" -lt 60 ]; then
        # 小于60秒，使用sleep循环
        echo "* * * * * $SCRIPT_PATH --run-loop $seconds"
    elif [ "$seconds" -eq 60 ]; then
        # 正好60秒，每分钟运行一次
        echo "* * * * * $SCRIPT_PATH --run"
    elif [ "$((seconds % 60))" -eq 0 ]; then
        # 能被60整除，计算分钟间隔
        local minutes=$((seconds / 60))
        if [ "$minutes" -lt 60 ]; then
            echo "*/$minutes * * * * $SCRIPT_PATH --run"
        else
            # 大于等于60分钟，计算小时间隔
            local hours=$((minutes / 60))
            if [ "$((minutes % 60))" -eq 0 ] && [ "$hours" -lt 24 ]; then
                echo "0 */$hours * * * $SCRIPT_PATH --run"
            else
                # 复杂间隔，使用sleep循环
                echo "* * * * * $SCRIPT_PATH --run-loop $seconds"
            fi
        fi
    else
        # 不能被60整除，使用sleep循环
        echo "* * * * * $SCRIPT_PATH --run-loop $seconds"
    fi
}

# 设置Crontab
setup_crontab() {
    local cron_job
    cron_job=$(seconds_to_cron "${CHECK_INTERVAL:-60}")
    local temp_cron_file
    
    if ! temp_cron_file=$(mktemp); then
        handle_error "无法创建临时文件"
    fi
    
    # 确保临时文件在脚本退出时被清理
    trap "rm -f '$temp_cron_file'" EXIT
    
    # 读取现有crontab，过滤掉旧的脚本任务
    if ! crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > "$temp_cron_file"; then
        # 如果没有现有的crontab，创建空文件
        : > "$temp_cron_file"
    fi
    
    # 添加新的任务
    echo "$cron_job" >> "$temp_cron_file"
    
    # 加载新的crontab文件
    if ! crontab "$temp_cron_file"; then
        handle_error "设置crontab失败"
    fi
    
    log_message "Crontab 已设置，脚本将每${CHECK_INTERVAL:-60}秒自动运行"
}

# 主函数
main() {
    # 切换到工作目录
    if ! mkdir -p "$WORK_DIR"; then
        handle_error "无法创建工作目录 $WORK_DIR"
    fi
    
    if ! cd "$WORK_DIR"; then
        handle_error "无法切换到工作目录 $WORK_DIR"
    fi

    # 文件锁机制，防止并发运行
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        log_message "另一个脚本实例正在运行，本次跳过"
        exit 1
    fi

    # 检查命令行参数
    case "$1" in
        "--run")
            # 由cron调用的自动运行模式
            if read_config; then
                # 执行日志清理（每次自动运行时都检查）
                cleanup_logs
                check_and_limit_traffic
            else
                log_message "[Auto Run] 配置文件丢失，无法执行流量检查"
                exit 1
            fi
            return 0
            ;;
        "--run-loop")
            # 循环运行模式，用于处理小于60秒的间隔
            local interval="$2"
            if [[ ! "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
                handle_error "无效的时间间隔参数: $interval"
            fi
            
            if read_config; then
                local last_cleanup=0
                while true; do
                    local current_time=$(date +%s)
                    
                    # 每隔CHECK_INTERVAL秒执行一次日志清理检查
                    if [ $((current_time - last_cleanup)) -ge "${CHECK_INTERVAL:-60}" ]; then
                        cleanup_logs
                        last_cleanup=$current_time
                    fi
                    
                    check_and_limit_traffic
                    sleep "$interval"
                done
            else
                log_message "[Loop Run] 配置文件丢失，无法执行流量检查"
                exit 1
            fi
            return 0
            ;;
        "--cleanup-logs")
            # 手动日志清理模式
            log_message "开始手动清理日志文件..."
            if read_config; then
                cleanup_logs
                log_message "日志清理完成"
            else
                log_message "配置文件不存在，使用默认设置进行日志清理"
                cleanup_logs
            fi
            return 0
            ;;
        "--help"|"-h")
            # 显示帮助信息
            echo "流量监控脚本使用说明："
            echo "  $0                    交互式配置和运行"
            echo "  $0 --run              自动运行模式（由cron调用）"
            echo "  $0 --run-loop <秒数>  循环运行模式（用于小间隔）"
            echo "  $0 --cleanup-logs     手动清理日志文件"
            echo "  $0 --help             显示此帮助信息"
            return 0
            ;;
    esac

    # 手动执行时的交互逻辑
    check_and_install_packages
    
    if check_existing_setup; then
        read_config
        # 执行日志清理
        cleanup_logs
        show_current_config
        read -p "是否需要修改配置？(y/n，默认n): " modify_choice
        if [[ "$modify_choice" == "y" || "$modify_choice" == "Y" ]]; then
            initial_config
            setup_crontab
        fi
    else
        log_message "未检测到有效配置，开始初始化设置..."
        initial_config
        setup_crontab
    fi

    # 手动运行时，显示一次当前流量状态
    if read_config; then
        log_message "正在检查当前流量状态..."
        check_and_limit_traffic
    fi
}

# 执行主函数
main "$@"

log_message "-----------------------------------------------------"