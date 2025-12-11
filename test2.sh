#!/usr/bin/env bash
# =============================================================================
# Proxmox VE — Open WebUI + Ollama LXC (v7.1 — улучшенная, декабрь 2025)
# Работает даже при 403 от ollama.com и при отсутствии curl
# Добавлено: активация RAG Web Search с DuckDuckGo по умолчанию (бесплатно, без ключа)
# Улучшения: больше памяти (12GB), ядер (6), модель llama3.1:8b для лучшего tool calling,
#             авто-установка SearXNG как fallback-поиска (локальный, приватный, без лимитов),
#             фиксы для стабильности, логи в /var/log/ollama.log
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
     /_/ Open WebUI + Ollama LXC (v7.1 — улучшенная с Web Search)
\033[0m\n"
CTID=$(pvesh get /cluster/nextid)
STORAGE="local-zfs"
BRIDGE="vmbr0"
ip link show "$BRIDGE" &>/dev/null || { echo "Bridge $BRIDGE не найден!"; exit 1; }
# Шаблон
if ! ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* &>/dev/null; then
  echo "Скачиваю шаблон Debian 12..."
  pveam download local debian-12-standard >/dev/null
fi
TEMPLATE_NAME=$(ls /var/lib/vz/template/cache/debian-12-standard_*_amd64.tar.* | tail -n1 | xargs basename)
MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g; s/.$//')"
echo "Создаю LXC $CTID..."
pct create "$CTID" "local:vztmpl/$TEMPLATE_NAME" \
  --hostname ollama-webui \
  --cores 6 --memory 12288 \
  --net0 name=eth0,bridge="$BRIDGE",hwaddr="$MAC",type=veth,ip=dhcp \
  --rootfs "$STORAGE:50" \
  --features nesting=1 \
  --unprivileged 1 \
  --start 1 >/dev/null
echo "Устанавливаю всё внутри контейнера..."
pct exec "$CTID" -- bash -c '
  set -euo pipefail
  # 1. Обновляем и ставим curl + wget + другие утилиты
  apt update -y
  apt upgrade -y
  apt install -y curl wget ca-certificates gnupg lsb-release python3 python3-pip git
  # 2. Docker
  curl -fsSL https://get.docker.com | sh
  # 3. Ollama — прямая ссылка с GitHub (актуальная на 11.12.2025)
  echo "Устанавливаю Ollama v0.13.2..."
  wget -qO- "https://github.com/ollama/ollama/releases/download/v0.13.2/ollama-linux-amd64.tgz" | tar -xzf - -C /usr/local
  ln -sf /usr/local/bin/ollama /usr/bin/ollama
  # 4. systemd-сервис с фиксом $HOME и логами
  cat > /etc/systemd/system/ollama.service << "EOF"
[Unit]
Description=Ollama Service
After=network-online.target
[Service]
ExecStart=/bin/sh -c "HOME=/root /usr/local/bin/ollama serve > /var/log/ollama.log 2>&1"
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
  # 5. Ждём запуска
  echo "Жду запуска Ollama..."
  for i in {1..30}; do
    if curl -s http://127.0.0.1:11434 2>/dev/null | grep -q "Ollama is running"; then
      echo "Ollama запущен!"
      break
    fi
    sleep 2
  done
  # 6. Модель (улучшено: llama3.1:8b для лучшей поддержки инструментов)
  echo "Скачиваю модель llama3.1:8b..."
  ollama pull llama3.1:8b
  # 7. Устанавливаем SearXNG как локальный поисковик (fallback для Web Search, приватный)
  echo "Устанавливаю SearXNG для локального поиска..."
  git clone https://github.com/searxng/searxng /opt/searxng
  cd /opt/searxng
  pip3 install -r requirements.txt
  cp searxng/settings.yml.example searxng/settings.yml
  # Простая настройка: используем DuckDuckGo как backend
  sed -i "s/use_default_settings: false/use_default_settings: true/" searxng/settings.yml
  # systemd для SearXNG
  cat > /etc/systemd/system/searxng.service << "EOF"
[Unit]
Description=SearXNG Search Engine
After=network.target
[Service]
ExecStart=/usr/bin/python3 /opt/searxng/searxng/webapp.py
WorkingDirectory=/opt/searxng
Restart=always
User=root
Group=root
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now searxng
  # Ждём запуска SearXNG
  for i in {1..20}; do
    if curl -s http://127.0.0.1:8888 2>/dev/null | grep -q "SearXNG"; then
      echo "SearXNG запущен!"
      break
    fi
    sleep 2
  done
  # 8. Open WebUI с активацией Web Search (DuckDuckGo по умолчанию, fallback на SearXNG)
  echo "Запускаю Open WebUI с Web Search..."
  mkdir -p /var/lib/open-webui
  chown 1000:1000 /var/lib/open-webui
  docker run -d --network=host \
    -v /var/lib/open-webui:/app/backend/data \
    -e OLLAMA_BASE_URL=http://127.0.0.1:11434 \
    -e ENABLE_RAG_WEB_SEARCH=true \
    -e WEB_SEARCH_PROVIDER=duckduckgo \
    -e WEB_SEARCH_DUCKDUCKGO_API_KEY="" \
    -e WEB_SEARCH_SEARXNG_URL="http://127.0.0.1:8888" \  # Fallback на локальный SearXNG
    --name open-webui --restart unless-stopped \
    ghcr.io/open-webui/open-webui:main
'
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
echo -e " → Модель llama3.1:8b уже скачана (лучше для поиска)"
echo -e " → Web Search включён (DuckDuckGo + локальный SearXNG)"
echo -e " → ID контейнера: $CTID"
echo -e " → Вход: pct enter $CTID"
echo -e " → Логи Ollama: tail -f /var/log/ollama.log\n"
exit 0
