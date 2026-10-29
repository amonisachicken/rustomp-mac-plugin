# rustomp-mac-plugin

**rustomp 插件的 macOS 打包工具** —— 把一个「已经生成好代码的 rustomp 插件项目」
打成 **AUv2 / VST3 / CLAP**（universal），做 ad-hoc 签名、装进用户级插件目录，并做进程内自检。

它**不针对任何具体插件**：所有插件相关的值都来自插件项目自己的 `rustomp.toml`（契约 A），
所以任何用 rustomp 做出来的效果器都能直接用它打包。

```text
插件项目（Rust + rustomp.toml）              rustomp-mac-plugin                     宿主
──────────────────────────────              ──────────────────────────────────     ──────
cargo nih-plug bundle-universal      ──►    改名 / plist / 新 AU 身份（mono·stereo）
  target/bundled/*.clap | *.vst3     ──►    clap-wrapper → AUv2（CMake）
                                            ad-hoc 签名 → ~/Library/Audio/Plug-Ins/
                                            au_smoke（进程内，绕开系统注册表）
                                                   │
                                           打印 ARTIFACT: <路径>  ──►  AU / VST3 / CLAP
```

Windows 的同位实现是 [rustomp-win-plugin](https://github.com/amonisachicken/rustomp-win-plugin)
（VST3 / CLAP + MSI，**没有 AU**）；框架是 [rustomp](https://github.com/amonisachicken/rustomp)；
仓库边界与三个跨仓契约见 rustomp 的 `docs/ecosystem.md`。

> macOS 真正特殊的只有 **AUv2**：nih-plug 只导出 VST3/CLAP，AU 得用 clap-wrapper 再包一层，
> 而 Logic 会按自己的缓存判断"这是什么插件、支持几个声道"。
> 这部分与两个必需补丁见 [`docs/03-logic-compat.md`](docs/03-logic-compat.md)。

---

## 1. 产品介绍

打包的本质是**三件与平台强相关的事**，本仓替插件项目把这三件事做掉：

| 交付物 | 用来做什么 |
|---|---|
| **AUv2 `.component`** | Logic 等 AU 宿主；`.clap` 嵌在 `Contents/PlugIns/`，用户只装一个文件 |
| **VST3 `.vst3`** | 其他宿主；universal（x86_64 + arm64） |
| **CLAP `.clap`** | 原生 CLAP 宿主；universal |
| **DMG 安装包** | `<Name> Installer.dmg`：三种插件 + 双击安装脚本 + 说明（用户级，免管理员） |
| **`ARTIFACT:` 行** | 契约 B 的唯一输出：框架/CI 只认这一行，不需要知道 macOS 的任何细节 |

它解决的是**"改完 DSP 到能在 Logic 里听到"之间那段脏活**：universal 构建、mono/stereo
独立身份、bundle 改名与 plist、clap-wrapper/CMake、ad-hoc 签名、装到对的位置、
用进程内工具证明 AU 真的能开、能渲染。

**面向谁**：已经用 rustomp 生成好插件项目（有 `rustomp.toml` 与 `plugin/src/generated/`）的开发者。
**不做**代码生成、不改 DSP、不碰插件源码 —— 那是 rustomp 与 rustomp-gen 的事。

### 当前状态（2026-10-29）

| 项 | 状态 |
|---|---|
| AUv2（mono / stereo 独立身份） | ✅ 已在 Logic 实测 |
| VST3 / CLAP（universal） | ✅ |
| 变体 | ✅ mono / stereo（`pack.sh` 默认两者都出）；dual 走 `scripts/build-au.sh`（过渡形态） |
| 安装 | ✅ 用户级 `~/Library/Audio/Plug-Ins/`，可 `--no-install` |
| 自检 | ✅ `au_smoke`（进程内，绕开注册表）+ `auval`（`build-au.sh`）+ `clap-probe` |
| 签名 | ✅ **ad-hoc**（`codesign -s -`）；Developer ID / 公证 ❌ |
| **DMG 安装包** | ✅ `--format dmg`（用户级：拖拽或双击 `安装.command`） |
| pkg 安装包 | ❌ 未做（DMG 已覆盖“分发给用户”的主路径） |
| standalone | ❌ 未做（列为 v0.2） |
| CI | ❌ 本仓没有 workflow（参考插件仓 `sparklin-drive` 的 CI 会三仓 checkout 跑打包） |
| 已知边界 | 只有 ad-hoc 签名；dual 无一键入口；DMG 只装当前用户；Developer ID / 公证、`pkg` 未做 |

---

## 2. 架构

```text
pack.sh（契约 B 入口）
  │  1 体检  scripts/doctor.sh            —— cargo/Xcode CLT/cmake/rust targets/cargo-nih-plug/框架/第三方/素材
  │  2 读清单 scripts/plugin-env.sh       —— 经框架 plugin_meta.py 读 rustomp.toml（契约 A）
  │  3 定变体                            —— 默认 mono + stereo；命令行 --variant 优先
  └  4 逐变体  scripts/build-variant.sh（一次构出 AU/VST3/CLAP）
        ├ gen-bundler-toml.sh   → <plugin>/bundler.toml
        ├ cargo nih-plug bundle-universal … --features <variant>
        ├ 改名 + plist          → "<Name> Mono|Stereo".{vst3,clap}
        ├ cmake（clap-wrapper） → build/au-<variant>/<Name>.component
        ├ plist 归位 + 断言     → subtype / type / manufacturer / factoryFunction
        ├ ad-hoc 签名           → 内层 .clap → 外层 .component / .vst3 / .clap
        ├ 安装（可选）          → ~/Library/Audio/Plug-Ins/{Components,VST3,CLAP}
        ├ au_smoke              → 进程内冒烟（mono 测 1ch / stereo 测 2ch）
        └ 写 manifest           → build/artifacts-<variant>.txt（绝对路径）

  ├  5 DMG（--format dmg） scripts/build-dmg.sh
  │       读 manifest → 按 --formats 过滤 → Payload/{Components,VST3,CLAP}
  │       + 安装.command + README.txt → hdiutil create（UDZO）→ build/dmg/<Name> Installer.dmg
  │
  └  6 汇总         stdout 逐行 `ARTIFACT: <绝对路径>`；一枚都没有则非 0 退出
```

| 层 | 选型 | 理由 |
|---|---|---|
| 脚本语言 | **bash** | 与 Windows 仓同构，两个平台的脚本可以逐段对照 |
| 编译 | `cargo nih-plug bundle-universal`（rev 钉死） | 一个产物覆盖 Intel / Apple Silicon |
| AU 包装 | **clap-wrapper** + Apple AudioUnitSDK | nih-plug 没有 AU 导出；这是成熟路径（M-002） |
| 签名 | `codesign --sign -`（ad-hoc） | 本地验证够用；分发签名单列（M-006） |
| 验证 | `au_smoke`（自写 C）+ `auval` + `clap-probe` | 前两者分别解决"注册表坏了"和"系统校验" |
| 并行度 | `RUSTOMP_BUILD_JOBS`（默认 4） | 不把整机压满（M-009） |
| DMG | `hdiutil`（系统自带，UDZO/HFS+）+ `安装.command` | 不引第三方打包器；安装范围固定用户级（M-011） |

### 目录

```text
pack.sh                  入口（契约 B）：体检 → 读清单 → 逐变体构建 → 打印 ARTIFACT
scripts/
  doctor.sh              环境体检（缺什么给"怎么装"）
  build-variant.sh       单变体：universal 构建 → 改名/plist → clap-wrapper → 签名 → 安装 → au_smoke
  build-au.sh            dual（mono+stereo 同体）变体的过渡构建（含 auval）
  build-dmg.sh           把已构建产物打成 DMG（Payload + 安装.command + README）
  check-au.sh            只做 AU 自检（已安装的 .component + Logic 缓存）
  gen-bundler-toml.sh    从 rustomp.toml 生成 <plugin>/bundler.toml
  fetch-third-party.sh   按固定版本拉第三方源码并应用 patches/（版本见 deps.lock）
  plugin-env.sh          读 rustomp.toml（经框架 plugin_meta.py）→ shell 变量
  reset-logic-cache.sh   清 Logic 的 AU 能力缓存（必须先退出 Logic）
cmake/CMakeLists.txt     clap-wrapper 的 AUv2 包装（禁构建期联网下载 SDK）
patches/                 第三方源码的必要补丁（0001：MIDI 归类 + 声道布局）
tools/au-smoke/          AU 进程内自检（C，绕开系统注册表）
tools/clap-probe/        最小 CLAP 宿主（dump 端口/参数/身份）
third_party/             第三方源码缓存（不入库，由 fetch-third-party.sh 填充）
deps.lock                外部依赖的固定版本
docs/                    决策 / 架构 / Logic 兼容 / 依赖 / 排障 / 开发日志
```

细节（每一跳做了什么、产物形状、plist 断言）见 [`docs/02-architecture.md`](docs/02-architecture.md)。

---

## 3. 功能范围

### 能做

| 类别 | 内容 |
|---|---|
| **格式** | AUv2（`.component`）、VST3（`.vst3`）、CLAP（`.clap`）、**DMG 安装包** |
| **架构** | universal：`x86_64` + `arm64` 同体；最低系统版本默认 11.0（`MACOS_DEPLOYMENT_TARGET`） |
| **变体** | mono / stereo，各自是**独立 AU 身份**（新 subtype + bundle id 后缀）；可一次出两个 |
| **安装** | 用户级 `~/Library/Audio/Plug-Ins/{Components,VST3,CLAP}`；`--no-install` 只产出 |
| **DMG** | `--format dmg` → `<Name> Installer.dmg`：`Payload/{Components,VST3,CLAP}` + `安装.command` + `README.txt`；安装范围是**当前用户**（系统级 `/Library/...` 需手动） |
| **自检** | `au_smoke` 进程内开/初始化/渲染（校验声道数与 RMS）；`auval`（`build-au.sh`）；`clap-probe` 查端口 |
| **通用性** | 只依赖 `rustomp.toml`（契约 A）；插件可以是更大 workspace 的成员（bundle 落插件根） |
| **可诊断** | `doctor.sh` 逐项说"缺什么、怎么装"；cmake 日志落在 `build/au-<variant>/` |

### 暂不（有明确边界，不是遗忘）

| 项 | 状态 |
|---|---|
| Developer ID 签名 / 公证 | 未做：对外分发才需要证书与 notarytool（本地是 ad-hoc） |
| `pkg` 安装包 | 未做：DMG 已能用（用户级）；pkg 的价值主要是系统级安装与统一卸载 |
| DMG 的签名/公证 | 未做：DMG 本身没有 Developer ID 签名；里面是 ad-hoc 签名的插件 |
| standalone | 未做：需要音频设备选择/设置持久化，列为 v0.2 |
| dual（mono+stereo 同体）一键打包 | 只有 `scripts/build-au.sh` 这条过渡入口；`pack.sh` 只分派 mono/stereo |
| CI | 本仓没有 workflow；参考插件仓 `sparklin-drive` 的 CI 会三仓 checkout 跑打包端 |

### 明确不做

| 不做 | 原因 |
|---|---|
| **DSP / 代码生成 / 改插件源码** | 那是 rustomp 与 rustomp-gen 的职责；本仓只消费已生成的产物 |
| **Windows / Linux 打包** | 平台分仓（ADR-015）；Windows 已由 [rustomp-win-plugin](https://github.com/amonisachicken/rustomp-win-plugin) 实现 |
| **AAX** | 需要 Avid 授权，且与 GPL-3 冲突 |
| **AUv3** | 需要完整 Xcode 生成 appex，不在本期范围 |

---

## 4. 部署与运行

### 依赖（一台干净的 Mac 从零开始）

| 依赖 | 用途 | 检查 | 装法 |
|---|---|---|---|
| **macOS 11+** | 平台 | — | — |
| **Xcode 命令行工具** | `cc` / `lipo` / `plutil` / `codesign` / `auval` | `xcode-select -p` | `xcode-select --install` |
| **cmake ≥ 3.20** | 编 clap-wrapper 的 AUv2 外壳 | `cmake --version` | `brew install cmake` |
| **Python ≥ 3.11** | 读 `rustomp.toml`（`tomllib`） | `python3 -V` | 系统自带或 `brew install python` |
| **Rust（rustup）** | 编译插件 | `rustc -V` | [rustup.rs](https://rustup.rs) |
| **两个 rust target** | universal | `rustup target list --installed` | `rustup target add aarch64-apple-darwin x86_64-apple-darwin` |
| **cargo-nih-plug**（rev 钉死） | `cargo nih-plug bundle-universal` | `cargo --list` 里出现 nih-plug | `cargo install --git https://github.com/robbert-vdh/nih-plug.git --rev de42101 cargo-nih-plug --locked` |
| **rustomp 框架仓** | 读清单 / 校验生成物 | 同级 `../rustomp/tools/meta/plugin_meta.py` | `git clone https://github.com/amonisachicken/rustomp.git` |
| **第三方源码**（clap-wrapper / CLAP SDK / AudioUnitSDK） | AUv2 构建 | `third_party/clap-wrapper/` 等 | `./scripts/fetch-third-party.sh` |

> 一条命令看缺什么：`./scripts/doctor.sh`（每一项都附"怎么装"）。
> 固定版本、离线注意与升级检查单见 [`docs/04-dependencies.md`](docs/04-dependencies.md)。

### 启动（打包一个插件）

```bash
# 目录约定：框架、打包工具、插件项目都是**同级**
#   some-dir/{rustomp, rustomp-mac-plugin, my-effect}

./scripts/fetch-third-party.sh                     # 一次性：拉第三方源码 + 打补丁
./scripts/doctor.sh                                # 一次性：体检
./pack.sh ../my-effect                             # mono + stereo，AU/VST3/CLAP，并安装
./pack.sh ../my-effect --variant stereo --format au --no-install
./pack.sh ../my-effect --format dmg --no-install    # 额外产出 <Name> Installer.dmg（不装到本机）
```

成功时 stdout **只有** `ARTIFACT:` 行（契约 B）：

```text
ARTIFACT: /Users/me/develop/rustomp-mac-plugin/build/au-mono/Sparklin Drive Mono.component
ARTIFACT: /Users/me/develop/sparklin-drive/target/bundled/Sparklin Drive Mono.vst3
ARTIFACT: /Users/me/develop/sparklin-drive/target/bundled/Sparklin Drive Mono.clap
ARTIFACT: /Users/me/develop/rustomp-mac-plugin/build/dmg/Sparklin Drive Installer.dmg
```

### 参数与环境变量

```text
pack.sh <plugin_dir> [--variant mono|stereo]... [--format au|vst3|clap|dmg]... [--no-install]

默认：variant = mono + stereo，format = au + vst3 + clap，安装到 ~/Library/Audio/Plug-Ins/。

> `--format` 控制两件事：哪些路径进 **`ARTIFACT:` 列表**，以及 **DMG 里放哪些格式**。
> 每个变体仍会把 AU/VST3/CLAP 全部构建（AU 内嵌 `.clap`，VST3/CLAP 由同一次
> `bundle-universal` 产出）；写 `--format dmg` 会在所有变体构建完后额外生成
> `<Name> Installer.dmg`（payload = 同时请求的 au/vst3/clap；只写 dmg 则三种全放）。
> 安装到本机用户目录仍默认进行，`--no-install` 关闭它（不影响 DMG）。
```

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `RUSTOMP_ROOT` | `<plugin_dir>/../rustomp` | 框架目录（读 `rustomp.toml` 用） |
| `PLUGIN_DIR` | 第一个位置参数 | 插件项目目录 |
| `RUSTOMP_GUEST` | — | 由框架的 `build-all.sh` 调用时指定插件目录 |
| `MACOS_DEPLOYMENT_TARGET` | `11.0` | AU 的最低系统版本。**不要留空**：留空会触发 clap-wrapper 的 CPM 联网下载（`Unknown CMake command CPMAddPackage`），同时写进 AU 的 `LSMinimumSystemVersion` |
| `RUSTOMP_BUILD_JOBS` | `4` | `cmake --build -j` 的并行度（本机内核恐慌史，别随手拉满） |

### 测试（本仓自己的验证）

```bash
./scripts/doctor.sh                              # 环境体检
./scripts/check-au.sh mono                       # 已安装 AU：安装时间/签名/声道能力/渲染/Logic 缓存
./scripts/check-au.sh stereo
./scripts/reset-logic-cache.sh                   # Logic 菜单不对时（先 ⌘Q 退出 Logic）
./scripts/build-au.sh                             # dual 双布局：构建 → 冒烟 → 安装 → auval
./scripts/build-au.sh --no-install                # 只到进程内冒烟（不装、不跑 auval）
./pack.sh ../my-effect --format dmg --no-install  # 只产出 DMG（便于检查内容）
hdiutil imageinfo "<...>/build/dmg/<Name> Installer.dmg"
```

`check-au.sh` 是**只读**的：它先告诉你插件本身能不能渲染、Logic 缓存里记的是什么，
再决定要不要清缓存。判据与三个工具的分工见
[`docs/03-logic-compat.md`](docs/03-logic-compat.md)。

---

## 5. 与 rustomp 对接

本仓是**契约 B 的一个实现**（`rustomp/docs/ecosystem.md` §2）：

| 契约 | 本仓怎么用 |
|---|---|
| **A：`rustomp.toml`** | 只读，且**必须**经框架的 `tools/meta/plugin_meta.py`（不自己解析 TOML）。用到的键：`[plugin] package/name/vendor`、`[au] subtype_*/manufacturer_*/bundle_id`、`[requires] packer`、`[assets]`（体检用） |
| **B：命令行与产物** | `pack.sh <plugin_dir> [--variant …] [--format …] [--no-install]`；成功时 **stdout 逐行** `ARTIFACT: <绝对路径>`，失败非 0 退出 + 人话原因 |
| **C：`[assets]`/`[ui]`** | 不消费内容，只在体检时确认素材文件存在（缺失会让插件编译期 `include_bytes!` 直接失败） |

**版本约束**：插件 `rustomp.toml` 的 `[requires] packer` 在启动时校验一次（只支持下界，如
`>=0.1`），不满足就明确报错；版本号取自 `git describe --tags`，浅克隆没有 tag 时退回硬编码。

**五个从平台事实来的约定**：

1. 插件项目必须在**框架目录树之外**（`cargo-nih-plug` 会向上找最顶层 `Cargo.toml` 当 workspace 根）；
2. 三个仓**同级**放置；`doctor.sh` 的提示里就是可直接粘贴的 clone 命令（不假设绝对路径）；
3. mono / stereo 是**两个独立插件身份**（新 subtype + bundle id 后缀），不是同一个插件的两种模式；
4. universal 需要两个 rust target；`MACOS_DEPLOYMENT_TARGET` 显式给 11.0；
5. `ARTIFACT:` 之外的一切日志都在 stderr（框架/CI 靠 stdout 判成功）。

---

## 6. 文档

细节全在 [`docs/`](docs/README.md)（含索引与"何时读哪篇"）：

- **决策账本** [`docs/00-decisions.md`](docs/00-decisions.md) —— 先读这个，每条形如 M-00x；
- **架构** [`docs/02-architecture.md`](docs/02-architecture.md) —— 调用链、产物形状、身份与 plist；
- **Logic 兼容** [`docs/03-logic-compat.md`](docs/03-logic-compat.md) —— 两个必需补丁与缓存机制；
- **依赖** [`docs/04-dependencies.md`](docs/04-dependencies.md) —— 固定版本、装法、离线注意、升级检查单；
- **排障** [`docs/05-troubleshooting.md`](docs/05-troubleshooting.md) —— 症状 → 真因 → 处理；
- **开发日志** [`docs/09-devlog.md`](docs/09-devlog.md) —— 做了什么、为什么、踩了什么坑。

---

## 7. 许可证

GPL-3.0-or-later（[`LICENSE`](LICENSE)）。第三方：CLAP SDK（MIT）、AudioUnitSDK（Apache-2.0）、
clap-wrapper（MIT），版本钉在 [`deps.lock`](deps.lock)。
