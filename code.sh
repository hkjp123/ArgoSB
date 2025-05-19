#!/bin/bash

# argosb.sh - Cloudflare Argo Tunnel 一鍵配置腳本 (僅暴露本地80端口)
# Author: yonggekkk (Original)
# Modifier: AI Assistant (for port 80 hardcoding and reorganization)
# Version: 2.0 (Modified)

# 彩色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 腳本版本
VERSION="v2.0-port80"

# 確保以 root 身份運行
[[ $EUID -ne 0 ]] && echo -e "${RED}錯誤：${PLAIN} 本腳本必須以 root 用戶身份運行！\n" && exit 1

# 全局變量
TUNNEL_TOKEN=""
TUNNEL_ID=""
DOMAIN=""
JSON_PATH=""
OS_ARCH=""
OS_RELEASE=""
OS_VERSION=""

# 預設本地服務端口 (硬編碼)
LOCAL_SERVICE_PORT=80

# 檢查系統
check_system() {
    OS_ARCH=$(arch)
    if [[ "$OS_ARCH" == "x86_64" || "$OS_ARCH" == "amd64" ]]; then
        OS_ARCH="amd64"
    elif [[ "$OS_ARCH" == "aarch64" || "$OS_ARCH" == "arm64" ]]; then
        OS_ARCH="arm64"
    else
        echo -e "${RED}錯誤：${PLAIN}不支持的系統架構: $OS_ARCH"
        exit 1
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_RELEASE=$ID
        OS_VERSION=$VERSION_ID
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS_RELEASE=$DISTRIB_ID
        OS_VERSION=$DISTRIB_RELEASE
    elif [ -f /etc/centos-release ]; then
        OS_RELEASE="centos"
        OS_VERSION=$(cat /etc/centos-release | awk '{print $4}')
    elif [ -f /etc/redhat-release ]; then
        OS_RELEASE="centos" # Red Hat an d CentOS are similar
        # Try to extract version
        OS_VERSION=$(grep -oP 'release \K[0-9]+' /etc/redhat-release)
    else
        echo -e "${RED}錯誤：${PLAIN}無法檢測到操作系統發行版。"
        exit 1
    fi
    echo -e "${GREEN}檢測到系統: ${OS_RELEASE} ${OS_VERSION} (${OS_ARCH})${PLAIN}"
}

# 安裝依賴
install_dependencies() {
    echo -e "${BLUE}正在安裝依賴...${PLAIN}"
    case "$OS_RELEASE" in
        ubuntu|debian)
            apt update && apt install -y curl wget lsb-release ca-certificates apt-transport-https gnupg
            ;;
        centos|rhel|almalinux|rocky)
            yum update && yum install -y curl wget
            ;;
        *)
            echo -e "${RED}錯誤：${PLAIN}不支持的發行版: $OS_RELEASE"
            exit 1
            ;;
    esac
    echo -e "${GREEN}依賴安裝完成。${PLAIN}"
}

# 下載並安裝 cloudflared
install_cloudflared() {
    echo -e "${BLUE}正在下載並安裝 cloudflared...${PLAIN}"
    CLOUDFLARED_LATEST_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${OS_ARCH}"
    
    if wget -q --spider "$CLOUDFLARED_LATEST_URL"; then
        wget -O /usr/local/bin/cloudflared "$CLOUDFLARED_LATEST_URL"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}錯誤：${PLAIN}下載 cloudflared 失敗。"
            # 嘗試備用下載 (如果 .deb 或 .rpm 包可用且更穩定)
            echo -e "${YELLOW}嘗試使用包管理器安裝...${PLAIN}"
            if [[ "$OS_RELEASE" == "ubuntu" || "$OS_RELEASE" == "debian" ]]; then
                curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
                echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflared.list
                apt update && apt install -y cloudflared
            elif [[ "$OS_RELEASE" == "centos" || "$OS_RELEASE" == "rhel" || "$OS_RELEASE" == "almalinux" || "$OS_RELEASE" == "rocky" ]]; then
                rpm -ivh https://pkg.cloudflare.com/cloudflared-stable-1.x86_64.rpm # 注意: 這個 URL 可能需要更新
                # 或者使用官方推薦的 repo 方式
                # curl -L https://pkg.cloudflare.com/cloudflared-ascii.repo | sudo tee /etc/yum.repos.d/cloudflared.repo
                # sudo yum update && sudo yum install cloudflared
            fi
            if ! command -v cloudflared &> /dev/null; then
                 echo -e "${RED}錯誤：${PLAIN}cloudflared 安裝失敗。"
                 exit 1
            fi
        else
             chmod +x /usr/local/bin/cloudflared
        fi
    else
        echo -e "${RED}錯誤：${PLAIN}無法訪問 cloudflared 下載鏈接: $CLOUDFLARED_LATEST_URL"
        exit 1
    fi
    
    # 驗證安裝
    if ! command -v cloudflared &> /dev/null; then
        echo -e "${RED}錯誤：${PLAIN}cloudflared 未成功安裝或未在 PATH 中。"
        exit 1
    fi
    echo -e "${GREEN}cloudflared 安裝成功: $(cloudflared --version)${PLAIN}"
}

# 創建配置文件和服務
create_config_and_service() {
    echo -e "${BLUE}正在創建配置文件和 systemd 服務...${PLAIN}"
    mkdir -p /etc/cloudflared

    if [[ ! -z "$TUNNEL_TOKEN" ]]; then
        # 使用 Token 配置
        cat > /etc/cloudflared/config.yml <<EOF
# Tunnel Token: ${TUNNEL_TOKEN:0:8}**********
# Version: ${VERSION}
# Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/#connect-an-app-in-the-dashboard-recommended

tunnel: ${TUNNEL_TOKEN}
ingress:
  - hostname: ${DOMAIN}
    service: http://localhost:${LOCAL_SERVICE_PORT}
  - service: http_status:404
EOF
    elif [[ ! -z "$TUNNEL_ID" && ! -z "$JSON_PATH" ]]; then
        # 使用 Tunnel ID 和 JSON 憑證配置
        cat > /etc/cloudflared/config.yml <<EOF
# Tunnel ID: ${TUNNEL_ID}
# Credentials File: ${JSON_PATH}
# Version: ${VERSION}
# Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/#create-a-tunnel-remotely-with-cloudflared

tunnel: ${TUNNEL_ID}
credentials-file: ${JSON_PATH}
ingress:
  - hostname: ${DOMAIN}
    service: http://localhost:${LOCAL_SERVICE_PORT}
  - service: http_status:404
EOF
    else
        echo -e "${RED}錯誤：${PLAIN}缺少 Tunnel Token 或 Tunnel ID/JSON 路徑。"
        exit 1
    fi

    # 創建 systemd 服務文件
    cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/local/bin/cloudflared --config /etc/cloudflared/config.yml --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared

    echo -e "${GREEN}配置文件和 systemd 服務創建成功。${PLAIN}"
}

# 配置 Tunnel (Token 方式)
configure_tunnel_token() {
    echo -e "${YELLOW}您選擇了使用 Tunnel Token 進行配置。${PLAIN}"
    read -rp "請輸入您的 Cloudflare Tunnel Token: " TUNNEL_TOKEN
    if [[ -z "$TUNNEL_TOKEN" ]]; then
        echo -e "${RED}錯誤：${PLAIN}Tunnel Token 不能为空。"
        exit 1
    fi
    read -rp "請輸入您要使用的域名 (例如: tunnel.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}錯誤：${PLAIN}域名不能为空。"
        exit 1
    fi
    echo -e "${BLUE}本地服務將被映射到 localhost:${LOCAL_SERVICE_PORT}${PLAIN}"
    create_config_and_service
}

# 配置 Tunnel (登錄方式)
configure_tunnel_login() {
    echo -e "${YELLOW}您選擇了通過登錄 Cloudflare 帳戶進行配置。${PLAIN}"
    echo -e "${BLUE}請按照提示在瀏覽器中登錄 Cloudflare 並授權。${PLAIN}"
    
    # 嘗試登錄，這通常會將憑證保存在 ~/.cloudflared/cert.pem
    # 如果用戶有多個賬戶或需要指定區域，這步可能更複雜
    if ! cloudflared tunnel login; then
        echo -e "${RED}錯誤：${PLAIN}Cloudflare 登錄失敗。"
        exit 1
    fi
    echo -e "${GREEN}Cloudflare 登錄成功。${PLAIN}"

    read -rp "請為您的新 Tunnel 輸入一個名稱 (例如: my-web-server): " TUNNEL_NAME
    if [[ -z "$TUNNEL_NAME" ]]; then
        echo -e "${RED}錯誤：${PLAIN}Tunnel 名稱不能为空。"
        exit 1
    fi

    # 創建 Tunnel 並獲取其 ID
    echo -e "${BLUE}正在創建 Tunnel: ${TUNNEL_NAME}...${PLAIN}"
    TUNNEL_INFO=$(cloudflared tunnel create "${TUNNEL_NAME}")
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}錯誤：${PLAIN}創建 Tunnel '${TUNNEL_NAME}' 失敗。"
        echo -e "${YELLOW}請檢查錯誤信息，或嘗試使用不同的 Tunnel 名稱。${PLAIN}"
        exit 1
    fi
    
    TUNNEL_ID=$(echo "$TUNNEL_INFO" | grep -oP 'Created tunnel\s+\S+\s+with id\s+\K[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if [[ -z "$TUNNEL_ID" ]]; then
        echo -e "${RED}錯誤：${PLAIN}無法從 cloudflared tunnel create 的輸出中提取 TUNNEL_ID。"
        echo -e "${YELLOW}輸出信息: ${TUNNEL_INFO}${PLAIN}"
        exit 1
    fi
    echo -e "${GREEN}Tunnel '${TUNNEL_NAME}' 創建成功，ID: ${TUNNEL_ID}${PLAIN}"

    # 憑證文件通常在 /root/.cloudflared/TUNNEL_ID.json (因為是以root運行)
    # 如果不是以 root 運行，則在 ~/.cloudflared/
    JSON_PATH="/root/.cloudflared/${TUNNEL_ID}.json" 
    if [ ! -f "$JSON_PATH" ]; then
        # 嘗試備用路徑，以防萬一
        JSON_PATH="${HOME}/.cloudflared/${TUNNEL_ID}.json"
        if [ ! -f "$JSON_PATH" ]; then
           echo -e "${RED}錯誤：${PLAIN}找不到 Tunnel 憑證文件。預期路徑: /root/.cloudflared/${TUNNEL_ID}.json 或 ${HOME}/.cloudflared/${TUNNEL_ID}.json"
           exit 1
        fi
    fi
    echo -e "${GREEN}找到憑證文件: ${JSON_PATH}${PLAIN}"

    read -rp "請輸入您要綁定到此 Tunnel 的域名 (例如: ${TUNNEL_NAME}.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}錯誤：${PLAIN}域名不能为空。"
        exit 1
    fi

    echo -e "${BLUE}正在為域名 ${DOMAIN} 創建 DNS CNAME 記錄指向 ${TUNNEL_ID}.cfargotunnel.com ...${PLAIN}"
    if ! cloudflared tunnel route dns "${TUNNEL_ID}" "${DOMAIN}"; then
        echo -e "${RED}錯誤：${PLAIN}為域名 ${DOMAIN} 創建 DNS 記錄失敗。"
        echo -e "${YELLOW}請確保您的 Cloudflare API Token (如果需要) 具有 DNS 編輯權限，或者手動在 Cloudflare Dashboard 中添加 CNAME 記錄：${PLAIN}"
        echo -e "${YELLOW}類型: CNAME, 名稱: ${DOMAIN} (或其子域名部分), 內容: ${TUNNEL_ID}.cfargotunnel.com, 代理狀態: 已代理 (橙色雲朵)${PLAIN}"
        # 雖然路由失敗，但仍然可以嘗試創建配置文件，用戶可以手動修復 DNS
    else
        echo -e "${GREEN}DNS 記錄創建成功。${PLAIN}"
    fi
    
    echo -e "${BLUE}本地服務將被映射到 localhost:${LOCAL_SERVICE_PORT}${PLAIN}"
    create_config_and_service
}

# 配置 Tunnel (使用已有的 Tunnel ID 和 JSON)
configure_tunnel_existing_json() {
    echo -e "${YELLOW}您選擇了使用已有的 Tunnel ID 和 JSON 憑證文件進行配置。${PLAIN}"
    read -rp "請輸入您的 Tunnel ID: " TUNNEL_ID
    if [[ -z "$TUNNEL_ID" ]]; then
        echo -e "${RED}錯誤：${PLAIN}Tunnel ID 不能为空。"
        exit 1
    fi
    read -rp "請輸入您的 Tunnel JSON 憑證文件的完整路徑 (例如: /root/.cloudflared/${TUNNEL_ID}.json): " JSON_PATH
    if [[ -z "$JSON_PATH" ]] || [[ ! -f "$JSON_PATH" ]]; then
        echo -e "${RED}錯誤：${PLAIN}JSON 憑證文件路徑無效或文件不存在。"
        exit 1
    fi
    read -rp "請輸入您要使用的域名 (例如: tunnel.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        echo -e "${RED}錯誤：${PLAIN}域名不能为空。"
        exit 1
    fi
    echo -e "${BLUE}本地服務將被映射到 localhost:${LOCAL_SERVICE_PORT}${PLAIN}"
    create_config_and_service
}

# 顯示狀態和日誌
show_status() {
    echo -e "${BLUE}Cloudflared 服務狀態:${PLAIN}"
    systemctl status cloudflared --no-pager
    echo -e "\n${BLUE}要查看實時日誌, 請運行:${PLAIN} journalctl -u cloudflared -f --no-hostname -o cat"
    echo -e "\n${GREEN}您的服務應該可以通過 https://${DOMAIN} 訪問 (DNS傳播可能需要一些時間)。${PLAIN}"
    echo -e "${YELLOW}本地服務 localhost:${LOCAL_SERVICE_PORT} 已被映射到公網。${PLAIN}"
}

# 卸載 cloudflared
uninstall_cloudflared() {
    echo -e "${RED}警告：這將卸載 cloudflared 並刪除其相關配置！${PLAIN}"
    read -rp "您確定要卸載嗎? (y/N): " CONFIRM_UNINSTALL
    if [[ "${CONFIRM_UNINSTALL,,}" != "y" ]]; then
        echo -e "${YELLOW}卸載已取消。${PLAIN}"
        exit 0
    fi

    echo -e "${BLUE}正在停止並禁用 cloudflared 服務...${PLAIN}"
    systemctl stop cloudflared
    systemctl disable cloudflared

    echo -e "${BLUE}正在刪除 cloudflared 相關文件...${PLAIN}"
    rm -f /usr/local/bin/cloudflared
    rm -f /etc/systemd/system/cloudflared.service
    rm -rf /etc/cloudflared # 刪除包含 config.yml 和可能的憑證的目錄
    # 注意：這不會刪除 ~/.cloudflared 或 /root/.cloudflared 中的憑證文件 (如 cert.pem 或 <tunnel-id>.json)
    # 如果需要，用戶需要手動刪除這些:
    echo -e "${YELLOW}注意: ~/.cloudflared 或 /root/.cloudflared 中的 Tunnel 憑證文件 (如 cert.pem 或 <tunnel-id>.json) 未被自動刪除。如果不再需要，請手動刪除。${PLAIN}"


    # 嘗試卸載通過包管理器安裝的 cloudflared
    if command -v apt &> /dev/null; then
        if dpkg -s cloudflared &> /dev/null; then
            echo -e "${BLUE}正在使用 apt 卸載 cloudflared...${PLAIN}"
            apt-get purge -y cloudflared
            rm -f /etc/apt/sources.list.d/cloudflared.list
            rm -f /usr/share/keyrings/cloudflare-main.gpg
            apt update
        fi
    elif command -v yum &> /dev/null; then
        if rpm -q cloudflared &> /dev/null; then
            echo -e "${BLUE}正在使用 yum 卸載 cloudflared...${PLAIN}"
            yum remove -y cloudflared
            rm -f /etc/yum.repos.d/cloudflared.repo
            yum clean all
        fi
    fi

    systemctl daemon-reload
    echo -e "${GREEN}cloudflared 已成功卸載。${PLAIN}"
}

# 主菜單
main_menu() {
    clear
    echo "================================================================"
    echo -e "        Cloudflare Argo Tunnel 一鍵配置腳本 (${GREEN}${VERSION}${PLAIN})"
    echo -e "        修改版: ${YELLOW}本地服務端口固定為 ${LOCAL_SERVICE_PORT}${PLAIN}"
    echo "----------------------------------------------------------------"
    echo "  作者: yonggekkk (原版)"
    echo "  修改: AI Assistant"
    echo "  GitHub: https://github.com/yonggekkk/argosb"
    echo "================================================================"
    echo -e "請選擇操作:"
    echo -e "  ${GREEN}1.${PLAIN} 安裝並配置 Cloudflare Tunnel (使用 Token)"
    echo -e "  ${GREEN}2.${PLAIN} 安裝並配置 Cloudflare Tunnel (登錄 Cloudflare 帳戶)"
    echo -e "  ${GREEN}3.${PLAIN} 安裝並配置 Cloudflare Tunnel (使用已有的 Tunnel ID 和 JSON)"
    echo "----------------------------------------------------------------"
    echo -e "  ${YELLOW}4.${PLAIN} 查看 Cloudflared 服務狀態和日誌信息"
    echo -e "  ${RED}5.${PLAIN} 卸載 Cloudflared"
    echo "----------------------------------------------------------------"
    echo -e "  ${BLUE}0.${PLAIN} 退出腳本"
    echo "================================================================"
    read -rp "請輸入選項 [0-5]: " choice

    case "$choice" in
        1)
            check_system
            install_dependencies
            install_cloudflared
            configure_tunnel_token
            show_status
            ;;
        2)
            check_system
            install_dependencies
            install_cloudflared
            configure_tunnel_login
            show_status
            ;;
        3)
            check_system
            install_dependencies
            install_cloudflared
            configure_tunnel_existing_json
            show_status
            ;;
        4)
            if ! systemctl list-units --full -all | grep -q 'cloudflared.service'; then
                echo -e "${RED}Cloudflared 服務未安裝或未找到。${PLAIN}"
                exit 1
            fi
            DOMAIN=$(grep -oP 'hostname: \K\S+' /etc/cloudflared/config.yml 2>/dev/null | head -n 1)
            show_status
            ;;
        5)
            uninstall_cloudflared
            ;;
        0)
            echo -e "${BLUE}退出腳本。${PLAIN}"
            exit 0
            ;;
        *)
            echo -e "${RED}無效選項，請重新輸入。${PLAIN}"
            sleep 2
            main_menu
            ;;
    esac
}

# 腳本入口
if [[ $# -gt 0 ]]; then
    case "$1" in
        install) # 為了兼容舊的直接調用方式，但建議使用菜單
            main_menu # 轉到菜單讓用戶選擇配置方式
            ;;
        uninstall)
            uninstall_cloudflared
            ;;
        *)
            echo -e "${RED}無效參數: $1${PLAIN}"
            echo "用法: bash $0 [install|uninstall]"
            echo "建議直接運行 bash $0 進入交互式菜單。"
            exit 1
            ;;
    esac
else
    main_menu
fi

exit 0