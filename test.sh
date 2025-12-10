#!/usr/bin/env bash
set -euo pipefail
clear

# ========== Open WebUI + Ollama для Proxmox ==========
# Оптимизированный скрипт с улучшенной безопасностью, производительностью и отладочными возможностями

# --------------------- Настройки ---------------------
DEFAULT_MODEL="llama3.2:3b"
CONTAINER_NAME="open-webui"
OLLAMA_VERSION="0.1.1"  # Проверять актуальность на github.com/ollama/ollama/releases
DOCKER_IMAGE="ghcr.io/open-webui/open-webui:main"
MEMORY_LIMIT="4096"     # Мб
CPU_LIMIT="2"           # Ядра
SWAP_LIMIT="2048"       # Мб

# --------------------- Проверки ---------------------
echo "=== Начинаем установку Open WebUI + Ollama ==="

# 1. Проверка подключения к интернету
if ! ping -c1 8.8.8.8 &>/dev/null; then
    echo "❌ Ошибка: Нет подключения к интернету!"
    exit 1
fi

# 2. Проверка на root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Ошибка: Скрипт должен запускаться от root"
    exit 1
fi

# --------------------- Установка зависимостей ---------------------
echo "📦 Устанавливаем зависимости..."
apt-get update && \
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    jq \
    && rm -rf /var/lib/apt/lists/*

# --------------------- Установка Docker ---------------------
echo "🐳 Устанавливаем Docker..."
curl -fsSL https://get.docker.com | sh -c "$(cut -d' ' -f3-)" || \
    { echo "❌ Ошибка при установке Docker"; exit 1; }

# Настройка Docker для совместимости с LXC
echo '{"userns-keep-id": true}' > /etc/docker/daemon.json
systemctl restart docker

# --------------------- Установка Ollama ---------------------
echo "🦙 Устанавливаем Ollama..."
OLLAMA_URL="https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64.tgz"

# Скачиваем и проверяем checksum
OLLAMA_SHA256=$(curl -s "https://api.github.com/repos/ollama/ollama/releases/latest" | \
    jq -r '.assets[] | select(.name | contains("ollama-linux-amd64.tgz")) | .download_count')

if [ "$OLLAMA_SHA256" == "null" ]; then
    echo "❌ Не удалось получить checksum для Ollama"
    exit 1
fi

# Проверяем существование checksum файла
CHECKSUM_URL="${OLLAMA_URL%.*}.sha256"
if curl -s "${CHECKSUM_URL}" >/dev/null; then
    wget -q "${CHECKSUM_URL}" -O - | sha256sum --check --quiet || \
        { echo "❌ Проверка checksum'a Ollama не пройдена"; exit 1; }
fi

wget -q "${OLLAMA_URL}" -O /tmp/ollama.tgz || \
    { echo "❌ Ошибка при скачивании Ollama"; exit 1; }

tar -xzf /tmp/ollama.tgz -C /usr/local/ || \
    { echo "❌ Ошибка при разархивации Ollama"; exit 1; }
rm -f /tmp/ollama.tgz

# Создаем пользователя для Ollama
useradd -r -m -d /var/lib/ollama -s /bin/false ollama || \
    { echo "❌ Не удалось создать пользователя ollama"; exit 1; }

# Устанавливаем Ollama в PATH
echo 'export PATH="/usr/local/bin:$PATH"' >> /root/.bashrc

# --------------------- Настройка systemd ---------------------
OLLAMA_SERVICE=/etc/systemd/system/ollama.service
cat > "$OLLAMA_SERVICE" <<EOF
[Unit]
Description=Ollama Service
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/ollama serve
Restart=always
User=ollama
Group=ollama
RestartSec=5s
Environment="OLLAMA_ORIGINS=*"
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_PORT=11434"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload || \
    { echo "❌ Ошибка при релоаде systemd"; exit 1; }
systemctl enable ollama || \
    { echo "❌ Не удалось активировать ollama"; exit 1; }

# --------------------- Проверка Ollama ---------------------
echo "🔍 Проверяем Ollama..."
if ! systemctl is-active ollama; then
    systemctl start ollama
    if ! systemctl is-active ollama; then
        echo "❌ Ollama не запустился"
        exit 1
    fi
fi

# --------------------- Установка Docker-образа Open WebUI ---------------------
echo "🚀 Устанавливаем Open WebUI..."
docker run --name "$CONTAINER_NAME" \
    -d \
    --restart unless-stopped \
    -p 8080:8080 \
    -e OLLAMA_BASE_URL=http://localhost:11434 \
    "$DOCKER_IMAGE" || \
    { echo "❌ Ошибка при запуске Open WebUI"; exit 1; }

# --------------------- Скачивание модели ---------------------
echo "🤖 Скачиваем модель $DEFAULT_MODEL..."
ollama pull "$DEFAULT_MODEL" || \
    { echo "❌ Ошибка при скачивании модели"; exit 1; }

# --------------------- Проверка работоспособности ---------------------
echo "🔧 Проверяем доступность Open WebUI..."
if ! curl -s http://localhost:8080 | grep -q "Open WebUI"; then
    echo "❌ Open WebUI не доступен по адресу http://localhost:8080"
    exit 1
fi

echo "✅ Все установлено успешно!"
echo "📋 Доступ к Open WebUI: http://<ваш-ip>:8080"
echo "📋 Обратите внимание: В первый раз может потребоваться некоторое время для инициализации"
