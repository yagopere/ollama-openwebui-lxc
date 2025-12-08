#!/usr/bin/env bash

# =============================================================================
# Proxmox VE — Ubuntu 25.04 + Ollama + Open WebUI (v3 — fixed ZFS/disk issues)
# Автор: yagopere + Grok (xAI)
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/ubuntu2504-ollama-vm-v3.sh | bash
# =============================================================================

set -e  # Выход на любой ошибке

# Подключаем API (опционально)
source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func 2>/dev/null) || true

function header_info {
  clear
  cat <<"EOF"
   __  ____                __           ___   ______ ____  __ __     _    ____  ___
  / / / / /_  __  ______  / /___  __   |__ \ / ____// __ \/ // /    | |  / /  |/  /
 / / / / __ \/ / / / __ \/ __/ / / /   __/ //___ \ / / / / // /_    | | / / /|_/ / 
/ /_/ / /_/ / /_/ / / / / /_/ /_/ /   / __/____/ // /_/ /__  __/    | |/ / /  / /  
\____/_.___/\__,_/_/ /_/\__/\__,_/   /____/_____(_)____/  /_/       |___/_/  /_/   
                                      
                     ██████╗ ██╗     ██╗     █████╗ ███╗   ███╗ █████╗ 
                    ██╔═══██╗██║     ██║    ██╔══██╗████╗ ████║██╔══██╗
                    ██║   ██║██║     ██║    ███████║██╔████╔██║███████║
                    ██║   ██║██║     ██║    ██╔══██║██║╚██╔╝██║██╔══██║
                    ╚██████╔╝███████╗██║    ██║  ██║██║ ╚═╝ ██║██║  ██║
                     ╚═════╝ ╚══════╝╚═╝    ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝
                                    + Open WebUI (v3 — ZFS fixed)
EOF
}

header_info
echo -e "\n Создаём Ubuntu 25.04 VM с Ollama + Open WebUI...\n"

# -------------------------- Цвета и эмодзи --------------------------
YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"; GN="\033[1;92m"; CL="\033[m"
CM="  ✔️ "; CROSS="  ✖️ "; INFO="  💡 "; TAB="  "

# -------------------------- Переменные по умолчанию --------------------------
GEN_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//' | tr a-f A-F)"
HN="ollama-ubuntu"
DISK_SIZE="50G"        # Для моделей + ОС
CORE_COUNT="4"
RAM_SIZE="8192"        # 8 ГБ
BRG="vmbr0"
MODEL_TO_PULL="llama3.2"
STORAGE=""
VMID=""
IMG_FILE="/tmp/plucky.img"
URL="https://cloud-images.ubuntu.com/plucky/current/plucky-server-cloudimg-amd64.img"

# -------------------------- Функции --------------------------
msg_info() { echo -ne "${TAB}${YW}⏳ $1...${CL}"; }
msg_ok()   { echo -e "\r${TAB}${CM}${GN}$1${CL}"; }
msg_error() { echo -e "\r${TAB}${CROSS}${RD}$1${CL}"; cleanup; exit 1; }

get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

cleanup() {
  [[ -n "$VMID" ]] && qm destroy "$VMID" 2>/dev/null || true
  rm -f "$IMG_FILE"
  echo -e "\n${TAB}${RD}Очистка завершена.${CL}"
}

check_root() { [[ $EUID -eq 0 ]] || msg_error "Запустите от root!"; }
arch_check() { [[ $(dpkg --print-architecture) = "amd64" ]] || msg_error "Только x86_64!"; }

trap cleanup EXIT

# -------------------------- Настройки через whiptail --------------------------
check_root
arch_check

VMID=$(get_valid_nextid)
HN=$(whiptail --backtitle "Proxmox Ollama VM" --inputbox "Hostname (default: ollama-ubuntu)" 8 50 ollama-ubuntu --title "HOSTNAME" 3>&1 1>&2 2>&3) || HN="ollama-ubuntu"

MODEL_CHOICE=$(whiptail --backtitle "Proxmox Ollama VM" --title "Модель для автозагрузки" --radiolist \
  "Выберите модель (Ollama скачает ~2–4 ГБ)" 12 50 4 \
  "llama3.2" "Llama 3.2 (3B, быстрая)" ON \
  "phi3" "Phi-3 (3.8B, Microsoft)" OFF \
  "gemma2:2b" "Gemma 2 (2B, Google)" OFF \
  "none" "Не загружать" OFF \
  3>&1 1>&2 2>&3) || MODEL_TO_PULL="none"
MODEL_TO_PULL="$MODEL_CHOICE"

# -------------------------- Выбор хранилища --------------------------
msg_info "Определяем хранилище..."
STORAGE_MENU=()
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{print $2}')
  FREE=$(echo "$line" | awk '{print $6 "G"}')
  [[ $TYPE =~ ^(dir|zfspool|lvmthin|btrfs)$ ]] && STORAGE_MENU+=("$TAG" "$TYPE – $FREE free" "OFF")
done < <(pvesm status -content images | awk 'NR>1 {print $1, $2, $6}')

[[ ${#STORAGE_MENU[@]} -eq 0 ]] && msg_error "Нет подходящего хранилища для VM!"

if [[ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --title "Выберите хранилище" --radiolist \
    "Куда ставим VM?" 15 70 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || msg_error "Отменено пользователем"
fi
msg_ok "Хранилище: $STORAGE"

# -------------------------- Cloud-Init скрипт --------------------------
CLOUD_CONFIG=$(cat <<EOF
#cloud-config
hostname: $HN
fqdn: $HN.local
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: users, admin, docker
    # Добавь свой SSH-ключ:
    # ssh_authorized_keys:
    #   - ssh-rsa ТВОЙ_ПУБЛИЧНЫЙ_КЛЮЧ...

package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - qemu-guest-agent
  - docker.io
  - docker-compose-v2

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now docker
  - usermod -aG docker ubuntu

  # Устанавливаем Ollama
  - curl -fsSL https://ollama.com/install.sh | sh
  - systemctl enable --now ollama

  # Загружаем модель (если выбрана)
  $([[ "$MODEL_TO_PULL" != "none" ]] && echo "- sudo -u ollama ollama pull $MODEL_TO_PULL")

  # Open WebUI в Docker
  - docker run -d --network=host \\
      -v ollama:/root/.ollama \\
      -v open-webui:/app/backend/data \\
      -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \\
      --name open-webui --restart unless-stopped \\
      ghcr.io/open-webui/open-webui:main

  # Фикс прав
  - chown -R 1000:1000 /root/.ollama /app/backend/data || true

write_files:
  - path: /etc/motd
    content: |
      Ollama + Open WebUI готово!
      
      Web UI: http://\$(hostname -I | awk '{print \$1}'):8080
      Логин: admin / admin (смените пароль!)
      Ollama API: http://IP:11434
      Модели: ollama list
EOF
)

# -------------------------- Скачивание образа --------------------------
msg_info "Скачиваем Ubuntu 25.04 cloud-img..."
wget -q --show-progress "$URL" -O "$IMG_FILE" || msg_error "Ошибка скачивания образа"

# -------------------------- Создание VM (БЕЗ SCSI) --------------------------
msg_info "Создаём VM ID $VMID..."
qm create $VMID \
  --name "$HN" \
  --tags "ollama,open-webui,community-script" \
  --memory $RAM_SIZE \
  --cores $CORE_COUNT \
  --net0 "virtio,bridge=$BRG,macaddr=$GEN_MAC" \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "$STORAGE:0,efitype=4m" \
  --agent 1 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --ide2 "$STORAGE:cloudinit" \
  --boot "order=scsi0" \
  --serial0 socket --vga serial0

# Проверяем создание
if [[ ! -f "/etc/pve/qemu-server/${VMID}.conf" ]]; then
  msg_error "VM не создана! Проверьте логи Proxmox."
fi
msg_ok "VM создана (ID $VMID)"

# -------------------------- Импорт диска --------------------------
msg_info "Импортируем диск..."
qm importdisk $VMID "$IMG_FILE" $STORAGE --format qcow2
DISK_REF="$STORAGE:vm-$VMID-disk-0"

# Прикрепляем импортированный диск как scsi0 С размером
qm set $VMID --scsi0 "$DISK_REF,size=$DISK_SIZE,discard=on,ssd=1"
qm set $VMID --boot order=scsi0

# Ресайз (для ZFS/других)
qm resize $VMID scsi0 "$DISK_SIZE"

# -------------------------- Cloud-init --------------------------
msg_info "Настраиваем cloud-init..."
mkdir -p /var/lib/vz/snippets
echo "$CLOUD_CONFIG" > "/var/lib/vz/snippets/user-$VMID.yaml"
qm set $VMID --cicustom "user=local:snippets/user-$VMID.yaml" --ipconfig0 ip=dhcp

# -------------------------- Запуск и проверка --------------------------
msg_info "Запускаем VM..."
qm start $VMID

sleep 10
if qm status $VMID | grep -q "status: running"; then
  msg_ok "VM запущена!"
else
  msg_error "VM не запустилась. Логи: qm monitor $VMID"
fi

msg_ok "Готово! VM $VMID ($HN) создана и запущена."
echo -e "\n${GN}Через 3–5 минут всё будет готово:${CL}"
echo -e "   ➜ Web UI: http://$(qm agent $VMID network-get-interfaces | grep 'inet ' | awk '{print $2}'):8080"
echo -e "   ➜ Логин/пароль: admin / admin"
echo -e "   ➜ SSH: ssh ubuntu@IP (добавь ключ в cloud-config для пароля)"
echo -e "   ➜ Модель: $MODEL_TO_PULL\n"
echo -e "${INFO}Проверь в Proxmox: qm config $VMID\n"

post_update_to_api "done" "none" 2>/dev/null || true
exit 0
