#!/usr/bin/env bash

set -euo pipefail

echo "==== Xray Ultimate Optimizer (0.4-beta) ===="

### --- ПРОВЕРКА ROOT ---
if [ "$EUID" -ne 0 ]; then
  echo "Запусти как root"
  exit 1
fi

### --- УСТАНОВКА ЗАВИСИМОСТЕЙ ---
echo "== Установка зависимостей =="

apt update -y
apt install -y curl jq ufw fail2ban ca-certificates gnupg lsb-release

### --- УСТАНОВКА DOCKER (ОФИЦИАЛЬНЫЙ СПОСОБ) ---
echo "== Установка Docker =="

curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm -f get-docker.sh
usermod -aG docker root 2>/dev/null || true

echo "✓ Docker установлен: $(docker --version)"

### --- УСТАНОВКА yq (YAML парсер) ---
if ! command -v yq &> /dev/null; then
  echo "Устанавливаем yq..."
  YQ_VERSION=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v4.40.5")
  YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"
  curl -sL "$YQ_URL" -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
fi

### --- ВЫБОР УСТАНОВКИ ---
echo ""
echo "Где установлен Xray?"
echo "1) Host (systemd)"
echo "2) Docker (standalone)"
echo "3) Панель управления (X-UI, 3X-UI, Remnawave и др.)"
read -p "Выбор [1-3]: " INSTALL_TYPE

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

### --- ПЕРЕМЕННЫЕ ---
DOCKER_CONTAINER=""
CONFIG_PATH_HOST=""
CONFIG_PATH_CONTAINER="/etc/xray/config.json"
LOG_PATH_HOST=""
LOG_PATH_CONTAINER="/var/log/xray/access.log"
COMPOSE_DIR=""
PANEL_TYPE=""

### --- DOCKER ОБРАБОТКА ---
if [ "$INSTALL_TYPE" == "2" ] || [ "$INSTALL_TYPE" == "3" ]; then
  echo "== Поиск контейнера =="

  CONTAINERS=$(docker ps --format "{{.Names}} {{.Image}}" | grep -Ei "xray|v2ray|x-ui|3x-ui|hiddify|marzban" || true)

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

  if ! docker inspect "$DOCKER_CONTAINER" &>/dev/null; then
    echo "❌ Контейнер '$DOCKER_CONTAINER' не найден"
    exit 1
  fi

  ### --- ОПРЕДЕЛЕНИЕ ТИПА ПАНЕЛИ ---
  if [ "$INSTALL_TYPE" == "3" ]; then
    CONTAINER_IMAGE=$(docker inspect "$DOCKER_CONTAINER" --format='{{.Config.Image}}' 2>/dev/null)
    
    if echo "$CONTAINER_IMAGE" | grep -qiE "x-ui|vaxilu"; then
      PANEL_TYPE="X-UI"
    elif echo "$CONTAINER_IMAGE" | grep -qiE "3x-ui|3x-ui"; then
      PANEL_TYPE="3X-UI"
    elif echo "$CONTAINER_IMAGE" | grep -qiE "hiddify"; then
      PANEL_TYPE="Hiddify"
    elif echo "$CONTAINER_IMAGE" | grep -qiE "marzban"; then
      PANEL_TYPE="Marzban"
    else
      PANEL_TYPE="Unknown Panel"
    fi
    
    echo "✓ Обнаружена панель: $PANEL_TYPE"
    echo "⚠ config.json управляется панелью и не должен редактироваться напрямую!"
  fi

  ### --- ПОЛУЧАЕМ ИНФОРМАЦИЮ О КОНТЕЙНЕРЕ ---
  MOUNT_INFO=$(docker inspect "$DOCKER_CONTAINER" --format='{{json .Mounts}}' 2>/dev/null || echo "[]")
  
  # Для панелей не ищем docker-compose, т.к. обычно устанавливаются скриптом
  if [ "$INSTALL_TYPE" == "2" ]; then
    COMPOSE_FILE=$(docker inspect "$DOCKER_CONTAINER" --format='{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || echo "")
    
    if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE/docker-compose.yml" ]; then
      COMPOSE_FILE="$COMPOSE_FILE/docker-compose.yml"
    elif [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE/compose.yml" ]; then
      COMPOSE_FILE="$COMPOSE_FILE/compose.yml"
    else
      COMPOSE_FILE=""
    fi

    if [ -z "$COMPOSE_FILE" ]; then
      for cf in ./docker-compose.yml ./compose.yml ~/docker-compose.yml /opt/docker-compose.yml; do
        if [ -f "$cf" ]; then
          COMPOSE_FILE="$cf"
          break
        fi
      done
    fi

    if [ -z "$COMPOSE_FILE" ]; then
      read -p "Путь к docker-compose.yml (или пусто для пропуска): " COMPOSE_FILE
    fi

    if [ -n "$COMPOSE_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
      COMPOSE_DIR=$(dirname "$COMPOSE_FILE")
      echo "✓ Найден compose: $COMPOSE_FILE"
      echo "✓ Директория: $COMPOSE_DIR"
    fi
  fi

  ### --- ПОИСК КОНФИГА (ТОЛЬКО ДЛЯ STANDALONE DOCKER) ---
  if [ "$INSTALL_TYPE" == "2" ]; then
    echo "== Проверка config.json =="

    for cfg_path in /etc/xray/config.json /usr/local/etc/xray/config.json /app/config.json /config/config.json; do
      if docker exec "$DOCKER_CONTAINER" test -f "$cfg_path" 2>/dev/null; then
        CONFIG_PATH_CONTAINER="$cfg_path"
        break
      fi
    done

    CONFIG_MOUNT=$(echo "$MOUNT_INFO" | jq -r --arg dest "$CONFIG_PATH_CONTAINER" '.[] | select(.Destination == $dest) | .Source' 2>/dev/null || true)

    if [ -n "$CONFIG_MOUNT" ] && [ -f "$CONFIG_MOUNT" ]; then
      echo "✓ Конфиг смонтирован с хоста: $CONFIG_MOUNT"
      CONFIG_PATH_HOST="$CONFIG_MOUNT"
    else
      echo "⚠ Конфиг НЕ смонтирован с хоста"
      echo "⚠ Без volume изменения config.json пропадут при пересоздании контейнера!"
      echo ""
      
      read -p "Добавить volume для config.json в docker-compose.yml? (y/n): " ADD_VOLUME
      
      if [ "$ADD_VOLUME" == "y" ] && [ -n "$COMPOSE_FILE" ]; then
        CONFIG_PATH_HOST="$COMPOSE_DIR/config.json"
        
        echo "Копируем конфиг из контейнера на хост..."
        if ! docker cp "$DOCKER_CONTAINER:$CONFIG_PATH_CONTAINER" "$CONFIG_PATH_HOST" 2>/dev/null; then
          echo "❌ Не удалось скопировать конфиг"
          exit 1
        fi
        
        echo "✓ Конфиг сохранён: $CONFIG_PATH_HOST"
        
        SERVICE=$(yq e '.services | keys | .[]' "$COMPOSE_FILE" 2>/dev/null | while read -r s; do
          IMAGE=$(yq e ".services.$s.image" "$COMPOSE_FILE" 2>/dev/null)
          echo "$IMAGE" | grep -qiE "xray|v2ray|x-ui|3x-ui" && echo "$s"
        done | head -n1)

        if [ -z "$SERVICE" ]; then
          SERVICE=$(yq e '.services | keys | .[0]' "$COMPOSE_FILE" 2>/dev/null)
        fi

        if [ -n "$SERVICE" ]; then
          echo "Сервис: $SERVICE"
          yq e -i ".services.$SERVICE.volumes += [\"./config.json:$CONFIG_PATH_CONTAINER\"]" "$COMPOSE_FILE"
          echo "✓ Volume добавлен в docker-compose.yml"
        fi
      elif [ "$ADD_VOLUME" == "y" ] && [ -z "$COMPOSE_FILE" ]; then
        echo "❌ docker-compose.yml не найден. Невозможно добавить volume."
        exit 1
      else
        echo "⚠ Продолжаем без volume. Изменения config.json не сохранятся."
      fi
    fi

    ### --- ПАТЧИНГ docker-compose.yml ---
    if [ -n "$COMPOSE_FILE" ]; then
      echo "== Оптимизация docker-compose.yml =="
      read -p "Пропатчить compose? (y/n): " PATCH

      if [ "$PATCH" == "y" ]; then
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%Y%m%d%H%M%S)"

        SERVICE=$(yq e '.services | keys | .[]' "$COMPOSE_FILE" 2>/dev/null | while read -r s; do
          IMAGE=$(yq e ".services.$s.image" "$COMPOSE_FILE" 2>/dev/null)
          echo "$IMAGE" | grep -qiE "xray|v2ray|x-ui|3x-ui" && echo "$s"
        done | head -n1)

        if [ -z "$SERVICE" ]; then
          SERVICE=$(yq e '.services | keys | .[0]' "$COMPOSE_FILE" 2>/dev/null)
        fi

        if [ -n "$SERVICE" ]; then
          echo "Сервис: $SERVICE"

          yq e -i ".services.$SERVICE.cap_add += [\"NET_ADMIN\", \"NET_BIND_SERVICE\"]" "$COMPOSE_FILE"
          yq e -i ".services.$SERVICE.ulimits.nofile.soft = 1048576" "$COMPOSE_FILE"
          yq e -i ".services.$SERVICE.ulimits.nofile.hard = 1048576" "$COMPOSE_FILE"
          yq e -i ".services.$SERVICE.sysctls.\"net.core.somaxconn\" = \"65535\"" "$COMPOSE_FILE"
          yq e -i ".services.$SERVICE.sysctls.\"net.ipv4.tcp_tw_reuse\" = \"1\"" "$COMPOSE_FILE"

          LOG_MOUNT=$(echo "$MOUNT_INFO" | jq -r --arg dest "$LOG_PATH_CONTAINER" '.[] | select(.Destination == $dest) | .Source' 2>/dev/null || true)
          
          if [ -z "$LOG_MOUNT" ]; then
            read -p "Добавить volume для логов (нужно для Fail2Ban)? (y/n): " ADD_LOG_VOLUME
            if [ "$ADD_LOG_VOLUME" == "y" ]; then
              mkdir -p "$COMPOSE_DIR/logs"
              yq e -i ".services.$SERVICE.volumes += [\"./logs:/var/log/xray\"]" "$COMPOSE_FILE"
              LOG_PATH_HOST="$COMPOSE_DIR/logs/access.log"
              echo "✓ Volume для логов добавлен"
            fi
          fi

          echo "✓ compose обновлён"

          cd "$COMPOSE_DIR"
          docker compose up -d
          echo "✓ Контейнер пересоздан"
        fi
      fi
    fi
  fi

  ### --- ДЛЯ ПАНЕЛЕЙ ---
  if [ "$INSTALL_TYPE" == "3" ]; then
    echo ""
    echo "== Информация о панели =="
    
    # Пробуем найти порт панели
    PANEL_PORT=$(docker port "$DOCKER_CONTAINER" 2>/dev/null | grep -oP ':\K\d+' | head -n1 || echo "не определён")
    echo "• Порт панели: $PANEL_PORT"
    echo "• Конфигурация хранится в базе данных панели"
    echo "• Для изменений используйте веб-интерфейс панели"
    echo ""
    
    # Для некоторых панелей можно получить конфиг через API или exec
    case "$PANEL_TYPE" in
      "X-UI"|"3X-UI")
        echo "• Для X-UI/3X-UI: настройки в /etc/x-ui/x-ui.db (SQLite)"
        echo "• Порты можно изменить через веб-интерфейс"
        ;;
      "Hiddify")
        echo "• Для Remnawave: используйте панель управления https://panel_domain"
        ;;
      "Marzban")
        echo "• Для Marzban: конфигурация в /opt/marzban/.env"
        ;;
    esac
    
    # Пробуем найти логи
    for log_path in /var/log/xray/access.log /tmp/xray/access.log /app/logs/access.log /var/log/x-ui/access.log; do
      if docker exec "$DOCKER_CONTAINER" test -f "$log_path" 2>/dev/null; then
        LOG_PATH_CONTAINER="$log_path"
        break
      fi
    done

    LOG_MOUNT=$(echo "$MOUNT_INFO" | jq -r --arg dest "$LOG_PATH_CONTAINER" '.[] | select(.Destination == $dest) | .Source' 2>/dev/null || true)
    if [ -n "$LOG_MOUNT" ] && [ -f "$LOG_MOUNT" ]; then
      LOG_PATH_HOST="$LOG_MOUNT"
    fi
  fi
fi

### --- ПОЛУЧЕНИЕ КОНФИГА ДЛЯ РЕДАКТИРОВАНИЯ ---
echo "== Подготовка config.json =="

if [ "$INSTALL_TYPE" == "3" ]; then
  echo "⚠ РЕЖИМ ПАНЕЛИ УПРАВЛЕНИЯ"
  echo ""
  echo "config.json генерируется панелью динамически и не должен редактироваться вручную."
  echo "Все изменения будут перезаписаны панелью при следующем обновлении конфигурации."
  echo ""
  read -p "Пропустить оптимизацию config.json? (y/n): " SKIP_CONFIG
  
  if [ "$SKIP_CONFIG" == "y" ]; then
    XRAY_CONFIG=""
    echo "✓ Оптимизация config.json пропущена"
  else
    # Если пользователь всё равно хочет попробовать
    echo "⚠ Внимание: изменения могут быть перезаписаны панелью!"
    read -p "Путь к config.json (если знаете): " XRAY_CONFIG
    
    if [ -n "$XRAY_CONFIG" ] && [ ! -f "$XRAY_CONFIG" ]; then
      echo "❌ Файл не найден: $XRAY_CONFIG"
      XRAY_CONFIG=""
    fi
  fi
elif [ "$INSTALL_TYPE" == "2" ]; then
  if [ -n "$CONFIG_PATH_HOST" ] && [ -f "$CONFIG_PATH_HOST" ]; then
    XRAY_CONFIG="$CONFIG_PATH_HOST"
  else
    echo "⚠ config.json не доступен на хосте"
    read -p "Пропустить оптимизацию config.json? (y/n): " SKIP_CONFIG
    
    if [ "$SKIP_CONFIG" == "y" ]; then
      XRAY_CONFIG=""
    else
      read -p "Путь к config.json: " XRAY_CONFIG
      if [ ! -f "$XRAY_CONFIG" ]; then
        echo "❌ Файл не найден: $XRAY_CONFIG"
        XRAY_CONFIG=""
      fi
    fi
  fi
else
  # Host installation
  XRAY_CONFIG=""
  for path in /usr/local/etc/xray/config.json /etc/xray/config.json; do
    [ -f "$path" ] && XRAY_CONFIG="$path"
  done

  if [ -z "$XRAY_CONFIG" ] || [ ! -f "$XRAY_CONFIG" ]; then
    read -p "Путь к config.json: " XRAY_CONFIG
  fi

  if [ ! -f "$XRAY_CONFIG" ]; then
    echo "❌ Файл не найден: $XRAY_CONFIG"
    XRAY_CONFIG=""
  fi
fi

# Валидация JSON если файл указан
if [ -n "$XRAY_CONFIG" ]; then
  if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
    echo "❌ Ошибка в JSON файле: $XRAY_CONFIG"
    XRAY_CONFIG=""
  fi
fi

### --- ОПРЕДЕЛЕНИЕ ПОРТОВ ---
echo "== Определение портов =="

DETECTED_PORTS=""

if [ -n "$XRAY_CONFIG" ]; then
  DETECTED_PORTS=$(jq -r '.. | objects | .port? // empty' "$XRAY_CONFIG" 2>/dev/null | grep -E '^[0-9]+$' | sort -nu || true)
  
  if [ -z "$DETECTED_PORTS" ]; then
    DETECTED_PORTS=$(grep -oP '"port"\s*:\s*\K[0-9]+' "$XRAY_CONFIG" 2>/dev/null | sort -nu || true)
  fi
fi

# Для панелей пробуем получить порты из контейнера
if [ "$INSTALL_TYPE" == "3" ] && [ -z "$DETECTED_PORTS" ]; then
  echo "Получаем порты из контейнера..."
  DETECTED_PORTS=$(docker port "$DOCKER_CONTAINER" 2>/dev/null | grep -oP ':\K\d+' | sort -nu | tr '\n' ' ' || true)
fi

AUTO_PORTS=""
for p in $DETECTED_PORTS; do
  AUTO_PORTS+="$p/both,"
done
AUTO_PORTS="${AUTO_PORTS%,}"

echo "Обнаружены порты: ${DETECTED_PORTS:-не найдено}"

if [ -n "$AUTO_PORTS" ]; then
  read -p "Использовать авто-порты? (y/n): " USE_AUTO
  
  if [ "$USE_AUTO" == "y" ]; then
    PORTS="$AUTO_PORTS"
  else
    read -p "Порты (формат: 443/both,80/tcp): " PORTS
  fi
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

  if [ -n "$PORTS" ]; then
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
  fi

  ufw --force enable
  echo "✓ UFW настроен"
fi

### --- FAIL2BAN НАСТРОЙКА ---
read -p "Включить Fail2Ban? (y/n): " USE_F2B

if [ "$USE_F2B" == "y" ]; then
  echo "== Настройка Fail2Ban =="

  mkdir -p /etc/fail2ban/filter.d

  cat > /etc/fail2ban/filter.d/xray.conf << 'EOF'
[Definition]
failregex = ^.*rejected.*from <HOST>.*$
            ^.*invalid user.*from <HOST>.*$
            ^.*authentication failed.*from <HOST>.*$
ignoreregex =
EOF

  if [ "$INSTALL_TYPE" == "2" ] || [ "$INSTALL_TYPE" == "3" ]; then
    if [ -n "$LOG_PATH_HOST" ]; then
      LOG_PATH="$LOG_PATH_HOST"
    else
      LOG_PATH="/var/log/xray/access.log"
      mkdir -p "$(dirname "$LOG_PATH")"
      touch "$LOG_PATH"
      
      if [ -n "$DOCKER_CONTAINER" ]; then
        echo "⚠ Для Docker создайте cron-задачу для сбора логов:"
        echo "*/5 * * * * docker logs --tail 100 $DOCKER_CONTAINER >> $LOG_PATH 2>&1"
        echo ""
        read -p "Создать cron-задачу автоматически? (y/n): " CREATE_CRON
        
        if [ "$CREATE_CRON" == "y" ]; then
          CRON_JOB="*/5 * * * * docker logs --tail 100 $DOCKER_CONTAINER >> $LOG_PATH 2>&1"
          (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
          echo "✓ Cron-задача добавлена"
        fi
      fi
    fi
  else
    LOG_PATH="/var/log/xray/access.log"
  fi

  mkdir -p "$(dirname "$LOG_PATH")"
  touch "$LOG_PATH"

  if [ -n "$PORTS" ]; then
    PORT_FILTER="${PORTS//\/both/,:\/tcp,:\/udp}"
  else
    PORT_FILTER="all"
  fi

  cat > /etc/fail2ban/jail.d/xray.local << EOF
[xray]
enabled = true
filter = xray
logpath = $LOG_PATH
maxretry = 5
bantime = 3600
findtime = 600
port = $PORT_FILTER
action = iptables-multiport[name=xray, port="$PORT_FILTER", protocol=tcp]
EOF

  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    systemctl restart fail2ban
  else
    service fail2ban restart 2>/dev/null || true
  fi

  echo "✓ Fail2Ban настроен (лог: $LOG_PATH)"
fi

### --- ПРИМЕНЕНИЕ ОПТИМИЗАЦИЙ К КОНФИГУ ---
if [ -n "$XRAY_CONFIG" ]; then
  echo "== Оптимизация config.json =="

  cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

  jq '
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
    .policy = (.policy // {}) |
    .policy.system = (.policy.system // {}) |
    .policy.system.statsOutboundUplink = true |
    .policy.system.statsOutboundDownlink = true |
    .inbounds |= map(
      .bufferSize = (.bufferSize // 512)
    )
  ' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" && mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

  echo "✓ Конфиг оптимизирован"

  ### --- ПЕРЕЗАПУСК КОНТЕЙНЕРА (ЕСЛИ DOCKER) ---
  if [ "$INSTALL_TYPE" == "2" ]; then
    echo "== Перезапуск контейнера =="
    
    if ! jq empty "$XRAY_CONFIG" 2>/dev/null; then
      echo "❌ Ошибка валидации конфига после редактирования"
      echo "Восстанавливаем из бэкапа..."
      cp "${XRAY_CONFIG}.bak."* "$XRAY_CONFIG" 2>/dev/null || true
    else
      docker restart "$DOCKER_CONTAINER"
      echo "✓ Контейнер перезапущен"
    fi
  fi
else
  echo "⚠ Оптимизация config.json пропущена"
fi

### --- ФИНАЛ ---
echo ""
echo "==== Оптимизация завершена ===="
echo ""

case "$INSTALL_TYPE" in
  1)
    echo "Host (systemd):"
    echo "• Проверьте статус: systemctl status xray"
    echo "• Логи: journalctl -u xray -f"
    ;;
  2)
    echo "Docker (standalone):"
    if [ -n "$CONFIG_PATH_HOST" ]; then
      echo "• config.json на хосте: $CONFIG_PATH_HOST"
    fi
    if [ -n "$LOG_PATH_HOST" ]; then
      echo "• Логи на хосте: $LOG_PATH_HOST"
    fi
    if [ -n "$COMPOSE_DIR" ]; then
      echo "• Управление: cd $COMPOSE_DIR && docker compose up -d"
    fi
    ;;
  3)
    echo "Панель управления ($PANEL_TYPE):"
    echo "• config.json управляется панелью (не редактируйте вручную)"
    echo "• Для изменений используйте веб-интерфейс панели"
    if [ -n "$DOCKER_CONTAINER" ]; then
      echo "• Логи: docker logs $DOCKER_CONTAINER"
    fi
    echo "• Системные оптимизации применены ✅"
    ;;
esac

echo ""
echo "Готово! 🚀"
