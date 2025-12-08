#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v8.0 — 100 % рабочая, декабрь 2025)
# Запуск одной строкой:
# curl -fsSL https://raw.githubusercontent.com/yagopere/proxmox-scripts/main/ollama-webui-lxc.sh | bash
# =============================================================================

set -euo pipefail
clear

cat << "EOF"
   ____                      _       __     __    __  ______
  / __ \____  ___  ____     | |     / /__  / /_  / / / /  _/
 / / / / __ \/ _ \/ __ \    | | /| / / _ \/ __ \/ / / // /
/ /_/ / /_/ /  __/ / / /    | |/ |/ /  __/ /_/ / /_/ // /
\____/ .___/\___/_/ /_/     |__/|__/\___/_.___/\____/___/
    /_/           Open WebUI + Ollama LXC (v8.0 — финальная)
EOF
echo

CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
BRIDGE="vmbr0"

ip link show "$BRIDGE" &>/dev/null || { echo "Bridge $BRIDGE не найден!"; exit 1; }

# Шаблон Debian 12
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* &>/dev/null; then
  echo "Скачиваю шаблон Debian 12..."
  pveam download local debian-12-standard >/dev/null 2>&1
fi
TEMPLATE=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1)
TEMPLATE_NAME=$(basename "$TEMPLATE")

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

  echo "1/5 Обновляю систему и ставлю curl..."
  apt update -y && apt upgrade -y
  apt install -y curl wget ca-certificates gnupg lsb-release

  echo "2/5 Устанавливаю Docker..."
  curl -fsSL https://get.docker.com | sh

  echo "3/5 Устанавливаю Ollama v0.3.2 (прямо с GitHub, без 403)..."
  wget -qO- "https://github.com/ollama/ollama/releases/download/v0.3.2/ollama-linux-amd64.tgz" | tar -xzf - -C /usr/local
  ln -sf /usr/local/bin/ollama /usr/bin/ollama

  echo "4/5 Создаю сервис Ollama с фиксом \$HOME..."
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

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ollama

  echo "5/5 Жду запуска Ollama и скачиваю модель..."
  for i in {1..30}; do
    if curl -s http://127.0.0.1:11434 2>/dev/null | grep -q "Ollama is running"; then
      break
    fi
    sleep 2
  done

  ollama pull llama3.2:3b

  echo "Запускаю Open WebUI..."
  mkdir -p /var/lib/open-webui && chown 1000:1000 /var/lib/open-webui
  docker run -d --network=host \
    -v /var/lib/open-webui:/app/backend/data \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    --name open-webui --restart unless-stopped \
    ghcr.io/open-webui/open-webui:main
'

pct reboot "$CTID" &>/dev/null

echo -n "Жду IP..."
for i in {1..60}; do
  IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP "(?<=inet )[\d.]{7,}" | head -1 || true)
  [[ -n "$IP" ]] && { echo; break; }
  echo -n "."
  sleep 3
done
[[ -z "$IP" ]] && IP="проверь в GUI → Summary"

echo -e "\n\033[1;32mГОТОВО! Через 2–5 минут открывай:\033[0m"
echo -e "   http://$IP:8080   (регистрация нового пользователя)"
echo -e "   Модель llama3.2:3b уже скачана и готова"
echo -e "   ID контейнера: $CTID"
echo -e "   Вход в контейнер: pct enter $CTID\n"
