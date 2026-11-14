#!/bin/bash
# ssb-xgrpc-patch — добавить протоколы VLESS/TRJ по XHTTP или gRPC на ноде SSB
# (вместо WS — для схемы "VLESS/TRJ + XHTTP (или gRPC) + TLS").
#
# Использование:
#   ssb-xgrpc-patch apply http [порт]   — XHTTP (HTTP/2 CONNECT) на 2080
#   ssb-xgrpc-patch apply grpc  [порт]   — gRPC на 2081
#   ssb-xgrpc-patch remove {http|grpc}  — убрать inbound'ы схемы
#   ssb-xgrpc-patch status              — что настроено
#
# Требования: sing-box >= 1.9, LE-сертификат домена, root.
# На 443 остаётся классика (WS+nginx); схемы живут на отдельных портах с прямым TLS.
set -uo pipefail

CMD="${1:-status}"
SCHEME="${2:-}"
PORT="${3:-}"
SBXCFG=/etc/sing-box/config.json
[[ -f $SBXCFG ]] || { echo "Ошибка: SSB не установлен"; exit 1; }

backup_config() {
    cp "$SBXCFG" "/root/sb-config-backup-$(date +%Y%m%d-%H%M%S).json"
    ls -1t /root/sb-config-backup-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
}

detect_domain() {
    local d=""
    [[ -f /etc/ssb-node.conf ]] && d=$(sed -n 's/^[[:space:]]*SSB_DOMAIN="\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' /etc/ssb-node.conf | head -1)
    [[ -z $d ]] && d=$(ls -d /etc/letsencrypt/live/*/ 2>/dev/null | grep -v README | head -1 | xargs -r basename)
    [[ -z $d ]] && d=$(nginx -T 2>/dev/null | grep -m1 -oP 'ssl_certificate\s+/etc/letsencrypt/live/\K[^/;]+' || true)
    echo "$d"
}

fw_open() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$1/tcp" >/dev/null 2>&1 && echo "  ufw: $1/tcp открыт"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --permanent --add-port="$1/tcp" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 && echo "  firewalld: $1/tcp открыт"
    fi
    return 0
}

reload_sbx() {
    systemctl reload sing-box.service 2>/dev/null
    sleep 5
    if systemctl is-active --quiet sing-box; then echo "  сервис перезагружен ✅"
    else
        echo "  reload не прошёл — restart"; systemctl restart sing-box.service; sleep 8; systemctl is-active sing-box
    fi
}

case "$CMD" in
apply)
    [[ "$SCHEME" == "http" || "$SCHEME" == "grpc" ]] || { echo "Использование: ssb-xgrpc-patch apply {http|grpc} [порт]"; exit 1; }
    if [[ "$SCHEME" == "http" ]]; then
        TAG="http"; PORT="${PORT:-2080}"; TP="http"
    else
        TAG="grpc"; PORT="${PORT:-2081}"; TP="grpc"
    fi
    domain=$(detect_domain)
    cert="/etc/letsencrypt/live/${domain}/fullchain.pem"; key="/etc/letsencrypt/live/${domain}/privkey.pem"
    [[ -n $domain && -f $cert && -f $key ]] || { echo "Ошибка: нет LE-сертификата"; exit 1; }
    # идемпотентность: убрать старый inbound схемы, если был
    backup_config
    jq --arg tag "trojan-${TAG}" 'del(.inbounds[] | select(.tag == $tag))' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
    jq --arg tag "vless-${TAG}" 'del(.inbounds[] | select(.tag == $tag))' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
    seed_u="seed-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    seed_p=$(head -c18 /dev/urandom | od -An -tx1 | tr -d ' \n')
    seed_uuid=$(cat /proc/sys/kernel/random/uuid)
    if [[ "$TP" == "grpc" ]]; then
        TJSON='{"type":"grpc","service_name":"'${TAG}'"}'
    else
        TJSON='{"type":"http","host":["'"${domain}"'"],"path":"/'"${TAG}"'"}'
    fi
    jq --arg tag "trojan-${TAG}" --argjson port "$PORT" --arg d "$domain" \
       --arg cu "$seed_u" --arg cp "$seed_p" --arg cert "$cert" --arg key "$key" --argjson tp "$TJSON" '
        .inbounds += [{
            "type":"trojan","tag":$tag,"listen":"::","listen_port":$port,
            "users":[{"name":$cu,"password":$cp}],
            "tls":{"enabled":true,"server_name":$d,"certificate_path":$cert,"key_path":$key},
            "transport":$tp
        }]' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
    jq --arg tag "vless-${TAG}" --argjson port "$PORT" --arg d "$domain" \
       --arg cu "$seed_u" --arg cuuid "$seed_uuid" --arg cert "$cert" --arg key "$key" --argjson tp "$TJSON" '
        .inbounds += [{
            "type":"vless","tag":$tag,"listen":"::","listen_port":$port,
            "users":[{"name":$cu,"uuid":$cuuid}],
            "tls":{"enabled":true,"server_name":$d,"certificate_path":$cert,"key_path":$key},
            "transport":$tp
        }]' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
    if sing-box check -C "$(dirname "$SBXCFG")" >/dev/null 2>&1; then echo "  конфиг валиден ✅"; else
        echo "!!! check провалился — откат"; cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBXCFG"; exit 1; fi
    fw_open "$PORT"
    systemctl reload sing-box.service 2>/dev/null; sleep 5
    systemctl is-active --quiet sing-box && echo "  сервис перезагружен ✅" || { systemctl restart sing-box.service; sleep 8; systemctl is-active sing-box; }
    echo "Готово: ${SCHEME} на порту ${PORT}/tcp (домен ${domain}). Выдать конфиги: ssb-xgrpc-add ORDER-x 10 ${SCHEME}"
    ;;
remove)
    [[ "$SCHEME" == "http" || "$SCHEME" == "grpc" ]] || { echo "Использование: ssb-xgrpc-patch remove {http|grpc}"; exit 1; }
    TAG="$SCHEME"; backup_config
    jq --arg t "trojan-${TAG}" 'del(.inbounds[] | select(.tag == $t))' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
    jq --arg t "vless-${TAG}" 'del(.inbounds[] | select(.tag == $t))' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
    sing-box check -C "$(dirname "$SBXCFG")" >/dev/null 2>&1 && { systemctl reload sing-box.service 2>/dev/null; echo "Удалено."; } || { cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBXCFG"; echo "откат"; }
    ;;
status)
    for t in trojan-http vless-http trojan-grpc vless-grpc; do
        if jq -e --arg t "$t" 'any(.inbounds[]; .tag == $t)' "$SBXCFG" >/dev/null 2>&1; then
            echo "$t: $(jq -r --arg t "$t" '.inbounds[]|select(.tag==$t)|"порт \(.listen_port), \(.transport.type), юзеров \((.users|length))"' "$SBXCFG")"
        fi
    done
    [[ -z $(jq -r '.inbounds[]|select(.tag|test("http|grpc"))|.tag' "$SBXCFG" 2>/dev/null) ]] && echo "схемы не добавлены (ssb-xgrpc-patch apply http|grpc)"
    ;;
*)
    echo "Использование: ssb-xgrpc-patch apply {http|grpc} [порт] | remove {http|grpc} | status"
    exit 1
    ;;
esac
