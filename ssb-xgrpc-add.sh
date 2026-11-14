#!/bin/bash
# ssb-xgrpc-add — выдать конфиги заказа: VLESS + Trojan по XHTTP или gRPC.
#
# Использование:
#   ssb-xgrpc-add ORDER-xxxxxx [count=10] [scheme=http|grpc] [out-tag]
#
# Результат: count x 2 JSON-конфигов (VLESS/TRJ) со сплит-маршрутизацией;
#   ссылки https://<домен>/<секрет>/<имя>-{VLESS|TRJ}-CLIENT.json;
#   маршрут — только персональный OUT заказа (auth_user).
set -uo pipefail

ORDER="${1:-}"; COUNT="${2:-10}"; SCHEME="${3:-http}"; OUT="${4:-}"
[[ $ORDER =~ ^ORDER-[0-9]+$ ]] || { echo "Использование: ssb-xgrpc-add ORDER-xxxxxx [count=10] [http|grpc] [out-tag]"; exit 1; }
[[ $COUNT =~ ^[0-9]+$ ]] && (( COUNT >= 1 && COUNT <= 50 )) || { echo "Ошибка: count = 1..50"; exit 1; }
[[ "$SCHEME" == "http" || "$SCHEME" == "grpc" ]] || { echo "Ошибка: scheme = http|grpc"; exit 1; }

SBXCFG=/etc/sing-box/config.json
RELOAD="systemctl reload sing-box.service"
[[ -f $SBXCFG ]] || { echo "Ошибка: SSB не установлен"; exit 1; }

if [[ "$SCHEME" == "http" ]]; then
    TAG="http"; TP="http"
    IN_TRJ="trojan-http"; IN_VL="vless-http"
    PORT=2080
else
    TAG="grpc"; TP="grpc"
    IN_TRJ="trojan-grpc"; IN_VL="vless-grpc"
    PORT=2081
fi

for t in "$IN_TRJ" "$IN_VL"; do
    jq -e --arg t "$t" 'any(.inbounds[]; .tag == $t)' "$SBXCFG" >/dev/null 2>&1 || {
        echo "Ошибка: inbound '${t}' не найден. Сначала: ssb-xgrpc-patch apply $SCHEME"; exit 1; }
done

domain=$(jq -r --arg t "$IN_TRJ" '.inbounds[]|select(.tag==$t)|.tls.server_name' "$SBXCFG")
tport=$(jq -r --arg t "$IN_TRJ" '.inbounds[]|select(.tag==$t)|.listen_port' "$SBXCFG")
vport=$(jq -r --arg t "$IN_VL" '.inbounds[]|select(.tag==$t)|.listen_port' "$SBXCFG")
tws=$(jq -r --arg t "$IN_TRJ" '.inbounds[]|select(.tag==$t)|.transport.path // ""' "$SBXCFG")
vws=$(jq -r --arg t "$IN_VL" '.inbounds[]|select(.tag==$t)|.transport.service_name // ""' "$SBXCFG")

[[ -z $OUT ]] && OUT="out-${ORDER#ORDER-}"
jq -e --arg t "$OUT" 'any(.outbounds[]; .tag == $t)' "$SBXCFG" >/dev/null 2>&1 || {
    echo "Ошибка: OUT-узел '${OUT}' не найден."; exit 1; }

rand() { head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c12; }
backup_config() {
    cp "$SBXCFG" "/root/sb-config-backup-$(date +%Y%m%d-%H%M%S).json"
    ls -1t /root/sb-config-backup-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
}

subspath=$(grep "location ~ ^/" /etc/nginx/nginx.conf 2>/dev/null | tail -n 1 | cut -d "/" -f 2 | cut -d " " -f 1)
webdir=""
[[ -n $subspath && -d /var/www/$subspath ]] && webdir="/var/www/$subspath"

OUTDIR="/root/ssb-xgrpc-out/${ORDER}-${TAG}"
mkdir -p "$OUTDIR"
chmod 700 /root/ssb-xgrpc-out "$OUTDIR" 2>/dev/null

RS_JSON='[
  {"type":"remote","tag":"category-ads-all","format":"binary","url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs"},
  {"type":"remote","tag":"geoip-ru","format":"binary","url":"https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"},
  {"type":"remote","tag":"torrent-clients","format":"source","url":"https://raw.githubusercontent.com/A-Zuro/sb-rule-sets/main/torrent-clients.json"},
  {"type":"remote","tag":"bypass-apps","format":"source","url":"https://raw.githubusercontent.com/A-Zuro/sb-rule-sets/main/bypass-apps.json"},
  {"type":"remote","tag":"encrypted-dns","format":"source","url":"https://raw.githubusercontent.com/A-Zuro/sb-rule-sets/main/encrypted-dns.json"},
  {"type":"remote","tag":"android-fcm","format":"source","url":"https://raw.githubusercontent.com/A-Zuro/sb-rule-sets/main/android-fcm.json"}
]'
gen_cfg() { # $1=file, $2=proxy_outbound_json
    jq -n --argjson proxy "$2" --argjson rs "$RS_JSON" '{
      log: {level: "info", timestamp: true},
      dns: {
        servers: [
          {type: "local", tag: "dns-local"},
          {type: "https", tag: "dns-remote", server: "8.8.8.8", path: "/dns-query", detour: "proxy"}
        ],
        rules: [
          {rule_set: ["geoip-ru", "bypass-apps", "android-fcm"], server: "dns-local"},
          {domain_suffix: [".ru", ".su"], server: "dns-local"}
        ],
        final: "dns-remote"
      },
      outbounds: [$proxy, {type: "direct", tag: "direct"}, {type: "block", tag: "block"}],
      route: {
        auto_detect_interface: true,
        default_domain_resolver: {server: "dns-local", strategy: "prefer_ipv4"},
        rule_set: $rs,
        rules: [
          {action: "sniff"},
          {protocol: "dns", action: "hijack-dns"},
          {rule_set: ["category-ads-all"], action: "reject", method: "drop"},
          {rule_set: ["encrypted-dns"], action: "reject", method: "drop"},
          {rule_set: ["torrent-clients", "bypass-apps", "android-fcm"], outbound: "direct"},
          {rule_set: ["geoip-ru"], outbound: "direct"},
          {domain_suffix: [".ru", ".su", ".ru.com", ".ru.net"], outbound: "direct"},
          {domain_suffix: ["openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com",
                           "anthropic.com", "claude.ai", "claudeusercontent.com"], outbound: "proxy"},
          {ip_is_private: true, outbound: "direct"}
        ],
        final: "proxy"
      }
    }' > "$1"
    chmod 600 "$1"
}

echo "Выдаю ${COUNT}x2 конфига (${SCHEME}): ${ORDER}, OUT '${OUT}', домен ${domain}"
backup_config

names=(); add_tj=""; add_vl=""
lv_vless=""; lv_trj=""
for ((i = 1; i <= COUNT; i++)); do
    name="${ORDER}-$(rand)"
    trjpass="$(rand)"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    names+=("$name")
    add_tj+="${add_tj:+,}{\"name\":\"${name}\",\"password\":\"${trjpass}\"}"
    add_vl+="${add_vl:+,}{\"name\":\"${name}\",\"uuid\":\"${uuid}\"}"

    # service_name fallback for grpc (must be before construction)
    [[ "$SCHEME" == "grpc" && -z "$tws" ]] && tws="grpc"
    [[ "$SCHEME" == "grpc" && -z "$vws" ]] && vws="grpc"

    if [[ "$SCHEME" == "http" ]]; then
        P_TRJ=$(jq -n --arg d "$domain" --argjson p "$tport" --arg pw "$trjpass" --arg path "$tws" '
            {type:"trojan", tag:"proxy", server:$d, server_port:$p, password:$pw,
             tls:{enabled:true, server_name:$d}}
            + (if $path != "" then {transport:{type:"http", host:[$d], path:$path}} else {transport:{type:"http"}} end)
            + {multiplex:{enabled:true, padding:true}}')
        P_VL=$(jq -n --arg d "$domain" --argjson p "$vport" --arg u "$uuid" --arg path "$vws" '
            {type:"vless", tag:"proxy", server:$d, server_port:$p, uuid:$u,
             tls:{enabled:true, server_name:$d}}
            + (if $path != "" then {transport:{type:"http", host:[$d], path:$path}} else {transport:{type:"http"}} end)
            + {multiplex:{enabled:true, padding:true}}')
    else
        P_TRJ=$(jq -n --arg d "$domain" --argjson p "$tport" --arg pw "$trjpass" --arg sn "$tws" '
            {type:"trojan", tag:"proxy", server:$d, server_port:$p, password:$pw,
             tls:{enabled:true, server_name:$d},
             transport:{type:"grpc", service_name:$sn}}')
        P_VL=$(jq -n --arg d "$domain" --argjson p "$vport" --arg u "$uuid" --arg sn "$vws" '
            {type:"vless", tag:"proxy", server:$d, server_port:$p, uuid:$u,
             tls:{enabled:true, server_name:$d},
             transport:{type:"grpc", service_name:$sn}}')
    fi
    # service_name fallback for grpc
    gen_cfg "${OUTDIR}/${name}-TRJ-CLIENT.json" "$P_TRJ"
    gen_cfg "${OUTDIR}/${name}-VLESS-CLIENT.json" "$P_VL"

    if [[ -n $webdir ]]; then
        cp "${OUTDIR}/${name}-TRJ-CLIENT.json" "${webdir}/${name}-TRJ-CLIENT.json"
        cp "${OUTDIR}/${name}-VLESS-CLIENT.json" "${webdir}/${name}-VLESS-CLIENT.json"
        chmod 644 "${webdir}/${name}-TRJ-CLIENT.json" "${webdir}/${name}-VLESS-CLIENT.json"
        base="https://${domain}/${subspath}"
    else
        base="${OUTDIR}"
    fi
    lv_trj+="${base}/${name}-TRJ-CLIENT.json"$'\n'
    lv_vless+="${base}/${name}-VLESS-CLIENT.json"$'\n'
done

# users в inbound'ах
jq --argjson u "[${add_tj}]" '(.inbounds[] | select(.tag=="'"${IN_TRJ}"'") | .users) += $u' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
jq --argjson u "[${add_vl}]" '(.inbounds[] | select(.tag=="'"${IN_VL}"'") | .users) += $u' "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"

# маршрут -> персональный OUT
if jq -e --arg t "$OUT" 'any(.route.rules[]; .outbound == $t and has("auth_user"))' "$SBXCFG" >/dev/null 2>&1; then
    jq --arg t "$OUT" --argjson n "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)" '
        (.route.rules[] | select(.outbound == $t and has("auth_user")) | .auth_user) += $n' \
        "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
else
    jq --arg t "$OUT" --argjson n "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)" '
        (.route.rules) = ((.route.rules | map(select(. != {"action":"reject"})))
          + [{"auth_user": $n, "outbound": $t}] + [{"action":"reject"}])' \
        "$SBXCFG" > /tmp/xg-$$.json && mv /tmp/xg-$$.json "$SBXCFG"
fi

if sing-box check -C "$(dirname "$SBXCFG")" >/dev/null 2>&1; then
    systemctl reload sing-box.service 2>/dev/null; sleep 5
    systemctl is-active --quiet sing-box 2>/dev/null || { systemctl restart sing-box.service; sleep 8; }
else
    echo "!!! sing-box check провалился — откат"
    cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBXCFG"
    exit 1
fi

OUTDIR="/root/ssb-xgrpc-out/${ORDER}-${TAG}"
lv_all="${lv_vless}${lv_trj}"
printf '%s' "$lv_all" > "${OUTDIR}/links-all.txt"
mkdir -p "$OUTDIR"
chmod 600 "$OUTDIR"/*-CLIENT.json 2>/dev/null
chmod 700 /root/ssb-xgrpc-out 2>/dev/null
echo "$(date '+%F %T') order=${ORDER} xgrpc-add scheme=${TAG} count=${COUNT} out=${OUT}" >> /root/ssb-orders.log

echo
echo "=== VLESS (${COUNT}) ==="; printf '%s' "$lv_vless"
echo "=== TRJ (${COUNT}) ==="; printf '%s' "$lv_trj"
echo "=== Итого: $((COUNT*2)) ссылок (${COUNT}x VLESS+TRJ), схема: ${TAG}, маршрут: ${ORDER} -> ${OUT} ==="
echo "Файлы: $OUTDIR/"
