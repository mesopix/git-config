# git-config-sync

把仓库中维护的 [`config/gitconfig`](config/gitconfig) 同步到当前用户的全局 Git 配置：安装器把文件复制到用户配置目录下的 `git-config-sync/gitconfig`，并在全局配置中追加一条指向它的 `include.path`。

因此，托管配置会覆盖之前定义的同名全局配置，但不影响仓库级配置和命令行 `-c` 配置；你已有的其他全局配置不会被修改或删除。

## 依赖

| 依赖 | 用途 | 安装 |
|---|---|---|
| git | 写入全局配置、校验语法 | [git-scm.com/downloads](https://git-scm.com/downloads) |
| Node.js | 仅一键安装器需要 | [nodejs.org](https://nodejs.org) |

## 安装

### 一键安装（推荐）

安装器是跨平台的 `install.js`。

**macOS / Linux**（Windows 的 Git Bash 里同样可用）：

```bash
curl -fsSL https://raw.githubusercontent.com/mesopix/git-config/main/install.js | node
```

**Windows**（PowerShell 或 CMD，系统自带 curl.exe）：

```
curl.exe -fsSL https://raw.githubusercontent.com/mesopix/git-config/main/install.js -o install.js && node install.js
```

（install.js 会临时下载到当前目录，安装成功后自动删除；失败则保留，修复问题后可直接 `node install.js` 重试，无需重新下载）

也可以 clone 仓库后执行 `node install.js config/gitconfig` 从本地文件安装（无需联网）。

安装器会自动完成：

1. 把 `config/gitconfig` 复制到用户配置目录（Windows：`%APPDATA%\git-config-sync\gitconfig`；macOS：`~/Library/Application Support/git-config-sync/gitconfig`；Linux：`~/.config/git-config-sync/gitconfig`）。写入前先用 git 校验语法，经临时文件 + 改名原子更新，非法配置不会破坏已安装的版本；
2. 在 `~/.gitconfig` 中追加一条 `include.path` 指向托管文件——全部通过 `git config` 完成，不会触碰文件里的其他配置；
3. 依赖检查：git 缺失时给出对应平台的安装链接。

重复执行安装是安全的：托管配置内容没有变化时不写文件；`include.path` 已存在时不重复添加；重复条目会自动合并为一条。

**卸载**：

```bash
curl -fsSL https://raw.githubusercontent.com/mesopix/git-config/main/install.js | node - --uninstall
```

或本地执行 `node install.js --uninstall`（只移除指向托管文件的 `include.path` 条目并删除托管文件，其他全局配置与其他 `include.path` 条目均不受影响）。

### 手动安装

1. 把 `config/gitconfig` 复制到用户配置目录下的 `git-config-sync/gitconfig`。
2. 执行（把路径换成上一步的绝对路径）：

```sh
git config --global --add include.path "<托管配置的绝对路径>"
```

## 修改配置

编辑 [`config/gitconfig`](config/gitconfig) 后在仓库内执行 `node install.js config/gitconfig` 即可同步到本机，无需 push；push 后重新执行安装命令则从 GitHub 拉取最新配置。

> 旧版 Go 二进制的托管路径与 `include.path` 写法与现在完全一致，装过的机器直接重跑安装命令即可无缝切换，无需先卸载。
