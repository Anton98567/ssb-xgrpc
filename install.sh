#!/bin/bash
# ssb-xgrpc — установка утилит: VLESS/TRJ по XHTTP или gRPC на ноде Secret-Sing-Box.
#
# Одна команда:
#   curl -fsSL https://raw.githubusercontent.com/Anton98567/ssb-xgrpc/main/install.sh | bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/Anton98567/ssb-xgrpc/main"
curl -fsSL "$BASE/ssb-xgrpc-patch.sh" -o /usr/local/bin/ssb-xgrpc-patch
curl -fsSL "$BASE/ssb-xgrpc-add.sh" -o /usr/local/bin/ssb-xgrpc-add
chmod 755 /usr/local/bin/ssb-xgrpc-patch /usr/local/bin/ssb-xgrpc-add
echo "Установлено:"
echo "  ssb-xgrpc-patch apply {xhttp|grpc} [порт] — протокол XHTTP (2080) или gRPC (2081) на ноде"
echo "  ssb-xgrpc-patch remove {xhttp|grpc}         — убрать схему"
echo "  ssb-xgrpc-patch status                      — что настроено"
echo "  ssb-xgrpc-add ORDER-xxxxxx [count=10] [xhttp|grpc] [out] — выдать count×2 конфигов"
