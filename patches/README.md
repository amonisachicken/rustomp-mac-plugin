# 第三方补丁

`third_party/` 下的源码由 `scripts/fetch-third-party.sh` 拉取（不入库），
拉取后会自动应用这里的 `*.patch`，保证可复现。

当前只有一份补丁：

| 补丁 | 修什么 |
|---|---|
| `0001-auv2-host-classification-and-layouts.patch` | ① AU 不要冒充乐器 / MIDI 插件（否则 Logic 归到"MIDI 控制效果器"）；② 用 `clap.audio-ports-config` 补全声道布局（否则单声道轨的 Audio FX 菜单里看不到） |

**细节、证据与验证方法见 [`../docs/03-logic-compat.md`](../docs/03-logic-compat.md)。**

> 改补丁前先读那篇；改完在干净 clone 里重跑 `./scripts/fetch-third-party.sh`
> 确认仍能 `git apply`，再验证 `./scripts/check-au.sh`。
