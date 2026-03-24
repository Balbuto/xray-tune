#!/usr/bin/env bash

set -euo pipefail

echo "==== Xray Ultimate Optimizer PRO (0.2beta) ===="

### --- ПРОВЕРКА ROOT ---
if [ "$EUID" -ne 0 ]; then
  echo "Запусти как root"
  exit 1
fi

### --- УСТАНОВКА ЗАВИСИМОСТЕЙ ---
echo "== Установка зависимостей =="

apt update -y
apt install -y curl jq ufw fail2ban docker.io

# Установка yq (YAML парсер)
if ! command -v yq &> /dev/null; then
  echo "Устанавливаем yq..."
  YQ_URL="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
  curl -sL "$YQ_URL" -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
fi

### --- ВЫБОР УСТАНОВКИ ---
echo ""
echo "Где установлен Xray?"
echo "1) Host (systemd)"
echo "2) Docker"
read -p "Выбор [1-2]: " INSTALL_TYPE

### --- RAM ---
echo ""
read -p "Сколько RAM (GB): " RAM

if [ "$RAM" -le 1 ]; then
  SOMAX=32768
  BACKLOG=8192
  RMEM=8388608
  WMEM=8388608
  SWAPSIZE=2
elif [ "$RAM" -le 2 ]; then
  SOMAX=65535
  BACKLOG=16384
  RMEM=16777216
  WMEM=16777216
  SWAPSIZE=2
else
  SOMAX=65535
  BACKLOG=32768
  RMEM=33554432
  WMEM=33554432
  SWAPSIZE=4
fi

echo "Профиль применён"

### --- УБИРАЕМ GOMEMLIMIT ---
sed -i '/GOMEMLIMIT/d' /etc/environment 2>/dev/null || true
sed -i '/GOGC/d' /etc/environment 2>/dev/null || true

### --- SYSTEMD ОПТИМИЗАЦИИ ---
if [ "$INSTALL_TYPE" == "1" ]; then
  mkdir -p /etc/systemd/system/xray.service.d

  cat > /etc/systemd/system/xray.service.d/override.conf << 'EOF'
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=infinity
OOMScoreAdjust=-1000
Restart=always
RestartSec=3
EOF

  systemctl daemon-reload
fi

### --- SYSCTL ОПТИМИЗАЦИИ ---
cat > /etc/sysctl.d/99-xray.conf << 'EOF'
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF

sysctl --system

### --- SWAP ---
if [ $(swapon --show | wc -l) -eq 0 ]; then
  echo "Создаём swap ${SWAPSIZE}G..."
  fallocate -l "${SWAPSIZE}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAPSIZE * 1024))
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

### --- DOCKER ОБРАБОТКА ---
DOCKER_CONTAINER=""
CONFIG_PATH_HOST=""
CONFIG_PATH_CONTAINER="/etc/xray/config.json"
LOG_PATH_HOST=""
LOG_PATH_CONTAINER="/var/log/xray/access.log"

if [ "$INSTALL_TYPE" == "2" ]; then
  if ! command -v docker &> /dev/null; then
    echo "Docker не установлен!"
    exit 1
  fi

  echo "== Поиск контейнера =="

  CONTAINERS=$(docker ps --format "{{.Names}} {{.Image}}" | grep -Ei "xray|v2ray|x-ui|3x-ui" || true)

  if [ -z "$CONTAINERS" ]; then
    docker ps
    read -p "Имя контейнера: " DOCKER_CONTAINER
  else
    echo "$CONTAINERS"
    COUNT=$(echo "$CONTAINERS" | wc -l)

    if [ "$COUNT" -eq 1 ]; then
      DOCKER_CONTAINER=$(echo "$CONTAINERS" | awk '{print $1}')
    else
      i=1
      declare -a LIST
      while read -r line; do
        NAME=$(echo "$line" | awk '{print $1}')
        echo "$i) $NAME"
        LIST[$i]=$NAME
        ((i++))
      done <<< "$CONTAINERS"

      read -p "Выбор: " CHOICE
      DOCKER_CONTAINER="${LIST[$CHOICE]}"
    fi
  fi

  echo "Контейнер: $DOCKER_CONTAINER"

  # Проверка существования контейнера
  if ! docker inspect "$DOCKER_CONTAINER" &>/dev/null; then
    echo "❌ Контейнер '$DOCKER_CONTAINER' не найден"
    exit 1
  fi

  ### --- ПОИСК КОНФИГА ВНУТРИ КОНТЕЙНЕРА ---
  echo "== Поиск config.json =="

  # Проверяем несколько возможных путей внутри контейнера
  for cfg_path in /etc/xray/config.json /usr/local/etc/xray/config.json /app/config.json /config/config.json; do
    if docker exec "$DOCKER_CONTAINER" test -f "$cfg_path" 2>/dev/null; then
      CONFIG_PATH_CONTAINER="$cfg_path"
      echo "✓ Найден конфиг в контейнере: $CONFIG_PATH_CONTAINER"
      break
    fi
  done

  # Проверяем, смонтирован ли конфиг как volume/bind-mount
  MOUNT_INFO=$(docker inspect "$DOCKER_CONTAINER" --format='{{json .Mounts}}' 2>/dev/null || echo "[]")
  CONFIG_MOUNT=$(echo "$MOUNT_INFO" | jq -r --arg dest "$CONFIG_PATH_CONTAINER" '.[] | select(.Destination == $dest) | .Source' 2>/dev/null || true)

  if [ -n "$CONFIG_MOUNT" ] && [ -f "$CONFIG_MOUNT" ]; then
    echo "✓ Конфиг смонтирован с хоста: $CONFIG_MOUNT"
    CONFIG_PATH_HOST="$CONFIG_MOUNT"
  else
    echo "⚠ Конфиг не смонтирован с хоста. Будем работать через docker cp/exec"
    CONFIG_PATH_HOST=""
  fi

  # Проверяем логи
  for log_path in /var/log/xray/access.log /tmp/xray/access.log /app/logs/access.log; do
    if docker exec "$DOCKER_CONTAINER" test -f "$log_path" 2>/dev/null; then
      LOG_PATH_CONTAINER="$log_path"
      break
    fi
  done

  LOG_MOUNT=$(echo "$MOUNT_INFO" | jq -r --arg dest "$LOG_PATH_CONTAINER" '.[] | select(.Destination == $dest) | .Source' 2>/dev/null || true)
  if [ -n "$LOG_MOUNT" ] && [ -f "$LOG_MOUNT" ]; then
    LOG_PATH_HOST="$LOG_MOUNT"
  fi

  ### --- DOCKER COMPOSE PATCH ---
  echo "== Поиск docker-compose.yml =="

  COMPOSE_FILE=""
  # Ищем в текущей директории и стандартных путях
  for cf in ./docker-compose.yml ./compose.yml ~/docker-compose.yml /opt/docker-compose.yml; do
    if [ -f "$cf" ]; then
      COMPOSE_FILE="$cf"
      break
    fi
  done

  # Если не нашли, спрашиваем у пользователя
  if [ -z "$COMPOSE_FILE" ]; then
    read -p "Путь к docker-compose.yml (или пусто для пропуска): " COMPOSE_FILE
  fi

  if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
    echo "Найден: $COMPOSE_FILE"
    read -p "Пропатчить compose? (y/n): " PATCH

    if [ "$PATCH" == "y" ]; then
      cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"

      # Найти сервис с Xray
      SERVICE=$(yq e '.services | keys | .[]' "$COMPOSE_FILE" 2>/dev/null | while read -r s; do
        IMAGE=$(yq e ".services.$s.image" "$COMPOSE_FILE" 2>/dev/null)
        echo "$IMAGE" | grep -qiE "xray|v2ray|x-ui|3x-ui" && echo "$s"
      done | head -n1)

      if [ -z "$SERVICE" ]; then
        echo "❌ Сервис не найден, пробуем первый сервис..."
        SERVICE=$(yq e '.services | keys | .[0]' "$COMPOSE_FILE" 2>/dev/null)
      fi

      if [ -n "$SERVICE" ]; then
        echo "Сервис: $SERVICE"

        # Добавляем cap_add
        yq e -i ".services.$SERVICE.cap_add += [\"NET_ADMIN\", \"NET_BIND_SERVICE\"]" "$COMPOSE_FILE"

        # Добавляем ulimits
        yq e -i ".services.$SERVICE.ulimits.nofile.soft = 1048576" "$COMPOSE_FILE"
        yq e -i ".services.$SERVICE.ulimits.nofile.hard = 1048576" "$COMPOSE_FILE"

        # Добавляем sysctl для BBR
        yq e -i ".services.$SERVICE.sysctls.\"net.core.somaxconn\" = \"65535\"" "$COMPOSE_FILE"
        yq e -i ".services.$SERVICE.sysctls.\"net.ipv4.tcp_tw_reuse\" = \"1\"" "$COMPOSE_FILE"

        # Проверяем/добавляем volumes для конфига и логов
        if [ -z "$CONFIG_MOUNT" ]; then
          echo "⚠ Добавьте volume для конфига в docker-compose:"
          echo "  volumes:"
          echo "    - ./config.json:$CONFIG_PATH_CONTAINER"
        fi

        if [ -z "$LOG_MOUNT" ]; then
          echo "⚠ Для Fail2Ban добавьте volume для логов:"
          echo "  volumes:"
          echo "    - ./logs:/var/log/xray"
        fi

        echo "✓ compose обновлён"

        DIR=$(dirname "$COMPOSE_FILE")
        cd "$DIR"

        if command -v docker compose &>/dev/null; then
          docker compose up -d
        else
          docker-compose up -d
        fi
      else
        echo "❌ Не удалось определить сервис для патчинга"
      fi
    fi
  fi
fi

### --- ПОЛУЧЕНИЕ КОНФИГА ДЛЯ РЕДАКТИРОВАНИЯ ---
echo "== Подготовка config.json =="

TEMP_CONFIG="/tmp/xray-config-tune.json"

if [ "$INSTALL_TYPE" == "2" ] && [ -z "$CONFIG_PATH_HOST" ]; then
  # Копируем конфиг из контейнера
  echo "Копируем конфиг из контейнера..."
  if ! docker cp "$DOCKER_CONTAINER:$CONFIG_PATH_CONTAINER" "$TEMP_CONFIG" 2>/dev/null; then
    echo "❌ Не удалось скопировать конфиг из контейнера"
    echo "Убедитесь, что путь верный: $CONFIG_PATH_CONTAINER"
    exit 1
  fi
  XRAY_CONFIG="$TEMP_CONFIG"
elif [ -n "$CONFIG_PATH_HOST" ]; then
  XRAY_CONFIG="$CONFIG_PATH_HOST"
else
  # Host installation или ручной путь
  XRAY_CONFIG=""
  for path in /usr/local/etc/xray/config.json /etc/xray/config.json; do
    [ -f "$path" ] && XRAY_CONFIG="$path"
  done

  if [ -z "$XRAY_CONFIG" ] || [ ! -f "$XRAY_CONFIG" ]; then
    read -p "Путь к config.json: " XRAY_CONFIG
  fi

  if [ ! -f "$XRAY_CONFIG" ]; then
    echo "❌ Файл не найден: $XRAY_CONFIG"
    exit 1
  fi
fi

# Валидация JSON
if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
  echo "❌ Ошибка в JSON файле: $XRAY_CONFIG"
  exit 1
fi

### --- ОПРЕДЕЛЕНИЕ ПОРТОВ (ИСПРАВЛЕННЫЙ REGEX) ---
echo "== Определение портов =="

# Исправленный паттерн: ищем "port": <число>
DETECTED_PORTS=$(jq -r '.. | objects | .port? // empty' "$XRAY_CONFIG" 2>/dev/null | grep -E '^[0-9]+$' | sort -nu || true)

if [ -z "$DETECTED_PORTS" ]; then
  # Fallback на grep с правильным паттерном
  DETECTED_PORTS=$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" 2>/dev/null | sort -nu || true)
fi

AUTO_PORTS=""
for p in $DETECTED_PORTS; do
  AUTO_PORTS+="$p/both,"
done
AUTO_PORTS="${AUTO_PORTS%,}"

echo "Обнаружены порты: ${DETECTED_PORTS:-не найдено}"
read -p "Использовать авто-порты? (y/n): " USE_AUTO

if [ "$USE_AUTO" == "y" ] && [ -n "$AUTO_PORTS" ]; then
  PORTS="$AUTO_PORTS"
else
  read -p "Порты (формат: 443/both,80/tcp): " PORTS
fi

### --- UFW НАСТРОЙКА ---
read -p "Включить UFW? (y/n): " USE_UFW

if [ "$USE_UFW" == "y" ]; then
  echo "== Настройка UFW =="
  ufw default deny incoming
  ufw default allow outgoing
  ufw limit ssh

  IFS=',' read -ra PORT_ARRAY <<< "$PORTS"

  for entry in "${PORT_ARRAY[@]}"; do
    PORT=$(echo "$entry" | cut -d'/' -f1)
    TYPE=$(echo "$entry" | cut -d'/' -f2)

    case "$TYPE" in
      tcp)
        ufw allow "$PORT/tcp"
        ;;
      udp)
        ufw allow "$PORT/udp"
        ;;
      both|*)
        ufw allow "$PORT/tcp"
        ufw allow "$PORT/udp"
        ;;
    esac
  done

  ufw --force enable
  echo "✓ UFW настроен"
fi

### --- FAIL2BAN НАСТРОЙКА ---
read -p "Включить Fail2Ban? (y/n): " USE_F2B

if [ "$USE_F2B" == "y" ]; then
  echo "== Настройка Fail2Ban =="

  mkdir -p /etc/fail2ban/filter.d

  # Создаём фильтр для Xray
  cat > /etc/fail2ban/filter.d/xray.conf << 'EOF'
[Definition]
failregex = ^.*rejected.*from <HOST>.*$
            ^.*invalid user.*from <HOST>.*$
            ^.*authentication failed.*from <HOST>.*$
ignoreregex =
EOF

  # Определяем путь к логам
  if [ "$INSTALL_TYPE" == "2" ]; then
    if [ -n "$LOG_PATH_HOST" ]; then
      LOG_PATH="$LOG_PATH_HOST"
    else
      # Создаём временный лог-файл и настраиваем сбор через docker logs
      LOG_PATH="/var/log/xray/access.log"
      mkdir -p "$(dirname "$LOG_PATH")"
      touch "$LOG_PATH"
      
      echo "⚠ Для Docker без volume логов создайте cron-задачу:"
      echo "*/5 * * * * docker logs --tail 100 $DOCKER_CONTAINER >> $LOG_PATH 2>&1"
    fi
  else
    LOG_PATH="/var/log/xray/access.log"
  fi

  mkdir -p "$(dirname "$LOG_PATH")"
  touch "$LOG_PATH"

  # Создаём jail конфигурацию
  cat > /etc/fail2ban/jail.d/xray.local << EOF
[xray]
enabled = true
filter = xray
logpath = $LOG_PATH
maxretry = 5
bantime = 3600
findtime = 600
port = ${PORTS//\/both/,:\/tcp,:\/udp}
action = iptables-multiport[name=xray, port="${PORTS//\/both/,:\/tcp,:\/udp}", protocol=tcp]
EOF

  # Перезапускаем Fail2Ban
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    systemctl restart fail2ban
  else
    service fail2ban restart 2>/dev/null || true
  fi

  echo "✓ Fail2Ban настроен (лог: $LOG_PATH)"
fi

### --- ПРИМЕНЕНИЕ ОПТИМИЗАЦИЙ К КОНФИГУ ===
echo "== Оптимизация config.json =="

# Создаём резервную копию
if [ "$INSTALL_TYPE" == "2" ] && [ -z "$CONFIG_PATH_HOST" ]; then
  # Для Docker без mount: бэкап во временный файл
  cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
else
  cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
fi

# Применяем оптимизации через jq
jq '
  # Добавляем/обновляем настройки транспорта
  .inbounds |= map(
    if .streamSettings then
      .streamSettings.sockopt |= (
        . // {} |
        .tcpKeepAliveIdle = 300 |
        .tcpKeepAliveInterval = 15 |
        .tcpNoDelay = true
      )
    else
      .
    end
  ) |
  # Добавляем глобальные настройки если нет
  .policy = (.policy // {}) |
  .policy.system = (.policy.system // {}) |
  .policy.system.statsOutboundUplink = true |
  .policy.system.statsOutboundDownlink = true |
  # Оптимизация buffer
  .inbounds |= map(
    .bufferSize = (.bufferSize // 512)
  )
' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

echo "✓ Конфиг оптимизирован"

### --- ВОЗВРАТ КОНФИГА В КОНТЕЙНЕР (ЕСЛИ НУЖНО) ---
if [ "$INSTALL_TYPE" == "2" ] && [ -z "$CONFIG_PATH_HOST" ] && [ "$XRAY_CONFIG" == "$TEMP_CONFIG" ]; then
  echo "== Возврат конфига в контейнер =="
  
  # Валидируем перед возвратом
  if ! jq empty "$TEMP_CONFIG" 2>/dev/null; then
    echo "❌ Ошибка валидации конфига после редактирования"
    exit 1
  fi

  # Копируем обратно в контейнер
  if ! docker cp "$TEMP_CONFIG" "$DOCKER_CONTAINER:$CONFIG_PATH_CONTAINER" 2>/dev/null; then
    echo "❌ Не удалось скопировать конфиг обратно в контейнер"
    exit 1
  fi

  # Проверяем, поддерживает ли контейнер hot reload
  if docker exec "$DOCKER_CONTAINER" kill -SIGHUP 1 2>/dev/null; then
    echo "✓ Конфиг применён (SIGHUP)"
  else
    echo "✓ Конфиг обновлён. Перезапускаем контейнер..."
    docker restart "$DOCKER_CONTAINER"
  fi

  # Очищаем временный файл
  rm -f "$TEMP_CONFIG"
fi

### --- ФИНАЛ ===
echo ""
echo "==== Оптимизация завершена ===="
echo ""
echo "Рекомендации:"
if [ "$INSTALL_TYPE" == "2" ]; then
  echo "• Для стабильной работы смонтируйте config.json с хоста:"
  echo "  -v /путь/к/config.json:$CONFIG_PATH_CONTAINER"
  echo "• Для Fail2Ban смонтируйте логи:"
  echo "  -v /путь/к/logs:/var/log/xray"
  echo "• Проверьте работу: docker logs $DOCKER_CONTAINER"
else
  echo "• Проверьте статус: systemctl status xray"
  echo "• Логи: journalctl -u xray -f"
fi
echo ""
echo "Готово! 🚀"
