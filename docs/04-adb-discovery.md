
# adb 无线调试发现与连接稳定性

## 1. 症状：明明同一 WiFi，@adb mdns services@ 却是空的

```bash
$ adb mdns services
List of discovered mdns services
（空）
```

## 2. 三个独立原因，常常同时出现

### 原因一：@adb mdns services@ 本身不可靠

- adb daemon 刚重启时，内置 mDNS 后端还没起来（@adb mdns check@ 显示版本号，但不代表已收到广播）
- 多网卡时容易只监听主接口：本例有 @enp1s0@ + @wlan0@ + @docker0@ + @waydroid0@ + @Meta@ 五张网卡
- 手机在 @wlan0@ 侧广播，但 adb 只扫 @enp1s0@（或反之）

### 原因二：IP 变了（最常见！）

无线调试的端口是**临时的**，每次重启重新分配。IP 也会因 DHCP 变化。
本例从 @192.168.1.4@ 变成了 @192.168.10.127@ —— 整个网段都换了。

```bash
$ ping -c 3 192.168.1.4
100% packet loss        # 旧 IP 全死
```

笔记里记着旧 IP 就永远连不上。

### 原因三：无线调试开关被关了

重启后系统不保证自动重新监听。检查：

```bash
adb shell 'settings get global adb_wifi_enabled'
# 1  = 开
# 0/null = 关

adb shell 'getprop service.adb.tcp.port'
adb shell 'getprop persist.adb.tcp.port'
# 空 = 没有持久化端口，重启后不会监听固定端口
```

## 3. 可靠做法：avahi-browse

```bash
avahi-browse -rtp _adb-tls-connect._tcp
```

输出（@=@ 开头的是解析后的完整记录）：

```
=;enp1s0;IPv4;adb-5986a22d-ZvyChm;_adb-tls-connect._tcp;local;Android.local;192.168.10.127;44125;"api=36" "name=PJD110" "v=1"
```

逐字段拆解：

```
=              解析成功（+ 表示只发现未解析）
enp1s0         本机接口
IPv4           协议
adb-5986a22d-ZvyChm   服务实例名（手机随机生成，重启会变）
_adb-tls-connect._tcp 服务类型
local          mDNS 域
Android.local  主机名
192.168.10.127 手机 IP    <-- 要的
44125          端口        <-- 要的
"api=36" "name=PJD110"  TXT 记录（API 等级、设备名）
```

有了 IP:端口，直接：

```bash
adb connect 192.168.10.127:44125
adb devices
# 192.168.10.127:44125   device product:PJD110 model:PJD110 device:OP5929L1
```

### 三个服务类型都要看

```bash
avahi-browse -rtp _adb-tls-connect._tcp     # 正常连接的端口（有了它就能连）
avahi-browse -rtp _adb._tcp                  # 老式无线调试（Android 10 及以下）
avahi-browse -rtp _adb-tls-pairing._tcp      # 配对端口（首次连接需要）
```

## 4. 连接稳定性：每条命令都要重连

**这是实操中最烦的坑**。原因是 adb server 和手机之间的 TLS 会话会因超时断开，
尤其是在脚本化、每条命令一个独立 shell 的情况下。

### 错误写法

```bash
adb shell 'ls /data/adb/modules'      # 可能 device not found
```

### 正确写法

```bash
adb start-server 2>/dev/null
adb disconnect >/dev/null 2>&1
for i in 1 2 3; do
  adb connect 192.168.10.127:44125 2>&1 | tail -1
  sleep 1
  adb devices | grep -q "192.168.10.127:44125.*device" && break
done

D=192.168.10.127:44125
adb -s $D shell 'ls /data/adb/modules'
```

### 遇到 "more than one device/emulator"

mDNS 自动连接的设备（序列号是长串服务名）和手动 connect 的是**两个 transport**：

```bash
$ adb devices
List of devices attached
192.168.10.127:44125                       device
adb-5986a22d-ZvyChm._adb-tls-connect._tcp  device      <-- 同一个手机的第二个入口
```

**处理**：
- 总是用 @-s 192.168.10.127:44125@ 显式指定
- 或者 @adb disconnect@ 清掉全部再重连
- 绝对不要依赖"只有一个设备"的隐式行为

### mDNS 自动连接的设备会变 offline

```bash
$ adb devices
adb-5986a22d-ZvyChm._adb-tls-connect._tcp  offline
```

这个 entry 是 adb 自己尝试连的，TLS 认证没走完就成了 @offline@。
**不影响**你用 @-s IP:PORT@ 的那条 transport。忽略即可。

## 5. 引号地狱：多层嵌套必翻车

```bash
# 想执行：grep -E '^(id|name)=' /data/adb/modules/x/module.prop
adb shell 'su -c "grep -E "^(id|name)=" /data/adb/modules/x/module.prop"'
# sh: syntax error: unexpected '('
```

**三层嵌套**（bash → adb → adb shell → su -c → sh）里，
每一层都会吃一层引号。

### 唯一可靠的解法：push 脚本

```bash
# 1) 本地写好
cat > /tmp/probe.sh <<'EOF'
grep -E '^(id|name)=' /data/adb/modules/playintegrityfix/module.prop
echo "--- files ---"
ls /data/adb/modules/playintegrityfix/
EOF

# 2) push
adb push /tmp/probe.sh /data/local/tmp/probe.sh

# 3) 执行（只剩一层引号）
adb shell 'su -c "sh /data/local/tmp/probe.sh"'
```

**这是本文档最实用的一条建议。** 凡是超过一行的诊断，一律 push 脚本。

## 6. USB 兜底

无线调试彻底不行时：

```bash
# 插 USB 线
adb devices                    # 应该直接出现设备
adb tcpip 5555                 # 切到固定端口
adb connect <手机IP>:5555       # 拔线后仍可无线
```

注意 @adb tcpip 5555@ 需要 **USB 已授权**，且部分魔改 ROM 不支持。

## 7. 排障速查表

| 现象 | 检查 | 修复 |
|---|---|---|
| @adb mdns services@ 空 | @avahi-browse -rtp _adb-tls-connect._tcp@ | 用 avahi 的 IP:端口手动 connect |
| @ping@ 旧 IP 不通 | @ip -4 addr@ 看本机网段 | 手机 IP 大概率也变了 |
| @Connection refused@ | 端口是临时的 | 重新扫 mDNS 拿新端口 |
| @device not found@ | adb server 刚重启 | 先 @adb connect@ 再操作 |
| @more than one device@ | 有两个 transport | 一律 @-s@ 指定序列号 |
| @unauthorized@ | 手机没确认授权弹窗 | 解锁手机点"允许" |
| 重启后连不上 | @getprop persist.adb.tcp.port@ 空 | 需要重新开无线调试或用 USB |
