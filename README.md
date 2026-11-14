# ssb-xgrpc

VLESS/TRJ по **XHTTP (HTTP/2)** и **gRPC** для нод Secret-Sing-Box — отдельные
схемы от классической WS и от naive.

## Схемы

| Схема | Транспорт sing-box | Порт (по умолчанию) | TLS |
|---|---|---|---|
| XHTTP | `http` (HTTP/2) | 2080 | LE-сертификат домена |
| gRPC | `grpc` | 2081 | LE-сертификат домена |

Обе живут на **отдельных портах с прямым TLS** (nginx на 443 не трогается — схемы
не конфликтуют с классической WS-нодой). В проде при желании их можно вынести на
443 через nginx (grpc_pass / proxy_pass h2) — как в Схемах B/C/4.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-xgrpc/main/install.sh | bash
```

## Использование

### 1. Добавить схему на ноду

```bash
ssb-xgrpc-patch apply xhttp   # XHTTP на 2080/tcp
ssb-xgrpc-patch apply grpc    # gRPC на 2081/tcp
ssb-xgrpc-patch status        # что настроено
ssb-xgrpc-patch remove xhttp  # убрать схему
```

### 2. Выдать конфиги заказа (VLESS + TRJ)

```bash
ssb-xgrpc-add ORDER-123456 10 xhttp   # 20 конфигов (10 VLESS + 10 TRJ) по XHTTP
ssb-xgrpc-add ORDER-123456 10 grpc    # 20 конфигов по gRPC
```

На выходе — JSON-конфиги со сплит-маршрутизацией (те же 32 rule-sets, что в
ssb-naive: реклама/DoH → reject; рунет/банки/apps/торренты → direct; AI → proxy;
остальное → proxy), ссылками через секрет-каталог ноды.

## Требования

* sing-box >= 1.9; проверено на 1.14.x;
* действующий LE-сертификат домена;
* открытые TCP-порты 2080/2081 (или свои);
* корневой доступ.

## Клиенты

XHTTP (HTTP/2): Karing, Hiddify, mihomo, sing-box.
gRPC: Karing, Hiddify, mihomo, sing-box, NekoBox.

## Примечания

* Трафик заказа идёт через **персональный OUT** (auth_user-правило) — политика
  «каждый заказ = свой OUT»;
* на ноде создаются inbound'ы `trojan-xhttp`/`vless-xhttp` (или `…-grpc`) и
  seed-пользователь (sing-box не принимает пустой `users`);
* бэкапы конфига: `/root/sb-config-backup-*.json` (10 последних);
* журнал: `/root/ssb-orders.log`.
