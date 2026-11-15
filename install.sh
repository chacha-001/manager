#!/bin/bash
set -euo pipefail

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root."
    exit 1
fi

echo "Installing CYBER JOSEPH Manager..."

# Repo/branch can be overridden with env vars if needed
REPO="${CJ_REPO:-chacha-001/manager}"
BRANCH="${CJ_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
MENU_URL="${RAW_BASE}/menu.sh"
SSHD_URL="${RAW_BASE}/ssh"
SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP="${SSHD_CONFIG}.backup.$(date +%F-%H%M%S)"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Make sure a downloader exists
if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    echo "Neither curl nor wget found, installing curl..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y curl ca-certificates >/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y curl ca-certificates >/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y curl ca-certificates >/dev/null
    else
        echo "Error: Neither curl nor wget is installed and no supported package manager was found."
        exit 1
    fi
fi

# Download a file safely: fails on HTTP errors and rejects empty/HTML responses
download_file() {
    local dest=$1
    local url=$2

    if command -v curl &>/dev/null; then
        if ! curl -4 -fsSL --retry 3 --connect-timeout 15 -o "$dest" "$url"; then
            echo "Error: failed to download $url"
            return 1
        fi
    else
        if ! wget -4 -q -T 15 -t 3 -O "$dest" "$url"; then
            echo "Error: failed to download $url"
            return 1
        fi
    fi

    if [[ ! -s "$dest" ]]; then
        echo "Error: downloaded file is empty: $url"
        return 1
    fi

    if head -c 300 "$dest" | grep -qi '<html\|<!doctype'; then
        echo "Error: got an HTML page instead of a file (check the repo/branch name): $url"
        return 1
    fi
}

# 1) Download everything FIRST, so a failure does not leave the system half-configured
MENU_TMP="$TMP_DIR/menu"
SSHD_TMP="$TMP_DIR/sshd_config"

echo "Downloading menu..."
download_file "$MENU_TMP" "$MENU_URL" || exit 1

echo "Downloading SSH configuration..."
download_file "$SSHD_TMP" "$SSHD_URL" || exit 1

# 2) Install menu
install -m 755 "$MENU_TMP" /usr/local/bin/menu
echo "Menu installed to /usr/local/bin/menu"

# 3) Fix the sftp-server path for this distro (Debian/Ubuntu and RHEL differ)
SFTP_PATH=""
for p in /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server /usr/lib/ssh/sftp-server; do
    if [[ -x "$p" ]]; then
        SFTP_PATH="$p"
        break
    fi
done
if [[ -n "$SFTP_PATH" ]]; then
    sed -i "s|^[[:space:]]*Subsystem[[:space:]]\+sftp.*|Subsystem sftp ${SFTP_PATH}|" "$SSHD_TMP"
fi

# 4) Apply SSH configuration with backup + validation
echo "Applying CYBER JOSEPH SSH configuration..."
cp -a "$SSHD_CONFIG" "$BACKUP"
echo "Backup saved to $BACKUP"

install -m 644 "$SSHD_TMP" "$SSHD_CONFIG"

# sshd needs this directory to validate/run on some systems
mkdir -p /run/sshd
chmod 755 /run/sshd

if ! sshd -t; then
    echo "ERROR: SSH configuration is invalid! Restoring previous configuration..."
    cp -a "$BACKUP" "$SSHD_CONFIG"
    exit 1
fi
echo "SSH configuration validated."

# 5) Restart SSH safely
restart_ssh() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart sshd 2>/dev/null \
        || systemctl restart ssh 2>/dev/null \
        || return 1
    elif command -v service >/dev/null 2>&1; then
        service sshd restart 2>/dev/null \
        || service ssh restart 2>/dev/null \
        || return 1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service sshd restart 2>/dev/null \
        || rc-service ssh restart 2>/dev/null \
        || return 1
    elif [ -x /etc/init.d/sshd ]; then
        /etc/init.d/sshd restart >/dev/null 2>&1
    elif [ -x /etc/init.d/ssh ]; then
        /etc/init.d/ssh restart >/dev/null 2>&1
    else
        return 1
    fi
}

if restart_ssh; then
    echo "SSH service restarted."
else
    echo "WARNING: SSH restart not supported on this system."
    echo "SSH config applied but service was not restarted automatically."
fi

# 6) Run CYBER JOSEPH setup
if ! /usr/local/bin/menu --install-setup; then
    echo "ERROR: Menu setup failed. Run 'menu --install-setup' manually to see details."
    exit 1
fi

echo "Installation complete!"
echo "Type 'menu' to start."
