# Windows 11 卸载 Game Bar 后的“Pick an app”弹窗修复

已卸载 Xbox Game Bar，但启动游戏仍出现“Pick an app / 选择一个应用”，或者任务栏有一个持续闪烁的选择应用窗口？本仓库提供一键应用、检查和恢复脚本，并记录一次原神启动弹窗的实际排查过程。

**适用条件：当前用户已经卸载 Xbox Game Bar，并且不再使用其录制、覆盖层等功能。** 这是一种协议处理与设置的规避方案，不是微软官方补丁。当前实机案例在修复后重新启动原神，用户确认不再出现弹窗；其他 Windows 版本与触发场景仍需验证。

## 一键使用

1. 在 GitHub 点击 **Code → Download ZIP**，解压整个目录。
2. 退出游戏。用你平时玩游戏的 Windows 用户，双击 **`Fix-GameBar.cmd`**。
3. 看到成功提示后，从正常启动器重新打开游戏，确认任务栏不再出现该窗口。

无需管理员权限。请用普通用户运行，不要切换到另一个管理员账户。脚本不安装 Game Bar，不下载软件，不创建服务、计划任务或开机启动项。

| 文件 | 用途 |
| --- | --- |
| `Fix-GameBar.cmd` | 双击应用修复 |
| `Restore-GameBar.cmd` | 双击恢复此工具首次应用前的目标设置 |
| `Check-GameBar.cmd` | 只检查当前进程看到的配置 |
| `Fix-GameBar.ps1` | 入口、备份、回读检查与失败回滚 |
| `lib/GameBarFix.psm1` | 受限范围的注册表读写逻辑 |
| [排查记录](docs/CASE-STUDY.zh-CN.md) | 本次失败尝试、最终有效操作、遗留项目 |

脚本界面使用英文，避免 Windows 命令行编码导致乱码。启动器的 `-ExecutionPolicy Bypass` **只对本次 PowerShell 进程生效**，不调用 `Set-ExecutionPolicy`，不修改系统执行策略。组织策略、应用控制仍可能禁止运行；本工具不绕过这些限制。

## 实际会修改什么

所有写入都在 **`HKEY_CURRENT_USER`（HKCU，当前用户）**。

下列值设为 `DWORD 0`：

| 注册表键 | 值名 | 用途 |
| --- | --- | --- |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR` | `AppCaptureEnabled` | 关闭应用捕获开关 |
| `HKCU\System\GameConfigStore` | `GameDVR_Enabled` | 关闭 Game DVR 开关 |
| `HKCU\Software\Microsoft\GameBar` | `ShowStartupPanel` | 关闭启动提示开关 |
| `HKCU\Software\Microsoft\GameBar` | `UseNexusForGameBarEnabled` | 关闭手柄按钮打开 Game Bar 的开关 |

然后为以下四个协议设置当前用户处理程序：

```text
ms-gamingoverlay
ms-gamebar
ms-gamebarservices
ms-xbox-overlay
```

对于每个协议，修改 `HKCU\Software\Classes\<协议>`：

- 默认描述不存在时才补上 `URL:<协议>`，已有描述保留。
- 设置空字符串 `URL Protocol`。
- 删除当前用户键中的 `NoOpenWith` 值（若存在）。
- 将 `shell\open\command` 默认值设为 `"<Windows系统目录>\systray.exe" "%1"`，类型 `REG_SZ`。

`systray.exe` 来自当前 Windows 的系统目录；它在本案例中承担静默处理这些 URI 的作用。脚本不安装或运行自制常驻 EXE。该做法也见于 [AveYo 的原始脚本](https://github.com/AveYo/Gaming/blob/main/ms-gamebar-annoyance.bat) 与 [Win11Debloat 的相关问题讨论](https://github.com/Raphire/Win11Debloat/issues/367)，但不代表微软对所有系统版本的行为保证。

最后通过 `SHChangeNotify` 通知 Shell 关联变更。应用后会回读全部 20 个目标值；这只能验证当前进程看到的设置，实际效果必须通过重启游戏验证。

默认脚本不会修改 `HKLM`、全局策略、AppX 类、默认应用列表、系统文件或 Explorer 进程。发现当前用户仍装有 Xbox Game Bar，或者目标命令键中有 `DelegateExecute` COM 处理程序时，会停止并报错，避免扩大修改范围。

## 备份、恢复和重复运行

原始目标值、类型及相关键是否存在，会保存到：

```text
%LOCALAPPDATA%\GameBarPopupFix\active-backup.clixml
```

备份仅留在本机，包括用于防止跨账户误恢复的用户 SID。仓库不包含本次实机的备份或诊断日志。

- 第一次应用在修改前写入备份；备份落盘失败时停止。
- 重复应用不会覆盖原始备份。
- 恢复时只处理固定目标，保留其他值与后来新增的子键；仅清理本工具新建且仍为空的键。
- 恢复成功后，备份改名保留为 `restored-<时间>.clixml`；下次应用会重新备份。
- 应用或恢复期间若出错，会尝试回滚到该次运行前的目标状态，并报告失败。

恢复只撤销**本工具此次备份对应的改动**，不会卸载软件、恢复所有系统设置，也无法撤销其他工具此前的修改。恢复后，如要重新使用 Game Bar，请自行正常安装 Xbox Game Bar。

不要用其他人的备份，也不要手工编辑备份。备份丢失后，脚本不能推算原始设置。

## 命令行和预览

在 Windows PowerShell 5.1 中：

```powershell
# 只读检查（默认模式）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Status

# 预览意图，不写注册表或备份
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Apply -WhatIf

# 应用或恢复
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Restore
```

优先使用 64 位 Windows 自带 PowerShell 5.1。操作期间不要用其他工具同时修改这些关联。关闭窗口、注销或重新启动游戏可能使 Shell 刷新结果；本工具不强制结束你的游戏或桌面进程。

## 显示成功却仍然弹窗

这次排查中，自动化工具内的普通命令进程，与独立启动的 Windows 用户进程，读到了不同的注册表状态，尽管用户 SID 相同。前者的“写入成功”没有消除真实游戏启动弹窗。最终在独立 Windows 用户进程中写入配置后才得到用户实测确认。具体隔离机制未查明，不能推断为所有 Windows 或自动化工具的通用行为。

因此请**先从资源管理器手动双击本仓库的 CMD**，在正常用户环境中运行。仓库不会自动通过 WMI 另起进程、请求提权或反复改更多系统项。如果依旧弹窗，请查看[排查记录中的复核方法](docs/CASE-STUDY.zh-CN.md#如果仍然出现)，定位具体 URI 与真正读取的注册表位置。

## 验证范围

无第三方测试依赖。运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GameBarFix.ps1
```

测试只写入 `HKCU\Software\GameBarPopupFixTests\<随机GUID>`，不会操作真实 Game Bar 键。覆盖首次应用、重复应用、七种值类型的备份恢复、原值缺失、无关值和后来新增子键保留、畸形备份拒绝及 COM 处理程序冲突。测试结束清理该次随机测试键。

**当前验证分两部分：** 早前实机按本文配置修复后，用户确认原神启动不再弹窗；仓库重写版验证注册表算法和启动脚本预览，不为重复测试而覆盖已修好的真实设置。尚未在不同 Windows 版本与干净系统上全面验证。

## 参考

- [Win11Debloat #367：卸载后 ms-gamingoverlay 弹窗](https://github.com/Raphire/Win11Debloat/issues/367)
- [AveYo：ms-gamebar-annoyance.bat 源码](https://github.com/AveYo/Gaming/blob/main/ms-gamebar-annoyance.bat)
- [Microsoft：应用注册与协议处理](https://learn.microsoft.com/en-us/windows/win32/shell/app-registration)
- [Microsoft：Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)
- [Microsoft：AllowGameDVR 策略说明](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-applicationmanagement#allowgamedvr)（文档注明该策略仅在 Windows 10 桌面版强制执行，不能据此保证 Windows 11 效果。）

本仓库是针对本案例独立整理的实现，参考链接用于说明技术来源，未打包上述项目代码或第三方二进制。
