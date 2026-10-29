# 依赖与固定版本

> 目标：一台**干净的 Mac** 从零开始能装齐；所有第三方版本**钉死**，构建可复现。
> 版本记录在 [`../deps.lock`](../deps.lock)；`scripts/fetch-third-party.sh` 里另有一份
> 实际使用的常量（**目前靠手工同步**，没有自动校验）。

---

## 1. 清单

| 依赖 | 版本 / 要求 | 用途 | 检查 |
|---|---|---|---|
| **macOS** | 11 及以上（AU 的 `LSMinimumSystemVersion` 默认 11.0） | 运行宿主 | — |
| **Xcode 命令行工具** | 当前 Xcode 对应版本 | `cc` / `lipo` / `plutil` / `codesign` / `auval` | `xcode-select -p` |
| **hdiutil** | 系统自带 | 打 DMG（`--format dmg`） | `command -v hdiutil` |
| **cmake** | ≥ 3.20（`cmake/CMakeLists.txt` 要求） | 编 clap-wrapper 的 AUv2 外壳 | `cmake --version` |
| **Python** | ≥ 3.11（`tomllib`） | 读 `rustomp.toml`（框架的 `plugin_meta.py`） | `python3 -V` |
| **Rust** | stable + 两个 target：`aarch64-apple-darwin`、`x86_64-apple-darwin` | universal 构建 | `rustup target list --installed` |
| **cargo-nih-plug** | 与 `deps.lock` 的 **nih-plug rev 一致**（当前 `de42101`） | `cargo nih-plug bundle-universal` | `cargo --list` / `command -v` |
| **rustomp 框架仓** | 与插件钉的 tag 配套（同级目录） | `tools/meta/plugin_meta.py`（契约 A）+ 生成物 | `plugin_meta.py` 是否存在 |
| **clap-wrapper** | `806bba0a5f792e3966b99c1561ab9952d3316d7c` | CLAP → AUv2 包装 | `third_party/clap-wrapper/` |
| **CLAP SDK** | `1.2.9`（MIT） | clap-wrapper / clap-probe 的接口定义 | `third_party/clap/` |
| **AudioUnitSDK** | `AudioUnitSDK-1.1.0`（Apache-2.0） | AUv2 基类 | `third_party/AudioUnitSDK/` |
| **git** | 任意近期版本 | 拉第三方源码；版本号取自本仓 tag | `git --version` |

`third_party/` 下的三份源码**不入库**（`.gitignore`），由脚本按固定版本填充。

---

## 2. 装法

```bash
# Rust + 两个 target（universal 必需）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# Xcode 命令行工具（含 cmake 之外的编译/签名工具）
xcode-select --install
brew install cmake

# 打包用的 cargo 子命令：rev 必须与 deps.lock 一致
cargo install --git https://github.com/robbert-vdh/nih-plug.git \
              --rev de42101 cargo-nih-plug --locked

# 第三方源码（clap-wrapper / CLAP SDK / AudioUnitSDK）+ 本地补丁
./scripts/fetch-third-party.sh

# 一次性体检：缺什么、怎么装
./scripts/doctor.sh
```

目录约定（三仓同级，插件项目也在这一层）：

```text
some-dir/
  rustomp/              ← 框架（读 manifest / 校验生成物）
  rustomp-mac-plugin/   ← 本工具
  sparklin-drive/       ← 插件项目（必须有 rustomp.toml + plugin/src/generated/）
```

---

## 3. 为什么钉版本

| 依赖 | 不钉会怎样 |
|---|---|
| nih-plug（git rev，不是 crates.io） | bundler 行为可能变（产物命名、目录形状）；插件仓的 `Cargo.toml` 也用同一个 rev |
| cargo-nih-plug | 与上面 rev 不一致时，`bundle-universal` 可能与插件代码的 API 期望不符 |
| clap-wrapper | AUv2 外壳的行为（属性宣称、布局枚举）直接决定宿主能否认出来 |
| CLAP SDK / AudioUnitSDK | ABI / 头文件变化会让补丁失效或产生不同产物 |

所以：**升级任何一项都要按"改 deps.lock + 改脚本常量 + 重新打包 + 宿主验证"走**，
不能只改一边。当前没有自动校验 deps.lock 与脚本常量是否一致（见 `05-troubleshooting.md`）。

---

## 4. 离线 / 网络受限

- `fetch-third-party.sh` 需要访问 GitHub（clap-wrapper / CLAP / AudioUnitSDK 各一次）；
  拉过一次之后 `third_party/` 就在本地，后续构建不需要网；
- **构建期不该联网**：`cmake/CMakeLists.txt` 设了
  `CLAP_WRAPPER_DOWNLOAD_DEPENDENCIES=OFF`，并且 `MACOS_DEPLOYMENT_TARGET` 必须显式给
  （否则会走 CPM 下载 Gulrak filesystem，见 E88.3）；
- `cargo install cargo-nih-plug` 需要 `cargo` 拉 crates.io 的依赖；
- 若直连 GitHub 受限，可先 `source ~/vpn.env` 再拉（脚本头部注释里就写了这一点）。

---

## 5. 升级检查单

1. 改 `deps.lock`（rev / tag）与 `fetch-third-party.sh` 里的常量（两处一致）；
2. `cargo install ... --rev <新 rev> cargo-nih-plug --locked` 重装子命令；
3. 删掉 `third_party/clap-wrapper`（只删这一份）后重跑 `fetch-third-party.sh`，
   确认补丁仍能 `git apply`；
4. `./scripts/doctor.sh` → `./pack.sh <插件> --no-install` → `./scripts/check-au.sh <variant>`；
5. 插件仓的 `Cargo.toml` 里 nih-plug rev 也要一起升，再跑插件自己的基线测试
   （音频数字必须不变，见框架仓的验证流程）。
