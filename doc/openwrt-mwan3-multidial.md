# OpenWrt + macvlan + mwan3 单线多拨实践

本文记录在 OpenWrt 上使用 `macvlan`/`veth`、`mwan3` 和 `NJUPT-AutoLogin.sh` 实现单线多拨的实践。场景以两个账号为例：

- `vwan1`：稳定账号，例如 `njupt`，作为主出口。
- `vwan2`：限时账号，例如 `ctcc`，作为辅助出口，可能在固定断网时间后需要恢复。

示例中所有账号、密码、MAC 地址、IP 地址都使用占位符。不要把真实账号、密码、完整日志、真实 MAC 地址提交到公开仓库。

## 目标

- 同一根 WAN 线创建多个 `macvlan` 设备，分别 DHCP 和认证。
- 用 `mwan3` 管理出口权重和故障切换。
- 将账号密码移出 crontab，避免出现在 LuCI 页面、系统日志或 shell 历史中。
- 对限时账号做恢复：在允许上网时间内，如果 `mwan3` 判定它离线，再执行重拨和认证。

## 前提

OpenWrt 上建议安装或确认以下组件：

```sh
opkg update
opkg install bash curl mwan3
```

包装脚本会使用 `flock` 避免多个 cron 实例并发运行。很多固件已内置 `flock`；如果没有，请按当前固件的软件源安装对应包，例如 `util-linux-flock` 或其他提供 `flock` 命令的包。

## 网络接口结构

假设物理 WAN 设备叫 `wan`，创建两个 `macvlan` 设备：

- `veth0` 挂在 `wan` 上，对应 `vwan1`
- `veth1` 挂在 `wan` 上，对应 `vwan2`

OpenWrt UCI 示例：

```sh
uci set network.veth0='device'
uci set network.veth0.name='veth0'
uci set network.veth0.ifname='wan'
uci set network.veth0.type='macvlan'
uci set network.veth0.mode='vepa'

uci set network.vwan1='interface'
uci set network.vwan1.proto='dhcp'
uci set network.vwan1.device='veth0'
uci set network.vwan1.metric='10'

uci set network.veth1='device'
uci set network.veth1.name='veth1'
uci set network.veth1.ifname='wan'
uci set network.veth1.type='macvlan'
uci set network.veth1.mode='vepa'

uci set network.vwan2='interface'
uci set network.vwan2.proto='dhcp'
uci set network.vwan2.device='veth1'
uci set network.vwan2.metric='20'

uci commit network
```

不要禁用物理 `wan` 设备。`veth0`/`veth1` 是挂在 `wan` 上的 `macvlan` 子设备，父设备 down 掉以后，子设备可能出现 `DEVICE_CLAIM_FAILED` 或 DHCP/链路异常。

### MAC 地址策略

不建议一开始就把所有 `macvlan` MAC 地址永久写死。更稳妥的做法是：

- 稳定主账号可以固定 MAC，减少重复认证。
- 限时账号如果出现“DHCP 有 IP、网关可达、认证出口不可达”，可以在恢复流程中临时换 MAC 后重拨。
- 临时 MAC 用于恢复时，应在拿到 IP 后从 UCI 删除，避免永久污染配置。

示例：

```sh
uci set network.veth0.macaddr='02:11:22:33:44:55'
uci delete network.veth1.macaddr 2>/dev/null || true
uci commit network
```

## 防火墙

把 `vwan1` 和 `vwan2` 放入 WAN zone。LuCI 中通常在：

`网络` -> `防火墙` -> `区域` -> `wan` -> `涵盖的网络`

应包含：

- `wan`
- `wan6`，如果使用 IPv6
- `vwan1`
- `vwan2`

注意这里应使用实际存在的接口名。不要把不存在的 `wan1`、`wan2` 填进去。

## mwan3 基本策略

`mwan3` 中给两个接口配置健康检查。主账号权重大，限时账号权重小：

```sh
uci set mwan3.vwan1='interface'
uci set mwan3.vwan1.enabled='1'
uci set mwan3.vwan1.family='ipv4'
uci add_list mwan3.vwan1.track_ip='223.5.5.5'
uci add_list mwan3.vwan1.track_ip='119.29.29.29'
uci set mwan3.vwan1.timeout='2'
uci set mwan3.vwan1.interval='5'
uci set mwan3.vwan1.down='3'
uci set mwan3.vwan1.up='2'

uci set mwan3.vwan2='interface'
uci set mwan3.vwan2.enabled='1'
uci set mwan3.vwan2.family='ipv4'
uci add_list mwan3.vwan2.track_ip='223.5.5.5'
uci add_list mwan3.vwan2.track_ip='119.29.29.29'
uci set mwan3.vwan2.timeout='2'
uci set mwan3.vwan2.interval='5'
uci set mwan3.vwan2.down='3'
uci set mwan3.vwan2.up='2'

uci set mwan3.vwan1_m1_w10='member'
uci set mwan3.vwan1_m1_w10.interface='vwan1'
uci set mwan3.vwan1_m1_w10.metric='1'
uci set mwan3.vwan1_m1_w10.weight='10'

uci set mwan3.vwan2_m2_w3='member'
uci set mwan3.vwan2_m2_w3.interface='vwan2'
uci set mwan3.vwan2_m2_w3.metric='2'
uci set mwan3.vwan2_m2_w3.weight='3'

uci set mwan3.balanced='policy'
uci add_list mwan3.balanced.use_member='vwan1_m1_w10'
uci add_list mwan3.balanced.use_member='vwan2_m2_w3'
uci set mwan3.balanced.last_resort='unreachable'

uci set mwan3.default_rule_v4='rule'
uci set mwan3.default_rule_v4.dest_ip='0.0.0.0/0'
uci set mwan3.default_rule_v4.use_policy='balanced'
uci set mwan3.default_rule_v4.family='ipv4'

uci commit mwan3
```

配置后重启：

```sh
/etc/init.d/network reload
/etc/init.d/firewall restart
/etc/init.d/mwan3 restart
```

## 账号配置方案

推荐目录：

```text
/root/njupt-autologin/
  login-one.sh
  accounts/
    vwan1.conf
    vwan2.conf
  locks/
```

权限：

```sh
chmod 700 /root/njupt-autologin
chmod 700 /root/njupt-autologin/accounts /root/njupt-autologin/locks
chmod 700 /root/njupt-autologin/login-one.sh
chmod 600 /root/njupt-autologin/accounts/*.conf
```

`vwan1.conf` 示例：

```sh
IFACE_UCI='vwan1'
DEV='veth0'
ISP='njupt'
LOGIN_ID='YOUR_NJUPT_ID'
LOGIN_PW='YOUR_PASSWORD'
TIME_UNLIMITED='1'
```

`vwan2.conf` 示例：

```sh
IFACE_UCI='vwan2'
DEV='veth1'
ISP='ctcc'
LOGIN_ID='YOUR_CTCC_ID'
LOGIN_PW='YOUR_PASSWORD'
TIME_UNLIMITED='0'
PAUSE_MWAN3='1'
RENEW_BEFORE_LOGIN='1'
RANDOMIZE_MAC_ON_RENEW='1'
CHECK_URL='http://connect.rom.miui.com/generate_204'
```

字段说明：

| 字段 | 含义 |
| --- | --- |
| `IFACE_UCI` | OpenWrt 逻辑接口名，例如 `vwan1` |
| `DEV` | Linux 设备名，例如 `veth0` |
| `ISP` | 传给脚本的运营商，常见为 `njupt`、`ctcc`、`cmcc` |
| `LOGIN_ID` / `LOGIN_PW` | 登录账号和密码，只保存在路由器本地 |
| `TIME_UNLIMITED` | `1` 表示不限时账号，会给 `NJUPT-AutoLogin.sh` 加 `-n`；`0` 表示遵守脚本内限时逻辑 |
| `PAUSE_MWAN3` | 恢复离线接口时是否短暂停止 `mwan3` |
| `RENEW_BEFORE_LOGIN` | 登录前是否重拨对应接口 |
| `RANDOMIZE_MAC_ON_RENEW` | 重拨时是否给对应 `macvlan` 临时随机 MAC |

添加第三个账号时，按同样模式增加：

1. 新增 `veth2` 和 `vwan3`。
2. 把 `vwan3` 加入 WAN firewall zone。
3. 在 `mwan3` 中增加 `vwan3` interface、member 和 policy。
4. 新建 `/root/njupt-autologin/accounts/vwan3.conf`。
5. crontab 增加一行：

```crontab
*/1 * * * * /root/njupt-autologin/login-one.sh vwan3
```

## crontab

不要把账号密码直接写进 crontab。使用包装脚本后，计划任务只保留接口名：

```crontab
*/1 * * * * /root/njupt-autologin/login-one.sh vwan1
*/1 * * * * /root/njupt-autologin/login-one.sh vwan2
```

`flock` 锁文件放在 `/root/njupt-autologin/locks`，不是 `/tmp`。`/tmp` 重启后会丢失，适合临时文件，不适合保存长期状态或账号配置。

## mwan3 与本机认证流量的坑

一个容易误判的现象：

- `vwan2` 能 DHCP 拿到 IP。
- `ping -I veth1 <gateway>` 正常。
- `mwan3` 判定 `vwan2 offline`。
- `curl --interface veth1 https://10.10.244.11:802/eportal/` 返回 `000`。
- 短暂停止 `mwan3` 后，认证页又能访问。

这说明问题不一定是账号时间窗口，也不一定是 DHCP 或 MAC 本身。`mwan3` 运行时的策略路由和防火墙标记可能影响路由器本机发起的 `curl --interface <dev>` 认证流量。

因此恢复逻辑不要每分钟无脑登录。推荐顺序是：

1. 如果 `mwan3 status` 已认为该接口 online，直接跳过。
2. 如果接口 offline，再短暂停止 `mwan3`。
3. 停止后先直接检测是否已经可访问连通性测试 URL。
4. 仍不通时，再重拨接口、临时换 MAC、执行登录。
5. 结束时必须恢复 `mwan3`。

这可以避免在线时每分钟反复 stop/start `mwan3`。

## 常用诊断命令

查看接口状态：

```sh
ifstatus vwan1
ifstatus vwan2
ip -br link
ip -4 addr show dev veth1
```

查看路由和策略：

```sh
ip -4 route show table main
ip -4 route show table 1
ip -4 route show table 2
ip -4 rule show
ip -4 route get 223.5.5.5 oif veth1
```

测试认证页：

```sh
curl -4 --interface veth1 --connect-timeout 3 --max-time 8 -k -I https://10.10.244.11:802/eportal/
```

短暂停止 `mwan3` 做隔离测试：

```sh
/etc/init.d/mwan3 stop
curl -4 --interface veth1 --connect-timeout 3 --max-time 8 -k -I https://10.10.244.11:802/eportal/
/etc/init.d/mwan3 start
```

如果停掉 `mwan3` 后认证页可达，优先检查本机认证流量与 `mwan3` 规则的交互。如果停掉后仍不可达，才更像上游认证状态、MAC 会话或账号限时问题。

## 常见坑

- 关闭物理 `wan`：`macvlan` 子设备依赖父设备，父设备不能直接禁用。
- 把不存在的接口名加入 firewall zone：应加入 `vwan1`、`vwan2`，不是随手写 `wan1`、`wan2`。
- 用 `curl --interface <IP>` 误判：绑定源 IP 时可能仍走主出口。调试多拨时优先用 `curl --interface veth1`。
- 只看脚本退出码：旧脚本失败时也可能最后 `exit 0`，包装脚本应做 post-check。
- 已在线仍重复登录：对已登录账号重复发送登录请求可能导致账号下线。
- 将密码写入 crontab：LuCI 页面和备份都可能暴露密码。
- 将长期状态放在 `/tmp`：重启后会丢失。

## 示例文件

本仓库提供一组脱敏示例：

- [login-one.sh](../examples/openwrt/njupt-autologin/login-one.sh)
- [vwan1.conf.example](../examples/openwrt/njupt-autologin/accounts/vwan1.conf.example)
- [vwan2.conf.example](../examples/openwrt/njupt-autologin/accounts/vwan2.conf.example)
- [crontab.example](../examples/openwrt/njupt-autologin/crontab.example)

复制到路由器后，把 `.example` 文件改名为 `.conf`，填入本地账号密码，并执行 `chmod 600`。
