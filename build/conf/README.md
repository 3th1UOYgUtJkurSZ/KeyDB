# 跨云 KeyDB 双主(active-replica)示例配置

`keydb-a ⇄ deploy-server-a ⇄ deploy-server-b ⇄ keydb-b`

两个站点(如 AWS / 阿里云)各一套 KeyDB + deploy-server,复制流经 deploy-server 的
**QUIC 隧道(mTLS 加密)**跨公网互通,**无需 VPN/专线**。两端 `active-replica` 互为主从即成双主。

## 拓扑与数据流

```
      站点 A(如 AWS)                                     站点 B(如 阿里云)
 ┌───────────────────────────┐                     ┌───────────────────────────┐
 │ keydb-a  :6379            │                     │            keydb-b  :6379 │
 │   replicaof 127.0.0.1:6390 │                     │ replicaof 127.0.0.1:6390   │
 │        │                   │                     │                   │        │
 │  deploy-a                  │                     │                  deploy-b  │
 │   redis_gateway :6390 ─────┼──QUIC/mTLS(公网)──▶│ quic_proxy :7982 ─▶ keydb-b│
 │   quic_proxy    :7982 ◀────┼──QUIC/mTLS(公网)───┼─ redis_gateway :6390       │
 └───────────────────────────┘                     └───────────────────────────┘
```

- keydb-a 拉取 keydb-b:`keydb-a → deploy-a:6390(gateway) → 隧道 → deploy-b:7982(proxy) → keydb-b:6379`
- keydb-b 拉取 keydb-a:对称。

## 文件

| 文件 | 部署到 | 说明 |
|---|---|---|
| `keydb-a.conf` / `keydb-b.conf` | 站点 A / B 的 KeyDB | `active-replica` + `replicaof 本地 gateway` + WAN 调优 |
| `deploy-a.yaml` / `deploy-b.yaml` | 站点 A / B 的 deploy-server | `quic_proxy`(出口)+ `redis_gateway`(入口)+ mTLS |
| `gen-certs.sh` | 本地生成一次 | 私有 CA + 两端服务端证书 + 共享客户端证书 → `certs/` |

## 端口

| 端口 | 用途 | 暴露面 |
|---|---|---|
| 6379/tcp | KeyDB | 仅本机(`bind 127.0.0.1`) |
| 6390/tcp | deploy redis_gateway 入口 | 仅本机 |
| 7982/udp | deploy quic_proxy(QUIC) | **公网**,安全组只放行对端公网 IP |
| 7981/tcp | deploy HTTP/运维(可选) | 内网 |

## 部署步骤

1. **生成证书**(一次,在能访问两端的地方):
   ```bash
   cd build/conf && ./gen-certs.sh
   ```
   把 `certs/` 一并分发到两端(与对应 yaml 同目录,或改 yaml 里的相对路径)。

2. **填占位符**:
   - `deploy-a.yaml` 的 `<DEPLOY_B_PUBLIC_IP>`、`deploy-b.yaml` 的 `<DEPLOY_A_PUBLIC_IP>`
   - 两端 `<TUNNEL_SECRET>` 用同一随机串(隧道 JWT 密钥)
   - 两端 keydb 的 `<REPL_PASSWORD>` 用同一随机串(复制账号密码)

3. **安全组**:各站点放行「对端公网 IP → 本站 7982/udp」;KeyDB 6379、gateway 6390 只监听回环,勿暴露。

4. **启动顺序**(避免首次全量同步覆盖数据):
   - 先起两端 deploy-server(`deploy-server -config deploy-X.yaml`);
   - 先起「有权威数据」的一端 KeyDB,待其就绪;再起另一端 KeyDB 去同步它。
   - 切勿两端同时冷启动后立刻并发写(见下)。

5. **验证**:
   ```bash
   keydb-cli -p 6379 info replication | grep -E 'role|master_link_status'   # 期望 up
   keydb-cli -p 6379 set k v         # 在 A 写
   keydb-cli -p 6379 get k           # 在 B 读到 v
   ```

## ⚠️ 注意(与之前讨论一致)

- **启动窗口数据丢失**:两端同时冷启动并在全量同步窗口内并发写,一侧 RDB 会覆盖对端(“first master wins”)。进入增量复制稳定态后才可靠。
- **同 key 双写冲突**:LWW(时间戳裁决),两云需 **NTP 同步时钟**;强烈建议**按地域分片键空间**(A 写 `a:*`、B 写 `b:*`)规避同 key 双写;计数器等非幂等操作走单主。
- **公网必开 mTLS**:本示例已启用(`ca_cert`/`client_cert`/`client_ca_file`)。隧道底层 QUIC 已加密,mTLS 提供双向身份认证,替代 VPN 的信任层。
- **不适用 KeyDB Cluster**:字节桥不改写 `MOVED/ASK`,仅适用单节点/双主。
