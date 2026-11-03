# PBZ 维护经验总结

本文总结 2026-11-01 会话中形成的维护约定和关键知识。修改 ASL、运行时生成器、
Boss 缓存、GameplayTag 判定或发布流程前应先阅读本文。

## 1. 源码与运行时边界

- 可编辑 ASL 和设置 XML 位于 `Source/Runtime`。
- `Components`、`dist` 发布包和本机 LiveSplit `Components` 都是生成输出。
- 注释只能写在 `Source/Runtime`、C# 源文件和工具脚本源码中。
- 生成的 ASL、C#、PowerShell 和 XML 发布文件必须移除全部注释。
- 不要直接编辑 `Components/PBZ-AutoSplitter.asl` 或
  `Components/PBZ-AutoSplitter_BySave.asl`，下一次生成会覆盖修改。

## 2. 中文注释与编码

- 说明性注释统一使用中文，保留 UE、LiveSplit、GAS 类型名和协议字段等必要英文。
- PowerShell 5.1 对无 BOM UTF-8 中文脚本兼容性不稳定，`Source/*.ps1` 中需要
  中文注释的脚本应保存为 UTF-8 BOM。
- 生成器会去掉 BOM 和注释，因此运行时文件仍使用无 BOM UTF-8。
- 注释中的 `-1` 等位模式说明必须明确错误哨兵和有效值的区别。

## 3. 生成、测试与同步

修改 `Source/Runtime` 后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\build_pbz_runtime.ps1 -SyncLiveSplit
```

验证命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\test_pbz_runtime.ps1
```

必须确认：

1. 两份生成 ASL 均通过 LiveSplit `ASLParser.Parse`。
2. 仓库和本机 `Components` 中的 ASL/XML 不包含注释。
3. 仓库与本机 PBZ 运行文件 SHA-256 一致。
4. `git diff --check` 没有尾随空白或补丁格式错误。

## 4. ASL 生命周期与状态约定

- `startup` 在脚本加载或重载时执行，负责 `asl-help`、日志，并立即读取 Boss
  设置 XML；设置不依赖游戏进程是否存在。
- `init` 在找到匹配的 PBZ 进程后执行，绑定游戏并记录构建门禁结果，再创建固定偏移、
  watcher、缓存和其他委托；不得重新加载设置 XML。
- `update` 在 ASL 宿主定时器中运行；昂贵扫描通过 50 ms/100 ms 门控限频。
- `start` 只在 NotRunning 阶段检查起始世界和 Loading 非零到零边沿。
- `isLoading` 和 `split` 只在 Running/Paused 阶段调用。
- `split` 消费队列前必须再次检查加载暂停、总开关和计时器阶段。
- `onStart`、`onReset` 清空计时周期状态；`exit` 清空进程会话状态。
- `shutdown` 在脚本卸载或重载时执行，`asl-help` 的 `Dispose` 会先运行。

## 5. GameplayTag 判定

- `DeadTagIndex = 0x538D8` 对应 `CharacterState.Dead`。
- `ExcludeFromBossRecordTagIndex = 0xE23D08` 对应
  `CharacterType.AI.ExcludeFromBossRecord`。
- `ReadTagFlags` 返回值：
  - `-1`：读取失败；
  - `0`：两个 Tag 均未激活；
  - `1`：仅 Dead；
  - `2`：仅 Exclude；
  - `3`：两者均激活。
- `-1` 的补码位模式也包含 bit 0/1，调用方必须先判断 `flags >= 0`，再做位测试。
- Exclude 的优先级由调用方实现；出现 Exclude 时必须清除该 Actor 的打点状态。
- Tag 容器中的 `entryCount` 是不同 Tag 计数项数量，不是 Count 总和，也不是
  游戏中所有 Tag 的总数。`4096` 只是损坏保护上限。

## 6. Boss 缓存与身份

- `MemoryBossFNameCache`：FName id 到名称字符串。
- `MemoryBossClassCache`：UClass 指针到类名，只在当前世界代际有效。
- `MemoryBossActorCache`：Actor 地址到 `long[6]`：
  UClass、对象 FName id、InternalIndex、AttributeSet、ASC、刷新时间。
- `MemoryBossPlayerRecord`：本地玩家链路的 `long[9]` 解析记录。
- `MemoryBossCacheWorld`、`MemoryBossCacheDest`：对象缓存所属世界代际。
- `MemoryBossNextScan`：下一次扫描的 UTC ticks，0 表示立即扫描。
- World/Dest 变化、加载、前端或 DestClass 校验失败时必须使对象缓存失效。
- 地址不能单独作为对象身份。复用 Actor 缓存前必须比较 UClass、对象 FName id
  和 InternalIndex。
- 仍需注意：当前 `Seen`、`Armed`、`Checks` 等集合只按 Actor 地址作键；
  身份失配时虽然会刷新组件缓存，但旧跟踪状态不会全部自动清除。

## 7. 失败处理与性能

- `update` 每轮先令 `Paused = true`，只有全部门控通过后才允许继续。
- `World`、`Dest`、`WorldNameId` 的 0/null 可明确视为失败。
- `Loading` 是合法 byte 0，`SetZeroOrNull` 无法区分“真实未加载”和“读取失败”；
  不能把该处描述成绝对 fail-closed。
- Actor 身份瞬间失效会被视为销毁边沿。内存短读可能与该边沿混淆，排查误打点时
  必须检查 `actor-invalid-*` 日志。
- Tag 扫描成本与 `entryCount` 成正比；每个 entry 为 0x10 字节。
- 所有读取运行在 LiveSplit UI 定时器线程，持续大量数组、Tuple、List 分配会造成卡顿。

## 8. 发布流程

1. 更新 `CHANGELOG.md` 版本和日期。
2. 生成正式 ZIP：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Source\package_release.ps1 `
  -Version 2.2.3 `
  -OutputPath .\dist\PBZ_AutoSplit_2.2.3.zip
```

3. 检查 ZIP 内 `.asl/.cs/.ps1/.xml` 均无注释。
4. 同步本机 `Components` 并核对 SHA-256。
5. 提交并推送 `main`。
6. 使用 `gh release create` 创建 tag、Release 和 ZIP 资产。
7. 用 `gh release view --json` 核对资产大小、digest 和 tag 目标提交。

## 9. 常见坑

- 修改 `Components` 而不是 `Source/Runtime`，导致生成时丢失修改。
- 忘记同步本机 `Components`，仓库和实际 LiveSplit 不一致。
- PowerShell 5.1 读取中文脚本编码失败，出现看似变量作用域或语法错误。
- 把 `-1` 当成普通位掩码，未先检查读取失败。
- 把 `entryCount` 理解为所有 Tag Count 的总和。
- 把 Actor 地址当作永久身份，忽略 UE 地址复用。
- 发布 ZIP 后再次重建 DLL，却没有重新打包或同步。

## 10. 相关文档

- `AGENT.md`：仓库强制规则和操作入口。
- `docs/architecture.md`：运行架构和数据流。
- `docs/development.md`：构建步骤。
- `docs/testing.md`：测试和 LiveSplit 验收。
- `docs/troubleshooting.md`：日志与故障排查。
