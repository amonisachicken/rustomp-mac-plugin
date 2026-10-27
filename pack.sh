#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# **rustomp-mac-plugin 的入口** —— 契约 B 的实现（见 rustomp/docs/ecosystem.md §2）。
#
#   ./pack.sh <plugin_dir> [--variant mono|stereo|dual]... [--format au|vst3|clap]... [--no-install]
#
# 成功：逐行打印 `ARTIFACT: <绝对路径>`，退出码 0。
# 失败：非 0 退出 + 人话原因（缺 Xcode CLT / 缺 rust target / 素材缺失 / 框架找不到…）。
#
# 框架（rustomp）只知道这一行 `ARTIFACT:`，不知道 macOS 的任何细节。
set -euo pipefail

PACKER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 版本从 git tag 取（没装 git / 不是 clone 时退回硬编码）
PACKER_VERSION="$(git -C "$PACKER_ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$PACKER_VERSION" ] || PACKER_VERSION="0.1.6"

usage() {
    sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    echo
    echo "环境变量："
    echo "  RUSTOMP_ROOT   框架目录（默认自动探测：<plugin_dir>/../rustomp）"
    echo "  PLUGIN_DIR     等价于第一个位置参数"
}

log()  { printf '%s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

PLUGIN_DIR="${PLUGIN_DIR:-}"
VARIANTS=()
FORMATS=()
INSTALL=1

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --variant) VARIANTS+=("${2:?--variant 需要参数}"); shift 2 ;;
        --format)  FORMATS+=("${2:?--format 需要参数}");  shift 2 ;;
        --no-install) INSTALL=0; shift ;;
        -*) die "未知参数：$1（--help 看用法）" ;;
        *)  # 位置参数与 $PLUGIN_DIR 冲突才算错（build.sh 会同时给两者）
            if [ -n "$PLUGIN_DIR" ] && [ "$PLUGIN_DIR" != "$1" ]; then
                die "只能指定一个插件目录（已有 ${PLUGIN_DIR}，又给了 $1）"
            fi
            PLUGIN_DIR="$1"; shift ;;
    esac
done

[ -n "$PLUGIN_DIR" ] || { usage; exit 2; }
PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)" || die "插件目录不存在：$PLUGIN_DIR"
export PLUGIN_DIR
[ -f "$PLUGIN_DIR/rustomp.toml" ] || die "${PLUGIN_DIR} 不是插件项目（没有 rustomp.toml）"

[ ${#VARIANTS[@]} -gt 0 ] || VARIANTS=(mono stereo)
[ ${#FORMATS[@]}  -gt 0 ] || FORMATS=(au vst3 clap)
for v in "${VARIANTS[@]}"; do
    case "$v" in mono|stereo|dual) ;; *) die "不支持的 variant：${v}（mono|stereo|dual）" ;; esac
done
for f in "${FORMATS[@]}"; do
    case "$f" in au|vst3|clap) ;; *) die "不支持的 format：${f}（au|vst3|clap）" ;; esac
done

# ---------------------------------------------------------------- 1. 体检
"$PACKER_ROOT/scripts/doctor.sh" || die "环境体检未通过（见上面缺什么）"

# ---------------------------------------------------------------- 2. 读 manifest
log "==> 读插件清单"
# shellcheck disable=SC1091
source "$PACKER_ROOT/scripts/plugin-env.sh"
log "    插件：${PLUGIN_NAME}（${PLUGIN_PACKAGE}）  框架：${RUSTOMP_ROOT}"

# 版本约束（契约：rustomp.toml [requires]）
REQ="$(python3 "$RUSTOMP_ROOT/tools/meta/plugin_meta.py" "$PLUGIN_DIR/rustomp.toml" --get requires.packer 2>/dev/null || true)"
if [ -n "$REQ" ] && [ "$REQ" != "" ]; then
    python3 - "$REQ" "$PACKER_VERSION" <<'PY' || die "本打包工具版本不满足插件要求"
import sys, re
req, ver = sys.argv[1], sys.argv[2]
def parse(v):
    return tuple(int(x) for x in re.findall(r"\d+", v)[:2])
lo = 0
m = re.search(r">=\s*([\d.]+)", req)
if m: lo = parse(m.group(1))
if parse(ver) < lo:
    print(f"✗ 插件要求 packer {req}，当前 {ver}", file=sys.stderr)
    sys.exit(1)
PY
    log "    requires.packer = ${REQ}（当前 ${PACKER_VERSION}）"
fi

# ---------------------------------------------------------------- 3. 逐 variant 构建
ARTIFACTS=()
for v in "${VARIANTS[@]}"; do
    log
    log "########## variant: ${v} ##########"
    args=("$v")
    [ "$INSTALL" = "1" ] || args=(--no-install "$v")
    # shellcheck disable=SC2068
    "$PACKER_ROOT/scripts/build-variant.sh" ${args[@]}

    SUFFIX=$([ "$v" = "mono" ] && echo "Mono" || ([ "$v" = "stereo" ] && echo "Stereo" || echo ""))
    NAME="$PLUGIN_NAME${SUFFIX:+ $SUFFIX}"
    COMPONENT="$PACKER_ROOT/build/au-${v}/${NAME}.component"
    for f in "${FORMATS[@]}"; do
        case "$f" in
            au)   [ -d "$COMPONENT" ] && ARTIFACTS+=("$COMPONENT") ;;
            vst3) [ -d "$PLUGIN_DIR/target/bundled/${NAME}.vst3" ] && ARTIFACTS+=("$PLUGIN_DIR/target/bundled/${NAME}.vst3") ;;
            clap) [ -d "$PLUGIN_DIR/target/bundled/${NAME}.clap" ] && ARTIFACTS+=("$PLUGIN_DIR/target/bundled/${NAME}.clap") ;;
        esac
    done
done

# ---------------------------------------------------------------- 4. 契约 B 的输出
log
log "==> 产物"
for a in "${ARTIFACTS[@]}"; do
    printf 'ARTIFACT: %s\n' "$a"
done
[ ${#ARTIFACTS[@]} -gt 0 ] || die "没有任何产物（检查 --format 与构建日志）"
