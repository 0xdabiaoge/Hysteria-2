#!/usr/bin/env sh

# --- 变量定义 ---
BINARY_PATH="/usr/local/bin/hysteria"
CONFIG_DIR="/etc/hy2"
# 共享证书
CERT_PATH="${CONFIG_DIR}/server.crt"
KEY_PATH="${CONFIG_DIR}/server.key"
# (V11) 模板化，用于共存
CONFIG_TPL="${CONFIG_DIR}/config-%s.json"
PASS_TPL="${CONFIG_DIR}/hy2-%s.pass"
OBFS_PASS_TPL="${CONFIG_DIR}/obfs-%s.pass"
PID_TPL="/var/run/hy2-%s.pid"
SERVICE_TPL="hy2-%s"

SCRIPT_PATH=$(readlink -f "$0")
SYSTEM_TYPE="none"

# --- 查找并定义 printf 命令 ---
PRINTF_CMD=""
if [ -x /usr/bin/printf ]; then
    PRINTF_CMD="/usr/bin/printf"
elif [ -x /bin/printf ]; then
    PRINTF_CMD="/bin/printf"
else
    echo "[致命错误] 未找到 /usr/bin/printf 或 /bin/printf。"
    echo "请安装 'coreutils' 包后再试。"
    exit 1
fi

# --- 颜色定义 ---
RED=$($PRINTF_CMD '\033[0;31m')
GREEN=$($PRINTF_CMD '\033[0;32m')
YELLOW=$($PRINTF_CMD '\033[0;33m')
NC=$($PRINTF_CMD '\033[0m')

# --- 辅助函数 ---

# 打印错误信息
err() {
    $PRINTF_CMD "%s[错误] %s%s\n" "${RED}" "$1" "${NC}"
}

# 打印成功信息
succ() {
    $PRINTF_CMD "%s[成功] %s%s\n" "${GREEN}" "$1" "${NC}"
}

# 打印提示信息
info() {
    $PRINTF_CMD "%s[提示] %s%s\n" "${YELLOW}" "$1" "${NC}"
}

# 退出脚本(用于错误)
exit_with_err() {
    exit 1
}

# 1. 检测运行环境 (Requirement 1)
detect_system() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        SYSTEM_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        SYSTEM_TYPE="openrc"
    else
        SYSTEM_TYPE="direct"
        info "未检测到 systemd 或 OpenRC。将使用 direct 进程管理模式。"
    fi
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "此脚本需要 root 权限运行。"
        exit_with_err
    fi
}

# 检查依赖
check_deps() {
    info "正在检查依赖 (curl, jq, openssl)..."
    # 检测包管理器
    if command -v apt >/dev/null 2>&1; then
        PM="apt"
    elif command -v apk >/dev/null 2>&1; then
        PM="apk"
    else
        err "未找到 apt 或 apk 包管理器。请手动安装 curl, jq, openssl。"
        return 1
    fi

    # 检查并安装依赖
    DEPS="curl jq openssl"
    for dep in $DEPS; do
        if ! command -v $dep >/dev/null 2>&1; then
            info "正在安装 $dep..."
            if [ "$PM" = "apt" ]; then
                apt update >/dev/null 2>&1
                apt install -y $dep >/dev/null 2>&1
            elif [ "$PM" = "apk" ]; then
                apk add --no-cache $dep >/dev/null 2>&1
            fi
            if ! command -v $dep >/dev/null 2>&1; then
                err "安装 $dep 失败。请检查您的网络或手动安装。"
                return 1
            fi
        fi
    done
    return 0
}

# 获取架构
get_arch() {
    case $(uname -m) in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        "armv7l") ARCH="arm" ;;
        "riscv64") ARCH="riscv64" ;;
        *) err "不支持的架构: $(uname -m)"; return 1 ;;
    esac
    return 0
}

# --- 核心功能 ---

# 搭建节点的核心逻辑
# 参数1: $1 (mode: "no-obfs" | "obfs")
install_hy2_logic() {
    MODE=$1
    if [ "$MODE" = "obfs" ]; then
        WITH_OBFS="true"
        NODE_TYPE_STR="混淆"
    else
        WITH_OBFS="false"
        NODE_TYPE_STR="无混淆"
    fi
    
    info "开始配置 Hysteria 2 ($NODE_TYPE_STR) 节点..."
    
    # 获取此模式的文件路径
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    HY2_PASS_FILE=$($PRINTF_CMD "$PASS_TPL" "$MODE")
    OBFS_PASS_FILE=""
    [ "$WITH_OBFS" = "true" ] && OBFS_PASS_FILE=$($PRINTF_CMD "$OBFS_PASS_TPL" "$MODE")

    # 1. 检查依赖
    if ! check_deps; then return 1; fi
    
    # 2. 检查和安装 *唯一* 的二进制文件
    if [ -f "$BINARY_PATH" ]; then
        info "Hysteria 2 二进制文件已存在，跳过下载。"
    else
        if ! get_arch; then return 1; fi
        info "正在获取最新版本号..."
        LATEST_VERSION=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | jq -r .tag_name)
        if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
            err "获取最新版本号失败 (可能是 GitHub API 限制)。"
            return 1
        fi
        info "最新版本为: $LATEST_VERSION"
        
        DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_VERSION}/hysteria-linux-${ARCH}"
        
        info "正在下载 Hysteria 2 二进制文件..."
        if ! curl -L -o "$BINARY_PATH" "$DOWNLOAD_URL"; then
            err "下载失败。请检查网络或 GitHub 连接。"
            return 1
        fi
        chmod +x "$BINARY_PATH"
        succ "Hysteria 2 二进制文件安装成功。"
    fi
    
    # 3. 检查和生成配置 (搭建节点)
    if [ -f "$CONFIG_FILE" ]; then
        $PRINTF_CMD "%s[警告] 已检测到 ($NODE_TYPE_STR) 节点的现有配置。是否覆盖? (y/n) [n]: %s" "${YELLOW}" "${NC}"
        read -p " " RECONFIG_CHOICE
        [ -z "$RECONFIG_CHOICE" ] && RECONFIG_CHOICE="n"
        
        if [ "$RECONFIG_CHOICE" != "y" ]; then
            info "操作已取消。保留现有配置。"
            return
        fi
        info "正在删除旧配置..."
        stop_service "$MODE" >/dev/null 2>&1
        rm -f "$CONFIG_FILE" "$HY2_PASS_FILE" "$OBFS_PASS_FILE"
    fi
    
    info "开始配置新 ($NODE_TYPE_STR) 节点..."
    # 4. 管理自签证书 (共享)
    if ! generate_self_signed_cert; then return 1; fi
    
    # 5. 生成配置
    if ! generate_config "$MODE"; then return 1; fi
    
    # 6. 设置服务
    if ! setup_service "$MODE"; then return 1; fi
    
    # 7. 启动服务
    if ! start_service "$MODE"; then return 1; fi
    
    succ "Hysteria 2 ($NODE_TYPE_STR) 节点搭建并启动成功。"
    view_link "$MODE"
}


# 生成自签证书 (共享)
generate_self_signed_cert() {
    if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
        info "检测到现有共享证书，跳过生成。"
        return 0
    fi
    
    info "正在生成共享自签证书..."
    mkdir -p "$CONFIG_DIR"
    
    if ! openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_PATH" >/dev/null 2>&1; then
        err "生成私钥 (ecparam) 失败。请检查 openssl 是否工作正常。"
        return 1
    fi
    
    if ! openssl req -new -x509 -nodes -key "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=proxy.com" -days 3650 >/dev/null 2>&1; then
         err "生成证书 (req) 失败。"
         return 1
    fi
    return 0
}

# 生成配置文件
# 参数1: $1 (mode: "no-obfs" | "obfs")
generate_config() {
    MODE=$1
    if [ "$MODE" = "obfs" ]; then
        WITH_OBFS="true"
        OTHER_MODE="no-obfs"
    else
        WITH_OBFS="false"
        OTHER_MODE="obfs"
    fi
    
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    HY2_PASS_FILE=$($PRINTF_CMD "$PASS_TPL" "$MODE")
    OBFS_PASS_FILE=""
    [ "$WITH_OBFS" = "true" ] && OBFS_PASS_FILE=$($PRINTF_CMD "$OBFS_PASS_TPL" "$MODE")

    mkdir -p "$CONFIG_DIR"
    
    # 检查端口是否与另一个节点冲突
    OTHER_CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$OTHER_MODE")
    USED_PORT=""
    if [ -f "$OTHER_CONFIG_FILE" ]; then
        USED_PORT=$(jq -r '.listen' "$OTHER_CONFIG_FILE" | cut -d ':' -f 2)
    fi
    
    # 端口 (必须输入)
    HY2_PORT=""
    while true; do
        read -p "请输入 hy2 监听端口 (必须输入): " HY2_PORT
        if [ -z "$HY2_PORT" ]; then
            err "端口不能为空。"
        elif [ "$HY2_PORT" = "$USED_PORT" ]; then
            err "端口 $HY2_PORT 已被 ($OTHER_MODE) 节点使用，请输入不同端口。"
        else
            break
        fi
    done
    
    # 伪装域名 (可回车默认)
    read -p "请输入伪装域名 (回车默认 www.microsoft.com): " FAKE_DOMAIN
    [ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="www.microsoft.com"
    
    # 生成密码
    PASSWORD=$(openssl rand -base64 16)
    # 使用 printf 存储密码，避免换行符
    $PRINTF_CMD "%s" "$PASSWORD" > "$HY2_PASS_FILE"

    # 使用 jq 构建 JSON
    BASE_CONFIG=$(jq -n \
        --arg port ":${HY2_PORT}" \
        --arg cert "${CERT_PATH}" \
        --arg key "${KEY_PATH}" \
        --arg sni "${FAKE_DOMAIN}" \
        --arg pass "${PASSWORD}" \
        '{listen: $port, tls: {cert: $cert, key: $key, sni: $sni}, auth: {type: "password", password: $pass}}')

    # 根据参数决定是否添加混淆
    if [ "$WITH_OBFS" = "true" ]; then
        OBFS_PASSWORD=$(openssl rand -base64 16)
        # 使用 printf 存储密码，避免换行符
        $PRINTF_CMD "%s" "$OBFS_PASSWORD" > "$OBFS_PASS_FILE"
        
        # 修正 obfs JSON 语法
        FINAL_CONFIG=$(echo "$BASE_CONFIG" | jq \
            --arg obfs_pass "$OBFS_PASSWORD" \
            '. + {obfs: {type: "salamander", salamander: {password: $obfs_pass}}}')
        info "流量混淆已开启。"
    else
        FINAL_CONFIG="$BASE_CONFIG"
    fi
    
    # 写入配置文件
    echo "$FINAL_CONFIG" | jq . > "$CONFIG_FILE"
    
    info "配置文件生成完毕: $CONFIG_FILE"
    $PRINTF_CMD "%s您的 hy2 密码: %s%s\n" "${GREEN}" "$PASSWORD" "${NC}"
    if [ "$WITH_OBFS" = "true" ]; then
        $PRINTF_CMD "%s您的混淆密码: %s%s\n" "${GREEN}" "$OBFS_PASSWORD" "${NC}"
    fi
    return 0
}

# 设置服务
# 参数1: $1 (mode)
setup_service() {
    MODE=$1
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    PID_FILE=$($PRINTF_CMD "$PID_TPL" "$MODE")

    info "正在设置 $SYSTEM_TYPE 服务: $SERVICE_NAME"
    case $SYSTEM_TYPE in
        "systemd")
            cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Hysteria 2 Service (${MODE})
After=network.target

[Service]
Type=simple
# (V13) 两个服务都调用同一个二进制文件
ExecStart=${BINARY_PATH} server -c ${CONFIG_FILE}
WorkingDirectory=/root
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
            ;;
        "openrc")
            cat > "/etc/init.d/${SERVICE_NAME}" << EOF
#!/sbin/openrc-run

name="Hysteria 2 (${MODE})"
description="Hysteria 2 Service"
# (V13) 两个服务都调用同一个二进制文件
command="${BINARY_PATH}"
command_args="server -c ${CONFIG_FILE}"
pidfile="${PID_FILE}"
command_background="yes"

depend() {
    need net
}
EOF
            chmod +x "/etc/init.d/${SERVICE_NAME}"
            rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
            ;;
        "direct")
            info "Direct 模式: ${SERVICE_NAME} 无需设置服务文件。"
            info "启动命令: nohup ${BINARY_PATH} server -c ${CONFIG_FILE} >/dev/null 2>&1 & echo \$! > ${PID_FILE}"
            info "停止命令: kill \$(cat ${PID_FILE}) 2>/dev/null && rm -f ${PID_FILE}"
            ;;
    esac
    return 0
}

# 启动服务
# 参数1: $1 (mode)
start_service() {
    MODE=$1
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    PID_FILE=$($PRINTF_CMD "$PID_TPL" "$MODE")

    info "正在启动 $SERVICE_NAME..."
    case $SYSTEM_TYPE in
        "systemd") systemctl restart "$SERVICE_NAME" ;;
        "openrc") rc-service "$SERVICE_NAME" restart ;;
        "direct")
            stop_service "$MODE" >/dev/null 2>&1
            nohup "$BINARY_PATH" server -c "$CONFIG_FILE" >/dev/null 2>&1 &
            echo $! > "$PID_FILE"
            sleep 1
            # 使用 /proc/$PID 检查进程是否存在
            if [ -f "$PID_FILE" ] && [ -d "/proc/$(cat "$PID_FILE")" ]; then
                succ "$SERVICE_NAME (direct) 已启动 (PID: $(cat "$PID_FILE"))"
            else
                err "$SERVICE_NAME (direct) 启动失败。"
                return 1
            fi
            ;;
    esac
    # 增加启动后状态检查
    sleep 2
    if ! check_service_status_internal "$MODE"; then
        err "服务 $SERVICE_NAME 启动失败，请检查日志！"
        view_status "$MODE" # 自动显示日志
        return 1
    fi
    return 0
}

# 停止服务
# 参数1: $1 (mode)
stop_service() {
    MODE=$1
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    PID_FILE=$($PRINTF_CMD "$PID_TPL" "$MODE")

    info "正在停止 $SERVICE_NAME..."
    case $SYSTEM_TYPE in
        "systemd") systemctl stop "$SERVICE_NAME" ;;
        "openrc") rc-service "$SERVICE_NAME" stop ;;
        "direct")
            if [ -f "$PID_FILE" ]; then
                PID=$(cat "$PID_FILE")
                # 使用 /proc/$PID 检查进程是否存在
                if [ -d "/proc/$PID" ]; then
                    kill "$PID"
                    sleep 1
                    info "$SERVICE_NAME (PID: $PID) 已停止。"
                else
                    info "PID 文件存在，但进程 $PID 未运行。"
                fi
                rm -f "$PID_FILE"
            else
                info "$SERVICE_NAME (direct) 未运行。"
            fi
            ;;
    esac
    return 0
}

# 查看节点链接 (保留 V9 URL 编码修复)
# 参数1: $1 (mode)
view_link() {
    MODE=$1
    if [ "$MODE" = "obfs" ]; then
        NODE_TYPE_STR="混淆"
    else
        NODE_TYPE_STR="无混淆"
    fi
    
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    HY2_PASS_FILE=$($PRINTF_CMD "$PASS_TPL" "$MODE")

    if [ ! -f "$CONFIG_FILE" ]; then
        err "($NODE_TYPE_STR) 节点配置文件不存在，请先搭建。"
        return 1
    fi
    
    # 尝试多种方式获取 IP
    SERVER_IP=$(curl -s http://checkip.amazonaws.com)
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -s https://ip.sb)
    fi
    if [ -z "$SERVER_IP" ]; then
        err "获取服务器公网 IP 失败。"
        return 1
    fi
    
    # 从 JSON 中读取
    PORT=$(jq -r '.listen' "$CONFIG_FILE" | cut -d ':' -f 2)
    SNI=$(jq -r '.tls.sni' "$CONFIG_FILE")
    
    # 读取原始密码(无换行)并进行 URL 编码
    PASSWORD_RAW=$(cat "$HY2_PASS_FILE")
    PASSWORD_ENCODED=$(echo "$PASSWORD_RAW" | jq -Rr @uri)
    
    URL="hy2://${PASSWORD_ENCODED}@${SERVER_IP}:${PORT}?sni=${SNI}&insecure=1"
    
    # 检查混淆
    OBFS_PASS_FILE=$($PRINTF_CMD "$OBFS_PASS_TPL" "$MODE")
    if [ -f "$OBFS_PASS_FILE" ]; then
        # 读取原始混淆密码(无换行)并进行 URL 编码
        OBFS_PASS_RAW=$(cat "$OBFS_PASS_FILE")
        OBFS_PASS_ENCODED=$(echo "$OBFS_PASS_RAW" | jq -Rr @uri)
        
        OBFS_TYPE=$(jq -r '.obfs.type' "$CONFIG_FILE")
        URL="${URL}&obfs=${OBFS_TYPE}&obfs-password=${OBFS_PASS_ENCODED}"
        ALIAS="hy2-obfs-${PORT}"
    else
        ALIAS="hy2-no-obfs-${PORT}"
    fi
    
    # 添加别名
    URL="${URL}#${ALIAS}"
    
    $PRINTF_CMD "\n--- Hysteria 2 ($NODE_TYPE_STR) 节点链接 ---\n"
    $PRINTF_CMD "%s%s%s\n\n" "${GREEN}" "$URL" "${NC}"
}

# 删除节点 (仅配置)
# 参数1: $1 (mode)
delete_node() {
    MODE=$1
    if [ "$MODE" = "obfs" ]; then
        NODE_TYPE_STR="混淆"
    else
        NODE_TYPE_STR="无混淆"
    fi
    
    CONFIG_FILE=$($PRINTF_CMD "$CONFIG_TPL" "$MODE")
    HY2_PASS_FILE=$($PRINTF_CMD "$PASS_TPL" "$MODE")
    OBFS_PASS_FILE=$($PRINTF_CMD "$OBFS_PASS_TPL" "$MODE")
    
    if [ ! -f "$CONFIG_FILE" ]; then
        err "($NODE_TYPE_STR) 节点配置文件已不存在。"
        return 1
    fi
    
    info "正在删除 ($NODE_TYPE_STR) 节点配置..."
    stop_service "$MODE"
    rm -f "$CONFIG_FILE" "$HY2_PASS_FILE" "$OBFS_PASS_FILE"
    
    # 移除服务
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    case $SYSTEM_TYPE in
        "systemd")
            systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
            rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
            systemctl daemon-reload
            ;;
        "openrc")
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1
            rm -f "/etc/init.d/${SERVICE_NAME}"
            ;;
        "direct")
            : # stop_service 已处理 PID
            ;;
    esac
    
    succ "($NODE_TYPE_STR) 节点配置已删除。二进制文件和证书已保留。"
    info "您可以运行 '搭建节点' 来重新创建它。"
}

# 内部服务状态检查 (非交互式)
# 参数1: $1 (mode)
check_service_status_internal() {
    MODE=$1
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    PID_FILE=$($PRINTF_CMD "$PID_TPL" "$MODE")
    
    case $SYSTEM_TYPE in
        "systemd")
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                return 0
            else
                return 1
            fi
            ;;
        "openrc")
            if rc-service "$SERVICE_NAME" status | grep -q "started"; then
                return 0
            else
                return 1
            fi
            ;;
        "direct")
            # 使用 /proc/$PID 检查进程是否存在
            if [ -f "$PID_FILE" ] && [ -d "/proc/$(cat "$PID_FILE")" ]; then
                return 0
            else
                return 1
            fi
            ;;
    esac
}


# 查看服务状态 (非交互式)
# 参数1: $1 (mode)
view_status() {
    MODE=$1
    SERVICE_NAME=$($PRINTF_CMD "$SERVICE_TPL" "$MODE")
    PID_FILE=$($PRINTF_CMD "$PID_TPL" "$MODE")

    if [ ! -f "$BINARY_PATH" ]; then
        err "Hysteria 2 未安装。"
        return 1
    fi
    
    info "正在获取 ($SERVICE_NAME) 服务状态..."
    case $SYSTEM_TYPE in
        "systemd")
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                succ "($SERVICE_NAME) 正在运行 (active)。"
            else
                err "($SERVICE_NAME) 已停止 (inactive)。"
                # 自动显示失败日志
                info "--- 最近 5 条日志 (用于排错) ---"
                journalctl -n 5 -u "$SERVICE_NAME" --no-pager
                info "---------------------------------"
            fi
            
            if systemctl is-enabled --quiet "$SERVICE_NAME"; then
                info "服务已 (enabled) 开机自启。"
            else
                info "服务已 (disabled) 禁止开机自启。"
            fi
            ;;
        "openrc")
            # rc-service status 本身就是非交互式的
            rc-service "$SERVICE_NAME" status
            ;;
        "direct")
            # 使用 /proc/$PID 检查进程是否存在
            if [ -f "$PID_FILE" ] && [ -d "/proc/$(cat "$PID_FILE")" ]; then
                succ "$SERVICE_NAME (direct) TA 正在运行 (PID: $(cat "$PID_FILE"))"
            else
                info "$SERVICE_NAME (direct) 已停止。"
            fi
            ;;
    esac
}

# 卸载 Hy2
uninstall_hy2() {
    info "正在完全卸载 Hysteria 2 (包括所有节点)..."
    stop_service "no-obfs"
    stop_service "obfs"
    
    # 移除服务
    case $SYSTEM_TYPE in
        "systemd")
            systemctl disable --now hy2-no-obfs >/dev/null 2>&1
            systemctl disable --now hy2-obfs >/dev/null 2>&1
            rm -f "/etc/systemd/system/hy2-no-obfs.service"
            rm -f "/etc/systemd/system/hy2-obfs.service"
            systemctl daemon-reload
            ;;
        "openrc")
            rc-update del hy2-no-obfs default >/dev/null 2>&1
            rc-update del hy2-obfs default >/dev/null 2>&1
            rm -f "/etc/init.d/hy2-no-obfs"
            rm -f "/etc/init.d/hy2-obfs"
            ;;
        "direct")
            : # stop_service 已处理 PID
            ;;
    esac
    
    # 移除文件
    rm -f "$BINARY_PATH"
    rm -rf "$CONFIG_DIR" # 删除包含所有配置、证书、密码的整个目录
    rm -f $($PRINTF_CMD "$PID_TPL" "no-obfs")
    rm -f $($PRINTF_CMD "$PID_TPL" "obfs")
    
    succ "Hysteria 2 已完全卸载。"
    
    # 删除脚本自身
    info "正在删除此脚本..."
    rm -f "$SCRIPT_PATH"
    exit 0
}

# --- 子菜单 ---

# 搭建节点子菜单
build_node_submenu() {
    while true; do
        clear
        $PRINTF_CMD "--- 搭建节点 ---\n"
        $PRINTF_CMD "----------------------------------------\n"
        $PRINTF_CMD "%s 1.%s 搭建无混淆版本\n" "${GREEN}" "${NC}"
        $PRINTF_CMD "%s 2.%s 搭建混淆版本\n" "${GREEN}" "${NC}"
        $PRINTF_CMD "----------------------------------------\n"
        $PRINTF_CMD "%s 0.%s 返回主菜单\n" "${GREEN}" "${NC}"
        
        read -p "请输入选项 [0-2]: " sub_choice
        
        case $sub_choice in
            1) 
                install_hy2_logic "no-obfs"
                $PRINTF_CMD "\n按任意键返回子菜单..."
                read -r _
                ;;
            2) 
                install_hy2_logic "obfs"
                $PRINTF_CMD "\n按任意键返回子菜单..."
                read -r _
                ;;
            0) break ;;
            *) err "无效选项。"; sleep 2 ;;
        esac
    done
}

# 通用管理子菜单
# 参数1: $1 (action: "view_link" | "delete_node" | "view_status")
# 参数2: $2 (title: "查看链接" | "删除节点" | "查看状态")
manage_node_submenu() {
    ACTION=$1
    TITLE=$2
    
    while true; do
        clear
        $PRINTF_CMD "--- %s ---\n" "$TITLE"
        $PRINTF_CMD "----------------------------------------\n"
        $PRINTF_CMD "%s 1.%s 管理 (无混淆) 节点\n" "${GREEN}" "${NC}"
        $PRINTF_CMD "%s 2.%s 管理 (混淆) 节点\n" "${GREEN}" "${NC}"
        $PRINTF_CMD "----------------------------------------\n"
        $PRINTF_CMD "%s 0.%s 返回主菜单\n" "${GREEN}" "${NC}"
        
        read -p "请选择要管理的节点 [0-2]: " sub_choice
        
        case $sub_choice in
            1) 
                $ACTION "no-obfs"
                # “按任意键”的提示已移到这里，
                # 这样 view_status 就不需要管它了
                $PRINTF_CMD "\n按任意键返回子菜单..."
                read -r _
                ;;
            2) 
                $ACTION "obfs"
                $PRINTF_CMD "\n按任意键返回子菜单..."
                read -r _
                ;;
            0) break ;;
            *) err "无效选项。"; sleep 2 ;;
        esac
    done
}


# --- 主菜单 ---
main_menu() {
    clear
    $PRINTF_CMD "Hysteria 2 (hy2) 管理脚本 (环境: %s)\n" "$SYSTEM_TYPE"
    $PRINTF_CMD "----------------------------------------\n"
    
    $PRINTF_CMD "%s 1.%s 搭建节点 \n" "${GREEN}" "${NC}"
    $PRINTF_CMD "%s 2.%s 查看节点链接 \n" "${GREEN}" "${NC}"
    $PRINTF_CMD "%s 3.%s 删除节点 \n" "${YELLOW}" "${NC}"
    $PRINTF_CMD "%s 4.%s 查看 hy2 服务状态 \n" "${GREEN}" "${NC}"
    $PRINTF_CMD "%s 5.%s 卸载 hy2 (删除所有文件和脚本)\n" "${RED}" "${NC}"
    $PRINTF_CMD "----------------------------------------\n"
    $PRINTF_CMD "%s 0.%s 退出脚本\n" "${GREEN}" "${NC}"
    
    read -p "请输入选项 [0-5]: " choice
    
    case $choice in
        1) 
            build_node_submenu 
            ;;
        2) 
            manage_node_submenu "view_link" "查看节点链接"
            ;;
        3) 
            manage_node_submenu "delete_node" "删除节点"
            ;;
        4. | 4) 
            manage_node_submenu "view_status" "查看服务状态"
            ;;
        5) 
            uninstall_hy2 
            ;;
        0) 
            exit 0 
            ;;
        *) 
            err "无效选项。"
            sleep 2
            ;;
    esac
    
    # 卸载(5)和退出(0)之外的选项，都会返回这里，重新调用主菜单
    if [ "$choice" != "5" ] && [ "$choice" != "0" ]; then
        main_menu
    fi
}

# --- 脚本入口 ---
check_root
detect_system
main_menu