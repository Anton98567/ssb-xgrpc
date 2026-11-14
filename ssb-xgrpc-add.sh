#!/bin/bash
# ssb-xgrpc-add — выдать конфиги заказа: VLESS + Trojan по XHTTP (HTTP) или gRPC.
#
# Использование:
#   ssb-xgrpc-add ORDER-xxxxxx [count=10] [http|grpc] [out-tag]
#
# Результат: count x 2 JSON-конфигов со сплит-маршрутизацией (как в проде),
#   ссылками через секрет-каталог ноды; маршрут — только персональный OUT заказа.
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
    TPORT=2080; VPORT=2082
else
    TAG="grpc"; TP="grpc"
    IN_TRJ="trojan-grpc"; IN_VL="vless-grpc"
    TPORT=2081; VPORT=2083
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
    echo "Ошибка: OUT-узел '${OUT}' не найден. Политика: каждому заказу — персональный OUT."; exit 1; }

rand() { head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c12; }
backup_config() {
    cp "$SBXCFG" "/root/sb-config-backup-$(date +%Y%m%d-%H%M%S).json"
    ls -1t /root/sb-config-backup-*.json 2>/dev/null | tail -n +11 | xargs -r rm -f
}

subspath=$(grep "location ~ ^/" /etc/nginx/nginx.conf 2>/dev/null | tail -n 1 | cut -d "/" -f 2 | cut -d " " -f 1)
webdir=""
[[ -n $subspath && -d /var/www/$subspath ]] && webdir="/var/www/$subspath"
rulesetpath=$(grep "alias /var/www/" /etc/nginx/nginx.conf 2>/dev/null | head -n 1 | cut -d "/" -f 4)

# --- шаблон клиента = продовый template.json (DOMAIN/RULESETPATH плейсхолдеры) ---
TPL_B64="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"
TPL="/tmp/xg-tpl-$$.json"
printf '%s' "$TPL_B64" | base64 -d | gunzip > "$TPL"
# пиннинг IP ноды (anti-DNS-spoof): IP подставляется резолвом домена;
# если домен не резолвится — пиннинг отключается, конфиг не ломается
nodeip=$(getent ahostsv4 "${domain:-}" 2>/dev/null | awk '{print $1; exit}')
if [[ -n $nodeip ]]; then
    sed -i "s|NODEIP|${nodeip}|g" "$TPL"
else
    python3 - "$TPL" <<'PYIP'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
for r in c.get("route", {}).get("rules", []):
    if "ip_cidr" in r:
        r["ip_cidr"] = [x for x in r["ip_cidr"] if x != "NODEIP"]
        if not r["ip_cidr"]:
            del r["ip_cidr"]
json.dump(c, open(p, "w"), ensure_ascii=False)
PYIP
fi
sed -i "s|DOMAIN|${domain}|g" "$TPL"
if [[ -n $rulesetpath && -d /var/www/$rulesetpath ]]; then
    sed -i "s|RULESETPATH|${rulesetpath}|g" "$TPL"
else
    echo "ВНИМАНИЕ: каталог rule-set на ноде не найден — rule-sets качаются с GitHub (медленнее)."
    python3 - "$TPL" <<'PY'
import json, subprocess, sys
tpl = sys.argv[1]
c = json.load(open(tpl))
def gh(tag, fn):
    if tag in ("torrent-clients","bypass-apps","encrypted-dns","android-fcm"):
        return "https://raw.githubusercontent.com/A-Zuro/sb-rule-sets/main/" + fn
    if tag == "geoip-ru":
        return "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"
    return "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/" + fn
def probe(u):
    try:
        r = subprocess.run(["curl","-sk","-o","/dev/null","-w","%{http_code}","-m","6", u],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip() == "200"
    except Exception:
        return False
for rs in c.get("route", {}).get("rule_set", []):
    fn = rs["url"].rsplit("/", 1)[-1]
    u = gh(rs["tag"], fn)
    if probe(u):
        rs["url"] = u
    else:
        rs["_drop"] = True
c["route"]["rule_set"] = [rs for rs in c["route"].get("rule_set", []) if not rs.pop("_drop", False)]
available = {rs["tag"] for rs in c["route"].get("rule_set", [])}
for sec in ("route", "dns"):
    if sec in c and "rules" in c[sec]:
        new = []
        for r in c[sec]["rules"]:
            if "rule_set" in r:
                r["rule_set"] = [t for t in r["rule_set"] if t in available]
                if not r["rule_set"]:
                    continue
            new.append(r)
        c[sec]["rules"] = new
json.dump(c, open(tpl, "w"), ensure_ascii=False, indent=1)
PY
fi

gen_cfg() { # $1=файл, $2=proxy-outbound (json)
    jq --argjson proxy "$2" '(.outbounds[] | select(.tag=="proxy")) = $proxy' "$TPL" > "$1"
    chmod 600 "$1"
}

OUTDIR="/root/ssb-xgrpc-out/${ORDER}-${TAG}"
mkdir -p "$OUTDIR"
chmod 700 /root/ssb-xgrpc-out "$OUTDIR" 2>/dev/null

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
    [[ "$SCHEME" == "grpc" && -z "$tws" ]] && tws="grpc"
    [[ "$SCHEME" == "grpc" && -z "$vws" ]] && vws="grpc"

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

rm -f "$TPL"
if sing-box check -C "$(dirname "$SBXCFG")" >/dev/null 2>&1; then
    systemctl reload sing-box.service 2>/dev/null; sleep 5
    systemctl is-active --quiet sing-box 2>/dev/null || { systemctl restart sing-box.service; sleep 8; }
else
    echo "!!! sing-box check провалился — откат"
    cp "$(ls -1t /root/sb-config-backup-*.json | head -1)" "$SBXCFG"
    exit 1
fi

echo "$(date '+%F %T') order=${ORDER} xgrpc-add scheme=${TAG} count=${COUNT} out=${OUT}" >> /root/ssb-orders.log

OUTDIR="/root/ssb-xgrpc-out/${ORDER}-${TAG}"
mkdir -p "$OUTDIR"
chmod 600 "$OUTDIR"/*-CLIENT.json 2>/dev/null
chmod 700 /root/ssb-xgrpc-out 2>/dev/null
lv_all="${lv_trj}${lv_vless}"
printf '%s' "$lv_all" > "${OUTDIR}/links-all.txt"

echo
echo "=== VLESS (${COUNT}) ==="; printf '%s' "$lv_vless"
echo "=== TRJ (${COUNT}) ==="; printf '%s' "$lv_trj"
echo "=== Итого: $((COUNT*2)) ссылок (${COUNT}x VLESS+TRJ), схема: ${TAG}, маршрут: ${ORDER} -> ${OUT} ==="
echo "Файлы и список для тикета: ${OUTDIR}/ (links-all.txt)"
