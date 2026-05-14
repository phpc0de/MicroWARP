#!/bin/sh
set -e

github_auth_header() {
    GITHUB_API_TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-}}
    if [ -n "$GITHUB_API_TOKEN" ]; then
        echo "Authorization: Bearer $GITHUB_API_TOKEN"
    fi
}

build_wgcf_download_url() {
    WGCF_REPO=${WGCF_REPO:-phpc0de/wgcf}
    WGCF_VER=$1
    WGCF_ARCH=$2
    echo "https://github.com/${WGCF_REPO}/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WGCF_ARCH}"
}

configure_upstream_proxy() {
    if [ "${ENABLE_UPSTREAM_PROXY:-0}" != "1" ]; then
        return 0
    fi

    if [ -z "${UPSTREAM_PROXY:-}" ]; then
        echo "==> [ERROR] ENABLE_UPSTREAM_PROXY=1 但未设置 UPSTREAM_PROXY"
        exit 1
    fi

    export HTTP_PROXY="$UPSTREAM_PROXY"
    export HTTPS_PROXY="$UPSTREAM_PROXY"
    export ALL_PROXY="$UPSTREAM_PROXY"
    export http_proxy="$UPSTREAM_PROXY"
    export https_proxy="$UPSTREAM_PROXY"
    export all_proxy="$UPSTREAM_PROXY"

    if [ -n "${NO_PROXY:-}" ]; then
        export NO_PROXY
        export no_proxy="$NO_PROXY"
    fi

    echo "==> [MicroWARP] 已开启上游代理: $UPSTREAM_PROXY"
}

if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

configure_upstream_proxy

WARP_MODE=${WARP_MODE:-free}
case "$WARP_MODE" in
    free|team) ;;
    *)
        echo "==> [ERROR] 不支持的 WARP_MODE: $WARP_MODE (仅支持 free/team)"
        exit 1
        ;;
esac

WG_CONF="/etc/wireguard/wg0.conf"
mkdir -p /etc/wireguard

# ==========================================
# 1. 账号全自动申请与配置生成 (阅后即焚)
# ==========================================
if [ ! -f "$WG_CONF" ]; then
    echo "==> [MicroWARP] 未检测到配置，正在全自动初始化 Cloudflare WARP..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) WGCF_ARCH="amd64" ;;
        aarch64) WGCF_ARCH="arm64" ;;
        *) echo "==> [ERROR] 不支持的架构: $ARCH"; exit 1 ;;
    esac

    WGCF_REPO=${WGCF_REPO:-phpc0de/wgcf}
    GITHUB_AUTH_HEADER=$(github_auth_header)
    if [ -n "${WGCF_VERSION:-}" ]; then
        WGCF_VER="$WGCF_VERSION"
    elif [ -n "$GITHUB_AUTH_HEADER" ]; then
        WGCF_VER=$(curl -sL -H "$GITHUB_AUTH_HEADER" "https://api.github.com/repos/${WGCF_REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    else
        WGCF_VER=$(curl -sL "https://api.github.com/repos/${WGCF_REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/')
    fi
    echo "==> [MicroWARP] 检测到最新 wgcf 版本: v${WGCF_VER}"
    WGCF_URL=$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")
    if [ -n "$GITHUB_AUTH_HEADER" ]; then
        curl -fsSL --connect-timeout 15 -H "$GITHUB_AUTH_HEADER" "$WGCF_URL" -o wgcf
    else
        wget --timeout=15 -qO wgcf "$WGCF_URL"
    fi
    chmod +x wgcf

    echo "==> [MicroWARP] 正在向 CF 注册设备..."
    if [ "$WARP_MODE" = "team" ]; then
        if [ -z "${TEAM_TOKEN:-}" ]; then
            echo "==> [ERROR] WARP_MODE=team 需要设置 TEAM_TOKEN"
            exit 1
        fi
        ./wgcf register --accept-tos --team-token "$TEAM_TOKEN" > /dev/null
    else
        ./wgcf register --accept-tos > /dev/null
    fi

    echo "==> [MicroWARP] 正在生成 WireGuard 配置文件..."
    ./wgcf generate > /dev/null

    mv wgcf-profile.conf "$WG_CONF"

    # 【核心安全】阅后即焚：删除注册工具和生成的账号明文文件
    rm -f wgcf wgcf-account.toml
    echo "==> [MicroWARP] 节点配置生成成功！"
else
    echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
fi

# ==========================================
# 2. 强力洗白与内核兼容性处理 (防正则误杀版)
# ==========================================

# 1. 智能提取出纯 IPv4 地址 (防止 wgcf v2.2.30 将双栈 IP 写在同一行导致误杀)
IPV4_ADDR=$(grep '^Address' "$WG_CONF" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)

# 2. 物理删除所有原始的 Address, AllowedIPs, DNS
sed -i '/^Address/d' "$WG_CONF"
sed -i '/^AllowedIPs/d' "$WG_CONF"
sed -i '/^DNS.*/d' "$WG_CONF"
# 清除可能存在的旧 MTU (兼容 Alpine Busybox 的正则写法)
sed -i '/^[Mm][Tt][Uu].*/d' "$WG_CONF"

# 3. 重建最纯净的 IPv4 路由规则
if [ -n "$IPV4_ADDR" ]; then
    sed -i "/\[Interface\]/a Address = $IPV4_ADDR" "$WG_CONF"
fi

# 4. 动态注入 MTU 变量 (默认 1280)
WG_MTU=${MTU:-1280}
sed -i "/\[Interface\]/a MTU = $WG_MTU" "$WG_CONF"
echo "==> [MicroWARP] 🛜 MTU 值已设置为: $WG_MTU"

sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$WG_CONF"

# 删除 Alpine 系统自带 wg-quick 中不兼容的路由标记
sed -i '/src_valid_mark/d' /usr/bin/wg-quick

# 【核心功能】强制注入 15 秒 UDP 心跳保活，对抗运营商 QoS 丢包
if ! grep -q "PersistentKeepalive" "$WG_CONF"; then
    sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$WG_CONF"
else
    sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$WG_CONF"
fi

# 【核心功能】针对 HK/US 强校验机房，注入自定义优选 Endpoint IP
if [ -n "$ENDPOINT_IP" ]; then
    echo "==>[MicroWARP] 🔀 检测到自定义 Endpoint IP，正在覆盖默认节点: $ENDPOINT_IP"
    sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$WG_CONF"
fi

# ==========================================
# 3. 拉起内核网卡 & 修复非对称路由
# ==========================================
# 3.1 记录 100.64.0.0/10 的原始回程路径，避免发布端口后 Tailscale 客户端握手卡死
PRE_WARP_ROUTE=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
PRE_WARP_GW=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "via") print $(i + 1)}')
PRE_WARP_DEV=$(printf '%s\n' "$PRE_WARP_ROUTE" | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}')

# 3.2 记录当前容器主网卡 IP 和网关，用于修复外部入站流量的非对称路由
ORIG_GW=$(ip -4 route show default | awk '{print $3}' | head -n 1)
ORIG_DEV=$(ip -4 route show default | awk '{print $5}' | head -n 1)
if [ -n "$ORIG_DEV" ]; then
    ORIG_IP=$(ip -4 addr show dev "$ORIG_DEV" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
fi

echo "==> [MicroWARP] 正在启动 Linux 内核级 wg0 网卡..."
wg-quick up wg0 > /dev/null 2>&1

# 3.3 注入源地址策略路由 (Policy-Based Routing) 修复入站非对称路由劫持
if [ -n "$ORIG_IP" ] && [ -n "$ORIG_GW" ] && [ -n "$ORIG_DEV" ]; then
    echo "==> [MicroWARP] 正在注入策略路由修复非对称路由死锁 (源IP: $ORIG_IP)..."
    # 添加容错 || true，防止部分精简版内核不支持多路由表导致启动崩溃
    ip rule add from "$ORIG_IP" table 128 priority 100 2>/dev/null || true
    ip route add table 128 default via "$ORIG_GW" dev "$ORIG_DEV" 2>/dev/null || true
fi

# 3.4 恢复 Tailscale 等指定内网网段的回程路由
TAILSCALE_CIDR=${TAILSCALE_CIDR:-"100.64.0.0/10"}
if [ -n "$PRE_WARP_GW" ] && [ -n "$PRE_WARP_DEV" ]; then
    if ip route replace "$TAILSCALE_CIDR" via "$PRE_WARP_GW" dev "$PRE_WARP_DEV" > /dev/null 2>&1; then
        echo "==>[MicroWARP] 已为 ${TAILSCALE_CIDR} 恢复 WARP 启动前的回程路由: via ${PRE_WARP_GW} dev ${PRE_WARP_DEV}"
    fi
fi

echo "==> [MicroWARP] 当前出口 IP 已成功变更为："
# 获取最新的 CF 溯源 IP (加入 5 秒强制超时，完美替代有缺陷的 & 后台执行)
curl -s -m 5 https://1.1.1.1/cdn-cgi/trace | grep ip= || echo "⚠️ 获取超时 (可能是底层握手延迟或节点被强阻断)"

# ==========================================
# 4. 启动 C 语言 SOCKS5 代理服务 (带高级参数绑定)
# ==========================================
# 读取环境变量，如果未设置则使用默认值 0.0.0.0 和 1080
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}

if [ -n "$SOCKS_USER" ] && [ -n "$SOCKS_PASS" ]; then
    echo "==>[MicroWARP] 🔒 身份认证已开启 (User: $SOCKS_USER)"
    echo "==>[MicroWARP] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    # 使用 exec 接管进程，实现 Zero-Overhead 的底层进程控制
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT" -u "$SOCKS_USER" -P "$SOCKS_PASS"
else
    echo "==> [MicroWARP] ⚠️ 未设置密码，当前为公开访问模式"
    echo "==> [MicroWARP] 🚀 MicroSOCKS 引擎已启动，正在监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    exec microsocks -i "$LISTEN_ADDR" -p "$LISTEN_PORT"
fi
