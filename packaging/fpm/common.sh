#!/bin/bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

FPM_DIR="$( cd "$( dirname ${BASH_SOURCE[0]} )" && pwd )"
REPO_DIR="$( cd "$FPM_DIR/../../" && pwd )"

PKG_NAME="opentelemetry-injector"
PKG_VENDOR="OpenTelemetry"
PKG_MAINTAINER="OpenTelemetry"
PKG_DESCRIPTION="OpenTelemetry Injector"
PKG_LICENSE="Apache 2.0"
PKG_URL="https://github.com/open-telemetry/opentelemetry-injector"

INSTALL_DIR="/usr/lib/opentelemetry"
libotelinject_INSTALL_PATH="${INSTALL_DIR}/libotelinject.so"
JAVA_AGENT_INSTALL_PATH="${INSTALL_DIR}/javaagent.jar"
CONFIG_DIR_REPO_PATH="${FPM_DIR}/etc/opentelemetry"
CONFIG_DIR_INSTALL_PATH="/etc/opentelemetry"
EXAMPLES_INSTALL_DIR="${INSTALL_DIR}/examples"
EXAMPLES_DIR="${FPM_DIR}/examples"

JAVA_AGENT_RELEASE_PATH="${FPM_DIR}/../java-agent-release.txt"
JAVA_AGENT_RELEASE_URL="https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases"
JAVA_AGENT_INSTALL_PATH="${INSTALL_DIR}/javaagent.jar"

NODEJS_AGENT_RELEASE_PATH="${FPM_DIR}/../nodejs-agent-release.txt"
NODEJS_AGENT_INSTALL_PATH="${INSTALL_DIR}/otel-js.tgz"

DOTNET_AGENT_RELEASE_PATH="${FPM_DIR}/../dotnet-agent-release.txt"
DOTNET_AGENT_RELEASE_URL="https://github.com/open-telemetry/opentelemetry-dotnet-instrumentation/releases"
DOTNET_AGENT_INSTALL_DIR="${INSTALL_DIR}/dotnet"

PREUNINSTALL_PATH="$FPM_DIR/preuninstall.sh"

get_version() {
    commit_tag="$( git -C "$REPO_DIR" describe --abbrev=0 --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true )"
    if [[ -z "$commit_tag" ]]; then
        latest_tag="$( git -C "$REPO_DIR" describe --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true )"
        if [[ -n "$latest_tag" ]]; then
            echo "${latest_tag}-post"
        else
            echo "0.0.1-post"
        fi
    else
        echo "$commit_tag"
    fi
}

download_java_agent() {
    local tag="$1"
    local dest="$2"
    local dl_url=""
    if [[ "$tag" = "latest" ]]; then
      dl_url="$JAVA_AGENT_RELEASE_URL/latest/download/opentelemetry-javaagent.jar"
    else
      dl_url="$JAVA_AGENT_RELEASE_URL/download/$tag/opentelemetry-javaagent.jar"
    fi

    echo "Downloading $dl_url ..."
    mkdir -p "$( dirname $dest )"
    curl -sfL "$dl_url" -o "$dest"
}

download_nodejs_agent() {
    local tag="$1"
    local dest="$2"
    npm pack @opentelemetry/auto-instrumentations-node@${tag#v}
    mkdir -p "$( dirname $dest )"
    pushd "$( dirname $dest )"
    npm pack @opentelemetry/auto-instrumentations-node@${tag#v}
    mv *.tgz otel-js.tgz
    popd
}

download_dotnet_agent() {
    local tag="$1"
    local dest="$2"
    local pkg="opentelemetry-dotnet-instrumentation-linux-glibc-x64.zip"
    local dl_url="$DOTNET_AGENT_RELEASE_URL/download/$tag/$pkg"

    echo "Downloading $dl_url ..."
    curl -sfL "$dl_url" -o /tmp/$pkg

    echo "Extracting $pkg to $dest ..."
    mkdir -p "$dest"
    unzip -d $dest /tmp/$pkg
    rm -f /tmp/$pkg
}

setup_files_and_permissions() {
    local arch="$1"
    local buildroot="$2"
    local libotelinject="$REPO_DIR/dist/libotelinject_${arch}.so"
    local java_agent_release="$(cat "$JAVA_AGENT_RELEASE_PATH" | tail -n 1)"
    local nodejs_agent_release="$(cat "$NODEJS_AGENT_RELEASE_PATH" | tail -n 1)"
    local dotnet_agent_release="$(cat "$DOTNET_AGENT_RELEASE_PATH" | tail -n 1)"

    mkdir -p "$buildroot/$(dirname $libotelinject_INSTALL_PATH)"
    cp -f "$libotelinject" "$buildroot/$libotelinject_INSTALL_PATH"
    sudo chmod 755 "$buildroot/$libotelinject_INSTALL_PATH"

    download_java_agent "$java_agent_release" "${buildroot}/${JAVA_AGENT_INSTALL_PATH}"
    sudo chmod 755 "$buildroot/$JAVA_AGENT_INSTALL_PATH"

    download_nodejs_agent "$nodejs_agent_release" "${buildroot}/${NODEJS_AGENT_INSTALL_PATH}"
    sudo chmod 755 "$buildroot/$NODEJS_AGENT_INSTALL_PATH"

    download_dotnet_agent "$dotnet_agent_release" "${buildroot}/${DOTNET_AGENT_INSTALL_DIR}"
    sudo chmod -R 755 "$buildroot/$DOTNET_AGENT_INSTALL_DIR"

    mkdir -p  "$buildroot/$CONFIG_DIR_INSTALL_PATH"
    cp -rf "$CONFIG_DIR_REPO_PATH"/* "$buildroot/$CONFIG_DIR_INSTALL_PATH"/
    sudo chmod -R 755 "$buildroot/$CONFIG_DIR_INSTALL_PATH"

    mkdir -p "$buildroot/$INSTALL_DIR"
    cp -rf "$EXAMPLES_DIR" "$buildroot/$INSTALL_DIR/"
    sudo chmod -R 755 "$buildroot/$EXAMPLES_INSTALL_DIR"

    sudo chown -R root:root "$buildroot"
}
