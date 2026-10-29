# 决策账本

每条都是一个**会影响实现形态**的决定，按 `M-00x` 编号。改实现前先读这里；
要推翻某条，就新增一条说明"为什么现在不一样了"，不要静默改。

| 编号 | 决定 | 一句话理由 |
|---|---|---|
| M-001 | macOS 打包**拆成独立仓**，框架只留瘦包装 | 打包与宿主兼容必须在本机验证（rustomp ADR-015） |
| M-002 | AUv2 用 **clap-wrapper** 把 CLAP 包一层，不自研 AU 绑定 | nih-plug 只导出 VST3/CLAP；clap-wrapper 是成熟路径（ADR-006） |
| M-003 | mono / stereo 出**两个独立 AU 身份**（新 subtype + bundle id 后缀） | 宿主按声道数过滤菜单；新身份天然绕开旧缓存（ADR-008） |
| M-004 | **universal**（x86_64 + arm64），最低系统版本**显式**给 11.0 | 一个产物覆盖两类 Mac；留空会触发 clap-wrapper 的 CPM 联网下载（E88.3） |
| M-005 | 第三方源码**不入库**，pin commit/tag + 本地补丁 | 可复现；补丁是 AU 宿主兼容的必需品 |
| M-006 | 只做 **ad-hoc 签名**；公证/分发签名单列 | 本地开发够用；对外分发要 Developer ID，是另一件事 |
| M-007 | 自检用**进程内** `au_smoke`，不只靠 `auval` | 本机 `AudioComponentRegistrar` 缓存坏掉时 `auval` 连 BYOD 都找不到 |
| M-008 | 契约 B：**stdout 只允许 `ARTIFACT:` 行** | 框架/CI 只认这一行；其余日志全走 stderr |
| M-009 | cmake 并行度默认 **4**，可用 `RUSTOMP_BUILD_JOBS` 覆盖 | `-j20` 在 10 核机器上是无谓的整机压力（本机有过内核恐慌史） |
| M-010 | 不做 **standalone / AAX**；Windows/Linux 不在本仓 | standalone 是独立的一件事；AAX 与 GPL-3 冲突；平台分仓 |
| M-011 | DMG 是**用户级**安装（`Payload` + `安装.command`），不做系统级 `/Library` | 免管理员、与 `--no-install` 语义一致；系统级留给 pkg |

---

## M-001 拆成独立仓

**背景**：打包逻辑（clap-wrapper / CMake / plist / codesign / Logic 缓存）与框架（DSP / 代码生成）是
两个平面；框架仓一度同时装着两者。

**决定**：拆出 `rustomp-mac-plugin`，入口是 `pack.sh`（契约 B 的第一个实现）；
框架的 `scripts/build-all.sh` 变成瘦包装（`exec` 到本仓 `pack.sh`，只认 `ARTIFACT:`）。

**后果**：框架里平台词为 0（rustomp 用测试断言这条）；代价是三个仓必须**同级**放置，
打包工具需要知道框架在哪才能读 `rustomp.toml`。

---

## M-002 AUv2 走 clap-wrapper

**背景**：nih-plug 只导出 VST3 + CLAP；Logic 只吃 AU（AUv2）。

**决定**：`cargo nih-plug bundle-universal` 先出 CLAP，再用 clap-wrapper 的
`target_add_auv2_wrapper()` 把它包成 `.component`，并把 `.clap` 嵌进
`Contents/PlugIns/`（用户只装一个文件）。

**后果**：AU 的行为 = CLAP 的行为 + wrapper 的兼容层；wrapper 的宿主兼容问题要用补丁修
（见 [`03-logic-compat.md`](03-logic-compat.md)），且必须自己验证 —— 不能假设"包装完就能被 Logic 认出来"。

---

## M-003 mono / stereo 是两个独立插件

**背景**：插件同时声明 mono + stereo 两个布局时，宿主需要正确读出两个布局才会在对应通道条出现。
实测 Logic 会按通道条声道数过滤插入菜单，只报 `{2,2}` 的 AU 在单声道轨里**整个消失**。

**决定**：每个插件出两个变体，各自是**新的 AU 身份**：

| 变体 | subtype | bundle id |
|---|---|---|
| mono | `[au] subtype_mono` | `[au] bundle_id` + `.mono` |
| stereo | `[au] subtype_stereo` | `[au] bundle_id` + `.stereo` |

**后果**：宿主把两个变体当不同插件扫描，不存在"缓存里记着旧布局"的问题；
代价是菜单里有两个条目、需要分开发布。

---

## M-004 universal + 显式最低系统版本

**背景**：Mac 有 Intel 与 Apple Silicon 两类机器；一个 universal 产物能同时覆盖。

**决定**：`cargo nih-plug bundle-universal`（`x86_64-apple-darwin` + `aarch64-apple-darwin`），
cmake 侧 `-DCMAKE_OSX_ARCHITECTURES="x86_64;arm64"`；
`MACOS_DEPLOYMENT_TARGET` **默认 11.0 且必须显式传给 cmake**。

**后果**：产物可直接在两类机器上加载；最低系统版本会写进 AU 的 `LSMinimumSystemVersion`。
**不要把它留空**：clap-wrapper 在为空时会走 "deployment < 10.15" 分支，去 CPM 联网下载
Gulrak filesystem —— 断网就报 `Unknown CMake command CPMAddPackage`（详见 E88.3 / `05-troubleshooting.md`）。

---

## M-005 第三方源码不入库，pin + 补丁

**背景**：clap-wrapper / CLAP SDK / AudioUnitSDK 是构建 AU 必需的第三方源码。

**决定**：`third_party/` 进 `.gitignore`，由 `scripts/fetch-third-party.sh` 按固定
commit/tag 拉取（版本同时记在 `deps.lock`，脚本里另有一份常量、需手工同步），
并自动应用 `patches/*.patch`。

**后果**：仓库干净、构建可复现；代价是首次构建需要联网（或在有网机器上先拉好再拷贝）。

---

## M-006 只做 ad-hoc 签名

**背景**：macOS 上未签名的 bundle 在部分宿主/系统策略下行为不一致。

**决定**：构建完直接 `codesign --force --sign -`（ad-hoc），顺序是
**先内层 `.clap`，再外层 `.component` / `.vst3` / `.clap`**。

**后果**：本机开发/自测无阻碍；**对外分发会被 Gatekeeper 拦**。
Developer ID + `notarytool` 是单独一项，没有混进构建脚本。

---

## M-007 进程内 au_smoke

**背景**：`auval` 依赖 `AudioComponentRegistrar` 的系统缓存；本机该缓存坏过一次，
`auval` 连第三方 AU（BYOD）都找不到，无法区分"插件坏了"和"系统缓存坏了"。

**决定**：自写 `tools/au-smoke`（C，约 370 行）：用 `AudioComponentRegister()` 在进程内注册
bundle 的工厂函数，然后走 open / initialize / render，校验声道能力与渲染 RMS。

**后果**：自检与系统注册表解耦，`--no-install` 时也能验证；
`auval` 仍作为安装后的第二道检查（`build-au.sh`，可 `--skip-auval`）。

---

## M-008 stdout 只出 ARTIFACT

**背景**：框架/CI 需要一个稳定、平台无关的"成功信号"。

**决定**：`pack.sh` 的 stdout **逐行只有** `ARTIFACT: <绝对路径>`；其余全部写 stderr。
没有任何产物时非 0 退出。

**后果**：框架不需要解析 macOS 细节；`pack.sh` 里每一句人读日志都必须 `>&2`。

---

## M-009 并行度默认 4

**背景**：cmake 构建 clap-wrapper 时原来按 `hw.ncpu` 取并行度（本机 20 路）。

**决定**：`RUSTOMP_BUILD_JOBS`（默认 4）传给 `cmake --build -j`。

**后果**：构建稍慢，但不会把整机压到危险区；需要快时显式调大即可。

---

## M-010 范围边界

| 不做 | 原因 |
|---|---|
| **standalone** | 需要音频设备选择/设置持久化，是独立的一件事；列为 v0.2 |
| **AAX** | 需要 Avid 授权，且与 GPL-3 冲突 |
| **Windows / Linux 打包** | 平台分仓（ADR-015）：Windows（`rustomp-win-plugin`）与 Linux（`rustomp-linux-plugin`）都已落地，均无 AU |
| **DSP / 代码生成 / 改插件源码** | 那是 rustomp 与 rustomp-gen 的职责；本仓只消费已生成的产物 |

---

## M-011 DMG 只做用户级安装

**背景**：Windows 的 MSI 有系统级 / 用户级两个包（W-010）；macOS 的分发习惯是 DMG。
DMG 本身只是一个磁盘镜像，真正的“安装”得靠用户拖拽或里面的脚本。

**决定**：`--format dmg` 产出 `<Name> Installer.dmg`，内容：

```text
Payload/{Components,VST3,CLAP}/…   三个格式的 bundle
安装.command                        双击 → 复制到 ~/Library/Audio/Plug-Ins/
README.txt                          安装路径 / Logic 缓存清法 / 已知边界
```

安装目标固定为**当前用户**；**不做**系统级 `/Library/Audio/Plug-Ins`
（那需要管理员，且与 pkg 的职责重叠）。

**后果**：分发路径简单、不会卡在提权对话框；代价是“装给全机所有用户”要用户手动复制。
DMG 与插件都**没有** Developer ID 签名/公证（M-006），首次打开可能要在系统设置里放行。
