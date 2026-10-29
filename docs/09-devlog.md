# 开发日志

按**条目编号**走（E1…）：每条记"做了什么 / 为什么 / 踩了什么"。
决策编号（M-00x）见 [`00-decisions.md`](00-decisions.md)；框架仓的对应记录在
[rustomp/DEVLOG.md](https://github.com/amonisachicken/rustomp/blob/master/DEVLOG.md)
（E4/E71/E74–E79/E88.3/E96 等），这里只记本仓自己的事。

---

## E1 从框架拆出来（2026-10-27，v0.1.0）

**做了什么**：把 macOS 打包从 `rustomp` 拆成独立仓：

- 入口 `pack.sh` —— **契约 B 的第一个实现**（只认 `ARTIFACT:` 行）；
- `scripts/doctor.sh`：环境体检，缺什么就给出"怎么装"；
- `cmake/`（clap-wrapper 的 AUv2 包装）、`patches/`、`tools/{au-smoke,clap-probe}`、
  `scripts/{build-variant,build-au,check-au,gen-bundler-toml,plugin-env,reset-logic-cache,fetch-third-party}.sh`；
- 框架侧 `scripts/build-all.sh` 变瘦包装（`exec` 到本仓 `pack.sh`）。

**为什么**：打包与宿主兼容必须在 macOS 本机验证，和纯 Rust 的框架是两个平面
（rustomp ADR-015；框架侧记录见其 DEVLOG E71）。

**踩了什么**：拆分本身没改行为 —— 拆前/后 `au_smoke` 通过、**RMS 0.356170 逐位不变**，
框架里的"平台词为 0"断言仍然成立。代价是三个仓必须同级，`plugin-env.sh` 要能自己找到框架。

---

## E2 干净 checkout 里的两个坑（2026-10-27，v0.1.1）

**发生了什么**：在**全新目录**里 clone 三个仓（钉 tag）跑真实构建，`v0.1.0` 直接炸：

1. 脚本里**全角标点紧跟变量**（`${VAR}（…`）→ bash 把全角字符当成变量名的一部分 →
   `unbound variable`。本机工作区里"能跑"是因为那个变量恰好总是非空。
2. `pack.sh` 对 `PLUGIN_DIR` 与位置参数的冲突判断过严，正常调用也会被拒。

**处理**：修掉两处并打 `v0.1.1`；tag 说明里直接写"v0.1.0 在干净 checkout 里会炸"。

**教训**（也是框架仓 E74 的结论）：**"本机能跑"证明不了"tag 能用"**。
打包工具必须有"全新 clone + 钉 tag"的回归路径。

---

## E3 doctor 的三处修正（2026-10-27，v0.1.2 / v0.1.3）

**做了什么**：

| 问题 | 根因 | 修法 |
|---|---|---|
| 装了 `cargo-nih-plug` 却报"没装" | 管道末端接 `grep -q`，grep 提前退出 → 上游 SIGPIPE(141) → `pipefail` 判管道失败 | 改用 `command -v` + `case` 匹配，不接管道 |
| 版本号写死 | 每发一版都要改脚本 | 从 `git describe --tags` 取，取不到才退回硬编码 |
| 第三方版本散落 | 不知道构建用的是哪个 rev | 新增 `deps.lock`（nih-plug rev、clap-wrapper commit、CLAP/AudioUnitSDK tag） |

**为什么**：`doctor.sh` 是用户见到的**第一个**输出，它的假阴性会直接把人带偏 ——
"明明装了却说没装"比"没装"更浪费时间。

**踩了什么**：`cargo nih-plug --help` 不能用来探测（没有 `--help` 子命令，返回非 0）；
这本身也会造成假阴性，所以探测只认 `cargo --list` / `command -v`。

---

## E4 依赖引导与"同级目录"约定（2026-10-27，v0.1.4 / v0.1.5）

**做了什么**：

- 缺框架时 `doctor.sh` 打印**可直接粘贴**的 clone 命令，tag 取自插件 `Cargo.toml` 里钉的版本；
- 框架查找一律按"**同级目录**"（`<plugin>/../rustomp`、本仓 `../rustomp`），
  去掉 `$HOME/develop` 这类绝对路径假设；
- README 的快速开始改成三仓同级目录 + 一条 `cd`，不再出现任何绝对路径。

**为什么**：新机器上最常见的失败不是编译，而是"框架放哪了"。绝对路径只在作者机器上成立。

**对照**：框架仓 E76/E77 记录了同一轮修正；这两条约定现在写进了
[rustomp/docs/ecosystem.md](https://github.com/amonisachicken/rustomp/blob/master/docs/ecosystem.md) §8。

---

## E5 AU 的 CPM 坑 + 并行度可配（2026-10-27 ~ 10-28，v0.1.6）

**症状**：断网/网络差时 AU 构建失败：

```text
file DOWNLOAD cannot compute hash
Unknown CMake command "CPMAddPackage"
```

**真因**：`CMAKE_OSX_DEPLOYMENT_TARGET` 为空 → clap-wrapper 走 "deployment < 10.15" 分支 →
用 CPM 现场下载 Gulrak filesystem。

**修法**：

- `MACOS_DEPLOYMENT_TARGET` 默认 **11.0** 并**显式**传给 cmake
  （`-DCMAKE_OSX_DEPLOYMENT_TARGET=…`），同时写进 AU 的 `LSMinimumSystemVersion`；
- 顺手把 `cmake --build` 的并行度改成可配：`RUSTOMP_BUILD_JOBS`（默认 **4**），
  不再按 `hw.ncpu`（本机 20 路）拉满。

**为什么写进两处**：一个 CMake 分支判断决定了"构建期是否联网"，而构建期联网 = 不可复现；
并行度则关系到整机稳定（本机有过内核恐慌史，见框架仓 E88.3 与本仓 M-009）。

**结果**：`v0.1.6` 起，断网也能完成 AU 构建；`doctor.sh` / `pack.sh` 不再需要额外参数。

---

## E6 文档重组：对齐 Windows 打包器的编排（2026-10-29）

**背景**：Windows 打包工具 [rustomp-win-plugin](https://github.com/amonisachicken/rustomp-win-plugin)
已经落地（v0.3.0：VST3/CLAP + 系统级/用户级两个 MSI）。它的 README 结构是
「产品介绍 → 架构 → 功能范围 → 部署与运行 → 与框架对接 → 文档」，把细节放进 `docs/`；
本仓 README 仍是"快速开始 + 若干长段落"的形态，且"Windows/Linux"一条已经过期。

**做了什么**：

- README 重排成同一套编排（§1–§7），只留"能开工"的信息；
- 细节拆到 `docs/`：决策账本 `00-decisions.md`、架构 `02-architecture.md`、
  Logic 兼容 `03-logic-compat.md`（原 `patches/README.md` 的内容并入）、
  依赖 `04-dependencies.md`、排障 `05-troubleshooting.md`、本日志 `09-devlog.md`；
- `patches/README.md` 缩成指向 `docs/03-logic-compat.md` 的短说明；
- 过期条目改正：Windows 打包**已落地**（在同位仓库，且**没有 AU**），Linux 仍未开工；
- 补上以前只在脚本注释里的平台事实：`pack.sh` 只分派 mono/stereo（dual 走 `build-au.sh`）、
  `requires.packer` 只支持下界、`deps.lock` 与脚本常量需手工同步。

**为什么**：两个平台读同一套结构，切换成本最低；README 只回答"怎么用"，
"为什么这样写"留在 docs，避免 README 越写越长又没人读完。

**没做什么**：没有改任何构建逻辑（本轮纯文档）。Windows 仓的 CI、本仓的签名/公证、
standalone 仍是未完成项，见 README §3。
