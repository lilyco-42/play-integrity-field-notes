# 一页纸诊断顺序

> 不要跳步。这个顺序是**由「改动代价」从小到大排的**：先做零成本的事，
> 确认了再动手机。每一步都给了判定标准和「不过就停」。

前置：找到手机。

```bash
sh scripts/pi-remote.sh discover
# avahi 那一段才是权威的；adb mdns services 空着是常态，不是故障
```

---

## Step 0 · 只读体检（零风险）

```bash
SERIAL=<ip>:<port> sh scripts/pi-remote.sh doctor
```

看 `summary` 那一行：`FAIL=0 WARN=0` → 全好，别再动任何东西。

有 FAIL 就按下面的顺序，**一次只修一个**。

---

## Step 1 · 商店打不开（最常见）

**判定**：

```bash
adb shell 'su -c "logcat -d -b crash | grep -c com.android.vending"'
```

- `0` → 不是崩溃，去 Step 3
- `>0` 且日志里有 `RECEIVER_EXPORTED` / `RECEIVER_NOT_EXPORTED` → **确认是 spoofVendingSdk**

**动手前先确认改的是哪份文件**（这一步错了，改十遍都不生效）：

```bash
adb shell 'su -c "strings /data/adb/modules/playintegrityfix/inject/arm64-v8a.so | grep pif.json"'
# 输出 /pif.json  → 生效的是 /data/adb/pif.json，不是模块目录里那份
```

**修**：

```bash
SERIAL=<ip>:<port> sh scripts/pi-remote.sh fix vending-sdk off
```

**判定通过**：`vending alive, pid=...` + `crash-buffer lines mentioning vending: 0`。

**回退**：脚本最后一行就打印了 `cp ...bak-<时间戳> ...` 命令，照抄即可。

---

## Step 2 · Play Integrity 三红

按这个顺序问，**每一问都可能直接终结排查**：

1. `cat /data/adb/tricky_store/tee_status` 是 `teeBroken=true` 吗？
   → 是的话 target.txt 的目标**必须**带 `!`，不带必红。
2. target.txt 一分钟后 mtime 变了吗？
   → 变了就是有 cron 在覆写它，你写的 `!` 会被冲掉，先断覆写源。
3. `pidof TrickyStore` 有进程吗？`grep -c tricky /proc/$(pidof keystore2)/maps` ≥1 吗？
   → daemon 没跑或没注入，target.txt 写对了也没用。
4. keybox 真的过期了吗？（**最常见的误判**）
   → `python3 scripts/keybox-check.py <keybox.xml>`，过期才去换。

四条都过了还红，才是 PIF 指纹/props 本身的问题。

**修**：

```bash
SERIAL=<ip>:<port> sh scripts/pi-remote.sh fix target
```

**判定通过**：`mtime unchanged -- the overwriter is gone` + `grep -c '!$' target.txt` = 6。

---

## Step 3 · 应用报「请使用官方客户端」

先别怀疑应用。它读的是 Play Integrity 的结果，Step 2 不过这里一定不过。
Step 2 修完，force-stop 该应用再开。

如果 Step 2 全绿它仍报错，才考虑：
- 该应用有自己的完整性校验（自签证书 / 包名白名单），PIF 管不到
- TrickyStore 的 target.txt 漏了它的包名（同样加 `!`）

---

## Step 4 · Zygisk 模块没生效

```bash
ps -A -o ARGS | grep -E '[z]ygisk-ptrace|[z]ygiskd|[c]ompanion'
```

- 没有 `zygisk-ptrace` → 没有任何 Zygisk 实现在注入，PIF 和 Shamiko 全是摆设
- 有 `zygisk-ptrace` 但没有 `companion` → 注入器活着，但模块没挂上

**互斥检查**：`zygisksu` 和 `rezygisk` 同时启用 = 必然失败，留一个。

---

## Step 5 · 还不行

把 `pi-doctor.sh` 的完整输出贴到 issue 里。它已经包含了：
设备与 Android 版本、root 域、崩溃计数、两份 pif.json 的差异、
tee_status、target.txt 行数与 `!` 数、daemon pid、keystore2 映射数、
keybox 证书数、Zygisk 进程、模块清单、待重启更新。

**不要**贴 `pif.json` 全文和 keybox 内容 —— 前者含你的指纹配置，后者是凭证。
