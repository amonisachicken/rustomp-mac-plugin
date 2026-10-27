# rustomp-mac-plugin

**rustomp 插件的 macOS 打包工具** —— 把「已经生成好代码的插件项目」打成
**AUv2 / VST3 / CLAP**（universal binary），签名、安装、并做进程内自检。

```text
插件项目（Rust + rustomp.toml）        rustomp-mac-plugin                宿主
──────────────────────────           ─────────────────────           ──────
cargo build（universal）      ──►      clap-wrapper → AUv2（CMake）
target/bundled/*.clap|*.vst3  ──►      plist 改写 / 改名 / ad-hoc 签名
                                       ~/Library/Audio/Plug-Ins/…
                                       au_smoke（进程内验证 AU）
                                              │
                                    打印 ARTIFACT: <路径>  ──►  AU / VST3 / CLAP
```

**这个仓库只管打包。** DSP、代码生成、面板都在 [rustomp](https://github.com/amonisachicken/rustomp)；
面板设计在 [rustomp-box-designer](https://github.com/amonisachicken/rustomp-box-designer)。
仓库边界与三个跨仓契约见 rustomp 的 `docs/ecosystem.md`。

---

## 快速开始

```bash
# 1) 准备（只需一次）—— 三个仓放同一个目录（框架是本工具的同级）
mkdir -p ~/projects && cd ~/projects
git clone git@github.com:amonisachicken/rustomp.git
git clone git@github.com:amonisachicken/rustomp-mac-plugin.git
cd rustomp-mac-plugin
./scripts/fetch-third-party.sh        # 拉 clap-wrapper / CLAP SDK / AudioUnitSDK（固定 commit）
cargo install --git https://github.com/robbert-vdh/nih-plug.git \
              --rev de42101 cargo-nih-plug --locked      # cargo 子命令（版本见 deps.lock）
./scripts/doctor.sh                   # 体检：cargo / Xcode CLT / cmake / rust targets / cargo-nih-plug…

# 2) 打包一个插件项目
git clone git@github.com:amonisachicken/sparklin-drive.git
./pack.sh ../sparklin-drive                              # mono + stereo，AU/VST3/CLAP，并安装
./pack.sh ../sparklin-drive --variant stereo --format au --no-install
```

成功时 stdout **只有** `ARTIFACT:` 行（契约 B）：

```text
ARTIFACT: /Users/me/develop/rustomp-mac-plugin/build/au-mono/Sparklin Drive Mono.component
ARTIFACT: /Users/me/develop/sparklin-drive/target/bundled/Sparklin Drive Mono.vst3
ARTIFACT: /Users/me/develop/sparklin-drive/target/bundled/Sparklin Drive Mono.clap
```

框架侧据此判断"打包成功与否"，**不需要知道 macOS 的任何细节**。

---

## 参数

```text
pack.sh <plugin_dir> [--variant mono|stereo|dual]... [--format au|vst3|clap]... [--no-install]

默认：variant = mono + stereo，format = au + vst3 + clap，安装到 ~/Library/Audio/Plug-Ins/
```

| 环境变量 | 作用 |
|---|---|
| `RUSTOMP_ROOT` | 显式指定框架目录（**默认**：`<plugin_dir>/../rustomp`，即同级目录） |
| `PLUGIN_DIR` | 等价于第一个位置参数 |
| `RUSTOMP_GUEST` | 若 `pack.sh` 由框架的 `build-all.sh` 调用，用它指定插件目录 |
| `MACOS_DEPLOYMENT_TARGET` | AUv2 的最低系统版本（**默认 11.0**）。**不要留空**：clap-wrapper 在它为空时会走 "deployment < 10.15" 分支，去 CPM 下载 Gulrak filesystem（需要联网，断网就报 `Unknown CMake command CPMAddPackage`）；同时它会写进 AU 的 `LSMinimumSystemVersion` |
| `RUSTOMP_BUILD_JOBS` | `cmake --build` 的并行度（**默认 4**）。原来按 `hw.ncpu` 给（本机 20 路），在 10 核机器上是无谓的整机压力 |

目录约定（三个仓同级）：

```text
some-dir/
  rustomp/              ← 框架
  rustomp-mac-plugin/   ← 本工具
  sparklin-drive/       ← 插件项目
```

**插件项目必须住在框架目录树之外**：`cargo-nih-plug` 会向上找**最顶层**的 `Cargo.toml`
当 workspace 根，插件嵌在 `rustomp/plugins/` 里会被拉到框架根 → `packages outside of workspace`。

---

## 目录

```text
pack.sh                  入口（契约 B）：体检 → 读清单 → 逐 variant 构建 → 打印 ARTIFACT
scripts/
  doctor.sh              环境体检（缺什么给"怎么装"）
  build-variant.sh       单个变体：Rust 通用二进制 → 改名/plist → clap-wrapper → AUv2 → 签名 → 安装 → au_smoke
  build-au.sh            双布局（mono+stereo 同体）变体的过渡用构建
  check-au.sh            只做 AU 自检
  gen-bundler-toml.sh    从插件 rustomp.toml 生成 bundler.toml（写在插件项目根）
  fetch-third-party.sh   拉 clap-wrapper / CLAP / AudioUnitSDK（固定 commit）并打补丁
  plugin-env.sh          读 rustomp.toml（经由框架的 plugin_meta.py）→ shell 变量
  reset-logic-cache.sh   清 Logic 的插件缓存（排查"改了没生效"）
cmake/CMakeLists.txt     clap-wrapper 的 AUv2 包装
patches/                 第三方源码的必要补丁（AUv2 host classification 等）
tools/au-smoke/          AU 进程内自检（C，绕过系统注册表）
tools/clap-probe/        最小 CLAP 宿主（查端口/feature/参数）
third_party/             第三方源码缓存（不入库，由 fetch-third-party.sh 填充）
```

---

## 为什么 AU 要绕这么一圈

- **AUv2 没有官方 Rust 绑定**：用 [clap-wrapper](https://github.com/free-audio/clap-wrapper) 把 CLAP 包成 AUv2；
- **宿主会按自己的缓存判断"这是什么插件"**：所以要**新的 AU 身份（subtype）+ 新 bundle id**
  —— 这就是 mono / stereo 分成两个独立插件的原因（ADR-008）；
- **Logic 的缓存很顽固**：改名/改 subtype 之后仍可能显示旧名字，用 `scripts/reset-logic-cache.sh`；
- **AUv2 的 host classification 有坑**：那个补丁（`patches/0001-…`）就是为了让 Logic 把它
  归到 Audio FX、而不是 Instrument。

---

## 已知限制

| 项 | 状态 |
|---|---|
| standalone | **没做**（要处理音频设备选择/设置持久化），列在 v0.2 |
| 签名 | 目前是 ad-hoc（`codesign -s -`）；对外分发需要 Developer ID + notarize，单列一项 |
| Windows / Linux | 不在本仓：未来的 `rustomp-win-plugin` / `rustomp-linux-plugin`，同一套契约 B |
| AAX | 不做（需要 Avid 授权） |

---

## 许可证

GPL-3.0-or-later。第三方源码的许可证见各自目录（CLAP SDK: MIT，AudioUnitSDK: Apache-2.0）。
