#!/usr/bin/env bash

# =============================================================================
# Proxmox VE - Open WebUI LXC with optional Ollama (v1.6 — fixed template, bridge, Docker)
# Автор: yagopere + Grok (xAI), на основе pve-docs + forum
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/openwebui-lxc-v1.6.sh | bash
# =============================================================================

# Цвета и эмодзи
YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
CM="  ✔️ "; CROSS="  ✖️ "; INFO="  💡 "; TAB="  "

msg_info() { echo -ne "${TAB}${YW}⏳ $1${CL}"; }
msg_ok()   { echo -e "\r${TAB}${CM}${GN}$1${CL}"; }
msg_error(){ echo -e "\r${TAB}${CROSS}${RD}$1${CL}"; exit 1; }

[[ $EUID -eq 0 ]] || msg_error "Запустите от root!"

header_info() {
  clear
  cat <<"EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_
          + Ollama (optional) — LXC for Proxmox VE 8.4+ (v1.6)
EOF
}

header_info
echo -e "\nСоздаём Open WebUI LXC с Ollama (опционально)...\n"

# Переменные
DISK_SIZE="50"
CORE_COUNT="4"
RAM_SIZE="8192"
BRG="vmbr0"
HN="openwebui-lxc"
STORAGE=""
VMID=""

# Валидный VMID
get_valid_nextid() {
  local try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

VMID=$(get_valid_nextid)

# Ollama опции
INSTALL_OLLAMA=$(whiptail --backtitle "Proxmox Open WebUI LXC" --title "Ollama?" --yesno "Установить Ollama?" 8 50 3>&1 1>&2 2>&3 && echo "yes" || echo "no")

MODEL_TO_PULL=""
if [ "$INSTALL_OLLAMA" == "yes" ]; then
  MODEL_TO_PULL=$(whiptail --backtitle "Proxmox Open WebUI LXC" --title "Модель Ollama" --radiolist \
    "Выберите модель (Ollama скачает ~2–4 ГБ)" 12 50 4 \
    "llama3.2:3b" "Llama 3.2 (3B, быстрая)" ON \
    "phi3:mini" "Phi-3 Mini (3.8B)" OFF \
    "gemma2:2b" "Gemma 2 (2B)" OFF \
    "none" "Не загружать" OFF \
    3>&1 1>&2 2>&3) || MODEL_TO_PULL="none"
fi

# Хранилище
msg_info "Определяем хранилище..."
STORAGE_MENU=()
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{print $2}')
  FREE=$(echo "$line" | awk '{print $6 "G"}')
  [[ $TYPE == "zfspool" || $TYPE == "dir" || $TYPE == "lvmthin" || $TYPE == "btrfs" ]] && STORAGE_MENU+=("$TAG" "$TYPE – $FREE free" "OFF")
done < <(pvesm status -content rootdir | awk 'NR>1 {print $1, $2, $6}')

[[ ${#STORAGE_MENU[@]} -eq 0 ]] && msg_error "Нет подходящего хранилища для LXC!"

if [[ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --title "Выберите хранилище" --radiolist \
    "Куда ставим LXC?" 15 70 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
fi
msg_ok "Хранилище: $STORAGE"

# Bridge
msg_info "Проверяем bridge $BRG..."
ip link show "$BRG" >/dev/null 2>&1 || msg_error "Bridge $BRG не найден! Создайте в GUI: Node > Network > Create > Linux Bridge (name=$BRG)."
msg_ok "Bridge: $BRG"

# Шаблон Debian 12
msg_info "Скачиваем шаблон Debian 12, если нет..."
TEMPLATE_BASE="debian-12-standard"
TEMPLATE_DIR="/var/lib/vz/template/cache"
if ! ls "${TEMPLATE_DIR}/${TEMPLATE_BASE}"*.tar.* >/dev/null 2>&1; then
  pveam download local "${TEMPLATE_BASE}" || msg_error "Ошибка скачивания шаблона!"
fi
TEMPLATE_FILE=$(ls "${TEMPLATE_DIR}/${TEMPLATE_BASE}"*.tar.* | head -1)
TEMPLATE_NAME=$(basename "$TEMPLATE_FILE")
msg_ok "Шаблон: $TEMPLATE_NAME"

# Создание LXC
msg_info "Создаём LXC ID $VMID..."
GEN_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//' | tr a-f A-F)"
pct create $VMID local:vztmpl/"$TEMPLATE_NAME" \
  --arch amd64 \
  --cores $CORE_COUNT \
  --hostname $HN \
  --memory $RAM_SIZE \
  --net0 name=eth0,bridge=$BRG,ip=dhcp,hwaddr=$GEN_MAC,type=veth \
  --rootfs $STORAGE:$DISK_SIZE \
  --swap 1024 \
  --unprivileged 1 \
  --features nesting=1 \
  --password ''
msg_ok "LXC создан"

msg_info "Запускаем LXC..."
pct start $VMID
sleep 10
msg_ok "LXC запущен"

# Установка внутри
exec_in() { pct exec $VMID -- bash -c "$1"; }

msg_info "Обновляем пакеты..."
exec_in "apt update && apt upgrade -y"
msg_ok "Обновлено"

msg_info "Устанавливаем Docker..."
exec_in "curl -fsSL https://get.docker.com | bash"
msg_ok "Docker установлен"

if [ "$INSTALL_OLLAMA" == "yes" ]; then
  msg_info "Устанавливаем Ollama..."
  exec_in "curl -fsSL https://ollama.com/install.sh | sh"
  exec_in "systemctl enable --now ollama"
  if [ "$MODEL_TO_PULL" != "none" ]; then
    exec_in "ollama pull $MODEL_TO_PULL"
  fi
  msg_ok "Ollama установлен"
  OLLAMA_ENV="-e OLLAMA_BASE_URL=http://127.0.0.1:11434"
else
  OLLAMA_ENV=""
fi

msg_info "Устанавливаем Open WebUI..."
exec_in "mkdir -p /var/lib/open-webui && chown -R 1000:1000 /var/lib/open-webui"
exec_in "docker run -d --network=host -v /var/lib/open-webui:/app/backend/data --name open-webui --restart unless-stopped $OLLAMA_ENV ghcr.io/open-webui/open-webui:main"
msg_ok "Open WebUI установлен"

msg_info "Перезагружаем LXC..."
pct reboot $VMID
sleep 20
msg_ok "Перезагружен"

# IP
msg_info "Ждём IP (до 60s)..."
IP="N/A"
for i in {1..12}; do
  IP=$(exec_in "ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1" || echo "N/A")
  [ "$IP" != "N/A" ] && break
  sleep 5
done
[ "$IP" == "N/A" ] && IP="проверьте в GUI (Summary)"

msg_ok "Готово! LXC $VMID ($HN) создан."
echo -e "\n${GN}Через 2–5 мин всё готово:${CL}"
echo -e "   ➜ Web UI: http://${IP}:8080 (регистрируйтесь)"
echo -e "   ➜ Ollama API: http://${IP}:11434 (если установлен)"
echo -e "   ➜ Консоль: pct enter $VMID"
echo -e "   ➜ Модель: $MODEL_TO_PULL\n${INFO}Логи: pct exec $VMID docker logs open-webui"
