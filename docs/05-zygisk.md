
# Zygisk 提供者：rezygisk 与 zygisksu 互斥

## 1. 症状

```bash
adb shell 'su -c "ksud module list"' | grep -A3 zygisksu
# {
#   "zygisk_running": "true",
#   "zygisk": "false",
#   "enabled": "false",
#   "id": "zygisksu",
#   "[❌": "Last injection failed!] ",
#   "mount": "false"
# }
```

@module.prop@ 的内容都被 ksud 改写了：

```bash
adb shell 'su -c "cat /data/adb/modules/zygisksu/module.prop"'
# [❌ Last injection failed!]
```

## 2. 根因：两套 Zygisk 实现抢同一个 hook 点

| 模块 | 实现方式 | 备注 |
|---|---|---|
| @zygisksu@ | ZygiskNext 内核模块 | 依赖 KSU 的 susfs/injection |
| @rezygisk@ | 用户态 ptrace 注入 | 更兼容 |

两者都想 hook @zygote@ 的 fork，同时装 → 后启动的那个注入失败。

**判断当前谁在工作**：

```bash
adb shell 'su -c "ps -A -o PID,ETIME,ARGS | grep zygisk"'
# 1617   03:36:34  zygisk-ptrace64 monitor          <- rezygisk
# 1764   03:36:33  zygiskd64                        <- rezygisk
# 1828   03:36:33  zygiskd32                        <- rezygisk
# 5020   03:36:24  zygiskd64-zygisk-assistant companion 13
# 15108  03:35:00  zygiskd64-playintegrityfix companion 14
```

@zygisk-ptrace64@ 是 rezygisk 的标志（ptrace 注入）。zygisksu 不走 ptrace。

**结论**：rezygisk 在工作，zygisksu 是死掉的残留。

## 3. 判断哪个该留

```bash
# 看各自是否能提供 companion（ZYGISK 模块依赖这个接口）
adb shell 'su -c "ps -A -o ARGS | grep companion"'
# zygiskd64-zygisk-assistant companion 13   <- 有，说明注入正常
# zygiskd64-playintegrityfix companion 14   <- 有
```

有 companion 进程 = Zygisk 框架正常工作，依赖它的模块（PIF、assistant）可以跑。

如果 companion 一个都没有 → Zygisk 框架坏了，需要排查。

## 4. 清理 zygisksu 残留

### 先确认不依赖它

```bash
adb shell 'su -c "cat /data/adb/modules/zygisksu/disable"'   # 应已存在（0 字节）
adb shell 'su -c "ls /data/adb/zygisksu/"'                   # 只剩 memory_type
```

### 移除

```bash
adb shell 'su -c "ksud module remove zygisksu"'
# 重启后生效
```

> 这一步会**要求重启**。按硬约束，执行前确认：
> - 影响的只是模块目录，不碰数据
> - 回退：重新安装 zygisksu 模块（不推荐，因为和 rezygisk 冲突）
> - 如果重启后 Zygisk 挂了：先禁用 rezygisk 再启用 zygisksu

### 也可以不动

如果只是觉得 @ksud module list@ 里那条 @[❌ Last injection failed!]@ 碍眼，
**建议不动**。它只是个状态字符串，不影响功能。
为了一个显示问题去重启，性价比很低。

## 5. 什么时候必须处理

| 场景 | 处理 |
|---|---|
| companion 进程存在、模块功能正常 | 不用管，忽略报错 |
| 所有 Zygisk 模块都不工作 | 逐个禁用排查 |
| 想换回 zygisksu | 先 @ksud module disable rezygisk@，重启，再 enable zygisksu |
| 升级 KSU 后注入失败 | 检查 susfs 版本兼容性 |

## 6. 相关：模块禁用标记

```bash
# 列出所有被禁用的模块
adb shell 'su -c "ls -d /data/adb/modules/*/disable 2>/dev/null"'
```

机制：目录里存在 @disable@ 文件 = 模块禁用。
@ksud module disable X@ 就是 @touch /data/adb/modules/X/disable@。

**回退**：@rm /data/adb/modules/X/disable@ 或 @ksud module enable X@。

同理 @remove@ 文件 = 下次重启删除。

## 7. 本机的模块全貌（参考）

```bash
adb shell 'su -c "
for m in /data/adb/modules/*/; do
  i=$(basename $m)
  d=$([ -e $m/disable ] && echo DISABLED || echo enabled)
  v=$(grep -m1 ^version= $m/module.prop 2>/dev/null | cut -d= -f2-)
  echo "$i | $d | $v"
done"'
```

本例 18 个模块的输出：

```
HID_Mao              | DISABLED | v1.18
RescueBrick          | enabled  | 22.6
TEE_AutoList         | DISABLED |
TS-evolution         | DISABLED | 1.0
ZaYuZaYu             | DISABLED | V2.5
built-in-busybox     | enabled  | v0.1.0
device_faker         | DISABLED | v1.5.0
hybrid_mount         | enabled  | 6.2.6
netproxy             | enabled  | v8.5.0
playintegrityfix     | enabled  | v3.0
rezygisk             | enabled  | v1.0.0
tricky_store         | enabled  | v1.4.1
ts_enhancer_extreme  | DISABLED | v1.0.0
zygisk-assistant     | enabled  | v2.1.4
zygisk-sui           | DISABLED | v13.5.4.3
zygisk_lsposed       | DISABLED | v1.9.2
zygisk_shamiko       | DISABLED | v1.2.5
zygisksu             | DISABLED |
```

**一次只启用一个** Zygisk 相关模块，启一个测一次，否则出问题无法定位。
