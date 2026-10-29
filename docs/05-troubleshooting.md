# 排障：症状 → 真因 → 处理

> 先跑 `./scripts/doctor.sh`，再跑 `./scripts/check-au.sh <variant>`。
> 这两个命令把"环境问题 / 插件问题 / 宿主缓存问题"分开，比猜快得多。
> 想看某条的历史背景，去 [`09-devlog.md`](09-devlog.md) 找对应条目。

---

## 构建

### `Unknown CMake command "CPMAddPackage"` / `file DOWNLOAD cannot compute hash`

**真因**：`CMAKE_OSX_DEPLOYMENT_TARGET` 为空或低于 10.15。clap-wrapper 会走
"deployment < 10.15" 分支，用 CPM 现场下载 Gulrak filesystem —— 断网/超时就是这两条报错。

**处理**：

```bash
MACOS_DEPLOYMENT_TARGET=11.0 ./pack.sh ../my-effect
```

默认值已经是 11.0（E88.3 / v0.1.6）；出现这条说明你用了旧脚本或手动调了 cmake。
**不要**用"让它联网下载"来绕：构建期联网会让可复现性消失。

### `cannot specify features for packages outside of workspace`

**真因**：插件项目被放进了框架目录树（例如 `rustomp/plugins/…`）。
`cargo-nih-plug` 会向上找**最顶层**的 `Cargo.toml` 当 workspace 根，于是把插件当成
框架 workspace 的成员。

**处理**：把插件移到所有仓的**同级**目录：

```text
some-dir/{rustomp, rustomp-mac-plugin, my-effect}
```

`pack.sh ../my-effect` 或 `PLUGIN_DIR=/abs/path ./pack.sh`，不要塞进 `rustomp/plugins/`。

### 明明装了 cargo-nih-plug，`doctor.sh` 却说没有

**真因**（v0.1.3 之前）：探测用了 `... | grep -q`，`pipefail` 下 grep 提前退出会让上游
收到 SIGPIPE(141)，整条管道非 0 → 假阴性。

**处理**：升级到 v0.1.3+。手工确认：

```bash
command -v cargo-nih-plug
cargo --list 2>/dev/null | grep nih-plug
```

（`cargo nih-plug --help` **不能**用来探测：它没有 `--help` 子命令，返回非 0。）

### `unbound variable` / 变量名后面粘了中文

**真因**（v0.1.1 之前）：bash 里全角标点紧跟变量（`${VAR}（…`）会被当成变量名的一部分。

**处理**：升级；若要改脚本，写成 `${VAR}（`。

### 构建把机器压满 / 风扇起飞

**真因**：cmake 并行度。旧脚本按 `hw.ncpu`（本机 20 路）给。

**处理**：默认已是 4（`RUSTOMP_BUILD_JOBS`）。确实要快再显式调大，别长期拉满：

```bash
RUSTOMP_BUILD_JOBS=6 ./pack.sh ../my-effect
```

### `pack.sh` 退出非 0，但没说清哪里错

按顺序看：

1. `scripts/doctor.sh`（人读模式）先过；
2. `build/au-<variant>/configure.log`（cmake 配置）→ `build.log`（编译）；
3. 插件项目自己的 `cargo build` / 基线测试（打包工具不替你验证 DSP）。

---

## 安装与产物

### stdout 里没有 `ARTIFACT:` 行

`pack.sh` 只把 `ARTIFACT:` 写 stdout，**日志全在 stderr**。没有行 = 没有产物：

- 检查 `--format` 是否拼错（只接受 `au|vst3|clap`）；
- 检查 `--variant`（`pack.sh` 只分派 `mono|stereo`；`dual` 会报未知变体，见下）；
- 看退出码：`echo $?` 非 0 就是失败，不是"没有输出"。

### `pack.sh --variant dual` 报"未知变体"

**真因**：dual（mono+stereo 同体）是拆仓前的过渡形态，由 `scripts/build-au.sh` 构建；
`build-variant.sh` 只认 mono / stereo（[`02-architecture.md`](02-architecture.md) §5）。

**处理**：要 dual 就直接 `./scripts/build-au.sh`；正常发版用 mono + stereo 两个独立身份（M-003）。

### 装完 Logic 里还是旧名字 / 旧行为

**真因**：宿主缓存，不是安装失败。安装脚本会先删旧再拷贝，文件层面一定是新的。

**处理**：先 `./scripts/check-au.sh <variant>` 看缓存条目，再决定是否清：

```bash
# 必须完全退出 Logic（⌘Q），否则退出时会把内存里的旧值写回 plist
./scripts/reset-logic-cache.sh
```

### 只想要 AU，但发现 VST3/CLAP 也被装了

`--format` **不控制构建与安装**：每个变体都会构出三种格式（AU 内嵌 `.clap`），
安装也是三种。它只筛选两处：`ARTIFACT:` 列表、**DMG 的 payload**。
要真的不装到本机，用 `--no-install`；“只装某一种格式”目前 **不支持**
（需要的话请手动拷只想要的那份）。

---

## DMG 安装包

### `hdiutil create` 报 “Resource busy” / “文件已存在”

**真因**：同名的 DMG 还挂载着，或者输出目录不可写。

**处理**：

```bash
hdiutil info | grep -i "<Name> Installer"     # 找到挂载点
hdiutil detach "/Volumes/<Name> Installer"    # 或在 Finder 里推出
./pack.sh ../my-effect --format dmg --no-install
```

`build-dmg.sh` 会用 `-ov` 覆盖同名文件，但**不会**替你卸载已挂载的卷。

### DMG 里少了一个格式

**真因**：payload 按 `--format` 里**同时请求**的 au/vst3/clap 过滤。
`--format dmg` 单独写 = 三种全放；`--format au dmg` = 只放 AU。

**处理**：想要三种就写 `--format dmg`，或显式 `--format au vst3 clap dmg`。
（注意：无论 payload 放什么，构建与安装仍是三种；见上一节。）

### 双击 `安装.command` 没反应 / 提示“无法验证开发者”

**真因**：DMG 没有 Developer ID 签名与公证，下载后文件带 quarantine；脚本本身也没有签名。

**处理**：右键 `安装.command` → **打开** → 再确认一次；或在终端里：

```bash
cd "/Volumes/<Name> Installer"
chmod +x 安装.command && ./安装.command
```

如果仍然被拦，可在“系统设置 → 隐私与安全性”里允许。**不要**把整个 DMG 或插件包
`xattr -dr com.apple.quarantine` 当成常规步骤——那等于绕过系统的安全提示。

### 装完宿主里还是旧的

`安装.command` 只负责复制，不负责清宿主缓存。先完全退出宿主，再按
[`03-logic-compat.md`](03-logic-compat.md) §3 清 Logic 缓存（DMG 的 `README.txt`
里也印了对应的 `plutil -remove` 命令）。

### 想装给全机（所有用户）

DMG 的 `安装.command` 只写 `~/Library/Audio/Plug-Ins`。系统级安装要手动复制到
`/Library/Audio/Plug-Ins/{Components,VST3,CLAP}`（需要管理员），或等 `pkg`。

---

## 宿主（Logic / AU 验证）

### 插件管理器里能看到，但音频轨的 Audio FX 菜单里没有

**真因**：AU 只报告了 `{2,2}`，没有 `in=1` 的布局；Logic 按通道条声道数过滤菜单。
证据与根因（`clap.configurable-audio-ports` vs `clap.audio-ports-config`）见
[`03-logic-compat.md`](03-logic-compat.md) §2。

**处理**：

1. 确认补丁已应用：`fetch-third-party.sh` 的输出里应有 `[patch] 已应用 0001-…`；
2. 用 mono 变体（独立身份，只有一个布局，无歧义）；
3. `./scripts/check-au.sh mono` 应看到 `SupportedNumChannels: 2 组 / in=1 out=1`。

### 被归到"MIDI 控制效果器"，只出现在软件乐器插槽

**真因**：AU 无条件宣称了 MIDI / MusicDevice 属性，Logic 缓存成 `MIDIProtocol = 1`
（[`03-logic-compat.md`](03-logic-compat.md) §1）。

**处理**：确认补丁已应用 → 退出 Logic → `reset-logic-cache.sh` → 重开扫描。
`check-au.sh` 打印的 `MIDIProtocol` 应为 `0`。

### `auval` 说 "didn't find the component"（连 BYOD 也找不到）

**真因**：系统 `AudioComponentRegistrar` 的缓存坏了，和插件无关。

**处理**：

- 用进程内自检绕过注册表：`./scripts/check-au.sh <variant>`（内部就是 `au_smoke`）；
- 需要恢复系统注册表时，`build-au.sh` 会尝试 `killall -9 AudioComponentRegistrar`
  （可能需要 `sudo` 或重启）。

### 宿主里没有声音 / 渲染失败

按三层查：

| 层 | 看什么 |
|---|---|
| 插件 | `check-au.sh` 的 `音频通路正常` 与 RMS；同一条命令会打印安装时间 |
| 声道 | mono 变体测 1ch、stereo 测 2ch；声道数给错会渲染失败 |
| 插件内部 | 插件仓自己的基线/对拍测试（打包工具不覆盖 DSP 正确性） |

### 分发时被 Gatekeeper 拦 / 别人机器上打不开

**这是预期的**：当前只有 **ad-hoc 签名**（M-006）。对外分发需要 Developer ID + notarytool，
属于另一项工作，不在本仓脚本里。

---

## 版本与仓库

### 提示"本打包工具版本不满足插件要求"

`pack.sh` 会读插件的 `[requires] packer`（只支持下界，如 `>=0.1`），
版本号来自 `git describe --tags`。浅克隆没有 tag 时会退回硬编码版本。

**处理**：`git fetch --tags`；或升级本仓到满足要求的 tag。

### 拉下来的第三方版本与 `deps.lock` 不一致

**真因**：`fetch-third-party.sh` 里的版本常量与 `deps.lock` 是**手工同步**的，没有自动校验；
而且 `third_party/<x>` 已存在时脚本会直接 `[skip]`，不会改版本。

**处理**：对比两处版本 → 只删需要换代的那一个目录
（如 `third_party/clap-wrapper`，**不要整个删 `third_party/`**）→ 重跑 `fetch-third-party.sh`。

### 换了一台机器，`third_party` 是空的

`third_party/` 不入库。跑一次 `./scripts/fetch-third-party.sh`；
或从有网机器把 `third_party/` 整个拷过来（版本已在 `deps.lock` 固定）。
