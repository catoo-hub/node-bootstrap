# node-bootstrap

> One-shot installer + management CLI for a Remnawave **node** with rotating SNI, wildcard TLS via Cloudflare DNS-01, selfsteal masking, and anti-DPI hardening.

---

## 🇷🇺 Русский

`node-bootstrap.sh` — production-ready bash-скрипт для развёртывания ноды Remnawave с минимумом ручной работы и максимумом защиты от DPI (в первую очередь ТСПУ).

### Что устанавливается на сервер

| Компонент | Назначение |
|---|---|
| **Базовая подготовка** | BBR, sysctl, swap, SSH hardening, UFW, fail2ban — лифт из `server-bootstrap.sh` |
| **mobile443-filter** | анти-скан фильтр на 443 (режим `node`) |
| **Docker + Compose v2** | с автоматическим fallback на `docker.io` если `get.docker.com` блокируется в регионе |
| **acme.sh + Cloudflare DNS-01** | wildcard-сертификат `*.node.example.com`, обновление раз в 60 дней |
| **Nginx (selfsteal)** | в контейнере, биндится **только** на `unix:/dev/shm/nginx.sock`, проксирует на статическую заглушку |
| **rw-node** (`ghcr.io/remnawave/node:latest`) | под нейтральным именем `web-node` в `/opt/web/node`, `network_mode: host` |
| **3×3 SNI-ротатор** | держит 3 валидных SNI одновременно, каждые 3 дня заменяет самый старый (жизнь строки = 9 дней) |
| **Node Exporter + Grafana dashboard** | опционально |
| **`nstp` CLI** | управляющий инструмент в `/usr/local/bin/nstp` |

### Архитектура соединения

```
client → :443/IP (rw-node → Xray Reality)
            ├─ Reality magic (UUID+pbk ok)     →  VLESS user traffic
            └─ обычный TLS handshake (любой SNI) → unix:/dev/shm/nginx.sock
                                                    ↓
                                                  Nginx (TLS на *.node.example.com)
                                                    ↓
                                                  статичный HTML stub
```

В Xray Reality `serverNames` живёт **3 строки одновременно** — текущая и две предыдущие. Сертификат wildcard, поэтому любой свежий поддомен сразу валиден.

### Стратегия защиты от блокировок SNI

Гипотеза: ТСПУ блокирует **конкретные строки SNI**, когда детектит на них Reality-трафик. Если SNI заблокирован — новые соединения с этой строкой висят / RST, но **другие SNI на той же ноде продолжают работать**.

Ротатор `nstp sni rotate` (по умолчанию — крон раз в 3 дня):

1. Генерирует новый поддомен в стиле «обычный сабдомен»: `api`, `cdn`, `docs`, `web`, `static`, `edge-3-fra` и т.п.
2. Добавляет его в `serverNames` inbound через `PATCH /api/config-profiles/inbounds/{uuid}` (новый SNI становится первым → новые подписки получают его)
3. Удаляет самый старый из `serverNames`
4. Создаёт host через `POST /api/hosts` с `tag: AUTOSNI:<имя_ноды>` и новым SNI
5. Удаляет старейший host с тем же тегом (старше 9 дней)
6. Дёргает `POST /api/nodes/{uuid}/actions/restart` — нода подтягивает обновлённый конфиг из панели

Старые подписки клиентов с уже выданным SNI продолжают работать, пока этот SNI не выйдет из активной тройки.

**FP по умолчанию = `randomized`** (uTLS генерирует разный fingerprint на каждое подключение). Если зацепят конкретный FP — `nstp fp set <chrome|firefox|safari|randomized>` массово обновит все AUTO-SNI хосты.

### Что нужно подготовить заранее

1. **DNS-зона в Cloudflare** для базового домена (`example.com`), под который пойдёт wildcard `*.node.example.com`
2. **Cloudflare API Token** со скоупом `Zone:DNS:Edit` для конкретной зоны (Cloudflare Dashboard → My Profile → API Tokens)
3. **Remnawave Panel URL** и **Panel API Token** (Settings → API Tokens)
4. **Node KEY** из панели (Nodes → Create new node → скопировать SECRET_KEY)

### Установка

```bash
# Интерактивно (с меню и подсказками)
bash <(curl -Ls https://raw.githubusercontent.com/catoo-hub/node-bootstrap/main/node-bootstrap.sh)

# Неинтерактивно
sudo bash node-bootstrap.sh \
    --domain example.com \
    --cf-token <CLOUDFLARE_TOKEN> \
    --panel-url https://panel.example.com \
    --panel-token <PANEL_API_TOKEN> \
    --node-key <NODE_SECRET_KEY> \
    --non-interactive
```

После установки в системе появится команда `nstp`:

```bash
nstp                    # интерактивное меню
nstp status             # health всех контейнеров + текущие SNI
nstp logs [service]     # docker compose logs -f (node|nginx|all)
nstp sni list           # текущие активные SNI и время до следующей ротации
nstp sni rotate         # вручную провернуть ротацию сейчас
nstp cert status        # сроки сертификатов
nstp cert renew         # принудительно обновить
nstp fp set <fp>        # массово сменить fingerprint у AUTO-SNI хостов
nstp update             # docker compose pull + restart
nstp uninstall          # снести всё с вопросом подтверждения
```

### CLI-флаги установщика

| Флаг | Описание |
|---|---|
| `--domain <d>` | базовый домен, под который выпускается wildcard (`example.com` → `*.node.example.com`) |
| `--node-name <n>` | имя ноды, попадает в тег hosts (`AUTOSNI:NODE01`). По умолчанию — hostname |
| `--cf-token <t>` | Cloudflare API Token со scope `Zone:DNS:Edit` |
| `--panel-url <u>` | URL панели Remnawave (`https://panel.example.com`) |
| `--panel-token <t>` | API Token из панели |
| `--node-key <k>` | SECRET_KEY ноды из панели |
| `--rotation-days <n>` | каденс ротации в днях (default: `3`) |
| `--active-snis <n>` | сколько SNI держать одновременно (default: `3`) |
| `--sni-style <s>` | стиль имён: `words` \| `cdn` \| `hex` (default: `cdn`) |
| `--fp <fp>` | default fingerprint: `randomized` \| `chrome` \| ... (default: `randomized`) |
| `--with-monitoring` | поставить Node Exporter + Grafana dashboard |
| `--dry-run` | симуляция, ничего не меняет |
| `--verbose` | debug-уровень логов |
| `--non-interactive`, `-y` | без интерактивных вопросов |
| `--status` | вывести состояние и выйти |
| `--uninstall` | интерактивное удаление |
| `--help` | справка |

### Что находится на диске после установки

```
/opt/web/
├── node/                       — rw-node (контейнер 'web-node')
│   ├── docker-compose.yml
│   └── .env                    — NODE_PORT, SECRET_KEY (mode 600)
├── nginx/                      — selfsteal
│   ├── docker-compose.yml
│   ├── nginx.conf
│   ├── conf.d/site.conf
│   ├── html/                   — статичная заглушка
│   ├── ssl/                    — wildcard cert + key (mode 600)
│   └── logs/
└── state/
    ├── sni.json                — текущие 3 активных SNI + host UUIDs
    ├── config.env              — параметры установки
    └── version

/etc/cron.d/web-sni-rotate      — крон каждое утро (но физически ротация раз в 3 дня)
/usr/local/bin/nstp             — CLI
/var/log/node-bootstrap.log
```

Все каталоги названы нейтрально (`web` / `node`), без слов `remnawave` / `xray` / `vless` — только то, что внутри `docker-compose.yml` (имя образа `ghcr.io/remnawave/node:latest`) обязательно остаётся.

### Удаление

```bash
nstp uninstall               # или
bash node-bootstrap.sh --uninstall
```

Останавливает контейнеры, удаляет `/opt/web/*`, чистит docker volumes, убирает кроны и CLI. Backup-папка `/var/backups/node-bootstrap/` остаётся (чтобы можно было откатиться руками).

---

## English

(coming soon — see Russian section above for full reference)

---

## License

MIT — see [LICENSE](./LICENSE).

## Related

- [`catoo-hub/server-bootstrap`](https://github.com/catoo-hub/server-bootstrap) — sibling project for relay/gate/base server setup.
- [Remnawave docs](https://docs.rw/) — panel API reference.
