# Keycade LazyVim

[English](README.md) | **简体中文**

> 专为 Omarchy（Wayland）打造的街机风格 LazyVim 快捷键记忆训练器，由你自己的牌组驱动

[![CI](https://github.com/GerritWanderer/keycade-lazyvim/actions/workflows/ci.yml/badge.svg)](https://github.com/GerritWanderer/keycade-lazyvim/actions/workflows/ci.yml)
[![CodeQL](https://github.com/GerritWanderer/keycade-lazyvim/actions/workflows/codeql.yml/badge.svg)](https://github.com/GerritWanderer/keycade-lazyvim/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/GerritWanderer/keycade-lazyvim/badge)](https://scorecard.dev/viewer/?uri=github.com/GerritWanderer/keycade-lazyvim)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14452/badge)](https://www.bestpractices.dev/projects/14452)
[![codecov](https://codecov.io/gh/GerritWanderer/keycade-lazyvim/branch/main/graph/badge.svg)](https://codecov.io/gh/GerritWanderer/keycade-lazyvim)
[![Omarchy Marketplace](https://img.shields.io/badge/Omarchy%20Marketplace-listed-2ea44f?logo=omarchy)](https://plugins.omarchy.org/plugin.html?id=gerritwanderer.keycade-lazyvim)
[![GitHub Release](https://img.shields.io/github/v/release/GerritWanderer/keycade-lazyvim?logo=github)](https://github.com/GerritWanderer/keycade-lazyvim/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

![LazyVim 的 leader 连打](docs/screenshots/keycade-lazyvim-zh-CN.png)

Keycade LazyVim 是 Omarchy 的原生桌面覆盖层（Overlay），将 LazyVim 快捷键记忆转化为节奏明快、街机风格的闯关练习。所有按键输入均在本地拦截判定，训练时不会误触发系统或应用的原本动作。

练习题库来自 LazyVim 官方键位表，并自动按你的 leader 键、已启用的 extras 模块与 `lua/config/keymaps.lua` 自定义映射完成校准。你的练习范围是一个个**牌组**：包含全部可用卡片的保留牌组 `all`、四个内置入门牌组，或你在 `decks.json` 中自行声明的收藏。每个牌组拥有独立的卡片计数、对局次数与掌握度评估，而每张卡片的记忆历史在所有牌组之间共享。

## 核心功能

- **校准的 LazyVim 题库**：官方键位表实时按你的 `mapleader` / `maplocalleader`、已启用的 `lazyvim.json` extras 与字面量 `keymaps.lua` 改动完成校准，无需手动设置。
- **自定义牌组**：在 `decks.json` 中用封闭词表种子声明命名牌组，并在应用内的「浏览」抽屉里逐卡微调成员。
- **序列连打即时判定**：原生支持 `<leader>ff`、`gcc` 等连续按键；卡片分步显示，按对一步即时点亮一步。
- **全局快捷键安全隔离**：基于 Wayland 快捷键抑制机制（Shortcuts Inhibitor），练习期间完全接管输入，彻底避免误触桌面动作。
- **科学的间隔重复算法**：每轮最多 24 张卡片——牌组较小时发完全部可用卡片——均衡编排未学、到期复习、易错薄弱与已掌握快捷键，稳步建立持久的肌肉记忆。
- **严谨的掌握度判定**：必须在连续两次不同的对局中均首试正确，卡片才会被判定为“已掌握”。
- **错题即时跟练纠错**：答错时界面保留正确答案引导跟练一次，并在当前轮次后段自动重新出题强化。
- **进度实时保存与断点续练**：学习进度实时保存在本地，随时退出随时恢复进度；牌组达成 100% 掌握时触发里程碑庆祝。
- **温和的一键排除**：对于键盘按不出或暂时不想练习的键位，可随时一键排除；亦可在排除面板中随时恢复，历史练习数据完整保留。
- **多语言与复古主题**：原生支持中英双语、复古电子音效，内置 Catppuccin、Tokyo Night、Gruvbox、Everforest 与 Ristretto 五套精致配色。
- **复古街机视觉质感**：细腻的 CRT 扫描线、点阵字符与动感跑马灯；开启系统“减少动效”时自动平滑关闭动画，读数依然清晰呈现。

## 系统要求

- Omarchy 4.x
- Quickshell 0.3.1（须包含 `Quickshell.Wayland._ShortcutsInhibitor.ShortcutInhibitor`）
- Hyprland（须配置 `binds:disable_keybind_grabbing = false`）
- `qt6-multimedia`（覆盖层的音效需要导入 `QtMultimedia`）
- Python 3

Keycade LazyVim 启动前必须确认 Wayland 快捷键抑制（输入保护）已完全激活；若保护不可用，程序将安全拒绝启动，绝不降级至仅依赖窗口焦点的不可靠模式。

## 安装指南

```bash
omarchy plugin add https://github.com/GerritWanderer/keycade-lazyvim.git --enable
```

在 `~/.config/hypr/bindings.lua` 中添加唤起快捷键，例如：

```bash
echo 'o.bind("SUPER + SHIFT + K", "Keycade LazyVim", "omarchy-shell shell summon gerritwanderer.keycade-lazyvim '\''{}'\''")' >> ~/.config/hypr/bindings.lua
```

## 更新指南

```bash
omarchy plugin update gerritwanderer.keycade-lazyvim
omarchy restart shell
```

> **注意**：更新后必须重启 shell，确保常驻的 Quickshell 进程彻底重新加载最新代码。

## 使用说明

- **启动**：按下快捷键 `Super + Shift + K`，或在终端执行：
  ```bash
  omarchy-shell shell summon gerritwanderer.keycade-lazyvim '{}'
  ```
- **选择牌组**：首页按声明顺序列出所有牌组——`all` 固定在最前——并实时显示每个牌组的卡片数量与掌握度。选定后按回车开始或继续练习。
- **整理卡片**：在首页或结算页打开「浏览」，把卡片分配进目标牌组；详见下文「牌组」。
- **切换牌组**：随时点击「← 返回」按钮退出当前练习，进度将自动保存，下次进入可无缝断点续练。
- **个性化设置**：在顶部控制栏切换语言、声音开关、音量与色彩主题，选项将自动记忆。
- **排除特定快捷键**：对局中点击卡片右上方的 `✕ 排除此键`，将该卡片从所有牌组与掌握度统计中移除；点击顶栏「已排除」可随时查看并恢复，历史数据完好保留。
- **退出保存**：单按并松开 `Esc` 键即可安全存盘并关闭覆盖层。带有修饰键的 Esc 组合键（如 `Super + Esc`）作为常规快捷键处理，不触发退出。

用户进度与会话数据持久化保存在 `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade-lazyvim/` 目录下，更新插件不会丢失数据；详见「状态与迁移」。

## 牌组

牌组是共享 LazyVim 题库之上一个具名的练习范围。保留牌组 `all` 始终包含全部可用卡片，固定显示在列表最前，不可删除。没有任何配置时，还会有四个内置入门牌组——导航（`navigation`）、LSP 与诊断（`lsp`）、搜索与查找（`search`）与 Git（`git`）——各自按词库分类播种。

牌组内容在每次启动时实时计算：`种子(题库) ∪ 已添加 − 已移除`。种子来自配置文件；`added` / `removed` 是保存在本地状态中的显式整理选择。因此 LazyVim 更新或开关某个 extra 会自动增减播种牌组的卡片；指向暂时缺失的牌组或卡片的整理记录会被保留（暂不生效），直到其再次出现。

### 配置

牌组在 `${XDG_CONFIG_HOME:-~/.config}/omarchy/keycade-lazyvim/decks.json` 中声明。该文件对 Keycade LazyVim **只读**——只做静态解析，绝不写入，也不涉及 Lua、卡片字面量或查询语言：

```json
{
  "schemaVersion": 1,
  "decks": [
    { "id": "marks", "name": "Marks & Jumps",
      "seed": { "extras": ["lazyvim.plugins.extras.editor.harpoon2"] } },
    { "id": "lsp", "name": "LSP & Diagnostics",
      "seed": { "categories": ["lsp", "diagnostics"], "contexts": ["normal"] } },
    { "id": "nemesis", "name": "Keeps Getting Me" },
    { "id": "all", "name": "Everything" }
  ]
}
```

- `schemaVersion` 必须为 `1`。最多接受 32 条声明（`all` 的覆盖声明也计入）；保留牌组 `all` 本身无论是否声明都始终存在。
- `id` 是稳定的状态键，必须匹配 `^[a-z][a-z0-9-]{0,31}$`。修改 `name`（最长 48 字符）不影响已保存的整理记录；修改 `id` 则相当于新建牌组。
- `seed` 可选且为封闭词表：取自内置题库的 `categories`、`extras` 与 `contexts`。只有出现的维度参与匹配，多个维度同时存在时取并集；出现但为空的数组不匹配任何卡片。完全**省略** `seed` 表示纯手工牌组——从空牌组开始，在「浏览」中逐卡添加；显式写成 `seed: {}` 则不加约束，匹配全部可用卡片。
- 声明 `id: "all"` 只会覆盖其显示名；其上的任何 `seed` 都会被忽略。
- 文件**不存在**时使用四个入门牌组；**存在**时完全替代入门牌组；**格式损坏**时回退到 `all`、显示原因，且不影响开始练习。无效条目、未知键与词表之外的值会被跳过、计数并显示。

来自 `lua/config/keymaps.lua` 的自定义映射（字面量 `vim.keymap.set` / `vim.keymap.del` 行）归入 `misc` 分类加入题库，可像其他卡片一样匹配 `misc` 或语境种子——也可手工挑选进任意牌组。

### 整理卡片

在首页或结算页打开「浏览」（对局进行中不可用；从结算页打开会先回到首页）。选择目标牌组——与你正在练习的牌组互不影响——再按分类、自定义（`keymaps.lua`）、已启用 extras 或成员状态过滤，逐卡切换其进出目标牌组。每行会标注该卡片同时所属的其他牌组。保留牌组 `all` 在此处为只读。

有两种移除卡片的手势，两者都完整保留学习历史：

- **对局中**的 `✕ 排除此键` 为**全局**排除——从包括 `all` 在内的所有牌组移除，直到你在顶栏恢复。
- **「浏览」中**的移除只作用于**目标牌组**。

整理状态上限为 24 KiB；会超出上限的添加将被拒绝并显示提示——不会静默驱逐任何已有记录。

### 对局、掌握与续练

- 每局发 `min(24, 可用)` 张卡片——7 张的牌组就发 7 张——除补救复习外不重复发卡。空牌组会拒绝开始并提示前往「浏览」。
- 掌握度是卡片级属性，在所有牌组间共享（在不同对局中连续两次首试正确）；对局次数、练习时长与 100% 庆祝均按牌组独立统计。
- 中断的对局原样续练；若期间有卡片离开牌组，已存对局会收缩为「已完成进度 + 剩余卡片」，分数、历史与原计划目标全部保留。

### 状态与迁移

Keycade LazyVim 只有三种状态文件——`settings.json`、`stats.json` 与 `session.json`——位于 `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade-lazyvim/`。从牌组功能之前的版本升级时，settings 从 schema 3 迁移到 4、stats 从 4 迁移到 5：每张卡片的记忆历史逐字保留，包括旧版按应用划分的机台下记录的历史（保留但不参与统计），原 LazyVim 的对局计数转移到 `all` 牌组。全局对局标识序列驱动卡片历史与排程，与牌组界面上显示的对局计数相互独立。升级到本版本会逐字保留所有卡片记录、不做任何删除，但不提供自动回退路径：旧版本可能拒绝新的 settings、stats 或 session 模式，将相关文件隔离后以全新进度启动。降级前请备份状态目录，并保留任何被隔离的文件以便恢复——不承诺旧版本能自动兼容卡片历史或牌组计数。

#### 从 `luneth90.keycade` 迁移

Keycade LazyVim 使用新的插件 ID 发布，Omarchy 会将它与旧插件并列安装，而不是原地升级：

```bash
omarchy plugin add https://github.com/GerritWanderer/keycade-lazyvim.git --enable
mv ~/.config/omarchy/keycade ~/.config/omarchy/keycade-lazyvim   # 仅在你声明过牌组时需要
omarchy plugin remove luneth90.keycade
```

首次启动会以重命名的方式接管已存在的 `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade/` 目录，所有卡片记录、对局计数与未完成的对局原样保留。若 `keycade-lazyvim` 状态目录已存在，旧目录将保持原样、绝不合并。另有两处需要你手动更新：重新绑定 Hyprland 快捷键（绑定中同时写有插件 ID 与显示名称），以及更新任何匹配 `keycade` 图层命名空间的 `layerrule`——它现在是 `keycade-lazyvim`。未迁移的 `decks.json` 会被视为不存在，此时内置入门牌组生效，功能不受影响。

## 卸载

```bash
omarchy plugin remove gerritwanderer.keycade-lazyvim
```

卸载后用户数据仍安全保留在 `${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/keycade-lazyvim/`。Keycade LazyVim 绝不在卸载时附带删除用户数据或静默修改 Hyprland 配置的危险脚本。

## 开发与测试说明

### 本机配置读取策略

内置词条库采用官方默认标准。有界静态解析只读取固定文件，用于校准 `mapleader` / `maplocalleader`、`lazyvim.json` 中启用的 extras、`lazy-lock.json` 中已安装的 LazyVim commit、`lua/config/keymaps.lua` 顶层字面量 `vim.keymap.set` / `vim.keymap.del` 改动，以及可选的 `decks.json` 牌组声明。所有读取均基于目录描述符、拒绝符号链接，只接受文档化的字面量形式；复杂写法会被跳过并计数。绝不执行 Lua 或 shell 配置，不启动编辑器，也不追踪 `require` 依赖链。

唯一的动态系统查询是启动预检：通过只读 `hyprctl` 确认 Hyprland 允许快捷键捕获后，覆盖层才会接管独占输入。所有 helper 都受 deadline 与输出上限保护，QML 在保留数据前还会独立重建有界白名单模型。

### 自动化测试与截图

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
for suite in tests/qml/tst_*.qml; do
  QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_STYLE_OVERRIDE=Fusion \
    /usr/lib/qt6/bin/qmltestrunner -input "$suite" -import /usr/lib/qt6/qml
done
./tests/test_state_store_qml.sh
./tests/test_ground_switching_qml.sh
./tests/test_run_counters_qml.sh
./tests/test_mastery_transition_qml.sh
/usr/lib/qt6/bin/qmllint -I /usr/lib/qt6/qml Keycade.qml lib/*.qml lib/sources/*.qml dev/InputProbe.qml
python3 tests/fuzz_keybinds.py -runs=1000
```

模糊烟雾测试需要固定的开发依赖（`requirements-dev.txt`，建议在 venv 中使用）。`./tools/shoot-screenshots` 在真实 Wayland 会话中重拍文档插图（维护者工具，需要 `grim`）。

## 开源协议

Keycade LazyVim 采用 [MIT 许可证](LICENSE) 发布。Copyright © 2026 luneth90 与 © 2026 GerritWanderer。
