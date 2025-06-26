#!/bin/bash

# 环境检测脚本 - 用于Flask API配置自动调整
# 输出：environment_config.json

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检测系统类型
detect_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        DISTRO=$ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
        DISTRO=$(echo $OS | tr '[:upper:]' '[:lower:]')
    else
        OS=$(uname -s)
        VER=$(uname -r)
        DISTRO="unknown"
    fi
    
    # 确定包管理器
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
        UPDATE_CMD="yum update"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
        UPDATE_CMD="dnf update"
    else
        PKG_MANAGER="unknown"
        INSTALL_CMD=""
        UPDATE_CMD=""
    fi
}

# 检查软件是否安装
is_installed() {
    local software=$1
    if command -v $software >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 检查服务状态
check_service_status() {
    local service=$1
    if systemctl is-active --quiet $service 2>/dev/null; then
        echo "active"
    elif systemctl is-enabled --quiet $service 2>/dev/null; then
        echo "inactive"
    else
        echo "disabled"
    fi
}

# 安装nginx
install_nginx() {
    log_info "正在安装nginx..."
    if [ "$PKG_MANAGER" = "apt" ]; then
        $UPDATE_CMD >/dev/null 2>&1
        $INSTALL_CMD nginx >/dev/null 2>&1
    elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
        $INSTALL_CMD nginx >/dev/null 2>&1
    else
        log_error "不支持的包管理器，无法自动安装nginx"
        return 1
    fi
    
    # 启用并启动nginx服务
    systemctl enable nginx >/dev/null 2>&1
    systemctl start nginx >/dev/null 2>&1
    log_info "nginx安装完成"
}

# 安装openvpn
install_openvpn() {
    log_info "正在安装openvpn..."
    if [ "$PKG_MANAGER" = "apt" ]; then
        $UPDATE_CMD >/dev/null 2>&1
        $INSTALL_CMD openvpn easy-rsa >/dev/null 2>&1
    elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
        $INSTALL_CMD openvpn easy-rsa >/dev/null 2>&1
    else
        log_error "不支持的包管理器，无法自动安装openvpn"
        return 1
    fi
    
    # 启用openvpn服务
    systemctl enable openvpn >/dev/null 2>&1
    log_info "openvpn安装完成"
}

# 创建pyuser账号
create_pyuser() {
    local username="pyuser"
    local home_dir="/home/$username"
    
    if id "$username" &>/dev/null; then
        log_info "用户 $username 已存在"
        return 0
    fi
    
    log_info "正在创建用户 $username..."
    
    # 创建用户账号，设置家目录和bash shell
    if useradd -m -d "$home_dir" -s /bin/bash "$username" 2>/dev/null; then
        log_info "用户 $username 创建成功"
        
        # 将用户添加到必要的组
        if [ "$PKG_MANAGER" = "apt" ]; then
            usermod -aG sudo "$username" 2>/dev/null || true
        elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
            usermod -aG wheel "$username" 2>/dev/null || true
        fi
        
        # 设置目录权限
        chown -R "$username:$username" "$home_dir"
        chmod 755 "$home_dir"
        
        return 0
    else
        log_error "创建用户 $username 失败"
        return 1
    fi
}

# 安装micromamba
install_micromamba() {
    local username="pyuser"
    local home_dir="/home/$username"
    
    log_info "正在为用户 $username 安装micromamba..."
    
    # 确定架构和下载URL
    local arch=$(uname -m)
    local micromamba_url=""
    
    case "$arch" in
        x86_64)
            micromamba_url="https://micro.mamba.pm/api/micromamba/linux-64/latest"
            ;;
        aarch64|arm64)
            micromamba_url="https://micro.mamba.pm/api/micromamba/linux-aarch64/latest"
            ;;
        *)
            log_error "不支持的架构: $arch"
            return 1
            ;;
    esac
    
    # 下载并安装micromamba（使用正确的方法）
    su - "$username" -c "
        # 1. 下载静态二进制文件
        curl -L '$micromamba_url' -o micromamba.tar.bz2
        
        # 2. 创建目录并解压
        mkdir -p ~/.local/bin
        tar -xjf micromamba.tar.bz2 -C ~/.local/bin --strip-components=1 bin/micromamba
        
        # 3. 清理临时文件
        rm -f micromamba.tar.bz2
        
        # 4. 确保可执行
        chmod +x ~/.local/bin/micromamba
    "
    
    if [ ! -f "$home_dir/.local/bin/micromamba" ]; then
        log_error "micromamba安装失败"
        return 1
    fi
    
    log_info "micromamba安装完成"
    return 0
}

# 配置micromamba环境
setup_micromamba_environment() {
    local username="pyuser"
    local home_dir="/home/$username"
    local micromamba_bin="$home_dir/.local/bin/micromamba"
    
    log_info "正在配置micromamba环境..."
    
    # 使用2024年新参数进行shell初始化和环境配置
    su - "$username" -c "
        # 1. 2024新版初始化（关键参数变更）
        ~/.local/bin/micromamba shell init --shell bash --root-prefix=\$HOME/mamba_root
        
        # 2. 激活环境配置
        echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc
        
        # 3. 创建.condarc配置文件（仅使用开源频道）
        cat > .condarc << 'EOL'
channels:
  - conda-forge
always_yes: true
auto_activate_base: false
channel_priority: strict
EOL
    "
    
    # 重新加载bash配置并创建环境
    su - "$username" -c "
        # 重新加载配置
        source ~/.bashrc 2>/dev/null || true
        
        # 创建pyuser环境用于gunicorn服务
        ~/.local/bin/micromamba create -n pyuser python=3.11 -y
        
        # 安装基础包到pyuser环境
        ~/.local/bin/micromamba install -n pyuser pip setuptools wheel gunicorn flask -y
    "
    
    if [ $? -eq 0 ]; then
        log_info "micromamba环境配置完成"
        return 0
    else
        log_error "micromamba环境配置失败"
        return 1
    fi
}

# 检查Python环境状态
check_python_environment() {
    local username="pyuser"
    local home_dir="/home/$username"
    local micromamba_bin="$home_dir/.local/bin/micromamba"
    
    # 检查用户是否存在
    if ! id "$username" &>/dev/null; then
        return 1
    fi
    
    # 检查micromamba是否安装
    if [ ! -f "$micromamba_bin" ]; then
        return 1
    fi
    
    # 检查pyuser环境是否存在
    if su - "$username" -c "~/.local/bin/micromamba env list" | grep -q "pyuser"; then
        return 0
    else
        return 1
    fi
}

# 检测nginx配置位置
detect_nginx_config() {
    local nginx_main_config=""
    local nginx_conf_dir=""
    local nginx_available_dir=""
    local nginx_enabled_dir=""
    
    # 查找主配置文件
    if [ -f /etc/nginx/nginx.conf ]; then
        nginx_main_config="/etc/nginx/nginx.conf"
    elif [ -f /usr/local/nginx/conf/nginx.conf ]; then
        nginx_main_config="/usr/local/nginx/conf/nginx.conf"
    elif [ -f /opt/nginx/conf/nginx.conf ]; then
        nginx_main_config="/opt/nginx/conf/nginx.conf"
    fi
    
    # 检查配置目录
    local possible_conf_dirs=(
        "/etc/nginx/conf.d"
        "/etc/nginx/default.d"
        "/etc/nginx/sites-available"
        "/etc/nginx/sites-enabled"
        "/usr/local/nginx/conf/conf.d"
    )
    
    for dir in "${possible_conf_dirs[@]}"; do
        if [ -d "$dir" ]; then
            case "$dir" in
                *conf.d)
                    nginx_conf_dir="$dir"
                    ;;
                *sites-available)
                    nginx_available_dir="$dir"
                    ;;
                *sites-enabled)
                    nginx_enabled_dir="$dir"
                    ;;
                *default.d)
                    if [ -z "$nginx_conf_dir" ]; then
                        nginx_conf_dir="$dir"
                    fi
                    ;;
            esac
        fi
    done
    
    # 检查主配置文件中的include指令
    local config_style="unknown"
    if [ -n "$nginx_main_config" ] && [ -f "$nginx_main_config" ]; then
        if grep -q "sites-enabled" "$nginx_main_config" 2>/dev/null; then
            config_style="sites-available"
        elif grep -q "conf.d" "$nginx_main_config" 2>/dev/null; then
            config_style="conf.d"
        elif grep -q "default.d" "$nginx_main_config" 2>/dev/null; then
            config_style="default.d"
        else
            config_style="main-only"
        fi
    fi
    
    echo "$nginx_main_config|$nginx_conf_dir|$nginx_available_dir|$nginx_enabled_dir|$config_style"
}

# 检测openvpn配置位置
detect_openvpn_config() {
    local openvpn_base_dir=""
    local openvpn_server_dir=""
    local openvpn_client_dir=""
    local config_structure="unknown"
    
    # 查找基础配置目录
    if [ -d /etc/openvpn ]; then
        openvpn_base_dir="/etc/openvpn"
    elif [ -d /usr/local/etc/openvpn ]; then
        openvpn_base_dir="/usr/local/etc/openvpn"
    fi
    
    if [ -n "$openvpn_base_dir" ]; then
        # 检查server和client子目录
        if [ -d "$openvpn_base_dir/server" ]; then
            openvpn_server_dir="$openvpn_base_dir/server"
            config_structure="separated"
        fi
        
        if [ -d "$openvpn_base_dir/client" ]; then
            openvpn_client_dir="$openvpn_base_dir/client"
        fi
        
        # 如果没有server/client子目录，使用基础目录
        if [ -z "$openvpn_server_dir" ] && [ -z "$openvpn_client_dir" ]; then
            config_structure="unified"
        elif [ -n "$openvpn_server_dir" ] && [ -z "$openvpn_client_dir" ]; then
            config_structure="server-only"
        fi
    fi
    
    echo "$openvpn_base_dir|$openvpn_server_dir|$openvpn_client_dir|$config_structure"
}

# 交互式输入网段配置
get_network_config() {
    local default_network="192.168.200.0/24"
    local default_server="192.168.200.0"
    local default_netmask="255.255.255.0"
    local default_route="192.168.200.0"
    
    echo
    echo "========================================"
    log_info "配置OpenVPN网段"
    echo "========================================"
    echo -n "请输入VPN网段 (默认: $default_network): "
    read -r input_network
    
    if [ -z "$input_network" ]; then
        input_network="$default_network"
    fi
    
    # 验证网段格式
    if ! echo "$input_network" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
        log_error "网段格式错误，使用默认网段: $default_network"
        input_network="$default_network"
    fi
    
    # 解析网段信息
    local network_ip=$(echo "$input_network" | cut -d'/' -f1)
    local cidr=$(echo "$input_network" | cut -d'/' -f2)
    
    # 计算子网掩码
    local netmask=""
    case "$cidr" in
        24) netmask="255.255.255.0" ;;
        16) netmask="255.255.0.0" ;;
        8)  netmask="255.0.0.0" ;;
        *)  netmask="255.255.255.0" ;;
    esac
    
    log_info "使用网段: $input_network"
    log_info "服务器IP: $network_ip"
    log_info "子网掩码: $netmask"
    
    # 导出全局变量
    export VPN_NETWORK="$input_network"
    export VPN_SERVER_IP="$network_ip"
    export VPN_NETMASK="$netmask"
    export VPN_ROUTE_IP="$network_ip"
}

# 配置OpenVPN服务器
configure_openvpn_server() {
    local openvpn_info=$(detect_openvpn_config)
    IFS='|' read -r openvpn_base openvpn_server openvpn_client openvpn_structure <<< "$openvpn_info"
    
    if [ -z "$openvpn_base" ] || [ ! -d "$openvpn_base" ]; then
        log_error "未找到OpenVPN配置目录"
        return 1
    fi
    
    # 确定目标配置目录
    local target_config_dir=""
    if [ "$openvpn_structure" = "separated" ] && [ -n "$openvpn_server" ]; then
        target_config_dir="$openvpn_server"
    else
        target_config_dir="$openvpn_base"
    fi
    
    log_info "OpenVPN配置目录: $target_config_dir"
    
    # 检查源配置文件
    local source_config="configs/server.conf"
    if [ ! -f "$source_config" ]; then
        log_error "源配置文件不存在: $source_config"
        return 1
    fi
    
    # 创建临时配置文件
    local temp_config="/tmp/server.conf.tmp"
    cp "$source_config" "$temp_config"
    
    # 修改网段配置
    log_info "修改OpenVPN服务器网段配置..."
    
    # 替换server配置行
    sed -i "s/^server [0-9.]* [0-9.]*$/server $VPN_SERVER_IP $VPN_NETMASK/" "$temp_config"
    
    # 替换route推送配置（如果存在）
    sed -i "s/^push \"route [0-9.]* [0-9.]*\"$/push \"route $VPN_ROUTE_IP $VPN_NETMASK\"/" "$temp_config"
    
    # 在配置文件顶部添加网段注释
    sed -i "s|^# Network: .*|# Network: $VPN_NETWORK|" "$temp_config"
    
    # 复制配置文件到OpenVPN目录
    local target_config_file="$target_config_dir/server.conf"
    
    if cp "$temp_config" "$target_config_file" 2>/dev/null; then
        log_info "OpenVPN服务器配置已更新: $target_config_file"
        
        # 设置正确的权限
        chmod 644 "$target_config_file"
        
        # 显示修改的内容
        echo
        log_info "配置文件关键设置:"
        echo "----------------------------------------"
        grep "^# Network:" "$target_config_file" || echo "# Network: $VPN_NETWORK"
        grep "^server " "$target_config_file"
        grep "^push.*route" "$target_config_file" || true
        echo "----------------------------------------"
        
    else
        log_error "复制配置文件失败: $target_config_file"
        return 1
    fi
    
    # 清理临时文件
    rm -f "$temp_config"
    
    # 保存配置到全局变量用于JSON生成
    export OPENVPN_CONFIG_FILE="$target_config_file"
    export OPENVPN_CONFIG_DIR="$target_config_dir"
    
    return 0
}

# 生成JSON配置文件
generate_config_file() {
    local output_file="environment_config.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # 获取nginx配置信息
    local nginx_info=$(detect_nginx_config)
    IFS='|' read -r nginx_main nginx_conf_dir nginx_available nginx_enabled nginx_style <<< "$nginx_info"
    
    # 获取openvpn配置信息
    local openvpn_info=$(detect_openvpn_config)
    IFS='|' read -r openvpn_base openvpn_server openvpn_client openvpn_structure <<< "$openvpn_info"
    
    # 检查服务状态
    local nginx_status=$(check_service_status nginx)
    local openvpn_status=$(check_service_status openvpn)
    
    # 检查Python环境状态
    local python_env_ready=$(check_python_environment && echo "true" || echo "false")
    local pyuser_home="/home/pyuser"
    local micromamba_bin="$pyuser_home/.local/bin/micromamba"
    
    # 获取micromamba版本信息
    local micromamba_version="null"
    local python_version="null"
    if [ -f "$micromamba_bin" ] && id "pyuser" &>/dev/null; then
        micromamba_version=$(su - pyuser -c "~/.local/bin/micromamba --version 2>/dev/null | head -1" 2>/dev/null || echo "null")
        python_version=$(su - pyuser -c "~/.local/bin/micromamba run -n pyuser python --version 2>/dev/null | cut -d' ' -f2" 2>/dev/null || echo "null")
    fi
    
    cat > "$output_file" << EOF
{
  "detection_info": {
    "timestamp": "$timestamp",
    "hostname": "$(hostname)",
    "script_version": "1.1"
  },
  "system": {
    "os": "$OS",
    "version": "$VER",
    "distribution": "$DISTRO",
    "architecture": "$(uname -m)",
    "kernel": "$(uname -r)",
    "package_manager": "$PKG_MANAGER"
  },
  "nginx": {
    "installed": $(is_installed nginx && echo "true" || echo "false"),
    "service_status": "$nginx_status",
    "configuration": {
      "main_config": "${nginx_main:-null}",
      "config_directory": "${nginx_conf_dir:-null}",
      "sites_available": "${nginx_available:-null}",
      "sites_enabled": "${nginx_enabled:-null}",
      "config_style": "$nginx_style"
    },
    "binary_path": "$(which nginx 2>/dev/null || echo null)",
    "version": "$(nginx -v 2>&1 | grep -o '[0-9.]*' | head -1 2>/dev/null || echo null)"
  },
  "openvpn": {
    "installed": $(is_installed openvpn && echo "true" || echo "false"),
    "service_status": "$openvpn_status",
    "configuration": {
      "base_directory": "${openvpn_base:-null}",
      "server_directory": "${openvpn_server:-null}",
      "client_directory": "${openvpn_client:-null}",
      "structure_type": "$openvpn_structure"
    },
    "binary_path": "$(which openvpn 2>/dev/null || echo null)",
    "version": "$(openvpn --version 2>/dev/null | head -1 | grep -o '[0-9.]*' | head -1 2>/dev/null || echo null)"
  },
  "python_environment": {
    "pyuser_exists": $(id "pyuser" &>/dev/null && echo "true" || echo "false"),
    "micromamba_installed": $([ -f "$micromamba_bin" ] && echo "true" || echo "false"),
    "environment_ready": $python_env_ready,
    "configuration": {
      "username": "pyuser",
      "home_directory": "$pyuser_home",
      "micromamba_binary": "$micromamba_bin",
      "environment_name": "pyuser",
      "python_version": "$python_version",
      "micromamba_version": "$micromamba_version"
    },
    "activation_command": "micromamba activate pyuser",
    "gunicorn_path": "$pyuser_home/mamba_root/envs/pyuser/bin/gunicorn"
  },
  "vpn_network_config": {
    "network": "${VPN_NETWORK:-null}",
    "server_ip": "${VPN_SERVER_IP:-null}",
    "netmask": "${VPN_NETMASK:-null}",
    "route_ip": "${VPN_ROUTE_IP:-null}",
    "config_file": "${OPENVPN_CONFIG_FILE:-null}",
    "config_directory": "${OPENVPN_CONFIG_DIR:-null}"
  },
  "flask_api_recommendations": {
    "nginx_config_target": "${nginx_conf_dir:-$nginx_main}",
    "openvpn_config_target": "${OPENVPN_CONFIG_DIR:-${openvpn_server:-$openvpn_base}}",
    "python_user": "pyuser",
    "python_environment": "pyuser",
    "gunicorn_binary": "$pyuser_home/mamba_root/envs/pyuser/bin/gunicorn",
    "working_directory": "$pyuser_home/app",
    "requires_root": true,
    "service_reload_commands": {
      "nginx": "systemctl reload nginx",
      "openvpn": "systemctl restart openvpn@server",
      "gunicorn": "systemctl restart gunicorn-api"
    }
  }
}
EOF

    log_info "环境配置文件已生成: $output_file"
}

# 主函数
main() {
    log_info "开始环境检测..."
    
    # 检测系统信息
    detect_system
    log_info "系统类型: $OS $VER ($DISTRO)"
    log_info "包管理器: $PKG_MANAGER"
    
    # 检查nginx
    if ! is_installed nginx; then
        log_warn "nginx未安装，正在安装..."
        if [ "$EUID" -eq 0 ]; then
            install_nginx
        else
            log_error "需要root权限安装nginx"
            exit 1
        fi
    else
        log_info "nginx已安装"
    fi
    
    # 检查openvpn
    if ! is_installed openvpn; then
        log_warn "openvpn未安装，正在安装..."
        if [ "$EUID" -eq 0 ]; then
            install_openvpn
        else
            log_error "需要root权限安装openvpn"
            exit 1
        fi
    else
        log_info "openvpn已安装"
    fi
    
    # 设置Python环境
    if ! check_python_environment; then
        log_warn "Python环境未配置，正在设置..."
        if [ "$EUID" -eq 0 ]; then
            # 创建pyuser用户
            if ! create_pyuser; then
                log_error "创建pyuser用户失败"
                exit 1
            fi
            
            # 安装curl（micromamba需要）
            if [ "$PKG_MANAGER" = "apt" ]; then
                apt-get install -y curl >/dev/null 2>&1
            elif [ "$PKG_MANAGER" = "yum" ] || [ "$PKG_MANAGER" = "dnf" ]; then
                $INSTALL_CMD curl >/dev/null 2>&1
            fi
            
            # 安装micromamba
            if ! install_micromamba; then
                log_error "安装micromamba失败"
                exit 1
            fi
            
            # 配置micromamba环境
            if ! setup_micromamba_environment; then
                log_error "配置micromamba环境失败"
                exit 1
            fi
        else
            log_error "需要root权限设置Python环境"
            exit 1
        fi
    else
        log_info "Python环境已配置"
    fi
    
    # 配置VPN网段
    get_network_config
    
    # 配置OpenVPN服务器
    if [ "$EUID" -eq 0 ]; then
        if ! configure_openvpn_server; then
            log_error "配置OpenVPN服务器失败"
            exit 1
        fi
    else
        log_error "需要root权限配置OpenVPN服务器"
        exit 1
    fi
    
    # 生成配置文件
    generate_config_file
    
    log_info "环境检测和配置完成!"
    
    # 显示配置摘要
    echo
    echo "配置摘要:"
    echo "========================================"
    if [ -f environment_config.json ]; then
        echo "VPN网段: ${VPN_NETWORK:-未配置}"
        echo "VPN服务器IP: ${VPN_SERVER_IP:-未配置}"
        echo "OpenVPN配置文件: ${OPENVPN_CONFIG_FILE:-未配置}"
        echo "Nginx配置位置: $(grep -o '"nginx_config_target": "[^"]*"' environment_config.json | cut -d'"' -f4)"
        echo "OpenVPN配置位置: $(grep -o '"openvpn_config_target": "[^"]*"' environment_config.json | cut -d'"' -f4)"
        echo "Python用户: $(grep -o '"python_user": "[^"]*"' environment_config.json | cut -d'"' -f4)"
        echo "Python环境: $(grep -o '"python_environment": "[^"]*"' environment_config.json | cut -d'"' -f4)"
        echo "Gunicorn路径: $(grep -o '"gunicorn_binary": "[^"]*"' environment_config.json | cut -d'"' -f4)"
        echo "推荐工作目录: $(grep -o '"working_directory": "[^"]*"' environment_config.json | cut -d'"' -f4)"
    fi
    
    # 显示OpenVPN重启提示
    echo
    echo "重要提示:"
    echo "========================================"
    log_info "请重启OpenVPN服务以应用新配置:"
    echo "  systemctl restart openvpn@server"
    echo "或者:"
    echo "  systemctl restart openvpn"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 
