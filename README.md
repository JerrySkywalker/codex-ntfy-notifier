# codex-ntfy-notifier

把 Codex/Codex GUI 的 Stop hook 通知通过自托管 ntfy 推送到 Android 手机：

```text
Codex hook -> %USERPROFILE%\.codex\notify-ntfy.cmd
           -> %USERPROFILE%\.codex\notify-ntfy.ps1
           -> https://ntfy.example.com/<topic>
           -> Android ntfy App
```

## 放置位置

推荐把本仓库放在：

```text
codex-ntfy-notifier
```

实际运行文件由安装脚本生成到：

```text
%USERPROFILE%\.codex
```

敏感信息不进入仓库。ntfy 密码使用 Windows DPAPI 保存到：

```text
%USERPROFILE%\.codex\ntfy-pass.dpapi
```

## 初始化

```powershell
cd codex-ntfy-notifier
powershell.exe -ExecutionPolicy Bypass -File .\scripts\install-codex-ntfy.ps1
```

也可以传参：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\install-codex-ntfy.ps1 `
  -NtfyUrl "https://ntfy.example.com" `
  -Topic "codex-topic" `
  -User "codex_notify"
```

脚本会提示输入 ntfy 密码，并使用当前 Windows 用户的 DPAPI 加密保存。

## 测试

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\test-codex-ntfy.ps1
```

## 备份现有配置

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\backup-current-codex-config.ps1
```

备份目录：

```text
.\backups\codex-backup-<timestamp>
```

## 仓库原则

本仓库只保存：

- 脚本模板
- 初始化脚本
- 文档
- 示例配置

本仓库不保存：

- ntfy 密码
- DPAPI 文件
- SSH 私钥
- API Key
- 真实 `.codex` 运行态日志

## 推荐工作流

1. 修改 `templates/notify-ntfy.ps1` 或 `templates/notify-ntfy.cmd`。
2. 提交 Git。
3. 运行 `scripts/install-codex-ntfy.ps1` 重新安装到 `%USERPROFILE%\.codex`。
4. 运行 `scripts/test-codex-ntfy.ps1` 测试。



