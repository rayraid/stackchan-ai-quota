// aihelper 固件 2.0：StackChan（CoreS3）
// 连 WiFi、每 2 秒向 Mac 上的小管家要一次状态、按设置画到屏幕上；
// 有 AI 在等你时：整屏变色、点头、亮灯、响一声，停几秒后自己回到平时的脸，
// 彩灯保持琥珀色、右上角留一个小 logo，直到你回到那个 AI。不需要碰机器人。
// 各部分：ui.cpp 画面，body.cpp 头/灯/声音，net.cpp 联网和配置。
#include "app.h"
#include <WiFi.h>

static Page gPage = P_FACE;
static String gDetailId;
static Page gDetailFrom = P_FACE;   // 明细页从哪一页进来的（返回时回到那一页）
static bool gDemoOff = false, gDemoRest = false;
static String gDemoMode;
static int gLastCmd = 0;
RTC_NOINIT_ATTR static int gLastCmdKept;   // 软重启后还记得做过的命令，避免 reboot 命令反复执行
static uint32_t gOtaFailAt = 0;
static uint32_t gLastTouch = 0, gHappyUntil = 0;
static const uint32_t BACK_TO_FACE_MS = 15000;   // 列表、明细 15 秒没碰就回到脸
static int gSimTap = 0, gSimX = 0, gSimY = 0;    // 串口模拟触摸：1 点一下  2 长按  3 摸头

// ---------- 整屏提醒：一条一条来，每条停 alertSecs 秒 ----------
static String gFlashId;               // 正在整屏提醒的那一条
static uint32_t gFlashAt = 0;
static bool gFlashReminder = false;   // 这次是「没回去，再提醒一次」
static int gFlashSeq = 0;             // 每开始一次 +1，body 据此点头、响一声
static std::vector<String> gFlashed;  // 已经整屏提醒过的
static uint32_t gLastRemind = 0;
static bool gSeeded = false;          // 开机后第一次拿到状态时，已经在等的不再重新闪一遍

static int rankOf(const String& k) { return k == "approval" ? 0 : k == "question" ? 1 : k == "error" ? 2 : k == "done" ? 3 : k == "restored" ? 4 : 5; }
static bool wasFlashed(const String& id) { for (auto& x : gFlashed) if (x == id) return true; return false; }
static const Wait* findWait(const State& s, const String& id) { for (auto& w : s.waiting) if (w.id == id) return &w; return nullptr; }
// 最要紧的一条：批准 > 提问 > 出错 > 做完了，同类先来的先
static const Wait* topWait(const State& s, bool onlyNew) {
  const Wait* best = nullptr;
  for (auto& w : s.waiting) {
    if (w.acked || (onlyNew && wasFlashed(w.id))) continue;
    if (!best || rankOf(w.kind) < rankOf(best->kind) || (rankOf(w.kind) == rankOf(best->kind) && w.since < best->since)) best = &w;
  }
  return best;
}
static void startFlash(const String& id, bool reminder) {
  gFlashId = id; gFlashAt = millis(); gFlashReminder = reminder; gFlashSeq++; gLastRemind = millis();
}
static void endFlash() {
  if (gFlashId.length() && !wasFlashed(gFlashId)) gFlashed.push_back(gFlashId);
  gFlashId = "";
}
// 「做完了」整屏提醒完就熄：这一条从屏幕上去掉（灯、右上角 logo 一起熄），并告诉小管家删掉
static void dropIfDone(const Cfg& c, const String& id) {
  if (!c.doneFlash || !id.length()) return;
  xSemaphoreTake(gMux, portMAX_DELAY);
  for (size_t i = 0; i < gState.waiting.size(); i++) {
    const String& k = gState.waiting[i].kind;
    if (gState.waiting[i].id != id || (k != "done" && k != "note")) continue;
    if (!gDemo) { gClearIds.push_back(id); gDoneSend.push_back(id); }
    gState.waiting.erase(gState.waiting.begin() + i);
    break;
  }
  xSemaphoreGive(gMux);
}
static void updateFlash(const State& s, const Cfg& c) {
  if (!s.valid) return;
  for (size_t i = 0; i < gFlashed.size();) { if (findWait(s, gFlashed[i])) i++; else gFlashed.erase(gFlashed.begin() + i); }   // 不在等的就忘掉
  if (!gSeeded) { gSeeded = true; for (auto& w : s.waiting) gFlashed.push_back(w.id); gLastRemind = millis(); }
  bool hide = (c.quiet || s.rest) && !c.qFace;      // 勿扰时不变脸
  int every = c.remind > 0 ? c.remind : (c.alert >= 2 ? 5 : 0);   // 分钟；「强」默认每 5 分钟再来一次
  if (gFlashId.length()) {
    const Wait* w = findWait(s, gFlashId);
    bool timeUp = c.alertSecs > 0 && millis() - gFlashAt > (uint32_t)c.alertSecs * 1000;
    if (w && timeUp) dropIfDone(c, gFlashId);
    if (!w || w->acked || timeUp || hide) endFlash();
    else if (c.alertSecs <= 0 && every > 0 && millis() - gLastRemind > (uint32_t)every * 60000) {   // 一直整屏时，到点再点一次头
      gFlashSeq++; gLastRemind = millis(); gFlashReminder = true;
    }
  }
  if (hide || gFlashId.length()) return;
  if (const Wait* w = topWait(s, true)) { startFlash(w->id, false); return; }
  if (every > 0 && millis() - gLastRemind > (uint32_t)every * 60000) {
    gLastRemind = millis();
    if (const Wait* w = topWait(s, false)) startFlash(w->id, true);
  }
}
// 整屏提醒时摸头 / 点屏幕：提前收起这一条，告诉小管家「已知道」（之后不再重复提醒，灯和小 logo 照旧到你回去）
static void collapseFlash(const Cfg& c) {
  if (!gFlashId.length()) return;
  dropIfDone(c, gFlashId);
  xSemaphoreTake(gMux, portMAX_DELAY);
  for (auto& w : gState.waiting) if (w.id == gFlashId) w.acked = true;
  if (!gDemo) gAckId = gFlashId;
  xSemaphoreGive(gMux);
  endFlash();
}

// ---------- 额度快用完：红卡片亮 1 分钟就收进首页；掉到更低一档（5%、用完）或另一家也快用完时再来一次 ----------
static std::vector<String> gLowSeen;  // 已经提醒过的「哪一家|哪个时间段|档位」
static uint32_t gLowAt = 0;           // 这次红卡片开始的时间，0 = 没在显示
static String lowTier(const Low& l) { return l.id + "|" + l.label + "|" + (l.left <= 0 ? "0" : l.left <= 5 ? "5" : "x"); }
static void updateLow(const State& s) {
  if (!s.valid) return;
  std::vector<String> now;
  for (auto& l : s.lows) now.push_back(lowTier(l));
  for (size_t i = 0; i < gLowSeen.size();) {          // 恢复了的就忘掉，以后再掉下来还会提醒
    bool keep = false;
    for (auto& k : now) if (k == gLowSeen[i]) keep = true;
    if (keep) i++; else gLowSeen.erase(gLowSeen.begin() + i);
  }
  for (auto& k : now) {
    bool seen = false;
    for (auto& x : gLowSeen) if (x == k) seen = true;
    if (!seen) { gLowSeen.push_back(k); gLowAt = millis() | 1; }
  }
  if (gLowAt && millis() - gLowAt > 60000) gLowAt = 0;
}

// ---------- 当前该显示什么 ----------
static Mode computeMode(const State& s, const Cfg& c) {
  if (gOta >= 0) return M_UPDATING;
  if (gOta == -2 && millis() - gOtaFailAt < 6000) return M_UPDATING;
  if (gDemo) {
    if (gDemoMode == "setup") return M_SETUP;
    if (gDemoMode == "nolink") return M_NOLINK;
    if (gDemoMode == "connecting") return M_CONNECTING;
    if (gDemoOff || !s.valid) return gDemoRest ? M_REST : M_OFF;
  } else {
    if (netPortal() || !netHasWifi()) return M_SETUP;
    if (WiFi.status() != WL_CONNECTED) return M_CONNECTING;
    if (!netHasToken()) return M_NOLINK;
    if (!gOnline || !s.valid) return (s.valid && s.rest) ? M_REST : M_OFF;
  }
  if (gFlashId.length()) return M_ASK;
  if (gLowAt && !s.lows.empty() && !s.rest) return M_LOW;
  if (s.rest) return M_REST;
  if (!s.ok) return M_STALE;
  return M_CALM;
}

static void onTap(int x, int y, const State& s, const Cfg& c, Mode m) {
  bodyNoteActivity();
  if (m == M_SETUP || m == M_NOLINK || m == M_CONNECTING || m == M_OFF || m == M_UPDATING) return;
  if (m == M_ASK) { collapseFlash(c); return; }
  if (m == M_LOW && gPage == P_FACE) { gLowAt = 0; return; }
  if (gPage == P_FACE) {               // 脸上：点某一家 → 它的明细，点别处 → 全部额度（位置跟着首页样式走）
    String id;
    if (uiFaceHit(s, c, x, y, id)) { gDetailId = id; gDetailFrom = P_FACE; gPage = P_DETAIL; }
    else gPage = P_LIST;
  } else if (gPage == P_LIST) {        // 全部额度：点某一家 → 它的明细；点顶部标题栏 → 回首页；点空白处不动
    int i = uiListHit(s, c, x, y);
    if (i >= 0) { gDetailId = s.subs[i].id; gDetailFrom = P_LIST; gPage = P_DETAIL; }
    else if (i == -2) gPage = P_FACE;
  } else gPage = gDetailFrom;          // 明细：点哪里都回上一页
}
static void onHold(int x, int y, const State& s, const Cfg& c, Mode m) {
  if (gPage == P_LIST && m != M_ASK) onTap(x, y, s, c, m);   // 全部额度里按住某一家 = 点它
  else bodyNoteActivity();
}
// 有 AI 在等你（灯亮着）时摸头：整屏收起，灯和右上角的小 logo 一起熄掉，开心地晃一下表示收到
static void clearWaiting(const Cfg& c) {
  xSemaphoreTake(gMux, portMAX_DELAY);
  if (!gDemo) for (auto& w : gState.waiting) { gClearIds.push_back(w.id); gClearSend.push_back(w.id); }
  gState.waiting.clear();
  xSemaphoreGive(gMux);
  gFlashId = "";
  gPage = P_FACE; gHappyUntil = millis() + 1300; bodyDo("wiggle", c);
}
static void onPat(const State& s, const Cfg& c, Mode m) {
  bodyNoteActivity();
  if (m == M_ASK) { clearWaiting(c); return; }          // 整屏提醒时摸头：收起并熄灯
  if (m == M_LOW && gPage == P_FACE) { gLowAt = 0; return; }
  if (!s.waiting.empty()) { clearWaiting(c); return; }  // 灯还亮着：熄掉
  if (m != M_CALM && m != M_STALE && m != M_LOW) return;
  if (gPage != P_FACE && c.touch != 2) { gPage = gPage == P_DETAIL ? gDetailFrom : P_FACE; return; }   // 全部额度、明细：摸头 = 返回
  if (c.touch == 0) { gPage = P_FACE; gHappyUntil = millis() + 1300; bodyDo("wiggle", c); }   // 开心一下
  else if (c.touch == 1) gPage = P_LIST;     // 首页摸头 → 全部额度（再摸一下回来）
}

static void applyBrightness(const Cfg& c, Mode m) {
  int b = c.bright;
  if (c.quiet || m == M_REST) b = c.qBright;
  else if (m == M_CALM && gPage == P_FACE && c.dimAfter > 0 && millis() - bodyLastActivity() > (uint32_t)c.dimAfter * 60000) b = std::min(b, 25);
  static int shown = -1;
  int v = 6 + constrain(b, 0, 100) * 249 / 100;
  if (v != shown) { shown = v; M5.Display.setBrightness(v); }
}

// ---------- 串口命令 ----------
static const char DEMO_JSON[] PROGMEM = R"JSON({"ok":true,"time":"16:27","data_time":"16:27","now":1000,"face":["claude","codex","antigravity"],"subs":[
{"id":"codex","icon":"demo","name":"Codex","mono":"CX","hue":"#7c9cff","left":98,"label":"本月","level":"ok","reset":"12月1日重置","windows":[{"label":"5小时","left":100,"level":"ok","reset":"","pace":"","mins":300},{"label":"本月","left":98,"level":"ok","reset":"12月1日重置","pace":"","mins":43200}]},
{"id":"claude","icon":"demo","name":"Claude","mono":"CL","hue":"#e08a63","left":74,"label":"5小时","level":"ok","reset":"17:30 恢复","windows":[{"label":"5小时","left":74,"level":"ok","reset":"17:30 恢复","pace":"","mins":300},{"label":"本周","left":93,"level":"ok","reset":"周四重置","pace":"","mins":10080},{"label":"Fable 本周","left":95,"level":"ok","reset":"周四重置","pace":"","mins":10080}]},
{"id":"cursor","icon":"demo","name":"Cursor","mono":"CU","hue":"#cfd4dc","left":98,"label":"本周","level":"ok","reset":"周日重置","windows":[{"label":"本周","left":98,"level":"ok","reset":"周日重置","pace":"","mins":10080}]},
{"id":"opencodego","icon":"demo","name":"OpenCode Go","mono":"OC","hue":"#5fd3bc","left":71,"label":"本月","level":"ok","reset":"12月7日重置","windows":[{"label":"5小时","left":100,"level":"ok","reset":"17:54 恢复","pace":"","mins":300},{"label":"本周","left":85,"level":"ok","reset":"周一重置","pace":"","mins":10080},{"label":"本月","left":71,"level":"ok","reset":"12月7日重置","pace":"照现在的速度 7 天后用完","mins":43200}]},
{"id":"antigravity","icon":"demo","name":"Antigravity","mono":"AG","hue":"#b28cff","left":63,"label":"Gemini 本周","level":"ok","reset":"周六重置","windows":[{"label":"Gemini 5小时","left":83,"level":"ok","reset":"16:20 恢复","pace":"","mins":300},{"label":"Gemini 本周","left":63,"level":"ok","reset":"周六重置","pace":"","mins":10080},{"label":"Claude/GPT 5小时","left":100,"level":"ok","reset":"20:18 恢复","pace":"","mins":300},{"label":"Claude/GPT 本周","left":73,"level":"ok","reset":"周日重置","pace":"","mins":10080}]}
],"lows":[],"waiting":[]})JSON";

static void demo(const String& kind) {
  State s;
  parseState(String(FPSTR(DEMO_JSON)), s);
  gDemoOff = gDemoRest = false;
  gDemoMode = kind;
  auto wait = [&](const char* agent, const char* proj, const char* k, const char* t) {
    Wait w; w.id = String("d-") + k; w.agent = agent; w.project = proj; w.kind = k; w.text = t; w.since = 958;
    String ag = agent;
    w.iconId = ag == "Claude Code" ? "claude" : ag == "Codex" ? "codex" : ag == "Cursor" ? "cursor" : "";
    w.mono = ag == "Claude Code" ? "CL" : ag == "Codex" ? "CX" : ag == "Cursor" ? "CU" : "";
    w.iconV = w.iconId.length() ? "demo" : "";
    s.waiting.push_back(w);
  };
  if (kind == "approval") wait("Claude Code", "aihelper", "approval", "需要你批准：Bash");
  else if (kind == "done") wait("Codex", "另一个项目", "done", "做完了，等你看结果");
  else if (kind == "question") wait("Claude Code", "aihelper", "question", "有问题要问你");
  else if (kind == "error") wait("Cursor", "网站改版", "error", "出错停下了");
  else if (kind == "waiting") { wait("Claude Code", "aihelper", "approval", "需要你批准：Bash"); s.waiting[0].acked = true; }
  else if (kind == "low") {
    Low l; l.id = "antigravity"; l.name = "Antigravity"; l.label = "Gemini 5小时"; l.left = 8; l.reset = "16:20 恢复"; s.lows.push_back(l);
    Sub& a = s.subs[4]; a.left = 8; a.label = "Gemini 5小时"; a.level = "low"; a.wins[0].left = 8; a.wins[0].level = "low";
  }
  else if (kind == "stale") s.ok = false;
  else if (kind == "off") gDemoOff = true;
  else if (kind == "rest") { gDemoOff = true; gDemoRest = true; }
  // 演示数据跟着语言换（真实使用时这些文字由小管家按语言生成）
  String lang = gCfg.lang;
  if (lang == "ja" || lang == "en") {
    const char* zh[] = {"5小时", "本周", "本月", "周四重置", "周六重置", "周日重置", "周一重置", "17:30 恢复", "16:20 恢复", "20:18 恢复", "17:54 恢复", "12月1日重置", "12月7日重置", "另一个项目", "网站改版"};
    const char* ja[] = {"5時間", "今週", "今月", "木曜リセット", "土曜リセット", "日曜リセット", "月曜リセット", "17:30 回復", "16:20 回復", "20:18 回復", "17:54 回復", "12月1日リセット", "12月7日リセット", "別のプロジェクト", "サイト改修"};
    const char* en[] = {"5h", "Week", "Month", "resets Thu", "resets Sat", "resets Sun", "resets Mon", "back 17:30", "back 16:20", "back 20:18", "back 17:54", "resets Dec 1", "resets Dec 7", "other-project", "website"};
    const char** to = lang == "ja" ? ja : en;
    auto tr2 = [&](String& x) { for (int i = 0; i < 15; i++) x.replace(zh[i], to[i]); };
    for (auto& b : s.subs) { tr2(b.label); tr2(b.reset); for (auto& w : b.wins) { tr2(w.label); tr2(w.reset); } }
    for (auto& w : s.waiting) tr2(w.project);
    for (auto& l : s.lows) { tr2(l.label); tr2(l.reset); }
  }
  gLowSeen.clear(); gLowAt = 0;
  xSemaphoreTake(gMux, portMAX_DELAY);
  gState = s; gFetchedAt = millis();
  xSemaphoreGive(gMux);
  gDemo = true;
}

static void dumpShot() {
  Serial.printf("SHOT %d %d\n", (int)cv.width(), (int)cv.height());
  for (int y = 0; y < cv.height(); y++) {
    String line;
    line.reserve(600);
    uint16_t prev = cv.readPixel(0, y);
    int run = 1;
    char b[32];
    for (int x = 1; x < cv.width(); x++) {
      uint16_t c = cv.readPixel(x, y);
      if (c == prev) run++;
      else { snprintf(b, sizeof b, "%04x*%d ", prev, run); line += b; prev = c; run = 1; }
    }
    snprintf(b, sizeof b, "%04x*%d", prev, run);
    line += b;
    Serial.println(line);
    Serial.flush();
  }
  Serial.println("END");
}

static void handleSerial() {
  static String buf;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\r') continue;
    if (ch != '\n') { if (buf.length() < 700) buf += ch; continue; }
    String cmd = buf; buf = ""; cmd.trim();
    if (!cmd.length()) continue;
    xSemaphoreTake(gMux, portMAX_DELAY);
    Cfg c = gCfg;
    xSemaphoreGive(gMux);
    if (netSerial(cmd)) continue;
    if (battSerial(cmd)) continue;
    if (cmd == "shot") dumpShot();
    else if (cmd.startsWith("demo ")) { String k = cmd.substring(5); if (k == "exit") gDemo = false; else demo(k); Serial.println("OK demo " + k); }
    else if (cmd.startsWith("set ")) {      // 开发调试：临时改设置，比如 set {"theme":"light"}
      JsonDocument d;
      if (deserializeJson(d, cmd.substring(4))) { Serial.println("ERR json"); continue; }
      xSemaphoreTake(gMux, portMAX_DELAY);
      parseCfg(d.as<JsonVariantConst>(), gCfg);
      xSemaphoreGive(gMux);
      Serial.println("OK");
    }
    else if (cmd == "page face") { gPage = P_FACE; gLastTouch = millis(); Serial.println("OK"); }
    else if (cmd == "page list") { gPage = P_LIST; gLastTouch = millis(); Serial.println("OK"); }
    else if (cmd.startsWith("page detail ")) { gDetailId = cmd.substring(12); gDetailFrom = P_FACE; gPage = P_DETAIL; gLastTouch = millis(); Serial.println("OK"); }
    else if (cmd == "pat") { gSimTap = 3; Serial.println("OK"); }                     // 模拟摸头
    else if (cmd.startsWith("tap ") || cmd.startsWith("hold ")) {                   // 模拟点屏幕：tap 160 200 / hold 160 120
      int sp = cmd.indexOf(' '), sp2 = cmd.indexOf(' ', sp + 1);
      gSimX = cmd.substring(sp + 1, sp2).toInt(); gSimY = cmd.substring(sp2 + 1).toInt();
      gSimTap = cmd.startsWith("tap") ? 1 : 2; Serial.println("OK");
    }
    else if (cmd == "icons off" || cmd == "icons on") { gNoIcons = cmd == "icons off"; Serial.println("OK"); }   // 截公开截图时只画字母方块
    else if (cmd == "info") Serial.printf("INFO fw=%s %s demo=%d heap=%u psram=%u rev=%d\n", FW_VERSION, netInfo().c_str(), (int)gDemo, (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getFreePsram(), c.rev);
    else if (cmd == "body") {
      auto in = M5StackChan.TouchSensor.getIntensities();
      Batt b = battGet();
      Serial.printf("BODY yaw=%d pitch=%d moving=%d touch=%d,%d,%d batt=%.2fV %.3fA pct=%d power=%d\n",
        M5StackChan.Motion.getCurrentYawAngle(), M5StackChan.Motion.getCurrentPitchAngle(), (int)M5StackChan.Motion.isMoving(),
        in[0], in[1], in[2], M5StackChan.getBatteryVoltage(), M5StackChan.getBatteryCurrent(), b.pct, (int)b.power);
    }
    else if (cmd == "nod" || cmd == "shake" || cmd == "droop" || cmd == "idle" || cmd == "chime" || cmd == "find") { bodyDo(cmd, c); Serial.println("OK"); }
    else if (cmd == "ota fail") { gOta = -2; gOtaFailAt = millis(); Serial.println("OK"); }
    else if (cmd == "ota show") { gOta = 37; Serial.println("OK"); }
    else if (cmd == "ota hide") { gOta = -1; Serial.println("OK"); }
    else if (cmd == "reboot") { ESP.restart(); }
    else Serial.println("? " + cmd);
  }
}

// ---------- 启动 ----------
void setup() {
  M5StackChan.begin();                                  // 屏幕、舵机电源、彩灯、头顶触摸一起初始化
  M5StackChan.Motion.setAutoTorqueReleaseEnabled(true); // 停下来以后舵机松劲，不会一直嗡嗡响
  M5StackChan.showRgbColor(0, 0, 0);
  Serial.begin(115200);
  M5.Display.setBrightness(160);
  uiBegin();
  if (esp_reset_reason() == ESP_RST_SW) gLastCmd = gLastCmdKept; else gLastCmdKept = 0;
  netBegin();
  bodyNoteActivity();
}

void loop() {
  M5StackChan.update();
  battUpdate();
  netLoop();
  handleSerial();

  xSemaphoreTake(gMux, portMAX_DELAY);
  State s = gState;
  Cfg c = gCfg;
  xSemaphoreGive(gMux);

  // 小管家发来的一次性命令
  if (!gDemo && s.cmdId && s.cmdId != gLastCmd) {
    gLastCmd = gLastCmdKept = s.cmdId;
    if (s.cmd == "reboot") { delay(100); ESP.restart(); }
    else if (s.cmd == "ota") netRequestOta();
    else bodyDo(s.cmd, c);
  }
  if (gOta == -2 && !gOtaFailAt) gOtaFailAt = millis();
  if (gOta == -2 && millis() - gOtaFailAt > 6000) { gOta = -1; gOtaFailAt = 0; }

  updateFlash(s, c);
  updateLow(s);
  Mode m = computeMode(s, c);
  auto t = M5.Touch.getDetail();
  bool touched = false;
  if (t.wasClicked() || gSimTap == 1) { onTap(gSimTap ? gSimX : t.x, gSimTap ? gSimY : t.y, s, c, m); touched = true; }
  else if (t.wasHold() || gSimTap == 2) { onHold(gSimTap ? gSimX : t.x, gSimTap ? gSimY : t.y, s, c, m); touched = true; }
  if (M5StackChan.TouchSensor.wasPressed() || gSimTap == 3) { onPat(s, c, m); touched = true; }
  gSimTap = 0;
  if (touched) {          // 收起提醒以后立刻生效
    gLastTouch = millis();
    xSemaphoreTake(gMux, portMAX_DELAY);
    s = gState;
    xSemaphoreGive(gMux);
    m = computeMode(s, c);
  }
  if (gPage != P_FACE && millis() - gLastTouch > BACK_TO_FACE_MS) gPage = P_FACE;

  UiCtx u;
  u.page = gPage;
  u.detailId = gDetailId;
  u.otaProgress = gOta;
  u.ssid = netSsid();
  u.flashId = gFlashId;
  u.reminder = gFlashReminder;
  u.happy = millis() < gHappyUntil;
  Batt bt = battGet();
  u.batt = bt.pct;
  u.power = bt.power;
  if (gFlashId.length() && c.alertSecs > 0) u.flashLeft = 1.0f - std::min(1.0f, (millis() - gFlashAt) / (c.alertSecs * 1000.0f));
  if (const Wait* w = findWait(s, gFlashId)) {
    uint32_t base = s.now > w->since ? s.now - w->since : 0;
    u.waited = base + (gDemo ? 0 : (millis() - gFetchedAt) / 1000);
  }
  uiRender(s, c, m, u);
  bodyUpdate(s, c, m, gFlashSeq);
  applyBrightness(c, m);
  delay(30);
}
