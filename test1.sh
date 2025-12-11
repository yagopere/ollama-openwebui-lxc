#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v7.1 — оптимизированная, декабрь 2025)
# Работает даже при 403 от ollama.com и при отсутствии curl
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/ollama-webui-lxc.sh | bash
# =============================================================================
set -euo pipefail
clear
echo -e "\033[1;36m
   ____ _ __ __ __ ______
  / __ \\____ ___ ____ | | / /__ / /_ / / / / _/
 / / / / __ \\/ _ \\/ __ \\ | | /| / / _ \\/ __ \\/ / / // /
/ /_/ / /_/ / __/ / / / | |/ |/ / __/ /_/ / /_/ // /
\\____/ .___/\\___/_/ /_/ |__/|__/\\___/_.___/\\____/___/
     /_/ Open WebUI + Ollama LXC (v7.1 — оптимизированная)
\033[0m\n"
CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
BRIDGE="vmbr0"
MODEL="llama3.2:3b"
ROOT_PASSWORD=$(openssl rand -base64 12)  # Генерируем случайный пароль для root
ip link show "$BRIDGE" &>/dev/null || { echo "Bridge $BRIDGE не найден!"; exit 1; }
# Шаблон
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* &>/dev/null; then
  echo "Скачиваю шаблон Debian 12..."
  pveam download local debian-12-standard >/dev/null
fi
TEMPLATE_NAME=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1 | xargs basename)
MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"
# Interactive опции
read -p "CTID [$CTID]: " input_ctid
CTID=${input_ctid:-$CTID}
read -p "Storage [$STORAGE]: " input_storage
STORAGE=${input_storage:-$STORAGE}
read -p "Модель [$MODEL]: " input_model
MODEL=${input_model:-$MODEL}
echo "Создаю LXC $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --hostname ollama-webui \
  --cores 4 --memory 8192 \
  --net0 name=eth0,bridge="$BRIDGE",hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "$STORAGE:50" \
  --features nesting=1,keyctl=1 \
  --unprivileged 1 \
  --start 1 >/dev/null
echo "Устанавливаю всё внутри контейнера..."
pct exec "$CTID" -- bash -c "
  set -euo pipefail
  echo 'Обновление пакетов...'
  apt update -y || { echo 'Ошибка apt update!'; exit 1; }
  apt upgrade -y
  apt install -y curl wget ca-certificates gnupg lsb-release docker-compose ufw openssh-server
  # Установка пароля для root и SSH
  echo 'root:$ROOT_PASSWORD' | chpasswd || { echo 'Ошибка установки пароля!'; exit 1; }
  sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
  systemctl enable --now ssh || { echo 'Ошибка запуска SSH!'; exit 1; }
  # Firewall
  ufw allow OpenSSH
  ufw allow 8080
  ufw --force enable
  # Docker
  curl -fsSL https://get.docker.com | sh || { echo 'Ошибка установки Docker!'; exit 1; }
  # Ollama
  echo 'Устанавливаю Ollama...'
  curl -fsSL https://ollama.com/install.sh | sh || {
    echo 'Fallback: ручная установка с GitHub...'
    wget -qO- 'https://github.com/ollama/ollama/releases/download/v0.13.2/ollama-linux-amd64.tgz' | tar -xzf - -C /usr/local
    ln -sf /usr/local/bin/ollama /usr/bin/ollama
  }
  if [[ ! -f /usr/bin/ollama ]]; then echo 'Ошибка установки Ollama!'; exit 1; fi
  # systemd-сервис с фиксом $HOME и OLLAMA_HOST
  cat > /etc/systemd/system/ollama.service << 'EOF'
[Unit]
Description=Ollama Service
After=network-online.target
[Service]
ExecStart=/bin/sh -c 'HOME=/root /usr/bin/ollama serve'
Restart=always
RestartSec=3
Environment='PATH=/usr/local/bin:/usr/bin:/bin'
Environment='OLLAMA_HOST=0.0.0.0:11434'
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ollama
  # Ждём запуска
  echo 'Жду запуска Ollama...'
  for i in {1..30}; do
    if curl -s http://127.0.0.1:11434 2>/dev/null | grep -q 'Ollama is running'; then
      echo 'Ollama запущен!'
      break
    fi
    sleep 2
  done
  [[ \$i -eq 30 ]] && { echo 'Ошибка запуска Ollama!'; exit 1; }
  # Модель
  echo 'Скачиваю модель $MODEL...'
  ollama pull '$MODEL'
  ollama list | grep -q '$MODEL' || { echo 'Ошибка pull модели!'; exit 1; }
  # Open WebUI с docker-compose
  echo 'Запускаю Open WebUI...'
  mkdir -p /var/lib/open-webui
  chown 1000:1000 /var/lib/open-webui
  cat > /root/docker-compose.yml << 'EOF'
version: '3'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    volumes:
      - /var/lib/open-webui:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://127.0.0.1:11434
    network_mode: host
    restart: unless-stopped
EOF
  docker-compose -f /root/docker-compose.yml up -d
  sleep 5
  docker ps | grep -q open-webui || { echo 'Ошибка запуска OpenWebUI!'; exit 1; }
  # Auto-update CRON
  echo '0 3 * * * curl -fsSL https://ollama.com/install.sh | sh && docker-compose -f /root/docker-compose.yml pull && docker-compose -f /root/docker-compose.yml up -d && systemctl restart ollama' > /etc/cron.daily/update-ollama
  chmod +x /etc/cron.daily/update-ollama
  # Swap (опционально, если RAM мало)
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
"
pct reboot "$CTID" &>/dev/null
echo "Жду IP..."
for i in {1..40}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP "(?<=inet )[\d.]{7,}" | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 3
done
[[ -z "$IP" ]] && IP="проверь в GUI → Summary"
echo -e "\n\033[1;32mГОТОВО! Через 3–7 минут открывай:\033[0m"
echo -e " → http://$IP:8080"
echo -e " → Модель $MODEL уже скачана"
echo -e " → ID контейнера: $CTID"
echo -e " → Доступ к консоли: pct enter $CTID (на хосте, без пароля)"
echo -e " → SSH: ssh root@$IP (пароль: $ROOT_PASSWORD)"
echo -e " → Вход: pct enter $CTID\n"
exit 0
