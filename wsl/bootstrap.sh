#!/usr/bin/env bash
# WSL2 (Ubuntu 24.04 arm64) bootstrap for the Surface Laptop Ultra.
# Run as root from Windows:  wsl -d Ubuntu-24.04 -u root -- bash bootstrap.sh <linux-user>
# Idempotent: safe to re-run.
set -euo pipefail

TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" ]]; then echo "usage: bootstrap.sh <linux-user>" >&2; exit 2; fi
if [[ "$(id -u)" -ne 0 ]]; then echo "run as root (wsl -u root)" >&2; exit 2; fi

log() { printf '%s [wsl] %s\n' "$(date +%H:%M:%S)" "$*"; }

arch="$(uname -m)"
[[ "$arch" == "aarch64" ]] || { echo "expected aarch64, got $arch" >&2; exit 1; }

# ------------------------------------------------------------------ systemd (needed for docker)
if ! grep -q '^systemd=true' /etc/wsl.conf 2>/dev/null; then
  log "enabling systemd in /etc/wsl.conf (takes effect after 'wsl --shutdown')"
  printf '[boot]\nsystemd=true\n\n[user]\ndefault=%s\n' "$TARGET_USER" > /etc/wsl.conf
fi

# ------------------------------------------------------------------ base packages
export DEBIAN_FRONTEND=noninteractive
log "apt update/upgrade"
apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  build-essential git curl wget ca-certificates gnupg jq unzip zip htop tmux \
  python3-venv pciutils usbutils i2c-tools can-utils

# ------------------------------------------------------------------ Docker CE (not Docker Desktop)
if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker CE"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$TARGET_USER"

# ------------------------------------------------------------------ NVIDIA container toolkit
# Do NOT install a Linux NVIDIA driver inside WSL: libcuda and nvidia-smi come from the
# Windows driver via /usr/lib/wsl/lib.
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "installing NVIDIA container toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
if pidof systemd >/dev/null 2>&1; then
  systemctl enable --now docker
  systemctl restart docker
else
  log "systemd not running yet - run 'wsl --shutdown' from Windows, then re-run this script"
fi

# ------------------------------------------------------------------ uv for the target user
if ! sudo -u "$TARGET_USER" bash -lc 'command -v uv' >/dev/null 2>&1; then
  log "installing uv for $TARGET_USER"
  sudo -u "$TARGET_USER" bash -lc 'curl -LsSf https://astral.sh/uv/install.sh | sh'
fi

# ------------------------------------------------------------------ GPU checks
log "GPU check (WSL passthrough)"
if [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
  /usr/lib/wsl/lib/nvidia-smi || log "WARN: nvidia-smi present but failed"
else
  log "WARN: /usr/lib/wsl/lib/nvidia-smi missing - Windows R616+ driver not exposed to WSL"
fi
if pidof systemd >/dev/null 2>&1; then
  log "GPU check (docker --gpus all)"
  if docker run --rm --gpus all ubuntu:24.04 nvidia-smi; then
    log "OK: container GPU passthrough works"
  else
    log "WARN: docker GPU passthrough failed - see NVIDIA/NemoClaw WSL N1X issues; native llama.cpp is unaffected"
  fi
fi
log "done"
