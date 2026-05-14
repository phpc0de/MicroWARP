#!/bin/sh
set -e

github_auth_header() {
    GITHUB_API_TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-}}
    if [ -n "$GITHUB_API_TOKEN" ]; then
        echo "Authorization: token $GITHUB_API_TOKEN"
    fi
}

build_wgcf_download_url() {
    WGCF_REPO=${WGCF_REPO:-phpc0de/wgcf}
    WGCF_VER=$1
    WGCF_ARCH=$2
    echo "https://github.com/${WGCF_REPO}/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${WGCF_ARCH}"
}

fetch_release_asset_id() {
    REPO=$1
    VERSION=$2
    ARCH=$3
    AUTH_HEADER=$4
    TAG="v${VERSION}"
    ASSET_NAME="wgcf_${VERSION}_linux_${ARCH}"
    API_URL="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
    RESP_FILE=/tmp/wgcf_release_resp.json
    HTTP_CODE_FILE=/tmp/wgcf_release_http_code.txt

    echo "==> [MicroWARP] 正在请求 release 元数据: ${API_URL}" >&2
    if [ -n "$AUTH_HEADER" ]; then
        curl -sS -L -H "$AUTH_HEADER" -w "%{http_code}" -o "$RESP_FILE" "$API_URL" > "$HTTP_CODE_FILE" || true
    else
        curl -sS -L -w "%{http_code}" -o "$RESP_FILE" "$API_URL" > "$HTTP_CODE_FILE" || true
    fi

    HTTP_CODE=$(cat "$HTTP_CODE_FILE" 2>/dev/null || true)
    RESP=$(cat "$RESP_FILE" 2>/dev/null || true)
    echo "==> [MicroWARP] release 元数据状态码: ${HTTP_CODE:-unknown}" >&2

    if [ "$HTTP_CODE" != "200" ]; then
        echo "==> [ERROR] 获取 release 元数据失败，HTTP 状态码: ${HTTP_CODE:-unknown}" >&2
        if [ -n "$RESP" ]; then
            echo "==> [DEBUG] release 元数据返回: $(printf '%s' "$RESP" | tr '\n' ' ' | cut -c1-220)" >&2
        fi
        return 1
    fi

    ESCAPED_ASSET_NAME=$(printf '%s' "$ASSET_NAME" | sed 's/[][(){}.^$*+?|/\\]/\\&/g')
    ASSET_ID=$(printf '%s' "$RESP" | tr '\n' ' ' | sed -n "s/.*\"id\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*,[^{}]*\"name\"[[:space:]]*:[[:space:]]*\"${ESCAPED_ASSET_NAME}\".*/\1/p")

    if [ -z "$ASSET_ID" ]; then
        echo "==> [ERROR] 在 release 中未找到资产: ${ASSET_NAME}" >&2
        echo "==> [DEBUG] 请确认 wgcf release 资产名与架构匹配" >&2
        ALL_ASSETS=$(printf '%s' "$RESP" | tr '\n' ' ' | sed 's/},{/},\n{/g' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr '\n' ',' | sed 's/,$//')
        if [ -n "$ALL_ASSETS" ]; then
            echo "==> [DEBUG] release 资产列表: $ALL_ASSETS" >&2
        fi
        return 1
    fi

    echo "$ASSET_ID"
}

download_wgcf_with_github_api() {
    REPO=$1
    VERSION=$2
    ARCH=$3
    AUTH_HEADER=$4
    OUT_FILE=$5
    ASSET_ID=$(fetch_release_asset_id "$REPO" "$VERSION" "$ARCH" "$AUTH_HEADER") || return 1

    API_URL="https://api.github.com/repos/${REPO}/releases/assets/${ASSET_ID}"
    HTTP_CODE_FILE=/tmp/wgcf_asset_http_code.txt
    HEADERS_FILE=/tmp/wgcf_asset_headers.txt
    EFFECTIVE_URL_FILE=/tmp/wgcf_asset_effective_url.txt

    echo "==> [MicroWARP] 通过 GitHub API 下载资产: ${API_URL}"
    curl -sS -L --connect-timeout 15 -H "$AUTH_HEADER" -H "Accept: application/octet-stream" -D "$HEADERS_FILE" -w "%{http_code}" "$API_URL" -o "$OUT_FILE" > "$HTTP_CODE_FILE" || true
    HTTP_CODE=$(cat "$HTTP_CODE_FILE" 2>/dev/null || true)
    echo "==> [MicroWARP] API 资产下载状态码: ${HTTP_CODE:-unknown}"

    if [ "$HTTP_CODE" != "200" ]; then
        curl -sS -L --connect-timeout 15 -H "$AUTH_HEADER" -H "Accept: application/octet-stream" -D "$HEADERS_FILE" -o /dev/null -w "%{url_effective}" "$API_URL" > "$EFFECTIVE_URL_FILE" || true
        EFFECTIVE_URL=$(cat "$EFFECTIVE_URL_FILE" 2>/dev/null || true)
        if [ -n "$EFFECTIVE_URL" ]; then
            echo "==> [DEBUG] API 最终跳转 URL: $EFFECTIVE_URL"
        fi
        if [ -f "$HEADERS_FILE" ]; then
            echo "==> [DEBUG] API 重定向链路状态与 Location:"
            awk '/^HTTP\// || /^Location:/ {print "==> [DEBUG] " $0}' "$HEADERS_FILE"
        fi
        return 1
    fi

    return 0
}

normalize_version() {
    RAW_VER=$1
    echo "${RAW_VER#v}"
}

detect_local_wgcf_version() {
    WGCF_BIN=$1
    WGCF_VER_FILE="${WGCF_BIN}.version"
    if [ -f "$WGCF_VER_FILE" ]; then
        CACHED_VER=$(cat "$WGCF_VER_FILE" 2>/dev/null | tr -d '\r\n' || true)
        if [ -n "$CACHED_VER" ]; then
            echo "$CACHED_VER"
            return 0
        fi
    fi
    if [ ! -x "$WGCF_BIN" ]; then
        return 1
    fi
    VER_OUT=$($WGCF_BIN version 2>/dev/null || true)
    if [ -z "$VER_OUT" ]; then
        VER_OUT=$($WGCF_BIN --version 2>/dev/null || true)
    fi
    if [ -z "$VER_OUT" ]; then
        VER_OUT=$($WGCF_BIN -v 2>/dev/null || true)
    fi
    LOCAL_VER=$(printf '%s' "$VER_OUT" | sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\([.-][0-9A-Za-z.-]\+\)\{0,1\}\).*/\1/p' | head -n 1)
    if [ -z "$LOCAL_VER" ]; then
        return 1
    fi
    echo "$LOCAL_VER"
}

fetch_latest_wgcf_version() {
    REPO=$1
    AUTH_HEADER=$2
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    RESP_FILE=/tmp/wgcf_latest_resp.json
    HTTP_CODE_FILE=/tmp/wgcf_latest_http_code.txt
    echo "==> [MicroWARP] 正在请求 wgcf latest 版本: ${API_URL}" >&2

    if [ -n "$AUTH_HEADER" ]; then
        echo "==> [MicroWARP] 使用 GitHub Token 鉴权请求 latest 版本" >&2
        curl -sS -L -H "$AUTH_HEADER" -w "%{http_code}" -o "$RESP_FILE" "$API_URL" > "$HTTP_CODE_FILE" || true
    else
        echo "==> [MicroWARP] 未提供 GitHub Token，使用匿名请求 latest 版本" >&2
        curl -sS -L -w "%{http_code}" -o "$RESP_FILE" "$API_URL" > "$HTTP_CODE_FILE" || true
    fi

    HTTP_CODE=$(cat "$HTTP_CODE_FILE" 2>/dev/null || true)
    RESP=$(cat "$RESP_FILE" 2>/dev/null || true)
    echo "==> [MicroWARP] latest 请求状态码: ${HTTP_CODE:-unknown}" >&2

    VER=$(printf '%s' "$RESP" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$VER" ]; then
        echo "==> [ERROR] 无法获取 ${REPO} 的 latest release 版本号" >&2
        echo "==> [ERROR] 请检查仓库可见性/Token权限，或显式设置 WGCF_VERSION" >&2
        if [ -n "$HTTP_CODE" ]; then
            echo "==> [ERROR] latest 请求 HTTP 状态码: $HTTP_CODE" >&2
        fi
        if [ -n "$RESP" ]; then
            echo "==> [DEBUG] GitHub API 返回: $(printf '%s' "$RESP" | tr '\n' ' ' | cut -c1-220)" >&2
        fi
        exit 1
    fi

    echo "$VER"
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
WGCF_BIN="${WGCF_BIN:-/var/lib/microwarp/wgcf}"
mkdir -p /etc/wireguard
mkdir -p "$(dirname "$WGCF_BIN")"

echo "==> [MicroWARP] 挂载检查: $(dirname "$WGCF_BIN") 内容如下"
ls -la "$(dirname "$WGCF_BIN")" || true
if [ -f "$WGCF_BIN" ]; then
    echo "==> [MicroWARP] 检测到缓存二进制: $WGCF_BIN"
else
    echo "==> [MicroWARP] 未检测到缓存二进制: $WGCF_BIN"
fi

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
    echo "==> [MicroWARP] WGCF_REPO: ${WGCF_REPO}"
    if [ -n "${WGCF_VERSION:-}" ]; then
        echo "==> [MicroWARP] 检测到固定 WGCF_VERSION: ${WGCF_VERSION}"
        WGCF_VER=$(normalize_version "$WGCF_VERSION")
    elif [ -n "$GITHUB_AUTH_HEADER" ]; then
        echo "==> [MicroWARP] 未设置 WGCF_VERSION，将读取 latest release"
        WGCF_VER=$(fetch_latest_wgcf_version "$WGCF_REPO" "$GITHUB_AUTH_HEADER")
    else
        echo "==> [MicroWARP] 未设置 WGCF_VERSION，将读取 latest release"
        WGCF_VER=$(fetch_latest_wgcf_version "$WGCF_REPO" "")
    fi

    if [ -z "$WGCF_VER" ]; then
        echo "==> [ERROR] WGCF_VER 为空，终止启动"
        exit 1
    fi

    echo "==> [MicroWARP] 检测到最新 wgcf 版本: v${WGCF_VER}"
    LOCAL_WGCF_VER=$(detect_local_wgcf_version "$WGCF_BIN" || true)
    if [ -n "$LOCAL_WGCF_VER" ]; then
        echo "==> [MicroWARP] 检测到本地 wgcf 版本: v${LOCAL_WGCF_VER}"
    fi

    if [ -n "$LOCAL_WGCF_VER" ] && [ "$LOCAL_WGCF_VER" = "$WGCF_VER" ]; then
        echo "==> [MicroWARP] 缓存命中: 本地 wgcf 版本匹配，跳过下载"
    else
        if [ -n "$LOCAL_WGCF_VER" ]; then
            echo "==> [MicroWARP] 缓存未命中: 本地 v${LOCAL_WGCF_VER} != 目标 v${WGCF_VER}"
        else
            echo "==> [MicroWARP] 缓存未命中: 本地无可用 wgcf，开始下载"
        fi
        WGCF_URL=$(build_wgcf_download_url "$WGCF_VER" "$WGCF_ARCH")
        echo "==> [MicroWARP] 目标 wgcf 下载地址: ${WGCF_URL}"
        if [ -n "$GITHUB_AUTH_HEADER" ]; then
            echo "==> [MicroWARP] 使用 GitHub Token 鉴权下载 wgcf（API 资产下载模式）"
            if ! download_wgcf_with_github_api "$WGCF_REPO" "$WGCF_VER" "$WGCF_ARCH" "$GITHUB_AUTH_HEADER" "$WGCF_BIN"; then
                echo "==> [ERROR] wgcf 下载失败（GitHub API 资产下载模式）"
                exit 1
            fi
        fi
        if [ -z "$GITHUB_AUTH_HEADER" ]; then
            echo "==> [MicroWARP] 使用匿名方式下载 wgcf"
            if ! wget --timeout=15 -qO "$WGCF_BIN" "$WGCF_URL"; then
                echo "==> [ERROR] wgcf 下载失败（匿名模式），请检查 URL 或设置 GITHUB_TOKEN"
                exit 1
            fi
        fi
        chmod +x "$WGCF_BIN"

        if [ ! -s "$WGCF_BIN" ] || [ ! -x "$WGCF_BIN" ]; then
            echo "==> [ERROR] 下载后的 wgcf 文件无效或不可执行: $WGCF_BIN"
            exit 1
        fi
        echo "$WGCF_VER" > "${WGCF_BIN}.version"
        echo "==> [MicroWARP] 下载并缓存 wgcf 成功: v${WGCF_VER}"
    fi

    echo "==> [MicroWARP] 正在向 CF 注册设备..."
    if [ "$WARP_MODE" = "team" ]; then
        if [ -z "${TEAM_TOKEN:-}" ]; then
            echo "==> [ERROR] WARP_MODE=team 需要设置 TEAM_TOKEN"
            exit 1
        fi
        "$WGCF_BIN" register --accept-tos --team-token "$TEAM_TOKEN" > /dev/null
    else
        "$WGCF_BIN" register --accept-tos > /dev/null
    fi

    echo "==> [MicroWARP] 正在生成 WireGuard 配置文件..."
    "$WGCF_BIN" generate > /dev/null

    mv wgcf-profile.conf "$WG_CONF"

    # 【核心安全】阅后即焚：删除注册工具和生成的账号明文文件
    rm -f wgcf-account.toml
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
