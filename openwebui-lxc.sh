#!/usr/bin/env bash

# =============================================================================
# Proxmox VE - Open WebUI LXC with optional Ollama (v1.7 — no password, pct enter access)
# Автор: yagopere + Grok (xAI)
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/openwebui-lxc-v1.7.sh | bash
# =============================================================================

set -euo pipefail

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
CM="✔"; CROSS="✖"; TAB="  "

msg_info() { echo -ne "${TAB}${YW}⏳ $1${CL}"; }
msg_ok()   { echo -e "\r${TAB}${CM} ${GN}$1${CL}"; }
msg_error(){ echo -e "\r${TAB}${CROSS} ${RD}$1${CL}"; exit 1; }

[[ $EUID -eq 0 ]] || msg_error "Запустите от root!"

clear
cat <<"EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/
          + Ollama (optional) — LXC для Proxmox VE 8.4+ (v1.7)
EOF
echo -e "\nСоздаём Open WebUI LXC с Ollama (опционально)...\n"

# Параметры
DISK_SIZE="50"
CORE_COUNT="4"
RAM_SIZE="8192"
BRIDGE="vmbr0"

# ID и hostname
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="openwebui-lxc"

# Ollama
if whiptail --title "Ollama" --yesno "Установить Ollama?" 8 50; then
  INSTALL_OLLAMA="yes"
  MODEL=$(whiptail --title "Модель Ollama" --radiolist "Выберите (~2–4 ГБ)" 12 60 4 \
    "llama3.2:3b" "Llama 3.2 3B (быстрая)" ON \
    "phi3:mini" "Phi-3 Mini 3.8B" OFF \
    "gemma2:2b" "Gemma 2 2B" OFF \
    "none" "Не загружать" OFF 3>&1 1>&2 2>&3) || MODEL="none"
else
  INSTALL_OLLAMA="no"
  MODEL="none"
fi

# Хранилище
msg_info "Определяем хранилище..."
mapfile -t STORES < <(pvesm status -content rootdir | awk 'NR>1 && ($2=="zfspool" || $2=="dir" || $2=="lvmthin" || $2=="btrfs") {print $1}')
[[ ${#STORES[@]} -eq 0 ]] && msg_error "Нет подходящего хранилища!"
if [[ ${#STORES[@]} -eq 1 ]]; then
  STORAGE="${STORES[0]}"
else
  STORAGE=$(whiptail --title "Хранилище" --radiolist "Куда ставим LXC?" 15 70 6 "${STORES[@]}" " " 3>&1 1>&2 2>&3)
fi
msg_ok "Хранилище: $STORAGE"

# Bridge
msg_info "Проверяем bridge $BRIDGE..."
ip link show "$BRIDGE" >/dev/null 2>&1 || msg_error "Bridge $BRIDGE не найден! Создайте в GUI."
msg_ok "Bridge: $BRIDGE"

# Шаблон
msg_info "Подготавливаем шаблон Debian 12..."
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* >/dev/null 2>&1; then
  pveam download local debian-12-standard
fi
TEMPLATE_NAME=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1 | xargs basename)
msg_ok "Шаблон: $TEMPLATE_NAME"

# MAC
MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"

# Создание LXC (без --password!)
msg_info "Создаём LXC $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --arch amd64 \
  --cores "$CORE_COUNT" \
  --hostname "$HOSTNAME" \
  --memory "$RAM_SIZE" \
  --net0 name=eth0,bridge="$BRIDGE",hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "$STORAGE:$DISK_SIZE" \
  --features nesting=1 \
  --unprivileged 1 \
  --start 1
msg_ok "LXC $CTID создан и запущен"

# Установка
exec_in() { pct exec "$CTID" -- bash -c "$1"; }

msg_info "Обновляем систему..."
exec_in "apt update && apt upgrade -y"

msg_info "Устанавливаем Docker..."
exec_in "curl -fsSL https://get.docker.com | sh"

if [[ "$INSTALL_OLLAMA" == "yes" ]]; then
  msg_info "Устанавливаем Ollama..."
  exec_in "curl -fsSL https://ollama.com/install.sh | sh"
  exec_in "systemctl enable --now ollama"
  [[ "$MODEL" != "none" ]] && exec_in "ollama pull $MODEL"
  OLLAMA_ENV="-e OLLAMA_BASE_URL=http://127.0.0.1:11434"
else
  OLLAMA_ENV=""
fi

msg_info "Устанавливаем Open WebUI..."
exec_in "mkdir -p /var/lib/open-webui && chown 1000:1000 /var/lib/open-webui"
exec_in "docker run -d --network=host -v /var/lib/open-webui:/app/backend/data --name open-webui --restart unless-stopped $OLLAMA_ENV ghcr.io/open-webui/open-webui:main"

msg_info "Перезагружаем LXC..."
pct reboot "$CTID"

# IP
msg_info "Ждём IP..."
IP=""
for i in {1..30}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 4
done
[[ -z "$IP" ]] && IP="проверьте в GUI > Summary"

msg_ok "ГОТОВО! LXC $CTID ($HOSTNAME)"
echo -e "\nЧерез 3–10 мин всё готово:"
echo -e "   ➜ Web UI: http://$IP:8080 (регистрация нового пользователя)"
[[ "$INSTALL_OLLAMA" == "yes" ]] && echo -e "   ➜ Ollama API: http://$IP:11434"
echo -e "   ➜ Модель: $MODEL"
echo -e "   ➜ Доступ к root: pct enter $CTID (без пароля)\n"

exit 0
