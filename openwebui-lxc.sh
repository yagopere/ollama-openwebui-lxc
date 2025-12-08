#!/usr/bin/env bash

# =============================================================================
# Proxmox VE - Open WebUI LXC with optional Ollama (v1.3 — official pct.1 syntax)
# Автор: yagopere + Grok (xAI), на основе pve-docs/pct.1.html
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/openwebui-lxc-v1.3.sh | bash
# =============================================================================

variables() {
  var_disk="50"  # ГБ
  var_cpu="4"
  var_ram="8192"  # МБ
  var_os="debian"
  var_version="12"
  var_unprivileged="1"
  var_bridge="vmbr0"
}

color() {
  YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; CL="\033[m"
  CM="  ✔️ "; CROSS="  ✖️ "; INFO="  💡 "; TAB="  "
}

catch_errors() {
  set -Eeuo pipefail
  trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  echo -e "\n${RD}[ERROR]${CL} line ${line_number}: exit ${exit_code}: ${YW}${command}${CL}\n"
  exit $exit_code
}

msg_info() { echo -ne "${TAB}${YW}⏳ $1${CL}"; }
msg_ok()   { echo -e "\r${TAB}${CM}${GN}$1${CL}"; }
msg_error(){ echo -e "\r${TAB}${CROSS}${RD}$1${CL}"; exit 1; }

root_check() { [[ $EUID -eq 0 ]] || msg_error "Запустите от root!"; }
pve_check() { pveversion | grep -q "pve-manager/8" || msg_error "Proxmox VE 8+ required"; }
arch_check() { [[ $(dpkg --print-architecture) = "amd64" ]] || msg_error "Только x86_64!"; }

get_nextid() {
  local try_id=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
  while [[ -f "/etc/pve/lxc/${try_id}.conf" || -f "/etc/pve/qemu-server/${try_id}.conf" ]]; do
    try_id=$((try_id + 1))
  done
  echo "$try_id"
}

header_info() {
  clear
  cat <<"EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/
          + Ollama (optional) — LXC for Proxmox VE 8.4+ (v1.3)
EOF
}

header_info
echo -e "\nСоздаём Open WebUI LXC с Ollama (опционально)...\n"

root_check; pve_check; arch_check
variables; color; catch_errors

# Опции
INSTALL_OLLAMA=$(whiptail --backtitle "Proxmox Open WebUI LXC" --title "Ollama?" --yesno "Установить Ollama?" 8 50 3>&1 1>&2 2>&3 && echo "yes" || echo "no")

MODEL_TO_PULL=""
if [[ "$INSTALL_OLLAMA" == "yes" ]]; then
  MODEL_CHOICE=$(whiptail --backtitle "Proxmox Open WebUI LXC" --title "Модель Ollama" --radiolist \
    "Выберите (~2–4 ГБ)" 12 50 4 \
    "llama3.2:3b" "Llama 3.2 (3B)" ON \
    "phi3:mini" "Phi-3 Mini (3.8B)" OFF \
    "gemma2:2b" "Gemma 2 (2B)" OFF \
    "none" "Нет" OFF \
    3>&1 1>&2 2>&3) || MODEL_TO_PULL="none"
  MODEL_TO_PULL="$MODEL_CHOICE"
fi

# Хранилище
msg_info "Определяем хранилище..."
STORAGE_MENU=()
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}'); TYPE=$(echo "$line" | awk '{print $2}'); FREE=$(echo "$line" | awk '{print $6 "G"}')
  [[ $TYPE == "dir" || $TYPE == "zfspool" || $TYPE == "lvmthin" || $TYPE == "btrfs" ]] && STORAGE_MENU+=("$TAG" "$TYPE – $FREE" "OFF")
done < <(pvesm status -content rootdir | awk 'NR>1 {print $1, $2, $6}')

[[ ${#STORAGE_MENU[@]} -eq 0 ]] && msg_error "Нет хранилища для LXC!"

if [[ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --title "Хранилище" --radiolist "Выберите?" 15 70 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
fi
msg_ok "Хранилище: $STORAGE"

# Bridge check
pvesh get /nodes/$(hostname)/network --type list | grep -q "$var_bridge" || { msg_info "Bridge $var_bridge не найден, используем vmbr0"; var_bridge="vmbr0"; }

# Создание LXC
CTID=$(get_nextid)
HN="openwebui-lxc-$(date +%s | cut -c1-3)"
DISK_SIZE="$var_disk"
CORE_COUNT="$var_cpu"
RAM_SIZE="$var_ram"

TEMPLATE="debian-12-standard"
if ! ls /var/lib/vz/template/cache/${TEMPLATE}*.tar.* >/dev/null 2>&1; then
  msg_info "Скачиваем шаблон $TEMPLATE..."
  pveam download local $TEMPLATE || msg_error "Ошибка скачивания шаблона"
  msg_ok "Шаблон скачан"
fi

msg_info "Создаём LXC $CTID..."
GEN_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//' | tr a-f A-F)"
pct create $CTID local:vztmpl/${TEMPLATE}*.tar.* \
  --arch amd64 \
  --cores $CORE_COUNT \
  --hostname $HN \
  --memory $RAM_SIZE \
  --net0 name=eth0,bridge=$var_bridge,ip=dhcp,hwaddr=$GEN_MAC,type=veth \
  --ostype $var_os \
  --rootfs $STORAGE:$DISK_SIZE \
  --swap 1024 \
  --unprivileged $var_unprivileged \
  --features nesting=1 \
  --onboot 1 || msg_error "Ошибка создания LXC (проверьте net0/bridge)"
msg_ok "LXC создан"

msg_info "Запускаем LXC..."
pct start $CTID
sleep 10
msg_ok "LXC запущен"

# Установка внутри
exec_in() { pct exec $CTID -- bash -c "$1"; }

msg_info "Обновляем пакеты..."
exec_in "apt update && apt upgrade -y"
msg_ok "Пакеты обновлены"

msg_info "Устанавливаем зависимости..."
exec_in "apt install -y curl wget ca-certificates gnupg lsb-release"
msg_ok "Зависимости установлены"

msg_info "Устанавливаем Docker..."
exec_in "install -m 0755 -d /etc/apt/keyrings"
exec_in "curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc"
exec_in "chmod a+r /etc/apt/keyrings/docker.asc"
exec_in "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable' | tee /etc/apt/sources.list.d/docker.list > /dev/null"
exec_in "apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
msg_ok "Docker установлен"

if [[ "$INSTALL_OLLAMA" == "yes" ]]; then
  msg_info "Устанавливаем Ollama..."
  exec_in "curl -fsSL https://ollama.com/install.sh | sh"
  exec_in "systemctl enable --now ollama
