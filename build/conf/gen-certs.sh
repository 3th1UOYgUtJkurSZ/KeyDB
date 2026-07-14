#!/usr/bin/env bash
#
# 生成跨云隧道 mTLS 所需的私有 CA + 两端服务端证书 + 共享客户端证书。
# 产物写到本脚本同目录的 certs/ 下。deploy-*.yaml 里按相对路径 certs/xxx 引用。
#
#   ./gen-certs.sh
#
# 说明:
#   - server_name 校验的是证书 SAN(DNS),与拨号用的 IP 无关,因此这里用 DNS SAN
#     (deploy-a / deploy-b)即可,无需把公网 IP 写进证书。
#   - deploy-a.yaml 连对端时 server_name=deploy-b(校验 deploy-b 的服务端证书),反之亦然。
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p certs && cd certs

DAYS=3650

# 私有 CA
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days $DAYS \
  -subj "/CN=xcloud-keydb-CA" 2>/dev/null

# 某端服务端证书:$1=名字(deploy-a / deploy-b),SAN=DNS:该名字
gen_server() {
  local name="$1"
  openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" \
    -subj "/CN=$name" 2>/dev/null
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "$name.crt" -days $DAYS \
    -extfile <(printf "subjectAltName=DNS:%s" "$name") 2>/dev/null
  rm -f "$name.csr"
}
gen_server deploy-a
gen_server deploy-b

# 共享客户端证书(两端 redis_gateway 出示给对端 quic_proxy)
openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr \
  -subj "/CN=xcloud-client" 2>/dev/null
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days $DAYS 2>/dev/null
rm -f client.csr ca.srl

echo "已生成证书到 $(pwd):"
ls -1 *.crt *.key
echo
echo "校验链:"; openssl verify -CAfile ca.crt deploy-a.crt deploy-b.crt client.crt
