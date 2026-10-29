#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 环境体检：缺什么就说清"怎么装"，不要等 cargo/cmake 用天书报错。
#
#   ./scripts/doctor.sh           # 人读
#   ./scripts/doctor.sh --quiet   # 只报错（pack.sh 用）
set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1
ok()   { [ "$QUIET" = "1" ] || printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
bad()  { printf '  ✗ %s\n' "$*" >&2; MISSING=1; }
MISSING=0

[ "$QUIET" = "1" ] || echo "==> 环境体检（rustomp-mac-plugin）"

# ---- 工具链 ----
if command -v cargo >/dev/null 2>&1; then ok "cargo $(cargo --version | awk '{print $2}')"
else bad "没有 cargo（装 Rust：https://rustup.rs）"; fi

if xcode-select -p >/dev/null 2>&1; then
    ok "Xcode CLT：$(xcode-select -p)"
    command -v cmake >/dev/null 2>&1 && ok "cmake $(cmake --version | head -1 | awk '{print $3}')" \
        || bad "没有 cmake（brew install cmake）"
    command -v cc >/dev/null 2>&1 && ok "cc" || bad "没有 cc（装 Xcode 命令行工具）"
else
    bad "没有 Xcode 命令行工具（xcode-select --install）"
fi

command -v python3 >/dev/null 2>&1 && ok "python3 $(python3 -V | awk '{print $2}')" \
    || bad "没有 python3（读 rustomp.toml 需要，macOS 自带或 brew install python）"

command -v plutil >/dev/null 2>&1 && ok "plutil" || bad "没有 plutil（系统自带，异常）"

# DMG 只需要 hdiutil（系统自带）；只在请求 dmg 时检查，避免与其它格式的体检耦合
case " ${RUSTOMP_FORMATS:-} " in
    *" dmg "*) command -v hdiutil >/dev/null 2>&1 && ok "hdiutil" || bad "没有 hdiutil（系统自带，异常；DMG 需要它）" ;;
esac

# cargo-nih-plug：打包靠它（`cargo nih-plug bundle-universal`）。
# 这不是 crates.io 上的普通依赖，必须显式装，且**钉同一个 rev**（见 deps.lock）。
# 注意两个坑：
#   1) `cargo nih-plug --help` 探测会误报（它没有 --help 子命令，返回非 0）；
#   2) 本脚本开了 `set -o pipefail`，而 `... | grep -q` 会让 grep 提前退出 →
#      上游 awk 收到 SIGPIPE(141) → 整条管道非 0 → 明明装了却报缺失。
#      所以这里用 `command -v` + case 匹配，不用管道。
_have_nih_plug=0
command -v cargo-nih-plug >/dev/null 2>&1 && _have_nih_plug=1
if [ "$_have_nih_plug" = "0" ]; then
    case "$(cargo --list 2>/dev/null || true)" in *nih-plug*) _have_nih_plug=1 ;; esac
fi
if [ "$_have_nih_plug" = "1" ]; then
    ok "cargo-nih-plug"
else
    bad "没有 cargo-nih-plug（装法：cargo install --git https://github.com/robbert-vdh/nih-plug.git --rev de42101 cargo-nih-plug --locked）"
fi

# ---- universal 需要两个 target ----
if command -v rustup >/dev/null 2>&1; then
    target=""
    for t in aarch64-apple-darwin x86_64-apple-darwin; do
        if rustup target list --installed 2>/dev/null | grep -qx "$t"; then
            ok "rust target $t"
        else
            bad "缺 rust target ${t}（rustup target add ${t}）"
        fi
    done
fi

# ---- 框架（读 manifest / 代码生成）----
# 约定：三个仓放在同一个目录（框架与打包工具都是**插件项目的同级**）。
# 探测顺序：显式 RUSTOMP_ROOT → 插件项目的同级 → 打包工具自己的同级
FRAME="${RUSTOMP_ROOT:-}"
if [ -z "$FRAME" ]; then
    for c in "${PLUGIN_DIR:-}/../rustomp" \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/rustomp"; do
        [ -f "$c/tools/meta/plugin_meta.py" ] && FRAME="$(cd "$c" && pwd)" && break
    done
fi
if [ -n "$FRAME" ] && [ -f "$FRAME/tools/meta/plugin_meta.py" ]; then
    ok "rustomp 框架：$FRAME"
else
    bad "找不到 rustomp 框架 —— 读 rustomp.toml / 校验生成物都要用它"
    # 提示里用插件钉的 tag（有 PLUGIN_DIR 时读它的 Cargo.toml）
    _tag=""
    if [ -n "${PLUGIN_DIR:-}" ] && [ -f "$PLUGIN_DIR/Cargo.toml" ]; then
        _tag="$(grep -oE 'tag = "v[0-9]+\.[0-9]+\.[0-9]+"' "$PLUGIN_DIR/Cargo.toml" 2>/dev/null | head -1 | sed 's/tag = "//; s/"$//')"
    fi
    _tag="${_tag:-v0.1.0}"
    _where="${PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    cat >&2 <<EOT
    约定：三个仓放在同一个目录（框架是插件项目的同级）
      cd "${_where}/.."
      git clone --depth 1 --branch ${_tag} https://github.com/amonisachicken/rustomp.git rustomp
    克隆完重跑即可，不需要设环境变量。
    仓库：https://github.com/amonisachicken/rustomp
EOT
fi

# ---- 第三方源码（AUv2 需要）----
TP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/third_party"
if [ -d "$TP/clap-wrapper" ] && [ -d "$TP/clap" ] && [ -d "$TP/AudioUnitSDK" ]; then
    ok "third_party 就绪"
else
    warn "third_party 缺（首次构建前跑：./scripts/fetch-third-party.sh）"
fi

# ---- 插件项目 ----
if [ -n "${PLUGIN_DIR:-}" ]; then
    ok "插件目录：$PLUGIN_DIR"
    if [ -d "$PLUGIN_DIR/plugin/src/generated" ]; then
        ok "生成物存在（generated/）"
    else
        bad "缺 $PLUGIN_DIR/plugin/src/generated（先跑 rustomp-gen）"
    fi
    for a in $(python3 - "$PLUGIN_DIR/rustomp.toml" <<'PY' 2>/dev/null
import sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
d = tomllib.load(open(sys.argv[1], "rb"))
root = sys.argv[1].rsplit("/", 1)[0]
for k, v in d.get("assets", {}).items():
    print(f"{k}={root}/{v}")
PY
    ); do
        f="${a#*=}"
        [ -f "$f" ] && ok "素材 ${a%%=*} ✓" || bad "素材缺失：$f"
    done
fi

exit "$MISSING"
