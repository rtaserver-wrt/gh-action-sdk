#!/bin/bash

set -euo pipefail

GROUP=

# Color output functions
echo_red() {
    echo -e "\033[31m$1\033[0m"
}

echo_green() {
    echo -e "\033[32m$1\033[0m"
}

echo_yellow() {
    echo -e "\033[33m$1\033[0m"
}

group() {
    endgroup
    echo "::group::  $1"
    GROUP=1
}

endgroup() {
    if [ -n "$GROUP" ]; then
        echo "::endgroup::"
    fi
    GROUP=
}

# Cleanup function
cleanup() {
    endgroup
    if [ -f logtmp ]; then
        rm -f logtmp
    fi
}

trap 'cleanup' ERR EXIT

group "bash setup.sh"
# snapshot containers don't ship with the SDK to save bandwidth
# run setup.sh to download and extract the SDK
if [ -f setup.sh ]; then
    bash setup.sh
fi
endgroup

FEEDNAME="${FEEDNAME:-action}"
BUILD_LOG="${BUILD_LOG:-1}"

# Handle signing keys
if [ -n "${KEY_BUILD:-}" ]; then
    echo "$KEY_BUILD" > key-build
    chmod 600 key-build
    CONFIG_SIGNED_PACKAGES="y"
fi

if [ -n "${PRIVATE_KEY:-}" ]; then
    echo "$PRIVATE_KEY" > private-key.pem
    chmod 600 private-key.pem
    CONFIG_SIGNED_PACKAGES="y"
fi

# Setup feeds configuration
if [ -z "${NO_DEFAULT_FEEDS:-}" ]; then
    if [ -f feeds.conf.default ]; then
        sed \
            -e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
            -e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
            -e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
            feeds.conf.default > feeds.conf
    else
        echo_yellow "Warning: feeds.conf.default not found"
        touch feeds.conf
    fi
fi

echo "src-link $FEEDNAME /feed/" >> feeds.conf

ALL_CUSTOM_FEEDS="$FEEDNAME "
# Process extra feeds
if [ -n "${EXTRA_FEEDS:-}" ]; then
    for EXTRA_FEED in $EXTRA_FEEDS; do
        echo "$EXTRA_FEED" | tr '|' ' ' >> feeds.conf
        FEED_NAME=$(echo "$EXTRA_FEED" | cut -d'|' -f2)
        ALL_CUSTOM_FEEDS+="$FEED_NAME "
    done
fi

group "feeds.conf"
cat feeds.conf
endgroup

group "feeds update -a"
if [ -x "./scripts/feeds" ]; then
    ./scripts/feeds update -a
else
    echo_red "Error: feeds script not found or not executable"
    exit 1
fi
endgroup

group "make defconfig"
make defconfig
endgroup

if [ -z "${PACKAGES:-}" ]; then
    # compile all packages in feed
    for FEED in $ALL_CUSTOM_FEEDS; do
        group "feeds install -p $FEED -f -a"
        ./scripts/feeds install -p "$FEED" -f -a
        endgroup
    done

    RET=0

    make \
        BUILD_LOG="$BUILD_LOG" \
        CONFIG_SIGNED_PACKAGES="${CONFIG_SIGNED_PACKAGES:-}" \
        IGNORE_ERRORS="${IGNORE_ERRORS:-}" \
        CONFIG_AUTOREMOVE=y \
        V="${V:-}" \
        -j "$(nproc)" || RET=$?
else
    # compile specific packages with checks
    for PKG in $PACKAGES; do
        echo_green "Processing package: $PKG"
        
        for FEED in $ALL_CUSTOM_FEEDS; do
            group "feeds install -p $FEED -f $PKG"
            ./scripts/feeds install -p "$FEED" -f "$PKG"
            endgroup
        done

        group "make package/$PKG/download"
        make \
            BUILD_LOG="$BUILD_LOG" \
            IGNORE_ERRORS="${IGNORE_ERRORS:-}" \
            "package/$PKG/download" V=s
        endgroup

        group "make package/$PKG/check"
        if [ "${FIXUP:-0}" -eq 1 ]; then
            echo_yellow "FIXUP=1 is set, so PKG_MIRROR_HASH might be generated"
            FIXUP_ARG="FIXUP=$FIXUP"
        else
            FIXUP_ARG=""
        fi
        
        make \
            BUILD_LOG="$BUILD_LOG" \
            IGNORE_ERRORS="${IGNORE_ERRORS:-}" \
            "package/$PKG/check" ${FIXUP_ARG} V=s 2>&1 | \
                tee logtmp
        endgroup

        # Check return code properly
        RET=${PIPESTATUS[0]}

        if [ "$RET" -ne 0 ]; then
            echo_red "=> Package check failed: $RET"
            exit "$RET"
        fi

        # Check for hash issues
        badhash_msg="HASH does not match "
        badhash_msg+="|HASH uses deprecated hash,"
        badhash_msg+="|HASH is missing,"
        if grep -qE "$badhash_msg" logtmp; then
            echo_red "Package HASH check failed"
            exit 1
        fi

        # Check patches
        PATCHES_DIR=$(find /feed -path "*/$PKG/patches" -type d 2>/dev/null | head -1)
        if [ -d "$PATCHES_DIR" ] && [ -z "${NO_REFRESH_CHECK:-}" ]; then
            group "make package/$PKG/refresh"
            make \
                BUILD_LOG="$BUILD_LOG" \
                IGNORE_ERRORS="${IGNORE_ERRORS:-}" \
                "package/$PKG/refresh" V=s
            endgroup

            if ! git -C "$PATCHES_DIR" diff --quiet -- . 2>/dev/null; then
                echo_red "Dirty patches detected, please refresh and review the diff"
                git -C "$PATCHES_DIR" checkout -- . 2>/dev/null || true
                exit 1
            fi

            group "make package/$PKG/clean"
            make \
                BUILD_LOG="$BUILD_LOG" \
                IGNORE_ERRORS="${IGNORE_ERRORS:-}" \
                "package/$PKG/clean" V=s
            endgroup
        fi

        # Check and format init scripts
        FILES_DIR=$(find /feed -path "*/$PKG/files" -type d 2>/dev/null | head -1)
        if [ -d "$FILES_DIR" ] && [ -z "${NO_SHFMT_CHECK:-}" ]; then
            if command -v shfmt >/dev/null 2>&1; then
                find "$FILES_DIR" -name "*.init" -exec shfmt -w -sr -s '{}' \; 2>/dev/null || true
                if ! git -C "$FILES_DIR" diff --quiet -- . 2>/dev/null; then
                    echo_red "init script must be formatted. Please run through shfmt -w -sr -s"
                    git -C "$FILES_DIR" checkout -- . 2>/dev/null || true
                    exit 1
                fi
            else
                echo_yellow "Warning: shfmt not found, skipping format check"
            fi
        fi
    done

    # Generate package dependency list
    make \
        -f .config \
        -f tmp/.packagedeps \
        -f <(echo "\$(info \$(sort \$(package-y) \$(package-m)))"; echo -en "a:\n\t@:") \
            2>/dev/null | tr ' ' '\n' > enabled-package-subdirs.txt

    RET=0

    # Compile specific packages
    for PKG in $PACKAGES; do
        if ! grep -m1 -qE "(^|/)$PKG$" enabled-package-subdirs.txt; then
            echo "::warning file=$PKG::Skipping $PKG due to unsupported architecture"
            continue
        fi

        echo_green "Compiling package: $PKG"
        make \
            BUILD_LOG="$BUILD_LOG" \
            IGNORE_ERRORS="${IGNORE_ERRORS:-}" \
            CONFIG_AUTOREMOVE=y \
            V="${V:-}" \
            -j "$(nproc)" \
            "package/$PKG/compile" || {
                RET=$?
                echo_red "Failed to compile package: $PKG"
                break
            }
    done
fi

# Generate package index if requested
if [ "${INDEX:-0}" = '1' ]; then
    group "make package/index"
    make package/index
    endgroup
fi

# Move artifacts
if [ -d bin/ ]; then
    echo_green "Moving bin/ to /artifacts/"
    mv bin/ /artifacts/
fi

if [ -d logs/ ]; then
    echo_green "Moving logs/ to /artifacts/"
    mv logs/ /artifacts/
fi

echo_green "Build completed with exit code: $RET"
exit "$RET"