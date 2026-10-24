# 原神启动时的 Game Bar / Pick an app 弹窗排查记录

记录日期：2026-10-24。只记录与复现、判断和修复有关的内容，去除了个人账户、机器路径、截图与原始跟踪数据。

## 现象与最终结果

Xbox Game Bar 已卸载。原神启动器点击“开始游戏”后，任务栏出现闪烁的 **Pick an app**。窗口可能保持最小化，不点击就持续存在，点击后又消失，容易被误判为短暂通知。

后台确认窗口属于 Windows 的 `OpenWith.exe -Embedding`。针对该进程的只读诊断提取到与 Game Bar 有关的 URI，形如：

```text
ms-gamingoverlay://startuptips/?TitleId=<游戏标识>&ProcessId=<进程>&WindowId=<窗口>
```

这说明 Windows 仍收到 Game Bar 启动提示请求，但不能正常交给已卸载的应用。本案例最终在正常 Windows 用户执行环境写入当前用户设置与协议处理命令后，用户退出并重新从启动器打开原神，反馈：**“这次没有了”**。

## 做过哪些尝试

| 操作 | 结果和判断 |
| --- | --- |
| 在普通工具命令环境关闭 DVR / Game Bar 开关 | 该环境内读回成功，但用户反复启动游戏仍有弹窗 |
| 编写并编译 `GameBarSilent.exe`，注册为协议处理程序 | 小型 GUI 子系统 .NET 程序，收到参数后退出；后加仅记录相关 URI 的诊断日志。真实调用没有到达它，未解决 |
| 补协议、应用能力注册、旧 AppX 类入口 | 没有解决；不纳入通用修复 |
| 经用户逐次允许管理员确认，添加机器级协议处理和 DVR 策略 | 多次实际启动仍有弹窗；机器级改动不能单独认定为有效方案 |
| 使用微软 Process Monitor 短时抓取 | 真实 OpenWith 查找的当前用户 `shell` 不存在，而工具内读取却存在，暴露执行环境差异 |
| 将机器级 `ms-gamingoverlay` 命令由无参数 `rundll32.exe` 改成 `systray.exe` | 单独应用后用户仍反馈出现弹窗 |
| 在独立正常用户进程复核并写入当前用户配置 | 看到了此前未改到的真实状态，写入后用户重启游戏确认弹窗消失 |

这次并未通过逐项撤销做最小充分性实验。因此可以确认**最后这组操作之后问题消失**，不能严谨声称四个协议和四个开关每一项都是本案例不可缺少的条件，也不能排除此前机器级改动的共同作用。仓库选择当前用户范围作为可恢复的最小修改层级，不复制机器级试错。

## 为什么早期反复没有效果

出现了可复核的执行环境差异：

| 观察项 | 普通工具命令进程 | 独立启动的 Windows 用户进程 |
| --- | --- | --- |
| Windows 用户 SID | 与另一环境相同 | 与另一环境相同 |
| 当前用户协议命令 | 可以看到自制处理程序 | 对应 `shell\open\command` 不存在 |
| `GameDVR_Enabled` | 早期测试读到已关闭 | 最终修复前仍为 `1` |
| 默认应用注册列表 | 与真实系统列表不一致 | 原有列表完整，最终修复前后数量不变 |

独立进程通过 WMI `Win32_Process.Create` 启动，在同一 Windows 用户下隐藏运行 PowerShell，没有通过该步骤提权，也没有操作鼠标键盘。进程令牌诊断显示相关桌面进程使用相同用户和普通完整性级别。查询包身份也没有给出能解释差异的结论。

**已经证明的是读写视图不一致；没有证明具体由哪种隔离、虚拟化或宿主机制导致。** 最后的用户确认比单个命令环境的回读更有说服力。早期据不完整状态作出的“已修好”判断不成立。

## 最后实际生效的一组配置

1. 真实当前用户的 `AppCaptureEnabled`、`GameDVR_Enabled`、`ShowStartupPanel`、`UseNexusForGameBarEnabled` 设为 `DWORD 0`。
2. 为 `ms-gamingoverlay`、`ms-gamebar`、`ms-gamebarservices`、`ms-xbox-overlay` 写入 HKCU URL 协议标记和 `"<系统目录>\systray.exe" "%1"` 命令，并删除 HKCU 对应 `NoOpenWith` 值；已有协议描述保留。
3. 通知 Shell 刷新关联。
4. 新独立进程回读四项设置和四个命令；当前用户默认应用列表数量保持不变。
5. 实际重新启动原神，用户确认不再弹窗。

补充验证中，`QueryUriSupportAsync` 对 `ms-gamingoverlay` 返回 Available，其他几个协议仍可能受机器级合并设置影响而返回 NotSupported。因此不声称所有协议能力已彻底修复；本次确认解决的是原神启动提示。

## 写过什么程序、留下什么

| 项目 | 用途 | 最终是否必需 |
| --- | --- | --- |
| `GameBarSilent.cs` / `GameBarSilent.exe` | 原本尝试收到 Game Bar URI 后静默退出，后加诊断日志 | 不必需，最终改用 Windows 自带程序 |
| 只读 OpenWith 诊断程序 | 限定目标进程，提取 Game Bar 相关 URI，定位启动提示来源 | 一次性诊断，不是修复组成部分 |
| 进程令牌诊断程序 | 检查用户、完整性级别及提升状态 | 一次性诊断 |
| Process Monitor 采集脚本 | 启动微软工具，短时记录并导出注册表查找 | 一次性诊断；没有安装常驻监控 |
| 最终用户配置修复脚本 | 备份、写入目标键、通知 Shell、回读 | 有效配置的依据，现已整理为通用脚本 |

此前自制 EXE 的安装目录为 `%LOCALAPPDATA%\GameBarSilent`。本案例原先的临时日志、跟踪文件和该 EXE 的清理动作被自动审批拒绝，未执行；因此没有把它们描述成“已经删除”。它不是服务、计划任务或开机启动程序，最终真实用户协议命令也不指向它。

早期还曾写入以下机器级设置：四个协议的 HKLM 注册、其中部分 `NoOpenWith` / `rundll32.exe` 命令，以及 `HKLM\Software\Policies\Microsoft\Windows\GameDVR\AllowGameDVR=0`；后又单独将 HKLM `ms-gamingoverlay` 改为 `systray.exe` 并移除其 `NoOpenWith`。这些不是通用脚本所需的步骤，也没有在问题解决后盲目删除。微软文档指出 AllowGameDVR 策略只在 Windows 10 桌面版强制执行，不能把它当作 Windows 11 的可靠修复依据。

早期尝试的旧“撤销所有修改”文件基于不同执行环境的快照，不适合用于恢复最终真实用户状态。实机最终配置另有专门备份，保留在原机器；本公开仓库不上传任何本机备份、注册表导出、二进制、截图或原始系统日志。

**仓库的恢复按钮只恢复运行仓库脚本之前的目标值。** 如果在已经修好的机器上首次运行，它备份的是当时已修好的状态，不会凭空找回本次排查之前的配置。

## 如果仍然出现

先用资源管理器以正常游戏用户双击修复脚本，再退出并重新从启动器打开游戏。若仍出现：

1. 核对窗口是否真的是 `OpenWith.exe`，以及请求的是哪个 `ms-...` 协议。
2. 使用微软官方 Process Monitor 短时按相关进程与协议名筛选，查看真实查找的 HKCU / HKCR 路径与结果；日志可能含个人信息，不要原样公开上传。
3. 检查实际命令键、继承的机器级设置、`DelegateExecute` 和 AppX 协议映射。不要仅根据同一个自动化 shell 的回读判断成功。
4. 若实际调用的是另一个 URI，或组织策略限制修改，按证据定位；本仓库不自动扩大到全局修复。

## 来源

- [Win11Debloat #367](https://github.com/Raphire/Win11Debloat/issues/367)：同类卸载后启动协议弹窗与处理方法讨论。
- [AveYo 原始脚本](https://github.com/AveYo/Gaming/blob/main/ms-gamebar-annoyance.bat)：`systray.exe` 协议处理的社区实现。
- [Microsoft Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)：真实注册表和进程调用跟踪工具。
- [Microsoft AllowGameDVR 文档](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-applicationmanagement#allowgamedvr)：策略适用范围。
