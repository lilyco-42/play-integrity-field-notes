
# Play 商店启动即闪退 —— RECEIVER_EXPORTED 全链分析

## 1. 完整崩溃栈

```
11-25 16:48:37.536 18982 19070 E OplusExceptionHelper: Process: com.android.vending, PID: 18982
11-25 16:48:37.536 18982 19070 E OplusExceptionHelper: java.lang.SecurityException: com.android.vending:
    One of RECEIVER_EXPORTED or RECEIVER_NOT_EXPORTED should be specified
    when a receiver isn't being registered exclusively for system broadcasts
11-25 16:48:37.536 18982 19070 E OplusExceptionHelper:   at android.os.Parcel.createExceptionOrNull(Parcel.java:3369)
11-25 16:48:37.536 18982 19070 E OplusExceptionHelper:   at android.os.Parcel.createException(Parcel.java:3353)
11-25 16:48:37.536 18982 19070 E OplusExceptionHelper:   at android.os.Parcel.readException(Parcel.java:3336)
11-25 16:48:37.550 18982 19070 E AndroidRuntime: java.lang.SecurityException: com.android.vending:
    One of RECEIVER_EXPORTED or RECEIVER_NOT_EXPORTED should be specified ...
```

@am_crash@ 事件（@logcat -b events@）里的远程栈更直观：

```
I am_crash: [10366,0,com.android.vending,684375749,java.lang.SecurityException,
  com.android.vending: One of RECEIVER_EXPORTED or RECEIVER_NOT_EXPORTED should be specified ...,
  Parcel.java,3369,0]
I am_crash:      at com.android.server.am.BroadcastController.registerReceiverWithFeatureTraced(BroadcastController.java:493)
I am_crash:      at com.android.server.am.BroadcastController.registerReceiverWithFeature(BroadcastController.java:262)
I am_crash:      at com.android.server.am.ActivityManagerService.registerReceiverWithFeature(ActivityManagerService.java:15618)
I am_crash:      at android.app.IActivityManager$Stub.onTransact(IActivityManager.java:2795)
I am_crash:      at com.android.server.am.ActivityManagerService.onTransact(ActivityManagerService.java:3000)
```

**注意栈的方向**：崩溃发生在 @com.android.server.am.BroadcastController@ —— 这是**系统服务端**，
不是应用自己的代码。应用调用 @registerReceiver@ → binder 到 system_server → system_server
做 flag 校验 → 校验失败 → 抛回给应用 → 应用无法 catch（SecurityException 在 binder 层抛出）。
所以这是**必然崩溃**，应用层没有任何补救余地。

## 2. 为什么 spoofVendingSdk 会触发它

Android 14 (API 34) 起，@Context.registerReceiver()@ 对**非系统广播**的接收器
强制要求显式声明 @RECEIVER_EXPORTED@ 或 @RECEIVER_NOT_EXPORTED@：

```java
// Android 13 及以下：可选参数，不传就默认旧行为
registerReceiver(receiver, filter);

// Android 14+：不传就抛 SecurityException
registerReceiver(receiver, filter, RECEIVER_EXPORTED);   // 或 NOT_EXPORTED
```

这段校验由 **system_server 按真实平台等级**执行。而 PlayIntegrityFix 的
@spoofVendingSdk@ 做的是：

```
在 vending 进程内 hook Build.VERSION.SDK_INT 的读取
→ vending 读到的 SDK_INT 变成比如 33（Android 13）
→ vending 走 Android 13 的代码分支，registerReceiver 不传 flag
→ 但 system_server 仍是 API 36 的真实 Android 16，强制检查
→ SecurityException
```

一句话：**SDK_INT 骗得过应用自己，骗不过系统服务。**

原始 pif.json：

```json
{
  "FINGERPRINT": "google/lynx_beta/lynx:16/BP31.250610.009/13905196:user/release-keys",
  "MANUFACTURER": "Google",
  "MODEL": "Pixel 7a",
  "SECURITY_PATCH": "2025-07-05",
  "spoofBuild": true,
  "spoofProvider": true,
  "spoofProps": true,
  "spoofSignature": true,
  "DEBUG": true,
  "spoofVendingSdk": true      <- 元凶
}
```

## 3. 定位方法（不靠猜）

### 3.1 确认崩溃在 RECEIVER_EXPORTED

```bash
adb shell 'logcat -d -b crash | grep -A5 "com.android.vending"'
adb shell 'logcat -d -b events | grep am_crash'
```

### 3.2 找到最早一次崩溃时间，对齐"最近改了什么"

```bash
adb shell 'logcat -d -b crash | grep -m1 "RECEIVER"'
# 11-25 13:27:43.664 ...   <- 崩溃起点
```

本例崩溃起点 13:27，而 12:12–13:25 正是上一轮改模块配置的时间窗 —— 时间线一拍即合。

### 3.3 验证 spoofVendingSdk 确实在生效

```bash
adb shell 'su -c "cat /data/adb/pif.json"'
```

如果这里是 @true@，基本可以定案。

## 4. 修复与验证

```bash
# 1) 备份
adb shell 'su -c "cp /data/adb/pif.json /data/adb/pif.json.bak-$(date +%Y%m%d-%H%M%S)"'

# 2) 改 false（注意只匹配 JSON 里那个键，别误伤其他行）
adb shell 'su -c "sed -i s/spoofVendingSdk[[:space:]]*:[[:space:]]*true/spoofVendingSdk\\": false/ /data/adb/pif.json"'

# 3) 清日志
adb shell 'su -c "logcat -c"'

# 4) 让 PIF 重新注入（force-stop 比 kill 干净）
adb shell 'su -c "am force-stop com.android.vending; am force-stop com.google.android.gms"'

# 5) 重启商店
adb shell 'su -c "am start -n com.android.vending/com.google.android.finsky.activities.MainActivity"'
```

> sed 的引号在 adb → su → sh 三层嵌套里非常容易翻车。更稳的做法是把脚本
> push 到手机上再执行，见 [04-adb-discovery.md](04-adb-discovery.md) 第 4 节。

**验证三条**（缺一不可）：

```bash
# a) 进程活着
adb shell 'pidof com.android.vending'
# 21213

# b) 零新崩溃
adb shell 'logcat -d -b crash | grep -c com.android.vending'
# 0

# c) 真的在前台（不是启动后立刻被杀）
adb shell 'dumpsys activity activities | grep -m1 ResumedActivity'
# ResumedActivity: ActivityRecord{... com.android.vending/com.google.android.finsky.activities.MainActivity}
```

## 5. 为什么 force-stop 而不是 kill

PIF 的注入发生在**进程 fork 时**（zygisk hook）。@kill -9@ 只是杀进程，
下次 fork 时 PIF 会**重新读** pif.json —— 理论上也行。
但 @am force-stop@ 更彻底：清掉 tasks、清掉 companion 连接、保证 PIF 重新走完整初始化路径。
实测 @kill -9@ 后有时 vending 起不来 3~5 秒，@force-stop@ 后稳定。

## 6. 副作用范围

| 项目 | 影响 |
|---|---|
| Play 商店 | 恢复 |
| Play Integrity | 可能变为"设备未通过认证"（vending 不再伪装成低 SDK） |
| 已安装应用 | 无影响 |
| 系统稳定性 | 无影响 |

如果 Play Integrity 因为这个变化掉级，那是**必然的 trade-off**，不能两全。
@spoofVendingSdk@ 的存在本身就是为了在"商店认证"和"商店能开"之间取舍。
