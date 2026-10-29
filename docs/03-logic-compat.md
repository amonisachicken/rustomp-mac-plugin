# AUv2 的宿主兼容（Logic）

> 这一页解释**为什么 `patches/` 里有两个必须的修复**，以及"插件管理器里能看到、
> 但音频轨的 Audio FX 菜单里找不到"这类症状怎么定位。
> 补丁本体在 [`../patches/`](../patches/)，由 `fetch-third-party.sh` 自动应用。

AU 的一切麻烦都来自同一件事：**宿主按自己的缓存判断"这是什么插件、支持几个声道"**。
缓存里的值由 wrapper 在**扫描时**宣称的属性决定；宣称错了，之后改名、重装都救不回来，
必须清缓存或换一个**新身份**。

---

## 1. 补丁 0001 的第一部分：不要冒充乐器 / MIDI 插件

**问题**：clap-wrapper 的 AUv2 外壳**无条件**对外宣称支持一批「乐器 / MIDI 专属」属性，
即使被托管的 CLAP 是纯音频效果器：

- `kMusicDeviceProperty_InstrumentCount`（MusicDevice 专属）
- `kMusicDeviceProperty_SupportsStartStopNote`
- `kMusicDeviceProperty_DualSchedulingMode`
- `kAudioUnitProperty_AudioUnitMIDIProtocol` / `HostMIDIProtocol`
- `kAudioUnitProperty_MIDIOutputCallback(Info)` / `MIDIOutputEventListCallback`

**后果**：Logic 会把一个纯音频效果器标记成 `MIDIProtocol = 1`
（见 `~/Library/Preferences/com.apple.logic10.plist` 里的 `aufx-XXXX-YYYY` 缓存条目），
于是把它归到 **"MIDI 控制效果器"**，在 Logic 里就**只出现在软件乐器插槽，音频轨的 Audio FX 里找不到**。

对照：BYOD / Waves 等原生 AUv2 效果器的缓存条目都是 `MIDIProtocol = 0`。

**修复**：

- `kMusicDeviceProperty_*` 只在 `_autype == aumu_musicdevice`（即 plist 里声明为乐器）时才宣称；
- MIDI 相关属性只在 `hasMIDI()`（有 MIDI note 输入端口或有 MIDI 输出）时才宣称；
- 否则一律返回 `kAudioUnitErr_InvalidProperty`。

**验证**：`tools/au-smoke` 会逐个查询上面这些属性，修复后全部返回
`kAudioUnitErr_InvalidProperty`：

```text
[ ok ] 不支持 kMusicDeviceProperty_InstrumentCount（效果器应有行为）
[ ok ] 不支持 kMusicDeviceProperty_SupportsStartStopNote（效果器应有行为）
[ ok ] 未宣称支持 MIDI（纯音频效果器）→ Logic 会归到 Audio FX
```

---

## 2. 补丁 0001 的第二部分：声道布局（Logic 找不到插件的真正原因）

**现象**：插件已经正确归类为 effect（Logic 插件管理器里能看到），
但在**音频轨**（单声道）的 Audio FX 菜单里依然找不到；只能先放到软件乐器轨再拖过去。

**证据**：

```text
$ tools/clap-probe target/bundled/"Rustomp Fuzz.clap"
    audio-ports-config 数量: 2
      [0] id=0 name=Stereo in=2 out=2
      [1] id=1 name=Mono   in=1 out=1        ← nih-plug 支持单声道

$ tools/au-smoke ... （修复前）
    SupportedNumChannels: 1 组
        in=2 out=2                            ← AU 只报立体声
```

**根因**：clap-wrapper 只通过 **`clap.configurable-audio-ports`**（较新的扩展）
枚举可选布局，而 **nih-plug 只实现了较旧的 `clap.audio-ports-config`**。
于是 `_channelCapsCache` 为空，AU 退回按端口数推导 → 只有 `{2,2}`。

Logic 的插入菜单会按当前通道条的声道数过滤：**单声道音轨需要一个支持 in=1 的
配置**，我们没有，所以整个插件从菜单里消失；插件管理器读的是静态信息，所以仍然显示。

**修复**：

- `PostConstructor()`：若 `_channelCapsCache` 为空且存在 `clap.audio-ports-config`，
  用它枚举布局填入缓存（限「单主输入 + 单主输出」的常见情形，多总线插件不臆测）。
- `applyConfigurationFromBusFormats()`：宿主选中的布局与某个 config 匹配时，
  调用 `apc->select(plugin, cfg.id)` 真正切换（在 `activateCLAP` 之前，符合 CLAP 规范）。

**验证**：

```text
$ tools/au-smoke ... （修复后）
[info] SupportedNumChannels: 2 组
        in=2 out=2
        in=1 out=1
[info] 声道数: 1   →  RMS=0.354240  音频通路正常
[info] 声道数: 2   →  RMS=0.354240  音频通路正常
```

> 即便补丁修好了布局，本仓仍然出 **mono / stereo 两个独立变体**（M-003）：
> 插件管理器里的"支持 in=1"不等于所有宿主都会正确枚举；独立身份没有歧义，
> 也顺带绕开任何陈旧缓存。

---

## 3. Logic 的缓存：`MIDIProtocol` 与 `ChannelConfigurations`

清缓存前先确认：Logic 必须**完全退出**（⌘Q），否则退出时会把内存里的旧值写回 plist。

```bash
./scripts/check-au.sh stereo     # 看已安装的 AU + Logic 缓存条目
./scripts/reset-logic-cache.sh   # Logic 没运行时才可用
```

`check-au.sh` 会打印缓存条目的两行关键值：

| 值 | 期望 | 含义 |
|---|---|---|
| `MIDIProtocol` | `0` | `1` = Logic 把效果器当 MIDI 插件（补丁 1 未生效/缓存未刷新） |
| `ChannelConfigurations` | 含 `1/1`（mono 变体）或 `2/2` | 缺 `1/1` = 单声道轨菜单里看不到 |

`reset-logic-cache.sh` 删除 `aufx-<subtype>-<manufacturer>` 条目（含几个历史命名的键），
然后 `killall cfprefsd` 让 Logic 重新扫描。

> `check-au.sh` 只读，不改任何东西 —— **先跑它再决定清不清缓存**，避免"明明插件坏了却去清缓存"。

---

## 4. 三条排查顺序（别倒过来）

1. **插件本身**：`./scripts/check-au.sh <variant>` 是否 `音频通路正常`？失败就是构建/渲染问题；
2. **系统注册表**：`auval` / 宿主找不到任何第三方 AU？本机 `AudioComponentRegistrar` 缓存可能坏了
   （本仓用进程内 `au_smoke` 绕开它，见 M-007）；
3. **宿主缓存**：插件能渲染、`auval` 也过，但 Logic 菜单里没有/归类错 → 清缓存（先退 Logic）。
