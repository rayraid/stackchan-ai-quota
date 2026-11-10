#!/bin/sh
# Antigravity 2.x 的正式钩子 → peon-ping → 小管家
#
# Antigravity 在 ~/.gemini/config/hooks.json 里这样调用它：
#   sh ".../antigravity-hook.sh" Stop            它停下来等你了
#   sh ".../antigravity-hook.sh" PreInvocation   要调用模型了（你回复之后的第一次就当作「你回去了」）
#
# Antigravity 的钩子是同步的，会卡住它自己，所以这里先立刻回一个 {}，
# 再把翻译好的事件放到后台交给 peon.sh（和 Claude Code、Codex、Cursor 走同一条路）。

event="${1:-Stop}"
input=$(cat)
printf '{}\n'

peon="${PEON_DIR:-$HOME/.claude/hooks/peon-ping}/peon.sh"
[ -f "$peon" ] || exit 0

(
  out=$(printf '%s' "$input" | /usr/bin/env python3 -c '
import json, os, sys, tempfile

event = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
conv = str(d.get("conversationId") or "")
if not conv:
    sys.exit(0)
roots = d.get("workspacePaths") or []
cwd = roots[0] if roots else os.path.expanduser("~")

# 记下「停下来等你」的会话，下一次调用模型时才算你回去了（不用每次调用模型都打扰 peon-ping）
mark_dir = os.path.join(tempfile.gettempdir(), "stackchan-antigravity")
mark = os.path.join(mark_dir, "".join(c for c in conv if c.isalnum() or c == "-"))

out = ""
if event == "Stop":
    reason = str(d.get("terminationReason") or "")
    if reason == "USER_CANCELED" or d.get("fullyIdle") is False:
        sys.exit(0)                    # 你自己停的 / 后台还在跑：不算等你
    out = "PostToolUseFailure" if reason == "ERROR" or d.get("error") else "Stop"
    os.makedirs(mark_dir, exist_ok=True)
    open(mark, "w").close()
elif event == "PreInvocation":
    if not os.path.exists(mark):
        sys.exit(0)
    os.remove(mark)
    out = "UserPromptSubmit"
if out:
    print(json.dumps({"hook_event_name": out, "notification_type": "", "cwd": cwd,
                      "session_id": "antigravity-" + conv, "permission_mode": "", "source": "antigravity"}))
' "$event")
  [ -n "$out" ] && printf '%s' "$out" | bash "$peon"
) </dev/null >/dev/null 2>&1 &

exit 0
