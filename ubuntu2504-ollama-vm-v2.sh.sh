#!/usr/bin/env bash

# =============================================================================
# Proxmox VE — Ubuntu 25.04 + Ollama + Open WebUI (v2 — с выбором модели)
# Автор: yagopere + Grok (xAI)
# GitHub: https://github.com/yagopere/proxmox-scripts
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/ubuntu2504-ollama-vm.sh | bash
# =============================================================================

# Подключаем API-функции из community-scripts (как в оригинале)
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
                                    + Open WebUI (v2)
EOF
}

header_info
echo -e "\n Создаём Ubuntu 25.04 VM с Ollama + Open WebUI...\n"

# -------------------------- Цвета и эмодзи --------------------------
YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"; GN="\033[1;92m"; CL="\033[m"; BGN="\033[4;92m"
CM="  ✔️ "; CROSS="  ✖️ "; INFO="  💡 "; TAB="  "

# -------------------------- Переменные по умолчанию --------------------------
GEN_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//' | tr a-f A-F)"
HN="ollama-ubuntu"
DISK_SIZE="50G"        # Для моделей + ОС
CORE_COUNT="4"
RAM_SIZE="8192"        # 8 ГБ
BRG="vmbr0"
MODEL_TO_PULL="llama3.2"  # По умолчанию, но спросим
STORAGE=""
VMID=""

# -------------------------- Функции --------------------------
msg_info() { echo -ne "${TAB}${YW}⏳ $1${CL}"; }
msg_ok()   { echo -e "\r${TAB}${CM}${GN}$1${CL}"; }
msg_error(){ echo -e "\r${TAB}${CROSS}${RD}$1${CL}"; exit 1; }

# Функция из оригинала для валидного VMID
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

check_root() { [[ $EUID -eq 0 ]] || msg_error "Запустите от root!"; }
arch_check() { [[ $(dpkg --print-architecture) = "amd64" ]] || msg_error "Только x86_64!"; }

# -------------------------- Настройки через whiptail --------------------------
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
  [[ $TYPE == "zfspool" || $TYPE == "dir" || $TYPE == "lvmthin" || $TYPE == "btrfs" ]] && STORAGE_MENU+=("$TAG" "$TYPE – $FREE free" "OFF")
done < <(pvesm status -content images | awk 'NR>1 {print $1, $2, $6}')

[[ ${#STORAGE_MENU[@]} -eq 0 ]] && msg_error "Нет подходящего хранилища для VM!"

if [[ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]]; then
  STORAGE=${STORAGE_MENU[0]}
else
  STORAGE=$(whiptail --title "Выберите хранилище" --radiolist \
    "Куда ставим VM?" 15 70 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit 1
fi
msg_ok "Хранилище: $STORAGE"

# -------------------------- Cloud-Init скрипт (улучшенный) --------------------------
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
    # Добавь свой SSH-ключ здесь:
    # ssh_authorized_keys:
    #   - ssh-rsa ТВОЙ_КЛЮЧ...

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

  # Загружаем выбранную модель
  $([[ "$MODEL_TO_PULL" != "none" ]] && echo "- sudo -u ollama ollama pull $MODEL_TO_PULL")

  # Open WebUI в Docker (с volume для данных)
  - docker run -d --network=host \\
      -v ollama:/root/.ollama \\
      -v open-webui:/app/backend/data \\
      -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \\
      --name open-webui --restart unless-stopped \\
      ghcr.io/open-webui/open-webui:main

  # Фикс прав на volumes
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

# Загружаем образ Ubuntu 25.04
msg_info "Скачиваем Ubuntu 25.04 cloud-img..."
URL="https://cloud-images.ubuntu.com/plucky/current/plucky-server-cloudimg-amd64.img"
wget -q --show-progress "$URL" -O /tmp/plucky.img

msg_info "Импортируем диск..."
qm importdisk $VMID /tmp/plucky.img $STORAGE --format qcow2 >/dev/null 2>&1
qm set $VMID --scsi0 "$STORAGE:vm-$VMID-disk-0,size=$DISK_SIZE,discard=on,ssd=1"

# Cloud-init (сниппет)
msg_info "Настраиваем cloud-init..."
mkdir -p /var/lib/vz/snippets
echo "$CLOUD_CONFIG" > /var/lib/vz/snippets/user-$VMID.yaml
qm set $VMID --cicustom "user=local:snippets/user-$VMID.yaml" --ipconfig0 ip=dhcp

msg_info "Запускаем VM..."
qm start $VMID

# Ждём готовности
sleep 10
msg_info "Проверяем статус VM..."
if qm status $VMID | grep -q running; then
  msg_ok "VM запущена!"
else
  msg_error "Ошибка запуска VM. Проверьте логи: qm monitor $VMID"
fi

msg_ok "Готово! VM $VMID ($HN) создана и запущена."
echo -e "\n${GN}Через 3–5 минут всё будет готово:${CL}"
echo -e "   ➜ Web-интерфейс: http://$(qm guest $VMID | grep IP | head -1 | awk '{print $2}'):8080"
echo -e "   ➜ Логин/пароль: admin / admin (смените сразу!)"
echo -e "   ➜ Ollama: ollama list (в SSH)"
echo -e "   ➜ SSH: ssh ubuntu@IP_VM\n"
echo -e "${INFO}Модель загружена: $MODEL_TO_PULL\n"

post_update_to_api "done" "none" 2>/dev/null || true
rm -f /tmp/plucky.img
exit 0