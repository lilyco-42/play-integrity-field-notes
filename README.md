# Android Play Integrity / KernelSU 实修手册

> 一次真实故障的完整复盘：**Google Play 商店一打开就闪退**、**Play Integrity 三项全红**、
> **X（Twitter）报「请使用官方 X 应用继续操作」**、**\`adb mdns services\` 扫不到手机**。
> 本文给出四条根因、可复现的验证方法、以及每一步的回退命令。
>
> [![offline tests](https://github.com/lilyco-42/play-integrity-field-notes/actions/workflows/test.yml/badge.svg)](https://github.com/lilyco-42/play-integrity-field-notes/actions/workflows/test.yml)

全部结论都来自一台真机（OnePlus PJD110 / OP5929L1 / Android 16 / SukiSU Ultra / ksud 4.2.0）
的实测，不是从教程里抄的。

---

## 0. TL;DR — 四条根因

| # | 症状 | 根因 | 一行修复 |
|---|---|---|---|
| A | Play 商店启动即闪退 | PIF 的 \`spoofVendingSdk: true\` 让商店进程看到错误的 SDK_INT，触发 Android 14+ 的 \`RECEIVER_EXPORTED\` 强制检查 | 把**活的** \`/data/adb/pif.json\` 里该项改 \`false\` |
| B | Play Integrity 三项全红 | \`teeBroken=true\` 的机器必须给 target.txt 目标加 \`!\`，但 target.txt 被另一个模块的 crond 每分钟覆写 | 停掉 TEE_AutoList 的 crond，写回 6 条 \`!\` |
| C | X 报「请使用官方 X 应用」 | 同 B（BASIC/DEVICE/STRONG 全红） | 同 B |
| D | \`adb mdns services\` 为空、连不上手机 | IP 因 DHCP 换网段 + adb mDNS 后端在多网卡下漏包 | \`avahi-browse -rtp _adb-tls-connect._tcp\` 拿真实端口 |

**最容易踩的坑：改错文件。** 生效的 PIF 配置是 \`/data/adb/pif.json\`，
不是 \`/data/adb/modules/playintegrityfix/pif.json\`。见 [docs/02](docs/02-pif-two-configs.md)。

---

## 1. 症状 A：Play 商店启动即闪退

### 现象

点开 Play 商店 → 白屏 1 秒 → 退回桌面。\`logcat -b crash\` 里反复出现：

\`\`\`
java.lang.SecurityException: com.android.vending: One of RECEIVER_EXPORTED or
RECEIVER_NOT_EXPORTED should be specified when a receiver isn't being registered
exclusively for system broadcasts
    at com.android.server.am.BroadcastController.registerReceiverWithFeatureTraced(BroadcastController.java:493)
    at com.android.server.am.BroadcastController.registerReceiverWithFeature(BroadcastController.java:262)
    at android.app.IActivityManager$Stub.onTransact(IActivityManager.java:2795)
\`\`\`

\`am_crash\` 事件里也能看到同样的 \`java.lang.SecurityException\`。

### 根因链

\`\`\`
PlayIntegrityFix 的 spoofVendingSdk: true
        │
        │  在 vending 进程里 hook，让 Build.VERSION.SDK_INT 返回一个更低的假值
        ▼
com.android.vending 认为自己在旧 Android 上跑
        │
        │  于是走旧代码路径：registerReceiver(...) 不传 RECEIVER_EXPORTED / RECEIVER_NOT_EXPORTED
        ▼
但真实平台是 Android 14+ (API 34)，系统**按真实平台等级**强制检查这个 flag
        │
        ▼
SecurityException → 进程崩溃 → 商店"打不开"
\`\`\`

关键点：**SDK_INT 是应用自己读的，但广播接收器的 flag 检查是系统做的**。
骗过了应用的自我认知，骗不过系统的强制校验 —— 两边认知不一致，必然炸。

### 修复

见 [docs/02-pif-two-configs.md](docs/02-pif-two-configs.md)。

\`\`\`bash
adb shell 'su -c "cp /data/adb/pif.json /data/adb/pif.json.bak"'
adb shell 'su -c "sed -i \"s/\\\"spoofVendingSdk\\\": true/\\\"spoofVendingSdk\\\": false/\" /data/adb/pif.json"'
adb shell 'su -c "am force-stop com.android.vending; am force-stop com.google.android.gms"'
adb shell 'su -c "am start -n com.android.vending/com.google.android.finsky.activities.MainActivity"'
\`\`\`

### 代价（必须知道）

| spoofVendingSdk | Play 商店 | Play Integrity |
|---|---|---|
| \`true\` | ❌ 闪退 | 更完整 |
| \`false\` | ✅ 可用 | 可能显示"设备未通过认证"，部分区服应用搜不到 |

**二者只能选一个。** 大多数人的实际需求是"商店能用"，所以选 \`false\`。

---

## 2. 症状 B/C：Play Integrity 三红 / X 拦截

### 现象

- Play Integrity API Checker：BASIC / DEVICE / STRONG 三项全红
- X（Twitter）原生 App 登录后提示「请使用官方 X 应用继续操作」
- 银行 / 支付类 App 提示环境异常

### 根因 1：\`teeBroken=true\` 需要 \`!\` 后缀

\`\`\`bash
adb shell 'su -c "cat /data/adb/tricky_store/tee_status"'
# teeBroken=true
\`\`\`

解锁 bootloader 的 OnePlus 机型 TEE 掉级，硬件 attestation 走不通。
TrickyStore 的 \`target.txt\` 里，**目标包名后加 \`!\` = 强制软件伪造（keybox）**：

\`\`\`
com.google.android.gms.unstable!
com.android.vending!
com.google.android.apps.walletnfcrel!
com.google.android.gms!
com.google.android.gsf!
io.github.vvb2060.keyattestation!
\`\`\`

### 根因 2：另一个模块在每分钟覆写 target.txt

\`\`\`bash
stat -c "%y" /data/adb/tricky_store/target.txt
# 2026-11-25 12:29:31   ← 整分变化 = 有 cron 在写
ps -A -o PID,ARGS | grep crond
# ... /data/adb/modules/TEE_AutoList/cron/root  → * * * * * sh Whitelist520/独断万古.sh
\`\`\`

\`独断万古.sh\` 是 base64 + eval 混淆的，静态 grep 搜不到 \`target.txt\` 字样，
但**每分钟整分 mtime 变化 + 内容被重排成 208 行纯包名（android 开头）** 足以证实它是写入者。

**你写的 \`!\` 会被冲掉，所以"改了没生效"。**

### 修复顺序（顺序不能错）

1. 禁用 TEE_AutoList 模块（断掉覆写源）
2. 杀掉它的 crond（已运行的进程不受 disable 影响）
3. 写回 6 条 \`!\` 到 target.txt
4. **跨一个整分**验证 mtime 不再变化
5. 确认 TrickyStore daemon 在跑

见 [docs/03-trickystore.md](docs/03-trickystore.md)。

---

## 3. 症状 D：\`adb mdns services\` 为空

### 现象

\`\`\`bash
$ adb mdns services
List of discovered mdns services
（空）
\`\`\`

但手机明明在同一 WiFi。

### 为什么

1. **\`adb mdns services\` 自己不可靠** —— daemon 刚重启时 mDNS 后端还没起来；
   多网卡（\`enp1s0\` + \`wlan0\` + \`docker0\` + \`waydroid0\`）时容易只监听主接口而错过广播。
2. **`IP 变了** —— DHCP 换网段后，笔记里的旧 IP（\`192.168.1.4\`）全是死的，
   \`ping\` 100% loss，\`adb connect\` 自然 \`Connection refused\`。

### 可靠做法

\`\`\`bash
avahi-browse -rtp _adb-tls-connect._tcp
# =;enp1s0;IPv4;adb-5986a22d-ZvyChm;_adb-tls-connect._tcp;local;Android.local;192.168.10.127;44125;"api=36" "name=PJD110" "v=1"
#                                              ↑ 真实 IP          ↑ 真实端口
\`\`\`

拿到 \`IP:端口\` 后 \`adb connect\` 即可。见 [docs/04-adb-discovery.md](docs/04-adb-discovery.md)。

---

## 4. 常见误判（我踩过的）

| 误判 | 真相 |
|---|---|
| "TrickyStore 报 \`verify1 failed / Bad file descriptor\` 说明文件坏了" | 先看 daemon 是否**正在跑**、\`keystore2\` 里有没有 \`libtricky_store.so\` 映射。日志可能是旧的，\`logcat\` 不会自动清 |
| "keybox 过期了" | 用 \`openssl x509 -noout -dates\` 逐张验。本例 6 张证书全部 2034/2042 到期，根本不是问题 |
| "改模块目录里的 pif.json 就行了" | 生效的是 \`/data/adb/pif.json\`。用 \`strings inject/arm64-v8a.so \| grep pif.json\` 确认路径 |
| "grep -i ksu 就能搜到 KernelSU" | 会命中 \`checksum\`、\`kSUD\`。必须 \`grep -o -i -E "kernelsu\|ksud\|apatch\|magisk"\` |
| "两个 zygisk 模块都装着更稳" | rezygisk 和 zygisksu 互斥。同时开 → 注入失败，模块列表里出现 \`[❌ Last injection failed!]\` |

---

## 5. 工具

三个脚本，全部**可离线测试**（无需手机就能验证逻辑）：

| 文件 | 角色 | 会不会改手机 |
|---|---|---|
| `scripts/pi-doctor.sh` | 只读体检，8 节 [OK]/[WARN]/[FAIL] | **不会**（有测试逐文件 sha256 证明） |
| `scripts/pi-fix.sh` | `vending-sdk on|off` / `target` 两个可逆修复 | 会，但先备份、最后打印回退命令、**从不 reboot** |
| `scripts/pi-remote.sh` | 主机侧包装：连手机 → push → `su -c` 执行 → 清理 | 间接 |
| `scripts/keybox-check.py` | 逐张验证 keybox 证书有效期 | **不会**（纯本地读文件） |

```bash
# 1) 先找手机（adb mdns 常常是空的，不代表手机有问题）
sh scripts/pi-remote.sh discover

# 2) 只读体检
SERIAL=192.168.10.127:44125 sh scripts/pi-remote.sh doctor

# 3) 修 Play 商店闪退（改 pif.json，自动备份，打印回退命令）
SERIAL=192.168.10.127:44125 sh scripts/pi-remote.sh fix vending-sdk off

# 4) 修 target.txt（停掉覆写它的 cron，补回 6 条 !，跨整分验证）
SERIAL=192.168.10.127:44125 sh scripts/pi-remote.sh fix target

# 5) 顺手排查"是不是 keybox 过期了"这个最常见误判
adb pull /data/adb/tricky_store/keybox.xml /tmp/kb.xml
python3 scripts/keybox-check.py /tmp/kb.xml
```

### 为什么需要 pi-remote.sh

手写 `adb shell 'su -c "..."'` 一定会在某个带括号的命令上炸：

```
$ adb shell 'su -c "grep -E '^(id|name)=' /data/adb/modules/x/module.prop"'
/system/bin/sh: syntax error: unexpected '('
```

引号要穿透三层 shell（本地 → adb → 设备 sh → su），几乎不可能正确转义。
**唯一可靠的做法是 push 一个脚本文件再执行它**，让设备侧只剩一层引号。
`pi-remote.sh` 做的就是这件事，并且每次执行前先 `adb connect`
（无线调试的连接会在两次调用之间掉）。

### 离线测试

```bash
sh tests/run-tests.sh          # 71 条断言，全绿才算改对了
sh tests/run-tests.sh -v       # 失败时把脚本输出也打出来
```

测试不 mock 逻辑，而是**用 `tests/fixtures/` 造一台假手机**（`root-good` 健康 /
`root-broken` 真故障 / `root-nokey` 缺键），再用 `tests/fixtures/bin/` 的
`getprop`/`pidof`/`logcat`/`ps`/`ksud`/`adb` 桩替换系统命令。
脚本通过 `PI_ROOT` / `PI_PROC` / `PI_FIXTURE_*` 接受重定位，
所以跑的是**真代码**，不是替身。

其中一条测试专门证明 doctor **确实只读**：跑之前和跑之后对整棵 fixture 树
逐文件比对 sha256，必须完全一致。

## 6. 硬约束（血的教训）

> **reboot / am start / input keyevent / 模块安装 / \`ksud feature set\` / \`pm clear\` 这类
> 改变手机运行态的动作，执行前必须先说明风险、影响范围、可逆性和回退命令，等确认再动。**

**优先只读**：\`adb devices\` / \`getprop\` / \`dumpsys\` / \`cat\` / \`logcat -d\`。

**设备失联时**只允许网络层 \`adb connect\` 与 mDNS 发现，**不得再次 reboot** ——
无线调试端口是临时的，重启后不会自动监听，二次 reboot 只会让恢复更难。

---

## 7. 文档索引

- [docs/01-play-store-crash.md](docs/01-play-store-crash.md) — RECEIVER_EXPORTED 崩溃的完整分析
- [docs/02-pif-two-configs.md](docs/02-pif-two-configs.md) — 两份 pif.json 哪个才算数
- [docs/03-trickystore.md](docs/03-trickystore.md) — TEE broken、target.txt、keybox、daemon
- [docs/04-adb-discovery.md](docs/04-adb-discovery.md) — mDNS 发现与连接稳定性
- [docs/05-zygisk.md](docs/05-zygisk.md) — Zygisk 提供者互斥
- [docs/06-doctor-checklist.md](docs/06-doctor-checklist.md) — 一页纸诊断顺序（照着做）

## License

MIT
