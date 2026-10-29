# 文档

本目录放细节；根 `README.md` 只放"够用就能开工"的部分。

| 文档 | 内容 | 什么时候读 |
|---|---|---|
| [`00-decisions.md`](00-decisions.md) | **决策账本**（M-00x）：每条都影响实现形态 | 改脚本 / 改构建流程之前 |
| [`02-architecture.md`](02-architecture.md) | 调用链、产物形状、AU 身份与 plist、目录结构 | 想知道"一条 `pack.sh` 到底做了什么" |
| [`03-logic-compat.md`](03-logic-compat.md) | AUv2 宿主兼容：MIDI 归类、声道布局、Logic 缓存 | Logic 里看不到 / 被归类错 / 单声道轨没菜单 |
| [`04-dependencies.md`](04-dependencies.md) | 依赖清单与固定版本、安装命令、离线注意 | 新机器从零装、升级 nih-plug / clap-wrapper |
| [`05-troubleshooting.md`](05-troubleshooting.md) | 常见症状 → 真因 → 处理 | 构建、安装、宿主异常 |
| [`09-devlog.md`](09-devlog.md) | 开发日志（E1…）：做了什么、踩了什么坑 | 想知道"为什么这样写" |

> 仓库边界与跨仓契约（A/B/C）在框架仓：
> [rustomp/docs/ecosystem.md](https://github.com/amonisachicken/rustomp/blob/master/docs/ecosystem.md)。
> Windows 的同位实现在
> [rustomp-win-plugin](https://github.com/amonisachicken/rustomp-win-plugin)（只有 VST3/CLAP，**没有 AU**）。

---

[← 返回 README](../README.md)
