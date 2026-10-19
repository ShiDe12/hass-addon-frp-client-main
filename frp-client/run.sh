#!/usr/bin/env bashio
WAIT_PIDS=()
CONFIG_PATH='/share/frpc.toml'
DEFAULT_CONFIG_PATH='/frpc.toml'

function stop_frpc() {
    bashio::log.info "Shutdown frpc client"
    kill -15 "${WAIT_PIDS[@]}" 2>/dev/null || true
    kill $(jobs -p) 2>/dev/null || true
}

function get_machine() {
    local arch
    if bashio::var.has_value "$(bashio::info.arch 2>/dev/null)"; then
        arch=$(bashio::info.arch)
    else
        arch=$(uname -m)
    fi

    local machine
    case $arch in
        "aarch64"|"arm64")
            machine="arm64"
        ;;
        "amd64"|"x86_64")
            machine="amd64"
        ;;
        "armhf")
            machine="arm_hf"
        ;;
        "armv7"|"armv7l")
            machine="arm"
        ;;
        "i386"|"i686")
            machine="386"
        ;;
        *)
            machine="amd64"
        ;;
    esac
    echo "$machine"
}

BUILTIN_VERSION=$(cat /etc/frp_builtin_version 2>/dev/null || echo "0.71.1")
REQUESTED_VERSION=$(bashio::config 'frpVersion' 2>/dev/null || echo "0.71.1")
REQUESTED_VERSION=$(echo "$REQUESTED_VERSION" | tr -d ' ' | tr -d '"')

GITHUB_MIRROR=$(bashio::config 'githubMirror' 2>/dev/null || echo "")
if [ -n "$GITHUB_MIRROR" ]; then
    GITHUB_MIRROR="${GITHUB_MIRROR%/}/"
fi

if [ "$REQUESTED_VERSION" = "latest" ] || [ -z "$REQUESTED_VERSION" ]; then
    bashio::log.info "Resolving latest FRP version from GitHub API..."
    LATEST_TAG=$(curl -sSL -m 10 -H "Accept: application/vnd.github.v3+json" -H "User-Agent: HomeAssistant-FRP-Addon" "https://api.github.com/repos/fatedier/frp/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
    if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "null" ]; then
        TARGET_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//')
        bashio::log.info "Resolved latest FRP version: ${TARGET_VERSION}"
    else
        bashio::log.warning "Unable to query latest FRP version from GitHub API (offline or rate limited). Falling back to built-in version ${BUILTIN_VERSION}."
        TARGET_VERSION="$BUILTIN_VERSION"
    fi
else
    TARGET_VERSION=$(echo "$REQUESTED_VERSION" | sed 's/^v//')
fi

CACHE_DIR="/data/frp_cache"
CACHE_BIN="${CACHE_DIR}/frp_${TARGET_VERSION}/frpc"
FRP_BIN=""

if [ "$TARGET_VERSION" = "$BUILTIN_VERSION" ] && [ -x "/usr/src/frpc" ]; then
    bashio::log.info "Using built-in frpc (${BUILTIN_VERSION})"
    FRP_BIN="/usr/src/frpc"
elif [ -x "$CACHE_BIN" ]; then
    bashio::log.info "Using cached frpc (${TARGET_VERSION}) at ${CACHE_BIN}"
    FRP_BIN="$CACHE_BIN"
else
    bashio::log.info "Downloading frpc v${TARGET_VERSION}..."
    MACHINE=$(get_machine)
    FILE_NAME="frp_${TARGET_VERSION}_linux_${MACHINE}.tar.gz"
    DOWNLOAD_URL="${GITHUB_MIRROR}https://github.com/fatedier/frp/releases/download/v${TARGET_VERSION}/${FILE_NAME}"

    DOWNLOAD_OK=false
    mkdir -p /tmp/frp_download
    mkdir -p /tmp/frp_extract

    bashio::log.info "Downloading from: ${DOWNLOAD_URL}"
    if curl -f -sSL -o "/tmp/frp_download/${FILE_NAME}" "$DOWNLOAD_URL"; then
        DOWNLOAD_OK=true
    else
        if [ "$MACHINE" = "arm_hf" ]; then
            ALT_FILE="frp_${TARGET_VERSION}_linux_arm.tar.gz"
            ALT_URL="${GITHUB_MIRROR}https://github.com/fatedier/frp/releases/download/v${TARGET_VERSION}/${ALT_FILE}"
            bashio::log.info "Retrying with machine 'arm': ${ALT_URL}"
            if curl -f -sSL -o "/tmp/frp_download/${FILE_NAME}" "$ALT_URL"; then
                DOWNLOAD_OK=true
            fi
        elif [ "$MACHINE" = "arm" ]; then
            ALT_FILE="frp_${TARGET_VERSION}_linux_arm_hf.tar.gz"
            ALT_URL="${GITHUB_MIRROR}https://github.com/fatedier/frp/releases/download/v${TARGET_VERSION}/${ALT_FILE}"
            bashio::log.info "Retrying with machine 'arm_hf': ${ALT_URL}"
            if curl -f -sSL -o "/tmp/frp_download/${FILE_NAME}" "$ALT_URL"; then
                DOWNLOAD_OK=true
            fi
        fi
    fi

    if [ "$DOWNLOAD_OK" = "true" ]; then
        if tar xzf "/tmp/frp_download/${FILE_NAME}" -C /tmp/frp_extract; then
            EXTRACTED_BIN=$(find /tmp/frp_extract -type f -name frpc | head -n 1)
            if [ -n "$EXTRACTED_BIN" ]; then
                mkdir -p "${CACHE_DIR}/frp_${TARGET_VERSION}"
                cp -f "$EXTRACTED_BIN" "$CACHE_BIN"
                chmod a+x "$CACHE_BIN"
                FRP_BIN="$CACHE_BIN"
                bashio::log.info "Successfully downloaded and cached frpc v${TARGET_VERSION}"
            fi
        fi
    fi

    rm -rf /tmp/frp_download
    rm -rf /tmp/frp_extract

    if [ -z "$FRP_BIN" ] || [ ! -x "$FRP_BIN" ]; then
        bashio::log.warning "Failed to download frpc v${TARGET_VERSION}."
        if [ -x "/usr/src/frpc" ]; then
            bashio::log.warning "Falling back to built-in frpc (${BUILTIN_VERSION})."
            FRP_BIN="/usr/src/frpc"
        else
            bashio::log.error "No usable frpc binary found!"
            exit 1
        fi
    fi
fi

OVERRIDE_CONFIG=$(bashio::config 'overrideConfig' 2>/dev/null || echo "true")
if [ "$OVERRIDE_CONFIG" = "false" ] && [ -f "$CONFIG_PATH" ]; then
    bashio::log.info "Preserving existing configuration at ${CONFIG_PATH} (overrideConfig is disabled)."
else
    bashio::log.info "Generating configuration at ${CONFIG_PATH}."
    cat <<EOF > $CONFIG_PATH
serverAddr = "$(bashio::config 'serverAddr')"
serverPort = $(bashio::config 'serverPort')
EOF

    if bashio::config.has_value 'authToken'; then
        AUTH_TOKEN=$(bashio::config 'authToken')
        if [ -n "$AUTH_TOKEN" ]; then
            cat <<EOF >> $CONFIG_PATH

auth.method = "token"
auth.token = "${AUTH_TOKEN}"
EOF
        fi
    fi

    cat <<EOF >> $CONFIG_PATH

log.to = "/share/frpc.log"
log.level = "trace"
log.maxDays = 3
EOF

    if bashio::config.has_value 'webServerPort'; then
        WS_PORT=$(bashio::config 'webServerPort')
        if [ -n "$WS_PORT" ] && [ "$WS_PORT" -gt 0 ] 2>/dev/null; then
            WS_USER="admin"
            WS_PASS="123456789"
            if bashio::config.has_value 'webServerUser'; then
                WS_USER=$(bashio::config 'webServerUser')
            fi
            if bashio::config.has_value 'webServerPassword'; then
                WS_PASS=$(bashio::config 'webServerPassword')
            fi
            cat <<EOF >> $CONFIG_PATH

webServer.addr = "0.0.0.0"
webServer.port = ${WS_PORT}
webServer.user = "${WS_USER}"
webServer.password = "${WS_PASS}"
EOF
        fi
    fi

    PROXY_TYPE="http"
    if bashio::config.has_value 'proxyType'; then
        VAL=$(bashio::config 'proxyType')
        if [ -n "$VAL" ]; then
            PROXY_TYPE="$VAL"
        fi
    fi

    LOCAL_IP="0.0.0.0"
    if bashio::config.has_value 'localIP'; then
        VAL=$(bashio::config 'localIP')
        if [ -n "$VAL" ]; then
            LOCAL_IP="$VAL"
        fi
    fi

    LOCAL_PORT=8123
    if bashio::config.has_value 'localPort'; then
        VAL=$(bashio::config 'localPort')
        if [ -n "$VAL" ] && [ "$VAL" -gt 0 ] 2>/dev/null; then
            LOCAL_PORT="$VAL"
        fi
    fi

    cat <<EOF >> $CONFIG_PATH

[[proxies]]
name = "$(bashio::config 'proxyName')"
type = "${PROXY_TYPE}"
localIP = "${LOCAL_IP}"
localPort = ${LOCAL_PORT}
EOF

    if bashio::config.has_value 'subdomain'; then
        SUBDOMAIN=$(bashio::config 'subdomain')
        if [ -n "$SUBDOMAIN" ]; then
            echo "subdomain = \"${SUBDOMAIN}\"" >> $CONFIG_PATH
        fi
    fi

    if bashio::config.has_value 'customDomain'; then
        CUSTOM_DOMAIN=$(bashio::config 'customDomain')
        if [ -n "$CUSTOM_DOMAIN" ]; then
            echo "customDomains = [\"${CUSTOM_DOMAIN}\"]" >> $CONFIG_PATH
        fi
    fi

    cat <<EOF >> $CONFIG_PATH
transport.useEncryption = true
transport.useCompression = true
EOF
fi

bashio::log.info "Starting frpc: $("$FRP_BIN" -v 2>/dev/null || echo "$FRP_BIN")"

cat $CONFIG_PATH

"$FRP_BIN" -c $CONFIG_PATH & WAIT_PIDS+=($!)

touch /share/frpc.log
tail -f /share/frpc.log &

trap "stop_frpc" SIGTERM SIGHUP
wait "${WAIT_PIDS[@]}"
