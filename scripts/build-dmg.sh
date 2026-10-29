#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 把**已经构建好的**插件产物打成 DMG（macOS 的“安装包”）。
#
#   ./scripts/build-dmg.sh [--variants "mono stereo"] [--formats "au vst3 clap"] [--out DIR]
#                          [--manifest-dir DIR]
#
# - 输入：<manifest-dir>/artifacts-<variant>.txt（默认 build/；由 scripts/build-variant.sh 写，
#   里面是本变体 AU/VST3/CLAP 的绝对路径）
# - 产物：<Name> Installer.dmg
#     Payload/Components/<Name>.component     AUv2
#     Payload/VST3/<Name>.vst3                 VST3
#     Payload/CLAP/<Name>.clap                 CLAP
#     安装.command                             双击装到当前用户目录（免管理员）
#     README.txt                               安装/排障说明
#
# 安装范围是**当前用户**：~/Library/Audio/Plug-Ins/{Components,VST3,CLAP}。
# 系统级（/Library/Audio/Plug-Ins）需要管理员权限，不在本脚本里做。
#
# 输出：DMG 的绝对路径，**stdout 一行**；日志走 stderr。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=./plugin-env.sh
# （先解析参数：--help 不应要求先有插件目录）

VARIANTS_STR=""
FORMATS_STR="au vst3 clap"
OUT_DIR=""
MANIFEST_DIR="$ROOT/build"
while [ $# -gt 0 ]; do
    case "$1" in
        --variants) VARIANTS_STR="${2:?--variants 需要参数}"; shift 2 ;;
        --formats)  FORMATS_STR="${2:?--formats 需要参数}";  shift 2 ;;
        --out)      OUT_DIR="${2:?--out 需要参数}";          shift 2 ;;
        --manifest-dir) MANIFEST_DIR="${2:?--manifest-dir 需要参数}"; shift 2 ;;
        -h|--help)  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1（--help）" >&2; exit 2 ;;
    esac
done

log()  { printf '%s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# shellcheck source=./plugin-env.sh
source "$ROOT/scripts/plugin-env.sh"

VARIANTS_STR="${VARIANTS_STR:-${BUILD_VARIANTS:-mono stereo}}"
[ -n "$VARIANTS_STR" ] || die "没有变体（--variants 或 manifest 的 [build] variants 都为空）"

for v in $VARIANTS_STR; do
    case "$v" in mono|stereo) ;; *) die "DMG 只支持 mono / stereo（收到 ${v}）" ;; esac
done
for f in $FORMATS_STR; do
    case "$f" in au|vst3|clap) ;; *) die "不支持的 payload format：${f}（au|vst3|clap）" ;; esac
done

command -v hdiutil >/dev/null 2>&1 || die "没有 hdiutil（macOS 系统自带；DMG 需要它）"

OUT_DIR="${OUT_DIR:-$ROOT/build/dmg}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
DMG="$OUT_DIR/${PLUGIN_NAME} Installer.dmg"
VOLNAME="${PLUGIN_NAME} Installer"

STAGE="$(mktemp -d "$OUT_DIR/stage.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 收集产物
log "==> 收集产物（variants: ${VARIANTS_STR}；formats: ${FORMATS_STR}）"
mkdir -p "$STAGE/Payload"
found=0
for v in $VARIANTS_STR; do
    MAN="$MANIFEST_DIR/artifacts-${v}.txt"
    [ -f "$MAN" ] || die "缺产物清单：$MAN（先构建变体 ${v}：./scripts/build-variant.sh ${v}）"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        base="$(basename "$p")"
        case "$base" in
            *.component) kind=au;   dest="$STAGE/Payload/Components/$base" ;;
            *.vst3)      kind=vst3; dest="$STAGE/Payload/VST3/$base" ;;
            *.clap)      kind=clap; dest="$STAGE/Payload/CLAP/$base" ;;
            *) continue ;;
        esac
        case " $FORMATS_STR " in
            *" $kind "*) ;;
            *) continue ;;
        esac
        [ -e "$p" ] || die "清单里的产物不存在：$p"
        mkdir -p "$(dirname "$dest")"
        # -R 保留 bundle 里的可执行位；签名在 bundle 内部，不需要额外步骤
        cp -R "$p" "$dest"
        log "    + $(basename "$(dirname "$dest")")/$base"
        found=$((found + 1))
    done < "$MAN"
done
[ "$found" -gt 0 ] || die "没有可打包的产物（检查 --variants / --formats 与构建清单）"

# ---------------------------------------------------------------- 2. 安装脚本
# 注意 heredoc 用 'EOF'：$HOME 等要在**用户机器上**展开，不能在这里展开
cat > "$STAGE/安装.command" <<'EOF'
#!/bin/bash
# 双击运行：把 Payload 里的插件装到**当前用户**的插件目录（不需要管理员密码）。
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Library/Audio/Plug-Ins"
installed=0
for d in Components VST3 CLAP; do
    src="Payload/$d"
    [ -d "$src" ] || continue
    mkdir -p "$DEST/$d"
    for item in "$src"/*; do
        [ -e "$item" ] || continue
        name="$(basename "$item")"
        rm -rf "$DEST/$d/$name"
        cp -R "$item" "$DEST/$d/"
        echo "  已安装：$DEST/$d/$name"
        installed=$((installed + 1))
    done
done

if [ "$installed" -eq 0 ]; then
    echo "✗ Payload 里没有可安装的插件" >&2
    exit 1
fi

# 让系统重新扫描 AU（没有权限时忽略；重启宿主/系统也能生效）
killall -9 AudioComponentRegistrar 2>/dev/null || true

echo
echo "完成。请完全退出并重新打开宿主（Logic 等）后再扫描插件。"
echo "若 Logic 仍显示旧的分类/名字，先退出 Logic，再参考 README.txt 里的命令清缓存。"
echo
read -r -p "按回车关闭这个窗口…" _ || true
EOF
chmod +x "$STAGE/安装.command"

# ---------------------------------------------------------------- 3. README
RESET_LINES=""
for v in $VARIANTS_STR; do
    case "$v" in
        mono)   suffix=" Mono";   subtype="$AU_SUBTYPE_MONO" ;;
        stereo) suffix=" Stereo"; subtype="$AU_SUBTYPE_STEREO" ;;
    esac
    [ -n "$subtype" ] || continue
    RESET_LINES="${RESET_LINES}  plutil -remove \"aufx-${subtype}-${AU_MANUFACTURER}\" ~/Library/Preferences/com.apple.logic10.plist
"
done

cat > "$STAGE/README.txt" <<EOF
${PLUGIN_NAME}（${PLUGIN_VENDOR}）—— macOS 安装说明

这个 DMG 里有什么
  Payload/Components/    AUv2 插件（.component）
  Payload/VST3/          VST3 插件（.vst3）
  Payload/CLAP/          CLAP 插件（.clap）
  安装.command           双击即可装到当前用户目录（不需要管理员密码）

推荐：双击「安装.command」
  如果系统提示“无法验证开发者”，右键点它 → 打开 → 再确认一次。

手动安装：把 Payload 下对应目录里的插件拖到
  ~/Library/Audio/Plug-Ins/Components   （AUv2）
  ~/Library/Audio/Plug-Ins/VST3         （VST3）
  ~/Library/Audio/Plug-Ins/CLAP         （CLAP）

装完请**完全退出**并重新打开宿主。若 Logic 里分类/名字不对（缓存），
先退出 Logic，再执行（终端）：

${RESET_LINES}  killall cfprefsd

已知边界
  - 本插件是 **ad-hoc 签名**，没有 Developer ID 签名与公证；首次打开可能需要在
    “系统设置 → 隐私与安全性”里允许。
  - 安装范围是**当前用户**（~/Library/Audio/Plug-Ins，不需要管理员）。
    若要装到全机目录 /Library/Audio/Plug-Ins，请手动复制（需要管理员）。
  - 同一台机器请勿同时保留旧版与新版的同一个插件身份（宿主可能扫到重复插件）。
EOF

# ---------------------------------------------------------------- 4. 生成 DMG
log "==> hdiutil 生成 DMG"
rm -f "$DMG"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" \
    -ov -format UDZO -fs HFS+ "$DMG" >&2 \
    || die "hdiutil create 失败"

[ -f "$DMG" ] || die "DMG 没生成：$DMG"
hdiutil imageinfo "$DMG" >/dev/null 2>&1 || die "DMG 校验失败：$DMG"
log "    $(du -h "$DMG" | awk '{print $1}')  ${DMG}"

printf '%s\n' "$DMG"
