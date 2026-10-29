# 架构

> 决策理由见 [`00-decisions.md`](00-decisions.md)；宿主兼容细节见 [`03-logic-compat.md`](03-logic-compat.md)。

---

## 1. 两个平面

| 平面 | 在哪运行 | 产物 |
|---|---|---|
| **代码生成** | 任意主机（框架 + `rustomp-gen`） | 插件的 `src/generated/*.rs` |
| **打包** | **macOS 本机**（Xcode CLT / cmake / codesign） | AUv2 / VST3 / CLAP + `ARTIFACT:` 行 |

本仓只做第二个平面：只读插件的 `rustomp.toml` 与已生成的代码，**不改 DSP、不改生成物**。

---

## 2. 调用链

```text
pack.sh（契约 B 入口）
  │  参数：<plugin_dir> [--variant mono|stereo]... [--format au|vst3|clap|dmg]... [--no-install]
  │
  ├─ 1 体检         scripts/doctor.sh
  │                   cargo / Xcode CLT / cmake / cc / python3 / plutil /
  │                   cargo-nih-plug / 两个 rust target / 框架 / third_party /
  │                   插件的 generated/ 与 [assets] 文件是否存在
  │
  ├─ 2 读清单       scripts/plugin-env.sh
  │                   → 框架的 tools/meta/plugin_meta.py（契约 A）→ shell 变量
  │                   → 校验 [requires] packer（只支持 ">=x.y" 这种下界）
  │
  └─ 3 逐变体       scripts/build-variant.sh <mono|stereo> [--no-install]
        ├─ gen-bundler-toml.sh   → <plugin>/bundler.toml（bundle 名 = 插件名）
        ├─ cargo nih-plug bundle-universal <pkg> --release --features <variant>
        ├─ 改名 + plist           → "<Name> Mono|Stereo".{vst3,clap}，改 CFBundle*
        ├─ cmake（clap-wrapper）  → build/au-<variant>/<Name>.component
        ├─ plist 归位 + 断言      → subtype / type / manufacturer / factoryFunction
        ├─ ad-hoc 签名            → 内层 .clap → 外层 .component / .vst3 / .clap
        ├─ 安装（可选）           → ~/Library/Audio/Plug-Ins/{Components,VST3,CLAP}
        └─ au_smoke               → 进程内冒烟测试（单声道 1ch / 立体声 2ch）
             写 build/artifacts-<variant>.txt（本变体三个产物的绝对路径）

  ├─ 4 DMG（可选）  scripts/build-dmg.sh
  │                   读 artifacts-*.txt → 按 --formats 过滤 → 暂存
  │                   Payload/{Components,VST3,CLAP} + 安装.command + README.txt
  │                   hdiutil create → build/dmg/<Name> Installer.dmg
  │
  └─ 5 汇总         stdout 逐行 `ARTIFACT: <绝对路径>`；一枚都没有则非 0 退出
```

要点：

- `--format` 控制两件事：哪些路径进 `ARTIFACT:` 列表、**DMG 的 payload 放哪些格式**；
  每个变体都会构出三种格式（AU 内嵌 `.clap`，VST3/CLAP 由同一次 `bundle-universal` 产出），
  安装也包含三种（除非 `--no-install`）；
- **所有日志走 stderr**（M-008），stdout 只有 `ARTIFACT:`；
- 单个变体失败即整体失败（`set -euo pipefail`），不会产出"半套"；
- cmake 的 configure / build 日志分别落在 `build/au-<variant>/{configure,build}.log`，
  失败时只 `tail` 关键几行，避免刷屏。

---

## 3. 产物形状

| 格式 | 路径 | 说明 |
|---|---|---|
| AUv2 | `build/au-<variant>/<Name> Mono.component` | 目录包；`.clap` 嵌在 `Contents/PlugIns/` |
| VST3 | `<plugin>/target/bundled/<Name> Mono.vst3` | nih-plug 产物改名后的目录包 |
| CLAP | `<plugin>/target/bundled/<Name> Mono.clap` | 目录包，二进制在 `Contents/MacOS/` |
| DMG | `build/dmg/<Name> Installer.dmg`（`--format dmg`） | 用户级安装包；内容见 §3.1 |

`<Name>` = 插件名 + ` Mono` / ` Stereo`（dual 变体无后缀）。
三个格式都是 **universal**（`x86_64` + `arm64`），可用 `lipo -info` 核对。

### 3.1 DMG 里有什么

```text
<Name> Installer.dmg
  Payload/Components/<Name> Mono.component     ← AUv2
  Payload/VST3/<Name> Mono.vst3                ← VST3
  Payload/CLAP/<Name> Mono.clap                ← CLAP
  安装.command                                  ← 双击：复制到 ~/Library/Audio/Plug-Ins/
  README.txt                                    ← 安装路径、缓存的清法、已知边界
```

- **安装范围是当前用户**（`~/Library/Audio/Plug-Ins`，不需要管理员）；
  系统级 `/Library/Audio/Plug-Ins` 需要手动复制；
- DMG 只**收集**已构建的产物（`build/artifacts-<variant>.txt`），不重新编译；
- `安装.command` 里用 `$HOME`，在**用户机器上**展开；脚本只做复制 + 尽力重启 AU 注册表；
- DMG 本身不做 Developer ID 签名/公证（与插件一样是本地开发形态）。

---

## 4. 身份从哪来

全部来自插件的 `rustomp.toml`（经过框架的 `plugin_meta.py`），本仓**不硬编码**：

| plist 键 | 来源 |
|---|---|
| `AudioComponents.0.type` | 固定 `aufx`（效果器） |
| `AudioComponents.0.subtype` | `[au] subtype_mono` / `subtype_stereo`（dual 用 `subtype_dual`） |
| `AudioComponents.0.manufacturer` | `[au] manufacturer_code` |
| `AudioComponents.0.factoryFunction` | clap-wrapper 固定 `wrapAsAUV2_inst0Factory` |
| `CFBundleIdentifier` | `[au] bundle_id` + `.mono` / `.stereo` |
| `LSMinimumSystemVersion` | `MACOS_DEPLOYMENT_TARGET`（默认 11.0） |

构建完会**读回 plist 断言** subtype（`build-variant.sh` 里 `plutil -extract` 失败即退出），
避免"装上了但身份不对"这种最难查的错。

VST3 / CLAP 的插件身份（class id / CLAP id）来自插件的 `identity.rs`，与变体后缀无关；
改名只改 bundle 名与 `CFBundle*`，不改内部身份。

---

## 5. 两套构建入口

| 入口 | 变体 | 用途 |
|---|---|---|
| `pack.sh` | mono / stereo（可多个） | **标准入口**（契约 B），框架与 CI 用它 |
| `scripts/build-au.sh` | dual（mono+stereo 同体） | 拆仓前的过渡形态，保留用于对照/排查 |

> `pack.sh --variant dual` 会在 `build-variant.sh` 报"未知变体"：`pack.sh` 只分派
> mono / stereo。要出 dual 布局请直接用 `scripts/build-au.sh`（安装后用 `auval` 做最后一道校验，
> 可 `--skip-auval` 跳过；`--no-install` 则在进程内冒烟之后就结束，不跑 `auval`）。

---

## 6. 目录

```text
pack.sh                  入口（契约 B）：体检 → 读清单 → 逐变体构建 → 打印 ARTIFACT
scripts/
  doctor.sh              环境体检（缺什么给"怎么装"）
  build-variant.sh       单变体：universal 构建 → 改名/plist → clap-wrapper → 签名 → 安装 → au_smoke
  build-au.sh            dual（双布局同体）变体的过渡构建（含 auval）
  build-dmg.sh           把已构建产物打成 DMG（Payload + 安装.command + README）
  check-au.sh            只做 AU 自检（已安装的 .component）
  gen-bundler-toml.sh    从 rustomp.toml 生成 <plugin>/bundler.toml
  fetch-third-party.sh   按固定版本（见 deps.lock）拉第三方源码并应用 patches/
  plugin-env.sh          读 rustomp.toml（经框架 plugin_meta.py）→ shell 变量
  reset-logic-cache.sh   清 Logic 的 AU 能力缓存
cmake/CMakeLists.txt     clap-wrapper 的 AUv2 包装（禁构建期联网下载 SDK）
patches/                 第三方源码的必要补丁（内容见 03-logic-compat.md）
tools/au-smoke/          AU 进程内自检（C，绕开系统注册表）
tools/clap-probe/        最小 CLAP 宿主（dump 端口/参数/身份）
third_party/             第三方源码缓存（不入库，由 fetch-third-party.sh 填充）
deps.lock                外部依赖的固定版本
build/artifacts-<v>.txt  每个变体的产物清单（build-variant.sh 写，build-dmg.sh 读）
docs/                    决策 / 架构 / 兼容 / 依赖 / 排障 / 开发日志
```

---

## 7. 失败时的定位顺序

1. **`doctor.sh` 先过**：它按"缺什么、怎么装"输出，不要跳过；
2. 读 `build/au-<variant>/configure.log`（cmake 配置）或 `build.log`（编译）；
3. 构建成功但宿主看不到 → 跑 `check-au.sh`（区分"插件坏"与"Logic 缓存/注册表坏"）；
4. 仍然异常 → [`05-troubleshooting.md`](05-troubleshooting.md) 按症状查。
