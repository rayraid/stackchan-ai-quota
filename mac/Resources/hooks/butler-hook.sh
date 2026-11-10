#!/bin/sh
# 小管家的提醒钩子：各个 AI 工具在「停下来等你 / 要你批准 / 你回来了」时调用它。
#
#   sh ".../butler-hook.sh" claude|codex|cursor|antigravity [事件名]
#
# AI 工具会把这次事件的详情（JSON）从标准输入传进来。这里原样转交给本机的小管家，
# 自己立刻返回，不卡住 AI。小管家没在运行也没关系，直接忽略。

tool="${1:-ai}"
event="${2:-}"
input=$(cat)

# Antigravity 要求钩子在标准输出回一个 JSON
[ "$tool" = "antigravity" ] && printf '{}\n'

port=$(cat "$HOME/Library/Application Support/StackChan Butler/port" 2>/dev/null)
[ -n "$port" ] || port=8787

(
  printf '%s' "$input" | /usr/bin/curl -s -m 3 -X POST \
    -H "Content-Type: application/json" -H "X-Butler-Tool: $tool" -H "X-Butler-Event: $event" \
    --data-binary @- "http://127.0.0.1:$port/hook"
) </dev/null >/dev/null 2>&1 &

exit 0
