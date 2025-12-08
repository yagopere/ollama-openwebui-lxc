#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v6.0 — финальная, декабрь 2025)
# Работает на Proxmox 8.4 + local-zfs + vmbr0
# Ollama v0.13.2 (актуальная), фикс $HOME, проверка запуска
# Запуск: curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/ollama-webui-lxc.sh | bash
# =============================================================================

set -euo pipefail
clear

echo -e "\033[1;36m
   ____                      _       __     __    __  ______
  / __ \\____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \\/ _ \\/ __ \\    | | /| / / _ \\/ __ \\/ / / // / 
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /  
\\____/ .___/\\___/_/ /_/     |__/|__/\\___/_.___/\\____/___/  
     /_/           Open WebUI + Ollama LXC (v6.0 — финальная)
\033[0m\n"

CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
BRIDGE="vmbr0"
OLLAMA_VERSION="v0.13.2"  # ← актуальная версия на декабрь 2025

# Проверка bridge
ip link show "$BRIDGE" &>/dev/null || { echo "Ошибка: bridge $BRIDGE не найден! Создайте в GUI."; exit 1; }

# Шаблон
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* &>/dev/null; then
  echo "Скачиваю шаблон Debian 12..."
  pveam download local debian-12-standard >/dev/null
fi
TEMPLATE_NAME=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1 | xargs basename)

MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"

echo "Создаю LXC $CTID (ollama-webui)..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --hostname ollama-webui \
  --cores 4 --memory 8192 \
  --net0 name=eth0,bridge="$BRIDGE",hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "$STORAGE:50" \
  --features nesting=1 \
  --unprivileged 1 \
  --start 1 >/dev/null

echo "Устанавливаю всё внутри контейнера..."

pct exec "$CTID" -- bash -c '
  set -euo pipefail

  echo "Обновляю систему и ставлю зависимости..."
  apt update -y
  apt upgrade -y
  apt install -y curl wget ca-certificates gnupg lsb-release

  echo "Устанавливаю Docker..."
  curl -fsSL https://get.docker.com | sh
  docker version

  echo "Устанавливаю Ollama $OLLAMA_VERSION..."
  wget -qO- "https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION/ollama-linux-amd64.tgz" | tar -xzf - -C /usr/local
  ln -sf /usr/local/bin/ollama /usr/bin/ollama
  ollama --version

  echo "Создаю systemd-сервис Ollama (с фиксом \$HOME)..."
  cat > /etc/systemd/system/ollama.service << "EOF"
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/bin/sh -c "HOME=/root /usr/local/bin/ollama serve"
Restart=always
RestartSec=3
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ollama

  echo "Жду запуска Ollama..."
  for i in {1..20}; do
    if curl -s http://127.0.0.1:11434 2>/dev/null | grep -q "Ollama is running"; then
      echo "Ollama успешно запущен!"
      break
    fi
    sleep 3
  done

  if ! curl -s http://127.0.0.1:11434 | grep -q "Ollama is running"; then
    echo "Ollama не запустился! Логи:"
    journalctl -u ollama -n 30
    exit 1
  fi

  echo "Скачиваю модель llama3.2:3b..."
  ollama pull llama3.2:3b

  echo "Запускаю Open WebUI..."
  mkdir -p /var/lib/open-webui
  chown 1000:1000 /var/lib/open-webui
  docker run -d --network=host \
    -v /var/lib/open-webui:/app/backend/data \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    --name open-webui --restart unless-stopped \
    ghcr.io/open-webui/open-webui:main

  sleep 5
  if docker ps | grep -q open-webui; then
    echo "Open WebUI запущен!"
  else
    echo "Open WebUI не запустился! Логи: docker logs open-webui"
    exit 1
  fi
'

pct reboot "$CTID" &>/dev/null

echo "Жду IP-адрес..."
for i in {1..40}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP "(?<=inet )[\d.]{7,}" | head -1 || true)
  [[ -n "$IP" ]] && break
  sleep 3
done
[[ -z "$IP" ]] && IP="проверь в веб-интерфейсе Proxmox → Summary"

echo -e "\n\033[1;32mГОТОВО! Через 2–5 минут всё будет работать:\033[0m"
echo -e "   Web UI → http://$IP:8080   (регистрация нового пользователя)"
echo -e "   Ollama → http://$IP:11434"
echo -e "   Модель llama3.2:3b уже скачана"
echo -e "   ID контейнера: $CTID"
echo -e "   Вход в контейнер: pct enter $CTID\n"

exit 0
