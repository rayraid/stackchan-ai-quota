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

查询参数：`t=<口令>`、`fw=<固件版本>`、`rssi=<WiFi 信号>`、`up=<开机秒数>`。小管家用后三个在设置里显示设备状态。

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

- `face`：平时画面底部 3 格依次显示哪几家，小管家按设置算好（2 家固定 + 1 格最紧张的）。
- `subs[].left/label/level/reset`：已经按「每家显示哪个时间段」「黄色/红色提醒线」算好，机器人直接画。
- `waiting`：已经按「哪些 AI 工具」「哪些情况」过滤好。
- `rest`：小管家告诉机器人「Mac 要睡觉了」。之后连不上时，机器人安静地睡觉，不显示「连不上 Mac」。
- `cmd`：一次性的命令，机器人记住做过的 `id`，同一个 `id` 只做一次。小管家 15 秒后自动撤掉。
  - `nod` 点头，`shake` 摇头，`chime` 响一声，`find` 点头 + 响 + 闪灯（找设备），`reboot` 重启，`ota` 去取新固件。

### `cfg`：机器人上的设置

| 字段 | 含义 | 取值 |
|---|---|---|
| `rev` | 设置的版本号，变了才重新应用 | 整数 |
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
| `remind` | 没理会时多少分钟后再提醒一次，0 = 不再提醒 | 整数 |
| `motion` | 头部动作总开关 | `true/false` |
| `nod` | 点头幅度 | 0 小 / 1 中 / 2 大 |
| `pitch` | 平时抬头角度（度） | 5–40 |
| `wander` | 没事时偶尔转转头 | `true/false` |
| `shake_low` | 额度快用完时摇头 | `true/false` |
| `sound` / `volume` / `tone` | 提示音开关 / 音量 0–100 / 音色 0 叮、1 叮咚、2 两声短哔、3 小号角 | |
| `led` / `led_bright` | 彩灯开关 / 亮度 0–100 | |
| `led_idle` / `led_attn` | 平时 / 等你时的灯色，空 = 关 | `#rrggbb` 或 `""` |
| `touch` | 摸头的作用 | 0 知道了 / 1 切换页面 / 2 不做什么 |
| `name` | 名字 | 文字 |
| `lang` | 屏幕上的语言 | `zh` 中文 / `ja` 日文 / `en` 英文 |
| `quiet` | 现在是不是勿扰（小管家按时段、临时勿扰、锁屏算好） | `true/false` |
| `q_still` / `q_mute` / `q_dark` | 勿扰时不动 / 不响 / 关灯 | `true/false` |
| `q_bright` | 勿扰时屏幕亮度 | 0–100 |
| `q_face` | 勿扰时「要你批准」照样变脸 | `true/false` |

## 4. 其他地址

| 地址 | 作用 |
|---|---|
| `POST /ack` `{"id": ""}` | 摸头 / 点屏幕「知道了」，空 id = 全部 |
| `POST /clear` `{"id": ""}` | 去掉提醒 |
| `POST /cmd` `{"do": "nod"}` | 只限本机：给机器人发一次性命令（见上面 `cmd`） |
| `POST /event` | 发一条测试提醒（向导里的「试一下」） |
| `POST /ntfy/<topic>` | 接收 peon-ping 的推送 |
| `GET /firmware.bin` | 新固件（机器人收到 `ota` 命令后来取，带口令） |
| `GET /health` | 不要口令，只回 `{"ok": true}` |

局域网里的请求都要带口令（`?t=` 或 `Authorization: Bearer`），本机访问不需要。
