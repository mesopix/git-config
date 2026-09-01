# git-config-sync

把仓库中维护的 [`config/gitconfig`](config/gitconfig) 同步到当前用户的全局 Git 配置：安装器把文件复制到用户配置目录下的 `git-config-sync/gitconfig`，并在全局配置中追加一条指向它的 `include.path`。

因此，托管配置会覆盖之前定义的同名全局配置，但不影响仓库级配置和命令行 `-c` 配置；你已有的其他全局配置不会被修改或删除。

## 依赖

| 依赖 | 用途 | 安装 |
|---|---|---|
| git | 写入全局配置、校验语法 | [git-scm.com/downloads](https://git-scm.com/downloads) |
| bash + curl | macOS / Linux 安装器运行环境，系统自带 | — |
| PowerShell 或 cmd + curl.exe | Windows 安装器运行环境，系统自带（Win10 1803+） | — |

安装器只依赖各系统原生的 shell，不再需要 Node.js。

## 安装

**macOS / Linux**（Windows 的 Git Bash 里同样可用）：

```bash
curl -fsSL https://raw.githubusercontent.com/mesopix/git-config/main/install.sh | bash
```

**Windows PowerShell**：

```powershell
curl.exe -fsSL https://raw.githubusercontent.com/mesopix/git-config/main/install.ps1 -o install.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

**Windows CMD**：

```
curl.exe -fsSL https://raw.githubusercontent.com/mesopix/git-config/main/install.cmd -o install.cmd && install.cmd
```

Windows 的两种方式会把安装脚本临时下载到当前目录，成功后自动删除；失败则保留，修复后可直接重跑 `powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1` 或 `install.cmd`，无需重新下载。

也可以 clone 仓库后从本地文件安装（无需联网）：

- macOS / Linux：`bash install.sh config/gitconfig`
- PowerShell：`powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 config\gitconfig`
- CMD：`install.cmd config\gitconfig`

安装器会自动完成：

1. 把 `config/gitconfig` 复制到用户配置目录（Windows：`%APPDATA%\git-config-sync\gitconfig`；macOS：`~/Library/Application Support/git-config-sync/gitconfig`；Linux：`~/.config/git-config-sync/gitconfig`）。写入前先用 git 校验语法，经临时文件 + 改名原子更新，非法配置不会破坏已安装的版本；
2. 在 `~/.gitconfig` 中追加一条 `include.path` 指向托管文件——全部通过 `git config` 完成，不会触碰文件里的其他配置；
3. 依赖检查：git 缺失时给出对应平台的安装链接。

重复执行安装是安全的：托管配置内容没有变化时不写文件；`include.path` 已存在时不重复添加；重复条目会自动合并为一条。没有任何改动时只输出一行 `Already up to date — nothing to do.`，不会让人误以为失败。

**卸载**：

- macOS / Linux：

```bash
curl -fsSL https://raw.githubusercontent.com/mesopix/git-config/main/install.sh | bash -s -- --uninstall
```

- PowerShell：`powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall`
- CMD：`install.cmd -u`

（只移除指向托管文件的 `include.path` 条目并删除托管文件，其他全局配置与其他 `include.path` 条目均不受影响。）

### 手动安装

1. 把 `config/gitconfig` 复制到用户配置目录下的 `git-config-sync/gitconfig`。
2. 执行（把路径换成上一步的绝对路径）：

```sh
git config --global --add include.path "<托管配置的绝对路径>"
```

## 修改配置

编辑 [`config/gitconfig`](config/gitconfig) 后在仓库内执行 `bash install.sh config/gitconfig`（Windows 用对应的 PowerShell/CMD 命令）即可同步到本机，无需 push；push 后重新执行安装命令则从 GitHub 拉取最新配置。

> 旧版 Go / Node 安装器的托管路径与 `include.path` 写法与现在完全一致，装过的机器直接重跑对应平台的安装命令即可无缝切换，无需先卸载。
