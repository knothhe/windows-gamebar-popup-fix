# Game Bar 一键卸载与游戏弹窗修复

在同一个脚本中卸载当前用户的 Xbox Game Bar，并处理游戏启动后出现的 **“Pick an app / 选择一个应用 / 需要新应用打开 ms-gamingoverlay”** 弹窗。

## 使用

下载 [最新版本 ZIP](https://github.com/knothhe/windows-gamebar-popup-fix/releases/latest)，解压后双击 **`Fix-GameBar.cmd`**，输入菜单序号：

| 选项 | 功能 |
| --- | --- |
| `1` | 一键卸载当前用户的 Game Bar，并应用游戏弹窗修复 |
| `2` | 只修复游戏弹窗，适合已经卸载 Game Bar 的情况 |
| `3` | 恢复本工具备份的注册表设置 |
| `4` | 检查安装状态与弹窗相关设置，不修改配置 |
| `0` | 退出 |

用平时玩游戏的 Windows 用户运行，通常无需管理员权限。操作前退出游戏；完成后从正常启动器重新打开游戏验证。

**所有处理逻辑都在 `Fix-GameBar.ps1` 一个文件里**，CMD 只是双击启动入口，不依赖其他模块、EXE 或下载。菜单使用英文以避免命令行编码问题。

## 处理范围

卸载使用 `Remove-AppxPackage`，仅针对当前用户的微软包 **`Microsoft.XboxGamingOverlay`**。不移除 Xbox 主应用、Gaming Services、其他用户的应用或系统预配包，不清空录制视频目录。卸载会按 Windows 正常行为移除该应用及其用户数据。

弹窗修复仅修改当前用户 `HKCU`：

| 注册表键 | 设为 `DWORD 0` 的值 |
| --- | --- |
| `Software\Microsoft\Windows\CurrentVersion\GameDVR` | `AppCaptureEnabled` |
| `System\GameConfigStore` | `GameDVR_Enabled` |
| `Software\Microsoft\GameBar` | `ShowStartupPanel`、`UseNexusForGameBarEnabled` |

对 `ms-gamingoverlay`、`ms-gamebar`、`ms-gamebarservices`、`ms-xbox-overlay` 四个协议，在 `HKCU\Software\Classes\<协议>` 中补充 URL 协议标记，删除该用户键的 `NoOpenWith` 值，并将 `shell\open\command` 默认值指向：

```text
"<Windows系统目录>\systray.exe" "%1"
```

已有协议描述保留。完成后通知 Shell 刷新关联并回读目标值。不会写入 HKLM，不创建服务、计划任务或开机启动项，也不重启桌面或结束游戏进程。发现不支持的 COM 协议处理入口时会停止，避免扩大修改范围。

## 备份与恢复

首次操作前，目标注册表值、类型和原本是否存在会保存到：

```text
%LOCALAPPDATA%\GameBarPopupFix\active-backup.clixml
```

重复运行保留原备份。菜单 `3` 只恢复这些目标值，保留无关数据；成功后将备份改名留存。处理失败会尝试回滚本次注册表修改。

**备份不包含 Game Bar 应用及其应用数据。恢复设置不会重新安装应用，也不能撤销已经完成的卸载。** 如需重新使用 Game Bar，先恢复设置，再从 Microsoft Store 安装。不要使用他人的备份；备份只保存在本机，不上传。

CMD 的 `-ExecutionPolicy Bypass` 仅影响本次 PowerShell 进程，不改变系统执行策略。脚本不绕过组织策略或应用控制。

## 命令行

使用 Windows 自带 PowerShell 5.1；不传 `Mode` 时默认只读检查。

```powershell
# 预览卸载与修复，不修改应用或注册表
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Uninstall -WhatIf

# 一键卸载 + 弹窗修复
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Uninstall

# 只修复 / 恢复设置 / 检查状态
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Restore
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Fix-GameBar.ps1 -Mode Status
```

## 测试与适用性

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GameBarFix.ps1
```

包含 9 项临时注册表测试和 7 项模拟卸载测试。前者仅操作 `HKCU\Software\GameBarPopupFixTests\<随机GUID>`；后者模拟 Appx 命令，不卸载真实应用。覆盖重复运行、七种值类型恢复、无关数据保留、无效备份拒绝、精确包名限定、预览和卸载失败处理。

协议处理是针对 Game Bar 已卸载场景的规避方案，不能保证消除所有游戏弹窗。不同 Windows 版本需实测；请从资源管理器以正常用户运行，修改后的回读结果不能代替实际重启游戏验证。

参考：[微软卸载命令说明](https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage)、[微软应用注册说明](https://learn.microsoft.com/en-us/windows/win32/shell/app-registration)、[协议处理方法参考](https://github.com/AveYo/Gaming/blob/main/ms-gamebar-annoyance.bat)。
