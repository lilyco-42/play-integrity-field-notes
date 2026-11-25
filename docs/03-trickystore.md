
# TrickyStore 全解：TEE broken、target.txt、keybox、daemon

## 1. 四个概念先分清

| 名词 | 是什么 | 出错时症状 |
|---|---|---|
| @tee_status@ | 本机 TEE 是否可用（@teeBroken=true/false@） | 决定 target.txt 要不要加 @!@ |
| @target.txt@ | 哪些包走"软件伪造"（加 @!@）或"正常处理" | 三红 / 应用被拦 |
| @keybox.xml@ | 伪造用的证书链（含私钥） | STRONG 失败 |
| @daemon@ | 后台进程，负责把 hook 塞进 @keystore2@ | 全部失效 |

## 2. tee_status：先看这个

```bash
adb shell 'su -c "cat /data/adb/tricky_store/tee_status"'
# teeBroken=true
```

解锁 bootloader 的 OnePlus / 部分小米机型，TEE（可信执行环境）降级，
硬件 attestation 链断裂。TrickyStore 对此的处理是：

- @teeBroken=false@（TEE 正常）→ @target.txt@ 里的包名**不加** @!@，走真实硬件路径
- @teeBroken=true@（TEE 坏了）→ 必须**加** @!@，强制走 keybox 软件伪造

**加错的后果**：TEE 坏了却不加 @!@ → 硬件路径必然失败 → BASIC/DEVICE/STRONG 全红。

## 3. target.txt：两个坑叠在一起

### 坑一：格式

```
# 正确（teeBroken=true）
com.google.android.gms.unstable!
com.android.vending!
com.google.android.apps.walletnfcrel!
com.google.android.gms!
com.google.android.gsf!
io.github.vvb2060.keyattestation!

# 错误（teeBroken=true 却不加 !）
com.google.android.gms
com.android.vending
```

@!@ 的含义在源码里是 "force software attestation"（强制软件证明）。
不加 @!@ = 尝试硬件 = 这台机器必然失败。

### 坑二：另一个模块在覆写它

```bash
adb shell 'su -c "stat -c \"%y %s\" /data/adb/tricky_store/target.txt"'
# 2026-11-25 12:29:31.150833403 +0800 4471
```

**判断是否有 cron 在写**：

1. 记下 mtime
2. 等到下一个整分（比如 12:29:00 → 12:30:00）
3. 再看 mtime —— 如果变了，且有 cron 进程，就是它

```bash
adb shell 'su -c "ps -A -o PID,ARGS | grep -i cron"'
# 9055 /data/adb/modules/TEE_AutoList/cron/root
```

```bash
adb shell 'su -c "cat /data/adb/modules/TEE_AutoList/cron/root"'
# * * * * * sh /data/adb/modules/TEE_AutoList/Whitelist520/独断万古.sh
```

@独断万古.sh@ 是 **base64 + eval 混淆**的：

```bash
head -3 /data/adb/modules/TEE_AutoList/Whitelist520/独断万古.sh
# #!/system/bin/sh
# eval "$(echo 'IyEvYmluL3No...' | base64 -d)"
```

静态 @grep target.txt@ 搜不到它。**但两个间接证据足够定罪**：

1. mtime 每分钟整分变化
2. 内容被重排：@android@ 开头、208 行、纯包名、@!@ 全部消失

这就是"我明明加了 @!@ 却没生效"的真相。

## 4. keybox.xml：不是它的问题

```bash
# 拉下来逐张验证（在 PC 上）
adb shell 'su -c "cat /data/adb/tricky_store/keybox.xml"' > keybox.xml
python3 scripts/keybox-check.py keybox.xml
```

本例 6 张证书的实测结果：

```
cert[0] subject=title=TEE, serialNumber=19df040a...  2024-07-12 -> 2034-07-10
cert[1] subject=title=TEE, serialNumber=7b4d2a5d...  2024-07-12 -> 2034-07-10
cert[2] subject=serialNumber=f92009e853b6b045      2022-03-20 -> 2042-03-15
cert[3] subject=title=TEE, serialNumber=19df040a...  2024-07-12 -> 2034-07-10
cert[4] subject=title=TEE, serialNumber=7b4d2a5d...  2024-07-12 -> 2034-07-10
cert[5] subject=serialNumber=f92009e853b6b045      2022-03-20 -> 2042-03-15
```

**全部有效，最早 2034 年到期。** keybox 不是问题 —— 别在它身上浪费时间。

> 一个常见的假象：@keybox.xml@ 里的 PEM 是**去掉了换行**的
> （@-----BEGINCERTIFICATE-----@ 连在一起）。@openssl x509@ 直接读会失败。
> 必须先手动按 64 字符折行再解析，脚本见 @scripts/keybox-check.py@。

## 5. daemon：怎么判断它真的在工作

### 5.1 进程在跑

```bash
adb shell 'su -c "ps -A -o PID,ETIME,ARGS | grep -i tricky"'
# 3487  03:38:28  busybox sh /data/adb/modules/tricky_store/service.sh
# 3488  03:38:28  TrickyStore
```

@ETIME 03:38:28@ = 已稳定运行 3 小时 38 分。如果只有 @service.sh@ 没有 @TrickyStore@，
说明 daemon 反复启动失败（@service.sh@ 里的 while 循环会一直重试）。

### 5.2 hook 真的注入进 keystore2 了

**这是最硬的证据**：

```bash
adb shell 'su -c "
  K=$(pidof keystore2)
  grep -c tricky /proc/$K/maps
"'
# 3
```

3 段映射 = @libtricky_store.so@ 的 @r-xp@ / @r--p@ / @rw-p@ 三个段。
如果返回 0，说明 hook 没生效，daemon 再"在跑"也没用。

### 5.3 日志可能是旧的

```bash
adb shell 'su -c "logcat -d | grep -c -i \"verify1 failed\""'
# 0
```

如果记忆里/笔记里记着 @E TrickyStore: verify1 failed@，**先确认现在还在不在报**。
@logcat@ 是环形缓冲，旧日志会一直留着，容易被误认为"还在出错"。
清掉再观察：

```bash
adb shell 'su -c "logcat -c"'
# 等 2 分钟
adb shell 'su -c "logcat -d | grep -i -E \"verify1|unverified|Bad file descriptor\""'
```

## 6. 完整修复流程

```bash
# 0) 前置检查
adb shell 'su -c "cat /data/adb/tricky_store/tee_status"'          # 应为 teeBroken=true
adb shell 'su -c "pidof keystore2"'                                 # 应非空

# 1) 断掉覆写源
adb shell 'su -c "touch /data/adb/modules/TEE_AutoList/disable"'
adb shell 'su -c "setprop ctl.stop crond" 2>/dev/null || true'
adb shell 'su -c "pkill -f TEE_AutoList" 2>/dev/null || true'

# 2) 备份
adb shell 'su -c "cp /data/adb/tricky_store/target.txt /data/adb/tricky_store/target.txt.bak-$(date +%Y%m%d-%H%M%S)"'

# 3) 写回 6 条 !
adb push scripts/write-target.sh /data/local/tmp/write-target.sh
adb shell 'su -c "sh /data/local/tmp/write-target.sh"'

# 4) 跨整分验证
adb shell 'su -c "stat -c %y /data/adb/tricky_store/target.txt"'
sleep 70
adb shell 'su -c "stat -c %y /data/adb/tricky_store/target.txt"'
# 两次输出相同 = 覆写源已断

# 5) 确认 ! 还在
adb shell 'su -c "grep -c \"\\!\" /data/adb/tricky_store/target.txt"'
# 6
```

## 7. 文件同源问题（进阶）

TrickyStore 的 @verify.sh@ 会对每个文件做 sha256 校验。
**第三方 CI 构建 + 官方 release 混装会触发校验失败**。

本例实测的官方 245 值：

```
service.apk         75a78b56d7c6615cf49dfad8c7b3ed22b966ce506c99e4d664dacb4298c5e54d
machikado           9966ed4617b73493147fda4508e47e5f82eb90675af664716bba93279a7f7c32
mazoku              2228e297b52440590af3c19177ed79fd899b35b1586d5580e0bea6380520f01b
libtricky_store.so  6d729980d400d656e5f2908dc86c69104f49e7067961f3fc43dec4b30804cc91
module.prop         5f37d592ffb95b278a865409f0beeb9ccc5e3c49d6caefc9ecb338d0ce736251
```

```bash
# 自查
adb shell 'su -c "cd /data/adb/modules/tricky_store && sha256sum service.apk machikado mazoku module.prop"'
```

不匹配就整组换成官方 release 的同版本文件，**不要混装**。

## 8. 错误诊断对照表

| 日志 | 含义 | 处理 |
|---|---|---|
| @verify1 failed@ | 文件 sha256 与官方不符 | 检查是否混装第三方构建 |
| @unverified!@ | keybox 校验失败 | 换 keybox / 检查证书 |
| @write failed with 9: Bad file descriptor@ | daemon 与 keystore2 通信断 | 重启 daemon |
| @keybox.xml not found@ | 路径错 | 确认 @/data/adb/tricky_store/keybox.xml@ |
| 三红但无任何日志 | target.txt 没加 @!@ | 按 tee_status 加 |
