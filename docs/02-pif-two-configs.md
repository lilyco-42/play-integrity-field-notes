
# 两份 pif.json —— 哪个才真正生效

这是整件事里**最容易踩的坑**，也是第一次修复失败的原因。

## 1. 现象

```bash
adb shell 'su -c "find /data/adb -name pif.json"'
# /data/adb/pif.json
# /data/adb/modules/playintegrityfix/pif.json
```

两份！内容几乎一样，但修改模块里那份 **完全没有效果**。

## 2. 怎么确认哪份是活的

看 inject so 里硬编码了哪个路径：

```bash
adb shell 'su -c "strings /data/adb/modules/playintegrityfix/inject/arm64-v8a.so | grep -i pif"'
# /pif.json
```

只有 @/pif.json@ —— 注意**没有** @/data/adb/modules/playintegrityfix/@ 前缀。
结合 PIF 的工作方式（注入到目标进程后读取配置），实际解析路径 = @/data/adb/pif.json@。

## 3. 两份文件的关系

```
/data/adb/modules/playintegrityfix/pif.json
    |- 模块自带的默认值（安装时写入）
    |- 修改它 → 只有重新安装/刷模块才生效
    - 通常被 UI（webroot）写入时才同步

/data/adb/pif.json
    |- ★ 运行时真正读取的配置
    |- 任何修改立即生效（下次进程 fork 时）
    - 必须改这一份
```

安装脚本大概是这个逻辑（伪代码）：

```sh
# post-fs-data.sh 或安装器
[ -f /data/adb/pif.json ] || cp "@{MODDIR}/pif.json" /data/adb/pif.json
```

所以两份会**分叉**：一旦有人改了 @/data/adb/pif.json@，模块目录里那份就是僵死的默认值。
本例中两份的 @spoofVendingSdk@ 一个 @true@ 一个 @false@ —— 完美验证了这个分叉。
而且这直接导致了第一次修复"改了没反应"。

## 4. 安全做法：永远同步两份

把脚本写成本地文件再 push，避免多层引号：

```sh
# fix-pif.sh
P=/data/adb/pif.json
M=/data/adb/modules/playintegrityfix/pif.json
TS=$(date +%Y%m%d-%H%M%S)
cp -f "@{P}" "@{P}.bak-@{TS}"
cp -f "@{M}" "@{M}.bak-@{TS}"
sed -i 's/"spoofVendingSdk": true/"spoofVendingSdk": false/' "@{P}" "@{M}"
echo "== live ==";   grep spoofVendingSdk "@{P}"
echo "== module =="; grep spoofVendingSdk "@{M}"
```

```bash
adb push fix-pif.sh /data/local/tmp/fix-pif.sh
adb shell 'su -c "sh /data/local/tmp/fix-pif.sh"'
```

## 5. 校验对齐

```bash
adb shell 'su -c "diff /data/adb/pif.json /data/adb/modules/playintegrityfix/pif.json"'
```

两份应该完全一致。不一致 = 你又踩坑了。

## 6. 回退

```bash
adb shell 'su -c "cp /data/adb/pif.json.bak-20261125-164805 /data/adb/pif.json"'
adb shell 'su -c "cp /data/adb/modules/playintegrityfix/pif.json.bak-20261125-164805 /data/adb/modules/playintegrityfix/pif.json"'
adb shell 'su -c "am force-stop com.android.vending"'
```

备份文件名带时间戳，@ls /data/adb/pif.json.bak-*@ 能看到所有历史版本。
