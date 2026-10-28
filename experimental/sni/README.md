# Tailscale Merlin：点对点 TLS / 自定义 SNI 实验版

此实验**修改 Tailscale 的 magicsock 收发层**，不部署 DERP、不依赖 stunnel。
基于官方 v1.104.1，固定提交 `9a522a9786c97eb7910c01ccb7bd66557b04c910`。
两端路由器必须运行这个版本。仅支持一对节点，不是官方支持的功能。

## 拓扑与行为

电视 / iPad / PC → 观看端 Tailscale 路由器 → TLS/TCP → 家中 Tailscale 路由器 → NAS。

- 客户端对真实公网 IP/域名发起连接，TLS ClientHello 可带 `speedtest.com` 等自定义 SNI。
- 内层仍是 WireGuard 加密数据包；Tailscale 控制平面、子网路由、密钥和 ACL 不替换。
- 按 **对端路由器的 nodekey 公钥**选择传输。发往该节点的 WireGuard 数据使用 TLS；其他节点保留普通模式。
- 不设置出口节点或默认路由，不会把普通互联网访问导向家里。
- 为避免测试失真，启用后该节点**不自动回退 UDP/DERP**。TLS 故障会暂时中断通过该节点的访问。
- 控制平面、网络探测和其他节点的流量仍可能使用原有协议；不是所有 Tailscale 连接都带这个 SNI。
- 没有配置文件/没有设置 `TS_MERLIN_TLS_CONFIG` 时，使用正常 Tailscale 模式。

## 认证方式

双方各有一个 TLS 身份证书和私钥，交换**公开证书**并固定验证其完整 SHA-256 指纹。
检查证书有效期，TLS 1.3，双向认证。SNI 不参与身份名称验证。
客户端设置 `InsecureSkipVerify` 仅用于替换公共 CA/域名验证，代码中的 `VerifyConnection`
强制执行对端证书固定校验，**不是关闭身份验证**。无需拥有 speedtest.com 的证书，也不会连接该网站。
TLS 协议使用 ALPN `merlin-wg/1`，不是完整的浏览器 HTTPS 流量仿真。
SNI 是否影响运营商限速需要同线路 A/B 测试，不保证满速。

## 构建

GitHub Actions：`Experimental Tailscale direct TLS SNI (ARMv5)`。
推送 `experimental/direct-tls-sni` 分支会触发构建；工作流进入默认分支后也可手动启动。
流程应用源码补丁、运行含 race detector 的 TLS 测试、编译原生 CLI 和 Linux ARMv5 combined 程序、UPX 3.94 压缩。
Actions artifact 包含压缩版、未压缩版、SHA256SUMS、配置示例、源码覆盖文件和集成补丁。

构建成功仅证明测试和交叉编译通过，不证明 Merlin 旧内核上的实际运行或吞吐量。
当前没有路由器实机、完整 site-to-site WireGuard 数据面或 Plex 播放测试结果。

## 准备两端配置

先保存两端原始 `tailscale.combined`、启动脚本和状态文件，保留本地 LAN/SSH 管理通道。
**不要只通过正在替换的 Tailscale 连接做首次安装。** 本构建不自动部署、不自动重启路由器。

1. 两端分别查询自己节点的公钥（不是登录 auth key）：

   ```sh
   /koolshare/bin/tailscale status --json | /koolshare/bin/jq -r '.Self.PublicKey'
   ```

2. 两端建立 `/koolshare/configs/tailscale/merlin-tls/`，权限设为 700。
   家中端在该目录运行 `sh generate-identity.sh server`；观看端运行 `sh generate-identity.sh client`。
   如旧系统 OpenSSL 不支持生成 EC 证书，可在可信电脑生成，再分别安全传入。
   只交换 `.crt` 文件，私钥不放入仓库、不在聊天中发送。

3. 分别用 `server.example.json` / `client.example.json` 创建目录下的 `config.json`。
   `peer_key` 填**另一端**的公钥。
   客户端 `connect` 填家中实际公网地址和 TCP 端口，不能填 Tailscale IP、NAS 内网 IP，
   也不能让这个公网目标再次路由进 Tailscale（避免循环）。
   初次 A/B 可先用 `normal.example.com`，再只将 `sni` 改为 `speedtest.com`。

4. 服务端路由器放行选定 TCP 监听端口（示例 18443）。若上游光猫/路由还做 NAT，需相应端口映射。
   这里 TLS 服务运行在**路由器本机**，不是把端口转发到 NAS。
   防火墙命令需要按实际固件/WAN 接口配置；此包不自动修改公网入口规则。

5. 安装实验二进制后，启动 `tailscaled` 时传入：

   ```sh
   export TS_MERLIN_TLS_CONFIG=/koolshare/configs/tailscale/merlin-tls/config.json
   ```

   仅在 SSH shell 中 export 不会自动作用于插件的重启/守护进程。
   `enable-startup.py` 可在有 Python 3 的电脑上读取**当前**控制脚本并生成修改副本：

   ```sh
   python3 enable-startup.py tailscale_config tailscale_config.sni
   ```

   它在 `start_ts()` 中导出环境变量；需要审查后再用生成文件替换路由器上的
   `/koolshare/scripts/tailscale_config`，保留权限。不要同时启动第二个 tailscaled。
   子网路由/角色/SNAT 使用已有配置，不修改访问 NAS 的 IP。

## 验证与回滚

- 日志 `/tmp/tailscale_daemon.log` 搜索 `merlin-tls:`。
- 双方应出现 `connected ... sni="speedtest.com" (direct TLS, no DERP)`。
- 连接结束会记录累计 TX/RX 包数和字节数；原有 `tailscale status` 的 direct/relay 字段未扩展，
  **不能仅靠该字段判断本实验通道**。
- 同时抓取 WAN 上指定 TCP 端口的握手，确认 SNI；观察 NAS 下载时这条连接的字节数。
- 同一文件、同一路由、同一端口，分别使用普通 SNI / speedtest SNI，断开并重建连接后各测多次。
- 路由器 CPU 饱和、跨网拥塞和 TCP 队头阻塞均可能降低速度。
- 节点重新登录造成 nodekey 变化后，需要更新另一端配置并重启。
- 回滚：移走 `config.json` 并按插件方式重启即可关闭实验传输；完整回滚恢复原二进制和启动脚本。

## 已知边界

首版单节点对、单条双向 TLS/TCP 连接。服务端同时服务一个已认证会话，断线自动重连。
握手超时 10 秒，写超时 15 秒，心跳 15 秒，读超时 60 秒；收发队列各 32 包。
没有 GUI 配置、节点密钥自动更新、自动证书续期、连接聚合或动态路径质量选择。
证书固定配置错误会拒绝连接；私钥/配置应仅由 root 管理。

源码文件 `overlay/wgengine/magicsock/merlin_tls.go` 是实际新增传输实现；
`apply.py` 将它接入 `endpoint.send`、WireGuard receive 函数和 bind 的打开/关闭生命周期。
