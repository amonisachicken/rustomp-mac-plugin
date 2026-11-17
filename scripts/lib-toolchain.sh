#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# **工具链解析（单一来源）** —— doctor 与 build 必须用同一套 cargo/rustc。
#
# 为什么需要它（下游 Freedist 报告 P4）：
#   `doctor.sh` 曾经用 `rustup target list --installed` 检查 target，
#   而 `build-variant.sh` 用的是 PATH 里的 `cargo nih-plug`。
#   当 PATH 里是 Homebrew 的 rustc、而 rustup 的 toolchain 才是装好的那套时，
#   doctor 全绿、构建却报 `E0463: can't find crate for core`。
#
# 用法：
#   source "$ROOT/scripts/lib-toolchain.sh"
#   rp_print_toolchain                      # 打印将要使用的 cargo/rustc/sysroot
#   rp_check_universal_targets || exit 1    # 检查两个 macOS target 是否真的可用
set -uo pipefail

# 解析实际会用的 cargo / rustc（**只看 PATH**，不做任何隐式切换）
rp_resolve_toolchain() {
    RP_CARGO="$(command -v cargo 2>/dev/null || true)"
    RP_RUSTC=""
    if [ -n "$RP_CARGO" ]; then
        # rustup 的 shim 旁边就是 rustc；优先用同一个目录，避免 cargo/rustc 混搭
        RP_RUSTC="$(dirname "$RP_CARGO")/rustc"
        [ -x "$RP_RUSTC" ] || RP_RUSTC="$(command -v rustc 2>/dev/null || true)"
    fi
    RP_SYSROOT=""
    [ -n "$RP_RUSTC" ] && RP_SYSROOT="$("$RP_RUSTC" --print sysroot 2>/dev/null || true)"
}

# cargo 的版本号（1.100.0）
rp_cargo_version() {
    [ -n "${RP_CARGO:-}" ] || { echo "?"; return; }
    "$RP_CARGO" --version 2>/dev/null | awk '{print $2}'
}

rp_print_toolchain() {
    rp_resolve_toolchain
    printf '  · cargo: %s（%s）\n' "${RP_CARGO:-未找到}" "$([ -n "$RP_CARGO" ] && "$RP_CARGO" --version | awk '{print $2}' || echo '-')"
    printf '  · rustc: %s（%s）\n' "${RP_RUSTC:-未找到}" "$([ -n "$RP_RUSTC" ] && "$RP_RUSTC" -V | awk '{print $2}' || echo '-')"
    printf '  · sysroot: %s\n' "${RP_SYSROOT:-未找到}"
}

# 目标平台的核心库里有没有 core（比 `rustup target list` 可靠：
# 它检查的是**真正会被用来编译的那个 rustc**）
rp_target_installed() {
    local t="$1" libdir
    [ -n "${RP_RUSTC:-}" ] || return 1
    libdir="$("$RP_RUSTC" --print target-libdir --target "$t" 2>/dev/null || true)"
    [ -n "$libdir" ] || return 1
    ls "$libdir"/libcore-*.rlib >/dev/null 2>&1
}

# 检查 universal 需要的两个 target；失败时给出**可直接执行**的修法
rp_check_universal_targets() {
    rp_resolve_toolchain
    local missing=() t
    for t in aarch64-apple-darwin x86_64-apple-darwin; do
        rp_target_installed "$t" || missing+=("$t")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0

    printf '  ✗ 当前 rustc 缺 target：%s\n' "${missing[*]}" >&2
    printf '    当前 cargo: %s\n' "${RP_CARGO:-未找到}" >&2
    printf '    当前 rustc: %s（sysroot %s）\n' "${RP_RUSTC:-未找到}" "${RP_SYSROOT:-?}" >&2
    if [ -n "${RP_SYSROOT:-}" ] && [ -d "${RP_SYSROOT}/../.." ]; then
        printf '    修法（装到这套 toolchain）：\n' >&2
        printf '      rustup target add %s\n' "${missing[*]}" >&2
    fi
    cat >&2 <<'EOT'
    如果 PATH 里有多个 rust（Homebrew / rustup 混用），先统一：
      export PATH="$HOME/.cargo/bin:$PATH"      # 让 rustup 的 cargo/rustc 优先
      command -v cargo && rustc -V
    然后重跑本脚本。**doctor 与构建必须用同一套 cargo/rustc**（P4）。
EOT
    return 1
}
