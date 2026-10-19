#!/usr/bin/env bashio
build_arch=$1
frp_version=$2

frp_url="https://github.com/fatedier/frp/releases/download/"
app_path="/usr/src"

function select_machine() {
    local machine;
    case $build_arch in
        "aarch64")
            machine="arm64"
        ;;
        "amd64")
            machine="amd64"
        ;;
        "armhf")
            machine="arm_hf"
        ;;
        "armv7")
            machine="arm"
        ;;
        "i386")
            machine="386"
        ;;
    esac;

    echo "$machine"
}

function install() {
    bashio::log.info "Installing built-in frpc (${frp_version})"
    echo "${frp_version}" > /etc/frp_builtin_version

    local machine=$(select_machine)
    local file_name="frp_${frp_version}_linux_${machine}.tar.gz"
    local file_url="${frp_url}v${frp_version}/${file_name}"
    bashio::log.info "URL ${file_url}"

    mkdir -p $app_path
    mkdir -p /tmp/frp_extract

    # Download with fallback for arm / arm_hf differences across versions
    if ! curl -o /tmp/${file_name} -fsSL $file_url; then
        if [ "$machine" = "arm_hf" ]; then
            bashio::log.info "Trying alternative machine 'arm' for armhf..."
            machine="arm"
            file_name="frp_${frp_version}_linux_${machine}.tar.gz"
            file_url="${frp_url}v${frp_version}/${file_name}"
            curl -o /tmp/${file_name} -fsSL $file_url
        elif [ "$machine" = "arm" ]; then
            bashio::log.info "Trying alternative machine 'arm_hf' for armv7..."
            machine="arm_hf"
            file_name="frp_${frp_version}_linux_${machine}.tar.gz"
            file_url="${frp_url}v${frp_version}/${file_name}"
            curl -o /tmp/${file_name} -fsSL $file_url
        fi
    fi

    tar xzf /tmp/${file_name} -C /tmp/frp_extract
    local extracted_bin=$(find /tmp/frp_extract -type f -name frpc | head -n 1)

    if [ -n "$extracted_bin" ]; then
        cp -f "$extracted_bin" ${app_path}/frpc
        chmod a+x ${app_path}/frpc
        bashio::log.info "Successfully installed built-in frpc (${frp_version})"
    else
        bashio::log.error "Failed to locate frpc in extracted archive!"
        exit 1
    fi

    rm -rf /tmp/${file_name}
    rm -rf /tmp/frp_extract
    ls -la $app_path
}

install
