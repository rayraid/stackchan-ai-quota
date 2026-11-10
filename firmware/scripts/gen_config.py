# 编译前自动运行：把「小管家在哪、口令是什么」写进 include/build_config.h
# 口令来自 ../bridge/config.json（小管家首次运行时自动生成），不需要手填。
Import("env")  # noqa: F821  (PlatformIO 提供)
import json
import os
import subprocess

proj = env["PROJECT_DIR"]  # noqa: F821
with open(os.path.join(proj, "..", "bridge", "config.json"), encoding="utf-8") as f:
    cfg = json.load(f)


def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except Exception:
        return ""


host = sh("scutil --get LocalHostName")          # 例如 My-Mac（设备用 .local 名字找这台 Mac）
ip = sh("ipconfig getifaddr en0") or sh("ipconfig getifaddr en1")  # 名字找不到时的备用地址

os.makedirs(os.path.join(proj, "include"), exist_ok=True)
with open(os.path.join(proj, "include", "build_config.h"), "w", encoding="utf-8") as f:
    f.write("// 自动生成，不要手改\n#pragma once\n")
    f.write('#define BRIDGE_HOST "%s"\n' % host)
    f.write('#define BRIDGE_IP_HINT "%s"\n' % ip)
    f.write("#define BRIDGE_PORT %d\n" % int(cfg.get("port", 8787)))
    f.write('#define BRIDGE_TOKEN "%s"\n' % cfg.get("token", ""))
print("build_config.h: 小管家 = %s.local (%s):%s" % (host, ip, cfg.get("port", 8787)))
