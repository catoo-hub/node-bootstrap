# node-bootstrap

> Production-ready installer + management CLI for Remnawave node profiles: a normal multi-SNI rotating node, or a WireGuard connector node for BS wg-relay.

## Install Profiles

`node-bootstrap.sh` has two first-class profiles:

| Profile | Use case | What it installs |
|---|---|---|
| `multi-sni-rotator` | Normal public node | Reality TCP, Reality gRPC, XHTTP, Hysteria2, nginx selfsteal, wildcard cert/DNS, rotating SNI hosts |
| `wg-connector` | WireGuard connector node for BS relay scenarios | WireGuard server, one VLESS/raw/Reality inbound on `10.66.66.1:9443`, one host. Host publication can be `client-wg` or `relay-tcp`. |

`multi-sni-rotator` is the default. It keeps the older behavior.

`wg-connector` intentionally skips nginx, wildcard DNS, wildcard certs, XHTTP/Hysteria/gRPC extra transports, SNI rotation, cert renew helpers, and nginx fail2ban/logrotate. `nstp` reads `NODE_PROFILE` from `/opt/web/state/config.env` and hides/disables SNI/cert/fingerprint/test tools in this profile.

### Normal Multi-SNI Node

```bash
bash <(curl -Ls https://raw.githubusercontent.com/catoo-hub/node-bootstrap/main/node-bootstrap.sh) \
  --domain node.example.com \
  --cf-token cf_xxx \
  --panel-url https://panel.example.com \
  --panel-token rw_xxx \
  --country NL \
  --hosting 1CENT \
  --profile multi-sni-rotator \
  -y
```

### WG Connector Node

```bash
bash <(curl -Ls https://raw.githubusercontent.com/catoo-hub/node-bootstrap/main/node-bootstrap.sh) \
  --domain cache.example.com \
  --cf-token cf_xxx \
  --panel-url https://panel.example.com \
  --panel-token rw_xxx \
  --country RU \
  --hosting AEZA \
  --profile wg-connector \
  --wg-allow-from <BS_RELAY_IP> \
  --wg-mtu 760 \
  -y
```

Legacy compatibility: `--wg-bridge-profile` is still accepted as an alias for `--profile wg-connector`, but new installs should use `--profile wg-connector`.

For old client-side WG (`--wg-host-mode client-wg`, default), the Remnawave host points to `10.66.66.1:9443` and uses raw Reality with host `sockopt` containing:

```json
{"dialerProxy":"wg-out"}
```

The generated XRAY_JSON template contains the client-side WireGuard outbound (`wg-out`). Remnawave adds the host-generated `proxy` outbound itself.

For `server-bootstrap --mode xray-wg-relay`, use relay-side TCP publication instead:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/catoo-hub/node-bootstrap/main/node-bootstrap.sh) \
  --domain cache.example.com \
  --cf-token cf_xxx \
  --panel-url https://panel.example.com \
  --panel-token rw_xxx \
  --country RU \
  --hosting AEZA \
  --profile wg-connector \
  --wg-host-mode relay-tcp \
  --wg-relay-public-address <BS_RELAY_IP_OR_DOMAIN> \
  --wg-relay-public-port 443 \
  --wg-allow-from <BS_RELAY_IP> \
  --wg-mtu 760 \
  -y
```

In `relay-tcp`, the generated Remnawave host points to the BS relay address (`<BS_RELAY_IP_OR_DOMAIN>:443`) and does not attach the XRAY_JSON `wg-out` template. The BS then forwards TCP to the gate over kernel WireGuard.

---

## 🇷🇺 Русский

`node-bootstrap.sh` (v1.1.3) поднимает Remnawave-ноду «с нуля и через API»: создаёт config-profile, регистрирует ноду в панели, генерирует Reality x25519 ключи и Hysteria пароли локально, создаёт hosts в подписках, ставит ротатор SNI и CLI `nstp`. От оператора требуются только домен Cloudflare и токены панели — никаких ручных правок в UI панели.

### Что устанавливается на сервер

| Компонент | Назначение |
|---|---|
| **Base hardening** | BBR sysctl, swap, SSH harden, UFW, fail2ban |
| **Docker + Compose v2** | с fallback на `docker.io` если `get.docker.com` отдаёт 403 |
| **acme.sh + Cloudflare DNS-01** | wildcard `*.<DOMAIN>` (где `<DOMAIN>` — параметр, например `node.example.com` → `*.node.example.com`), авто-renew |
| **Nginx selfsteal** | unix-socket `/dev/shm/nginx.sock` с proxy_protocol, wildcard cert; gRPC pass через `/dev/shm/xrxh.socket` для XHTTP; default-server `ssl_reject_handshake on` |
| **rw-node** (`ghcr.io/remnawave/node:latest`) | нейтральное имя `web-node` в `/opt/web/node`, `network_mode: host` |
| **4 inbounds** | Reality TCP `:443`, Reality gRPC `:8443`, VLESS-XHTTP через unix-socket, Hysteria2 `:9443/udp` — всё в одной config-profile в панели |
| **3×3 SNI-ротатор** | каждые 3 дня обновляет `serverNames` в обоих Reality inbound'ах + создаёт 2 свежих host (TCP+gRPC), удаляет 2 самых старых |
| **WireGuard server** | опционально: `wg-web` на ноде для BS `wg-relay` и Xray `dialerProxy` |
| **`nstp` CLI** | `/usr/local/bin/nstp` — status, logs, cert, sni list/rotate, fp, update, uninstall |

### Архитектура соединения

```
client → :443/IP TCP    (rw-node Xray Reality, raw)        → SNI matches
            ├─ Reality magic ok                  →  VLESS user traffic
            └─ обычный TLS handshake             →  unix:/dev/shm/nginx.sock
                                                       ↓
                                                  Nginx (wildcard *.<DOMAIN>)
                                                       ↓
                                                  HTML stub
                                                       │
                                                       └─ /<XHTTP_PATH> → grpc_pass unix:/dev/shm/xrxh.socket → Xray XHTTP inbound

client → :8443 TCP      (rw-node Xray Reality, gRPC, serviceName=grpc-proxy)
client → :9443 UDP      (rw-node Xray Hysteria2, TLS с тем же wildcard cert через симлинк /etc/nginx/ssl/node.<DOMAIN>/)
```

Default-server в nginx с `ssl_reject_handshake on` бесшумно дропает запросы с неизвестным SNI — селфстил выглядит как одиночный сайт.

### Опциональный WG-layer для BS relay

Если нужно тестировать схему, где BS принимает только WireGuard UDP и пробрасывает его на ноду через `server-bootstrap --mode wg-relay`, включите WG-сервер на ноде:

```
client → BS_RELAY_IP:51820/udp → nft DNAT+SNAT relay → NODE_IP:51820/udp
                                             ↓
                                      wg-web на ноде
                                             ↓
                          Xray Reality по внутреннему адресу 10.66.66.1:443
```

Для этого нода создаёт:
- WireGuard interface `wg-web` с адресом `10.66.66.1/24`
- клиентский peer `10.66.66.2/32`
- `/opt/web/state/wg-client.conf`
- `/opt/web/state/xray-wireguard-outbound.json`
- `/opt/web/state/xray-wg-vless-client-example.json`
- `/opt/web/state/xray-dialerproxy-example.json`

#### WG bridge profile

Для схемы `client -> BS wg-relay UDP -> wg-web на ноде -> VLESS/raw/Reality` можно включить отдельный профиль:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/catoo-hub/node-bootstrap/main/node-bootstrap.sh) \
  --domain cache.example.com \
  --cf-token cf_xxx \
  --panel-url https://panel.example.com \
  --panel-token rw_xxx \
  --country RU \
  --hosting AEZA \
  --with-wg-server \
  --wg-bridge-profile \
  --wg-allow-from <BS_RELAY_IP> \
  --wg-mtu 760 \
  -y
```

В этом режиме скрипт:
- создаёт WireGuard server `wg-web` (`10.66.66.1/24`, client `10.66.66.2/32`, MTU `760`);
- создаёт один server-side config-profile inbound `VLESS/raw/Reality` на `0.0.0.0:9443`;
- создаёт XRAY_JSON subscription template с `wg-out`;
- создаёт host с address `10.66.66.1`, port `9443`, `securityLayer: DEFAULT`, `sockoptParams: {"dialerProxy":"wg-out"}`;
- пропускает SNI rotator, потому что bridge использует фиксированный Reality `serverNames` (`--wg-reality-sni`, default `5post-gate.x5.ru`).

Дополнительные upstream exits можно передать флагами `--wg-exit-ru-*` и `--wg-exit-fin-*`. Если их не передавать, в серверном Xray config останутся только `DIRECT`, `BLOCK` и `EXIT`.

Важно: WireGuard outbound относится к **клиентскому Xray config**, а не к серверному config-profile rw-node. Клиентский VLESS-outbound должен ходить не на публичный IP ноды, а на внутренний WG-адрес (`10.66.66.1:443` в стандартном примере или `10.66.66.1:9443` в WG bridge profile), а `sockopt.dialerProxy` должен ссылаться на `wg-out`. Для такого клиента публичная точка входа — BS relay UDP.

### Стратегия защиты от блокировок SNI

Гипотеза: ТСПУ блокирует конкретные **строки** SNI после детекта Reality-трафика. При наличии 3 одновременно валидных SNI в `serverNames` — блокировка одной не убивает ноду.

Ротатор работает **раз в день** через крон (`/etc/cron.d/web-sni-rotate` в 04:xx), но физическое изменение делает только когда прошло `ROTATION_DAYS` (по умолчанию 3) с последней ротации. Это значит:

- **3 SNI активны одновременно**, каждый живёт **9 дней**
- При ротации: новый SNI prepend'ится, самый старый дропается
- Subscription URL юзера получает **2 свежих host** (Reality TCP + gRPC с новым SNI) и **2 статичных** (XHTTP + Hysteria, без ротации)
- Существующие подписки клиентов с уже выданным SNI продолжают работать, пока не истечёт активный пул

**Fingerprint по умолчанию — `randomized`** (uTLS меняет FP на каждом подключении). Если блочат конкретный FP — `nstp fp set <fp>` сменит default; новые хосты будут с новым значением.

### Что нужно подготовить заранее

1. **DNS-зона в Cloudflare** для базового домена (`example.com`)
2. **Cloudflare API Token** со scope `Zone:DNS:Edit` для этой зоны (Cloudflare → My Profile → API Tokens → Create Token → Custom)
3. **Remnawave Panel URL** и **Panel API Token** (Settings → API Tokens — с правом создавать ноды, профили и хосты)

**Не нужно создавать ноду в панели вручную** — скрипт это делает сам через API.

### Установка

**Интерактивно:**
```bash
bash <(curl -Ls https://raw.githubusercontent.com/catoo-hub/node-bootstrap/main/node-bootstrap.sh)
```

**Неинтерактивно:**
```bash
sudo bash node-bootstrap.sh \
    --domain example.com \
    --cf-token cf_xxx \
    --panel-url https://panel.example.com \
    --panel-token rw_xxx \
    --country NL \
    --hosting 1CENT \
    --non-interactive
```

Скрипт сам:
- Определит **следующий sequence number** для страны (`NL-01`, `NL-02`, ...)  через `GET /api/nodes`
- Сгенерирует Reality x25519 keypairs через `docker run xray x25519`
- Создаст config-profile `NL-02` с 4 inbound'ами (теги: `NL-02`, `NL-02-GRPC`, `NL-02-XHTTP`, `NL-02-HYS`)
- Зарегистрирует ноду `NL-02-1CENT` с `countryCode: "NL"`
- Поднимет контейнеры
- Создаст 4 хоста в подписках с remark `[NL-02-1CENT] 🇳🇱 Netherlands · REALITY` и т.д. (40 chars max, ASCII-safe + 2 emoji-точки)
- Запустит ротатор

### CLI-флаги

| Флаг | По умолчанию | Описание |
|---|---|---|
| `--domain <d>` | (required) | базовый домен для wildcard cert |
| `--cf-token <t>` | (required) | Cloudflare API Token |
| `--panel-url <u>` | (required) | URL панели |
| `--panel-token <t>` | (required) | API token панели |
| `--country <CC>` | (required) | ISO-2 код страны |
| `--hosting <s>` | — | hosting suffix (1CENT, HETZNER) |
| `--seq <NN>` | auto-detect | sequence number |
| `--node-port <p>` | `60000` | панель ↔ нода control port |
| `--rotation-days <n>` | `3` | каденс ротации |
| `--active-snis <n>` | `3` | сколько SNI держать живыми |
| `--sni-style` | `cdn` | `cdn` \| `words` \| `hex` |
| `--fp` | `randomized` | default Xray fingerprint |
| `--with-wg-server` | off | поставить WireGuard server на ноду |
| `--wg-port <p>` | `51820` | UDP-порт WireGuard на ноде |
| `--wg-iface <name>` | `wg-web` | имя WireGuard-интерфейса |
| `--wg-server-addr <cidr>` | `10.66.66.1/24` | адрес WG-сервера на ноде |
| `--wg-client-addr <cidr>` | `10.66.66.2/32` | адрес generated WG client |
| `--wg-allow-from <ip>` | any | открыть WG в UFW только с IP BS relay |
| `--dry-run` | — | симуляция |
| `--verbose, -v` | — | debug |
| `--non-interactive, -y` | — | без вопросов |

**Fallback на существующую ноду** (если уже создана в UI):
```bash
sudo bash node-bootstrap.sh ... --existing-node --existing-node-uuid <uuid> --node-key <SECRET_KEY>
```

**Нода для BS `wg-relay`:**
```bash
sudo bash node-bootstrap.sh \
    --domain example.com \
    --cf-token cf_xxx \
    --panel-url https://panel.example.com \
    --panel-token rw_xxx \
    --country RU \
    --hosting 1CENT \
    --with-wg-server \
    --wg-allow-from <BS_RELAY_IP> \
    --non-interactive
```

### Управление после установки

```bash
nstp                    # интерактивное меню
nstp status             # контейнеры + cert + текущие SNI
nstp logs [node|nginx|all]
nstp sni list           # активные SNI + время до следующей ротации
nstp sni rotate-now     # форс-ротация прямо сейчас
nstp cert status        # сроки сертификата
nstp cert renew         # форс-renew
nstp fp set chrome      # сменить default FP (новые хосты получат)
nstp wg status          # WireGuard server status
nstp wg client          # generated wg-client.conf
nstp wg xray            # Xray wireguard outbound + full VLESS/dialerProxy пример
nstp wg refresh         # пересобрать WG/Xray client-файлы из текущего state
nstp update             # docker compose pull + up -d
nstp uninstall          # снести всё (с подтверждением)
```

### Структура на диске

```
/opt/web/
├── node/                       — rw-node (контейнер 'web-node')
│   ├── docker-compose.yml
│   └── .env                    — APP_PORT, SSL_CERT (mode 600)
├── nginx/                      — selfsteal
│   ├── docker-compose.yml
│   ├── nginx.conf
│   ├── conf.d/site.conf        — wildcard server_name + XHTTP gRPC pass + reject default
│   ├── html/index.html         — статичная заглушка
│   ├── ssl/                    — wildcard cert + key
│   └── logs/
└── state/
    ├── config.env              — параметры установки
    ├── secrets.env             — токены (CF, Panel, Node KEY)
    ├── sni.json                — текущие 3 активных SNI + UUID хостов + static_hosts
    ├── wg-client.conf          — optional WireGuard client config для BS/Xray
    ├── xray-wireguard-outbound.json
    ├── xray-wg-vless-client-example.json
    ├── xray-dialerproxy-example.json
    └── version

/etc/nginx/ssl/node.<DOMAIN>/   — симлинк → /opt/web/nginx/ssl/  (для Hysteria2 совместимости)
/etc/wireguard/wg-web.conf      — optional WireGuard server config
/etc/cron.d/web-sni-rotate      — крон ежедневно в 04:xx
/usr/local/bin/nstp             — CLI
/usr/local/bin/web-sni-rotate   — ротатор
/usr/local/bin/web-cert-renew   — renew helper
/var/log/node-bootstrap.log
/var/log/web-sni-rotate.log
```

Все каталоги названы нейтрально (`web` / `node`). В docker-compose.yml единственное упоминание upstream — `image: ghcr.io/remnawave/node:latest`.

### Что НЕ делается автоматически

- **Привязка к squads** — после установки в панели надо вручную (или через `internal-squads` API) указать, какие squads видят созданные хосты. По умолчанию хосты доступны всем.
- **Monitoring (Node Exporter + Grafana dashboard)** — планируется в v1.2

### Удаление

```bash
nstp uninstall   # или bash node-bootstrap.sh --uninstall
```

Гасит контейнеры, удаляет `/opt/web/*`, симлинки, cron и CLI. Backups в `/var/backups/node-bootstrap/` остаются.

**Внимание:** удаление не трогает ресурсы в самой панели Remnawave — config-profile, node-запись и созданные хосты надо удалить вручную через UI или API.

---

## Известные upstream-баги

### XHTTP: `?x_padding=` в `Referer` ловят некоторые WAF

В текущих версиях Xray (≤ 26.3.27) клиент XHTTP **жёстко** шлёт в каждый запрос:

```
Referer: https://<host>/<path>/?x_padding=<random>
```

Эта подпись попала в правила некоторых российских CDN-WAF (CDNvideo / CDNetworks RU / Beeline CDN edge) — они отдают `403 HIT` ещё на edge, до origin. Подробности и репродьюс: [XTLS/Xray-core#6263](https://github.com/XTLS/Xray-core/issues/6263) (closed: NOT_PLANNED).

**Когда касается нас:**
- ✅ Не касается, если трафик клиента идёт напрямую к нашему европейскому IP — никакого RU CDN на пути
- ⚠️ Касается, если ISP клиента роутит через CDNvideo/Beeline edge (зависит от провайдера и региона)

**Что сделано в скрипте на пробу:**
В XHTTP `extra` добавлены `xPaddingKey: "v"` и `xPaddingPlacement: "query"` — в текущем Xray игнорируется, но потенциально начнёт работать в будущих версиях ядра (по намёку маинтейнера).

**Если у конкретного юзера XHTTP не идёт:**
- Reality TCP / gRPC остаются основными — они работают
- Hysteria2 — UDP-альтернатива

XHTTP в подписке — как дополнительный fallback, не как основной транспорт.

---

## English

(coming — see Russian section above for full reference)

---

## License

MIT — see [LICENSE](./LICENSE).

## Related

- [`catoo-hub/server-bootstrap`](https://github.com/catoo-hub/server-bootstrap) — sibling project for relay/gate/base server setup
- [Remnawave docs](https://docs.rw/) — panel API reference
