#!/usr/bin/env bash

# =============================================================================
# Proxmox VE — Ubuntu 25.04 + Ollama + Open WebUI (одним скриптом)
# Автор: ты + я :)
# GitHub: https://github.com/ТВОЙ_ЮЗЕР/ТВОЙ_РЕПО
# =============================================================================

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

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
                                    + Open WebUI
EOF
}

header_info
echo -e "\n Создаём Ubuntu 25.04 VM с предустановленной Ollama + Open WebUI...\n"

# -------------------------- Цвета и эмодзи --------------------------
YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"; GN="\033[1;92m"; CL="\033[m"; BGN="\033[4;92m"
CM="  ✔️ "; CROSS="  ✖️ "; INFO="  💡 "; TAB="  "

# -------------------------- Переменные --------------------------
GEN_MAC=02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//' | tr a-f A-F)
VMID=$(pvesh get /cluster/nextid --output-format json | jq -r '.')
HN="ollama-ubuntu"
DISK_SIZE="32G"        # достаточно для нескольких больших моделей
CORE_COUNT="4"
RAM_SIZE="8192"        # 8 ГБ — комфортно для 7B–13B моделей
BRG="vmbr0"
STORAGE=""

# -------------------------- Функции --------------------------
msg_info() { echo -ne "${TAB}${YW}⏳ $1${CL}"; }
msg_ok()   { echo -e "\r${TAB}${CM}${GN}$1${CL}"; }
msg_error(){ echo -e "\r${TAB}${CROSS}${RD}$1${CL}"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || msg_error "Запустите от root!"; }
arch_check() { [[ $(dpkg --print-architecture) = "amd64" ]] || msg_error "Только x86_64!"; }

# -------------------------- Выбор хранилища --------------------------
msg_info "Определяем хранилище..."
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{print $2}')
  FREE=$(echo "$line" | awk '{print $6}')
  [[ $TYPE == "zfspool" || $TYPE == "dir" || $TYPE == "lvmthin" || $TYPE == "btrfs" ]] && STORAGE_MENU+=("$TAG" "$TYPE – $FREE free" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
[[ ${#STORAGE_MENU[@]} -eq 0 ]] && msg_error "Нет подходящего хранилища для VM!"

if [[ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --title "Выберите хранилище" --radiolist \
    "Куда ставим VM?" 15 70 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
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
    ssh_authorized_keys:
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... # ← сюда можешь вставить свой публичный ключ
    groups: users, admin, docker

package_update: true
package_upgrade: true
packages:
  - curl
  - qemu-guest-agent
  - docker.io
  - docker-compose

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now docker

  # Устанавливаем Ollama
  - curl -fsSL https://ollama.com/install.sh | sh
  - systemctl enable --now ollama

  # Open WebUI в Docker
  - docker run -d --network=host -v ollama:/root/.ollama -v open-webui:/app/backend/data --name open-webui --restart unless-stopped ghcr.io/open-webui/open-webui:main

  # Тянешь сразу какую-нибудь модель (раскомментируй нужную)
  # - sudo -u ollama ollama pull llama3.2
  # - sudo -u ollama ollama pull phi3
  # - sudo -u ollama ollama pull gemma2:2b

write_files:
  - path: /etc/motd
    content: |
      ██████╗ ██╗     ██╗     █████╗ ███╗   ███╗ █████╗ 
      ██╔═══██╗██║     ██║    ██╔══██╗████╗ ████║██╔══██╗
      ██║   ██║██║     ██║    ███████║██╔████╔██║███████║
      ██║   ██║██║     ██║    ██╔══██║██║╚██╔╝██║██╔══██║
      ╚██████╔╝███████╗██║    ██║  ██║██║ ╚═╝ ██║██║  ██║
       ╚═════╝ ╚══════╝╚═╝    ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝  ╚═╝
      
      Web UI: http://$(hostname -I | awk '{print $1}'):8080
      Логин: admin / admin  (смените пароль сразу!)
EOF
)

# -------------------------- Создание VM --------------------------
msg_info "Создаём VM ID $VMID..."
qm create $VMID \
  --name $HN \
  --tags ollama,open-webui,community-script \
  --memory $RAM_SIZE \
  --cores $CORE_COUNT \
  --net0 virtio,bridge=$BRG,macaddr=$GEN_MAC \
  --machine q35 \
  --bios ovmf \
  --efidisk0 $STORAGE:0,efitype=4m \
  --agent 1 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --scsi0 $STORAGE:0,size=$DISK_SIZE,discard=on,ssd=1 \
  --ide2 $STORAGE:cloudinit \
  --boot order=scsi0 \
  --serial0 socket --vga serial0

# Загружаем образ
msg_info "Скачиваем Ubuntu 25.04 cloud-img..."
URL="https://cloud-images.ubuntu.com/plucky/current/plucky-server-cloudimg-amd64.img"
wget -q --show-progress "$URL" -O plucky.img

msg_info "Импортируем диск..."
qm importdisk $VMID plucky.img $STORAGE --format qcow2 >/dev/null
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0,size=$DISK_SIZE,discard=on,ssd=1

# Cloud-init
msg_info "Настраиваем cloud-init..."
echo "$CLOUD_CONFIG" | qm set $VMID --cicustom "user=local:snippets/user-$VMID.yaml" --ipconfig0 ip=dhcp
# Сохраняем cloud-config как сниппет
mkdir -p /var/lib/vz/snippets
echo "$CLOUD_CONFIG" > /var/lib/vz/snippets/user-$VMID.yaml
pvesm add dir local --path /var/lib/vz/snippets --content snippets 2>/dev/null || true

msg_info "Запускаем VM..."
qm start $VMID

msg_ok "Готово! VM $VMID ($HN) запущена."
echo -e "\n${GN}Через 2–3 минуты всё будет готово:${CL}"
echo -e "   ➜ Web-интерфейс: http://$(qm config $VMID | grep ipconfig0 | sed -e 's/.*ip=//' -e 's/,.*//'):8080"
echo -e "   ➜ Логин/пароль: admin / admin (смените сразу!)"
echo -e "   ➜ Ollama API: http://IP:11434\n"
echo -e "${INFO}Для подключения по SSH: ssh ubuntu@IP (пароль не задан — только ключ, добавь свой в cloud-config выше)\n"

post_update_to_api "done" "none"
exit 0