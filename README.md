# NJUPT_AutoLogin

南京邮电大学校园网自动登录脚本。本分支以 **OpenWrt 路由器长期运行** 为主要使用场景，同时保留 macOS、Linux 和 MikroTik RouterOS 的基础用法。

> [!NOTE]
> 本分支基于 [s235784/NJUPT_AutoLogin](https://github.com/s235784/NJUPT_AutoLogin)，重点补充 OpenWrt 自动认证、单线多拨、mwan3 分流、限时账号恢复和凭据安全实践。原项目采用 Apache-2.0 license，本分支继续保留原许可证和原作者信息。

> [!WARNING]
> 脚本会依赖系统时间判断限时账号是否处于可上网时段。OpenWrt 上请先校准时间，否则可能在可登录时段跳过登录，或在断网时段反复尝试。

## OpenWrt 快速开始

### 1. 安装依赖

```sh
opkg update
opkg install bash curl
```

如果要做单线多拨，还需要：

```sh
opkg install kmod-macvlan mwan3 luci-app-mwan3
```

部分固件已内置 `flock`；如果没有，请安装当前软件源中提供 `flock` 命令的包，例如 `util-linux-flock`。包装脚本会用它防止多个定时任务并发登录。

### 2. 上传脚本

把 `NJUPT-AutoLogin.sh` 放到路由器，例如：

```sh
scp NJUPT-AutoLogin.sh root@192.168.1.1:/root/NJUPT-AutoLogin.sh
ssh root@192.168.1.1
chmod 700 /root/NJUPT-AutoLogin.sh
```

### 3. 单账号定时登录

简单场景可以直接在 LuCI 的 `系统 -> 计划任务` 中添加：

```crontab
*/5 * * * * /bin/bash /root/NJUPT-AutoLogin.sh -I njupt -t 2 -n YOUR_ID 'YOUR_PASSWORD'
```

说明：

- `-I njupt` 表示教育网账号；电信为 `ctcc`，移动为 `cmcc`。
- `-n` 表示不限时账号；限时账号不要加 `-n`。
- OpenWrt 上脚本会尝试自动识别 WAN 设备。需要指定接口时再加 `-i wan`、`-i veth0` 等。
- 密码含有特殊字符时请用单引号或双引号包起来。

不过，长期运行不建议把账号密码直接写在 crontab 中。更安全的做法见下面的“账号配置与凭据安全”。

## 账号配置与凭据安全

推荐把账号配置放到路由器本地文件中，让 crontab 只出现接口名，不出现账号和密码：

```text
/root/njupt-autologin/
  login-one.sh
  accounts/
    vwan1.conf
    vwan2.conf
  locks/
```

初始化目录：

```sh
mkdir -p /root/njupt-autologin/accounts /root/njupt-autologin/locks
chmod 700 /root/njupt-autologin
chmod 700 /root/njupt-autologin/accounts /root/njupt-autologin/locks
```

复制示例：

```sh
cp examples/openwrt/njupt-autologin/login-one.sh /root/njupt-autologin/login-one.sh
cp examples/openwrt/njupt-autologin/accounts/vwan1.conf.example /root/njupt-autologin/accounts/vwan1.conf
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
CHECK_URL='http://connect.rom.miui.com/generate_204'
```

计划任务：

```crontab
*/1 * * * * /root/njupt-autologin/login-one.sh vwan1
```

这样 LuCI 计划任务、系统日志和仓库示例中都不会出现真实账号密码。

## OpenWrt 单线多拨

单线多拨的核心是：在同一个物理 WAN 口上创建多个 `macvlan` 虚拟网卡，每个虚拟网卡分别 DHCP、分别认证，再交给 `mwan3` 做分流和故障切换。

这个方案适合以下目标：

- 一个账号限速时，用多个账号叠加带宽。
- 一个限时账号会固定断网时，自动切到另一个不断网账号。
- 保留一个稳定主出口，同时让辅助账号在可用时参与分流。

更完整的研究记录见 [OpenWrt + macvlan + mwan3 单线多拨实践](./doc/openwrt-mwan3-multidial.md)。

### 1. 确认物理 WAN 设备

在 OpenWrt 上查看 WAN 使用的设备：

```sh
uci -q get network.wan.device
uci -q get network.wan.ifname
ip -br link
```

下面示例假设父设备叫 `wan`。如果你的设备是 `eth0.2`、`eth1` 或其他名字，请替换成实际值。

> [!CAUTION]
> 不要直接禁用物理 `wan` 设备。`veth0`、`veth1` 是挂在它上面的 `macvlan` 子设备，父设备 down 掉后，子设备可能出现 `DEVICE_CLAIM_FAILED` 或 DHCP 异常。

### 2. 创建 macvlan 设备

两个账号示例：

```sh
uci set network.veth0='device'
uci set network.veth0.name='veth0'
uci set network.veth0.ifname='wan'
uci set network.veth0.type='macvlan'
uci set network.veth0.mode='vepa'

uci set network.veth1='device'
uci set network.veth1.name='veth1'
uci set network.veth1.ifname='wan'
uci set network.veth1.type='macvlan'
uci set network.veth1.mode='vepa'

uci commit network
```

`mode` 一般使用 `vepa`。如果你的交换/上游环境特殊，也可以测试 `bridge`，但不要把 macvlan 模式当作所有问题的根因；先确认父设备、DHCP、路由和认证出口是否正常。

### 3. 创建 DHCP 接口

```sh
uci set network.vwan1='interface'
uci set network.vwan1.proto='dhcp'
uci set network.vwan1.device='veth0'
uci set network.vwan1.hostname='openwrt-vwan1'
uci set network.vwan1.metric='10'

uci set network.vwan2='interface'
uci set network.vwan2.proto='dhcp'
uci set network.vwan2.device='veth1'
uci set network.vwan2.hostname='openwrt-vwan2'
uci set network.vwan2.metric='20'

uci commit network
/etc/init.d/network reload
```

要点：

- 每个接口使用不同 hostname。
- 每个接口使用不同 metric；主出口 metric 小一些。
- 多个接口都应能拿到 IPv4 地址后再继续配置 mwan3。

### 4. 加入防火墙 WAN 区域

LuCI 路径：

`网络 -> 防火墙 -> 区域 -> wan -> 涵盖的网络`

应包含：

- `wan`
- `wan6`，如果使用 IPv6
- `vwan1`
- `vwan2`

不要把不存在的 `wan1`、`wan2` 填进去。

### 5. 配置 mwan3 接口、成员、策略和规则

LuCI 路径：

`网络 -> 均衡负载`

建议顺序：

1. `接口`：添加 `vwan1`、`vwan2`，跟踪 IP 可用 `223.5.5.5`、`119.29.29.29`。
2. `成员`：给主账号更高优先级和权重，例如 `vwan1` metric 1 weight 10，`vwan2` metric 2 weight 3。
3. `策略`：添加 `balanced` 或 `night_balanced`，包含上面的成员。
4. `规则`：添加 `default_rule_v4`，目标 `0.0.0.0/0`，使用上面的策略。

UCI 示例：

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
/etc/init.d/mwan3 restart
```

权重不要照抄。更合理的做法是按账号可用带宽估算，例如 1000 Mbps 账号 weight 10，300 Mbps 账号 weight 3。

### 6. 为每个接口添加账号配置

`vwan1` 作为稳定主账号：

```sh
IFACE_UCI='vwan1'
DEV='veth0'
ISP='njupt'
LOGIN_ID='YOUR_NJUPT_ID'
LOGIN_PW='YOUR_PASSWORD'
TIME_UNLIMITED='1'
```

`vwan2` 作为限时辅助账号：

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

添加第三个账号时，重复增加：

1. `veth2` 和 `vwan3`
2. firewall zone 中的 `vwan3`
3. mwan3 interface/member/policy
4. `/root/njupt-autologin/accounts/vwan3.conf`
5. crontab 中的一行 `/root/njupt-autologin/login-one.sh vwan3`

### 7. 配置定时任务

```crontab
*/1 * * * * /root/njupt-autologin/login-one.sh vwan1
*/1 * * * * /root/njupt-autologin/login-one.sh vwan2
```

包装脚本的行为：

- 用 `flock` 避免并发运行。
- 如果 mwan3 已认为接口 online，则跳过，避免重复登录导致账号下线。
- 如果接口 offline，必要时短暂停止 mwan3，再测试认证出口。
- 对限时账号可执行重拨、临时随机 MAC、登录、post-check。
- 结束时恢复 mwan3。
- 日志只记录接口和状态，不记录账号密码。

## 单线多拨常见坑

### 只拿到 IP 不代表已认证

`vwan2` 能 DHCP 拿到 IP、能 ping 网关，只能说明二层和 DHCP 基本可用；它仍可能无法访问认证页或公网。应继续测试：

```sh
curl -4 --interface veth1 --connect-timeout 3 --max-time 8 -k -I https://10.10.244.11:802/eportal/
ping -I veth1 -c 3 223.5.5.5
```

### `mwan3 online` 与 `curl --interface` 不是同一层判断

有些情况下，mwan3 运行时会影响路由器本机发起的 `curl --interface veth1` 认证流量。隔离测试：

```sh
/etc/init.d/mwan3 stop
curl -4 --interface veth1 --connect-timeout 3 --max-time 8 -k -I https://10.10.244.11:802/eportal/
/etc/init.d/mwan3 start
```

如果停掉 mwan3 后认证页可达，恢复脚本就应该只在接口 offline 时短暂停 mwan3，而不是每分钟无脑登录。

### `curl --interface <IP>` 可能误判

调试多拨时优先用设备名：

```sh
curl --interface veth1 ...
```

绑定源 IP 时，内核仍可能按主路由选择出口，造成“看起来通了，实际不是这个虚拟网卡通了”的假象。

### 固定 MAC 要谨慎

稳定主账号可以固定 MAC，减少重复认证。限时账号如果出现恢复困难，可以在恢复流程中临时随机 MAC 并重拨，但不建议永久写死所有虚拟口 MAC。

### 不要把长期状态放在 `/tmp`

`/tmp` 重启后会丢失，适合临时输出，不适合保存账号配置、长期状态或锁目录。推荐使用：

```text
/root/njupt-autologin/accounts
/root/njupt-autologin/locks
```

## 脚本参数

一般格式：

```sh
/bin/bash NJUPT-AutoLogin.sh [-i interface] [-I isp] [-t timeout] [-p ipv4_addr] [-r restart_device] [-T sleep_time] [-6] [-m] [-n] [-c] [-l] [-h] [-v] login_id login_password
```

| 选项 | 名称 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `-i` | interface 网络接口 | OpenWrt 自动检测，其他平台默认为 `eth0` | 指定认证使用的接口，例如 `wan`、`veth0` |
| `-I` | ISP 运营商 | `ctcc` | `njupt`、`ctcc`、`cmcc` |
| `-t` | timeout 超时时间 | `2` | 连通性检测和请求超时 |
| `-p` | IPv4 地址 | 自动检测 | 手动指定 IPv4 地址 |
| `-r` | restart_device 网络设备 | - | 登录失败且返回空时可尝试重启接口 |
| `-T` | sleep_time 登录等待时间 | `1` | 与 `-r` 配合使用 |
| `-6` | IPv6 登录 | - | 实验性功能，用于教育网 IPv6 |
| `-m` | MAC 检测 | - | 仅当 MAC 变化且网络不通时尝试登录 |
| `-n` | 不限时账号 | - | 所有时间都会尝试登录 |
| `-c` | 跳过连通性检测 | - | 非多拨场景不要轻易使用 |
| `-l` | 登出模式 | - | 执行登出 |
| `-h` | 帮助 | - | 显示帮助 |
| `-v` | 调试输出 | - | 输出详细执行过程 |

参数：

| 参数 | 名称 |
| --- | --- |
| `login_id` | 登录用户名 |
| `login_password` | 登录密码 |

> [!CAUTION]
> 对已登录账号重复发送登录请求可能导致账号下线。定时任务应先判断连通性或 mwan3 状态，不要在网络正常时无条件登录。

## 其他平台

### Linux / macOS

直接运行脚本并指定接口：

```sh
/bin/bash NJUPT-AutoLogin.sh -i en0 -I ctcc -t 2 YOUR_ID 'YOUR_PASSWORD'
```

Linux 使用前确认依赖：

| 包名 | 备注 |
| --- | --- |
| `bash` | 必须 |
| `curl` | 必须 |
| `net-tools` | 用于部分 IP 获取逻辑 |
| `iconv` | 返回值转编码，缺失通常不影响 IPv4 登录 |
| `network-manager` | Wi-Fi 自动连接相关，OpenWrt 一般没有 |

### MikroTik RouterOS

RouterOS 平台使用方法见 [README_RouterOS.md](./README_RouterOS.md)。

## 更新日志

- 2026.07 添加 OpenWrt 单线多拨、mwan3 恢复、账号配置和凭据安全文档
- 2025.09.09 添加 MAC 地址检测，避免因网络波动重复登陆导致掉线 [@Symb0x76](https://github.com/Symb0x76)
- 2025.04.28 添加重启网络设备再登录的选项 [@RunawayRanger](https://github.com/RunawayRanger)
- 2025.04.18 更换连通性测试链接地址 [@Glucy2](https://github.com/Glucy-2)
- 2024.09.20 实验性添加对校园网 IPv6 权限的获取和 WLAN SSID 的识别 [@SteveXu9102](https://github.com/SteveXu9102)
- 2024.04.17 重构；添加对 macOS 的支持 [@BlockLune](https://github.com/BlockLune)
- 2023.07.23 适配 2023 年 7 月更新的校园网接口
- 2022.09.02 添加对多网卡设备的支持
- 2022.08.31 适配三牌楼校区
- 2022.08.31 添加对不断网账号的支持

## 参考

- [南邮校园网自动登录脚本](https://nosora.dev/archives/204)
- [南邮校园网单线多拨教程](https://nosora.dev/archives/347)
- [南京邮电大学*校园网/电信宽带/移动宽带*路由器共享 WiFi + 自动认证](https://github.com/kaijianyi/NJUPT_NET)
- [校园网自动登录全平台解决方案](https://zhuanlan.zhihu.com/p/364016452)
- [你邮的 IPv6 讨论](https://tieba.baidu.com/p/8707266189?pid=150503656049&cid=150604976178#150604976178)
