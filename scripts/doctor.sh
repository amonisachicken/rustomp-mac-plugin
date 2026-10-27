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

# ---- universal 需要两个 target ----
if command -v rustup >/dev/null 2>&1; then
    target=""
    for t in aarch64-apple-darwin x86_64-apple-darwin; do
        if rustup target list --installed 2>/dev/null | grep -qx "$t"; then
            ok "rust target $t"
        else
            bad "缺 rust target $t（rustup target add $t）"
        fi
    done
fi

# ---- 框架（读 manifest / 代码生成）----
FRAME="${RUSTOMP_ROOT:-}"
if [ -z "$FRAME" ]; then
    for c in "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/rustomp" \
             "$HOME/develop/rustomp"; do
        [ -f "$c/tools/meta/plugin_meta.py" ] && FRAME="$c" && break
    done
fi
if [ -n "$FRAME" ] && [ -f "$FRAME/tools/meta/plugin_meta.py" ]; then
    ok "rustomp 框架：$FRAME"
else
    bad "找不到 rustomp 框架（设 RUSTOMP_ROOT=/path/to/rustomp）"
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
