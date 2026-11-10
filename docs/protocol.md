# 小管家和机器人之间的约定（第 2 版）

Mac 上的小管家是一个很小的 HTTP 服务，机器人每 2 秒来取一次状态。

## 1. 机器人怎么找到 Mac

- 小管家在局域网里用 Bonjour 公布服务 `_aihelper._tcp`，端口默认 8787，TXT 记录：
  - `v=2`
  - `id=<这台 Mac 上小管家的随机编号>`（第一次运行时生成，写进设置）
- 机器人查询 `_aihelper._tcp`，优先用 `id` 和自己存的一致的那一个；找不到就用上次成功连上的地址。

## 2. 第一次配置：通过 USB 串口（115200）

一行一条命令，回复以 `OK` / `ERR` 开头。文字参数一律用十六进制编码的 UTF-8，避免空格和中文出问题。

| 命令 | 作用 | 回复 |
|---|---|---|
| `hello` | 握手 | `HELLO aihelper fw=<版本> board=cores3 configured=<0/1> mac=<芯片 MAC>` |
| `cfg wifi <ssid hex> <密码 hex>` | 暂存 WiFi | `OK` |
| `cfg link <token> <mac id> <主机名 hex> <端口>` | 暂存小管家的口令和位置 | `OK` |
| `cfg save` | 写进 NVS 并开始连 WiFi | `OK`，之后异步打印 `WIFI ok <ip>` 或 `WIFI fail` |
| `cfg show` | 看现在的配置（不打印密码和口令） | `CFG ssid=<hex> mac_id=… host=<hex> port=… token=<有/无>` |
| `cfg clear` | 清空配置（恢复成第一次开机的样子） | `OK` |

密码只经过 USB 线，不经过网络。没有用 USB 配置时，机器人仍然可以用手机连 `StackChan-Setup` 热点配网，但那样没有口令，需要在 Mac 上配对一次。

## 3. 取状态：`GET /state`

查询参数：`t=<口令>`、`fw=<固件版本>`、`rssi=<WiFi 信号>`、`up=<开机秒数>`，读得到电池时还有 `bat=<电量 0~100>`、`pwr=<插着线 0/1>`、`bmv=<电池电压，毫伏>`、`bma=<电池电流，毫安，放电为正、充电为负>`。小管家用这些在菜单栏面板和设置里显示设备状态和电量。

返回（只列出第 2 版新增或改变的字段；`subs`、`waiting`、`lows` 和第 1 版相同）：

```json
{
  "v": 2,
  "now": 1794295651, "time": "16:27", "ok": true, "data_time": "16:27",
  "subs": [ ... ],
  "face": ["claude", "codex", "antigravity"],
  "waiting": [ ... ],
  "lows": [ ... ],
  "rest": false,
  "cfg": { "rev": 12, ... },
  "cmd": { "id": 7, "do": "nod" }
}
```

- `face`：首页上常驻显示的几家，依次是第 1、2、3 格，小管家按设置算好（2 家固定 + 1 格最紧张的）。样式 B 只用前两个，D 不用。
- `subs[].icon`：这一家图标的版本号，空 = 没有图标（机器人画字母方块）。
- `waiting[].icon` / `waiting[].icon_v` / `waiting[].mono`：提醒画面和首页右上角小圆章用哪一家的图标、版本号；没有图标时写 `mono` 两个字母。
- `subs[].left/label/level/reset`：已经按「每家显示哪个额度」「黄色/红色提醒线」算好，机器人直接画。
- `subs[].windows[]`：这一家的每个额度（`label`、`left`、`level`、`reset`、`pace`，`mins` = 周期分钟数，明细页 A 用它挑周期最短的那个画大圆环）。
- `waiting`：已经按「哪些 AI 工具」「哪些情况」过滤好；「做完了」到设定时间（默认 10 分钟）由小管家去掉。机器人自己决定整屏闪多久、一条接一条。
- `rest`：小管家告诉机器人「Mac 要睡觉了」。之后连不上时，机器人安静地睡觉，不显示「连不上 Mac」。
- `cmd`：一次性的命令，机器人记住做过的 `id`，同一个 `id` 只做一次。小管家 15 秒后自动撤掉。
  - `nod` 点头，`shake` 摇头，`chime` 响一声，`find` 点头 + 响 + 闪灯（找设备），`reboot` 重启，`ota` 去取新固件。

### `cfg`：机器人上的设置

| 字段 | 含义 | 取值 |
|---|---|---|
| `rev` | 设置的版本号，变了才重新应用 | 整数 |
| `home` | 首页样式 | `A` 轻底栏 / `B` 眼睛就是额度 / `C` 说给你听 / `D` 只有脸 |
| `list` | 全部额度页样式 | `A` 两列小卡片 / `B` 一行一家 / `C` 竖条对比 |
| `detail` | 明细页样式 | `A` 大圆环（周期最短的额度）+ 旁边几行 / `B` 统一横条 |
| `alert_secs` | 整屏提醒停几秒，之后回到首页 | 整数，默认 10，0 = 一直到你回去 |
| `alert_style` | 提醒画面样式 | `now` 整屏变色 / `B` 柔和变色 / `C` 脸 + 底部卡片 |
| `done_flash` | 「做完了」整屏提醒完就熄（不留 logo 和灯），机器人用 `/clear` 的 `done_ids` 告诉小管家 | true / false |
| `theme` | 配色 | `night` 深夜蓝 / `black` 纯黑 / `warm` 暖色 / `light` 浅色 |
| `eye` | 眼睛样式 | `capsule` 胶囊 / `round` 圆点 / `bar` 竖条 |
| `eye_color` | 眼睛颜色，空 = 跟随配色 | `#rrggbb` 或 `""` |
| `bright` | 屏幕亮度 | 0–100 |
| `used` | 数字显示「用了多少」而不是「还剩多少」 | `true/false` |
| `clock` | 平时画面显示时钟 | `true/false` |
| `blink` / `look` | 眨眼 / 偶尔左右张望 | `true/false` |
| `sleepy` | 现在是不是「晚上显得困」的时段（小管家算好） | `true/false` |
| `dim_after` | 没动静多少分钟后变暗，0 = 从不 | 整数 |
| `alert` | 提醒强度 | 0 轻 / 1 中 / 2 强 |
| `remind` | 没回去时多少分钟后再整屏提醒一次，0 = 不再提醒（「强」默认 5） | 整数 |
| `motion` | 头部动作总开关 | `true/false` |
| `nod` | 点头幅度 | 0 小 / 1 中 / 2 大 |
| `pitch` | 平时抬头角度（度） | 5–40 |
| `wander` | 没事时偶尔转转头 | `true/false` |
| `shake_low` | 额度快用完时摇头 | `true/false` |
| `sound` / `volume` / `tone` | 提示音开关 / 音量 0–100 / 音色 0 叮、1 叮咚、2 两声短哔、3 小号角 | |
| `led` / `led_bright` | 彩灯开关 / 亮度 0–100 | |
| `led_idle` / `led_attn` | 平时 / 等你时的灯色，空 = 关 | `#rrggbb` 或 `""` |
| `touch` | 平时摸头的作用（整屏提醒时摸头总是提前收起） | 0 开心一下 / 1 切换页面 / 2 不做什么 |
| `name` | 名字 | 文字 |
| `lang` | 屏幕上的语言 | `zh` 中文 / `ja` 日文 / `en` 英文 |
| `quiet` | 现在是不是勿扰（小管家按时段、临时勿扰、锁屏算好） | `true/false` |
| `q_still` / `q_mute` / `q_dark` | 勿扰时不动 / 不响 / 关灯 | `true/false` |
| `q_bright` | 勿扰时屏幕亮度 | 0–100 |
| `q_face` | 勿扰时「要你批准」照样变脸 | `true/false` |

## 4. 其他地址

| 地址 | 作用 |
|---|---|
| `POST /ack` `{"id": "w12"}` | 整屏提醒时摸头 / 点屏幕提前收起：这一条不再重复提醒（灯和小 logo 照旧到你回去），空 id = 全部 |
| `POST /hook`（只限本机） | 小管家自己的钩子脚本 `butler-hook.sh` 用：请求头 `X-Butler-Tool`（claude / codex / cursor / antigravity）、`X-Butler-Event`（可空），正文是 AI 工具传给钩子的原始 JSON |
| `POST /clear` `{"ids": ["w12", "w13"]}` | 机器人上摸头熄灯：去掉这几条（灯和小 logo 一起熄）；`done_ids` 是「做完了」整屏提醒完自己熄掉的；也可以用 `{"id": ""}`，空 id = 全部 |
| `POST /cmd` `{"do": "nod"}` | 只限本机：给机器人发一次性命令（见上面 `cmd`） |
| `POST /event` | 发一条测试提醒（向导里的「试一下」） |
| `POST /ntfy/<topic>` | 接收 peon-ping 的推送 |
| `GET /firmware.bin` | 新固件（机器人收到 `ota` 命令后来取，带口令） |
| `GET /icon?id=claude&s=28&bg=dark` | 图标：`s`×`s` 像素，每个像素 4 字节 B、G、R、A（不预乘）；`bg` 是图标所在的底色（`dark` / `light`），决定用 logo 的哪个版本 |
| `GET /health` | 不要口令，只回 `{"ok": true}` |

局域网里的请求都要带口令（`?t=` 或 `Authorization: Bearer`），本机访问不需要。
