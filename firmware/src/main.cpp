// aihelper 固件 2.0：StackChan（CoreS3）
// 连 WiFi、每 2 秒向 Mac 上的小管家要一次状态、按设置画到屏幕上；
// 有 AI 在等你时：整屏变色、点头、亮灯、响一声；摸头或点屏幕表示「知道了」。
// 各部分：ui.cpp 画面，body.cpp 头/灯/声音，net.cpp 联网和配置。
#include "app.h"
#include <WiFi.h>

static Page gPage = P_FACE;
static String gDetailId, gAckedLow;
static bool gDemoOff = false, gDemoRest = false;
static String gDemoMode;
static int gLastCmd = 0;
RTC_NOINIT_ATTR static int gLastCmdKept;   // 软重启后还记得做过的命令，避免 reboot 命令反复执行
static uint32_t gOtaFailAt = 0;

static String lowKey(const State& s) {
  String k;
  for (auto& l : s.lows) k += l.id + l.label + "|";
  return k;
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
  bool hide = (c.quiet || s.rest) && !c.qFace;      // 勿扰时不变脸
  for (auto& w : s.waiting) if (!w.acked && !hide) return M_ASK;
  if (!s.lows.empty() && lowKey(s) != gAckedLow && !s.rest) return M_LOW;
  if (s.rest) return M_REST;
  if (!s.ok) return M_STALE;
  return M_CALM;
}

static void ackAll() {
  xSemaphoreTake(gMux, portMAX_DELAY);
  for (auto& w : gState.waiting) w.acked = true;
  xSemaphoreGive(gMux);
  if (!gDemo) gAckPending = true;
}

static void onTap(int y, const State& s, Mode m) {
  bodyNoteActivity();
  if (m == M_SETUP || m == M_NOLINK || m == M_CONNECTING || m == M_OFF || m == M_UPDATING) return;
  if (m == M_ASK) { ackAll(); return; }
  if (m == M_LOW && gPage == P_FACE) { gAckedLow = lowKey(s); return; }
  if (gPage == P_FACE) gPage = P_LIST;
  else if (gPage == P_LIST) {
    int i = uiListHit(s, y);
    if (i >= 0) { gDetailId = s.subs[i].id; gPage = P_DETAIL; }
    else gPage = P_FACE;
  } else gPage = P_LIST;
}

static void onPat(const State& s, const Cfg& c, Mode m) {
  bodyNoteActivity();
  if (c.touch == 2) return;
  if (m == M_ASK) { ackAll(); return; }
  if (m == M_LOW && gPage == P_FACE) { gAckedLow = lowKey(s); return; }
  if (c.touch == 1 && (m == M_CALM || m == M_STALE)) gPage = gPage == P_FACE ? P_LIST : P_FACE;
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
{"id":"codex","icon":"demo","name":"Codex","mono":"CX","hue":"#7c9cff","left":98,"label":"本月","level":"ok","reset":"12月1日重置","windows":[{"label":"5小时","left":100,"level":"ok","reset":"","pace":""},{"label":"本月","left":98,"level":"ok","reset":"12月1日重置","pace":""}]},
{"id":"claude","icon":"demo","name":"Claude","mono":"CL","hue":"#e08a63","left":74,"label":"5小时","level":"ok","reset":"17:30 恢复","windows":[{"label":"5小时","left":74,"level":"ok","reset":"17:30 恢复","pace":""},{"label":"本周","left":93,"level":"ok","reset":"周四重置","pace":""},{"label":"Fable 本周","left":95,"level":"ok","reset":"周四重置","pace":""}]},
{"id":"cursor","icon":"demo","name":"Cursor","mono":"CU","hue":"#cfd4dc","left":98,"label":"本周","level":"ok","reset":"周日重置","windows":[{"label":"本周","left":98,"level":"ok","reset":"周日重置","pace":""}]},
{"id":"opencodego","icon":"demo","name":"OpenCode Go","mono":"OC","hue":"#5fd3bc","left":71,"label":"本月","level":"ok","reset":"12月7日重置","windows":[{"label":"5小时","left":100,"level":"ok","reset":"17:54 恢复","pace":""},{"label":"本周","left":85,"level":"ok","reset":"周一重置","pace":""},{"label":"本月","left":71,"level":"ok","reset":"12月7日重置","pace":"照现在的速度 7 天后用完"}]},
{"id":"antigravity","icon":"demo","name":"Antigravity","mono":"AG","hue":"#b28cff","left":63,"label":"Gemini 本周","level":"ok","reset":"周六重置","windows":[{"label":"Gemini 5小时","left":83,"level":"ok","reset":"16:20 恢复","pace":""},{"label":"Gemini 本周","left":63,"level":"ok","reset":"周六重置","pace":""},{"label":"Claude/GPT 5小时","left":100,"level":"ok","reset":"20:18 恢复","pace":""},{"label":"Claude/GPT 本周","left":73,"level":"ok","reset":"周日重置","pace":""}]}
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
  gAckedLow = "";
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
    else if (cmd == "page face") { gPage = P_FACE; Serial.println("OK"); }
    else if (cmd == "page list") { gPage = P_LIST; Serial.println("OK"); }
    else if (cmd.startsWith("page detail ")) { gDetailId = cmd.substring(12); gPage = P_DETAIL; Serial.println("OK"); }
    else if (cmd == "info") Serial.printf("INFO fw=%s %s demo=%d heap=%u psram=%u rev=%d\n", FW_VERSION, netInfo().c_str(), (int)gDemo, (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getFreePsram(), c.rev);
    else if (cmd == "body") {
      auto in = M5StackChan.TouchSensor.getIntensities();
      Serial.printf("BODY yaw=%d pitch=%d moving=%d touch=%d,%d,%d batt=%.2fV\n",
        M5StackChan.Motion.getCurrentYawAngle(), M5StackChan.Motion.getCurrentPitchAngle(), (int)M5StackChan.Motion.isMoving(),
        in[0], in[1], in[2], M5StackChan.getBatteryVoltage());
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

  Mode m = computeMode(s, c);
  auto t = M5.Touch.getDetail();
  bool touched = false;
  if (t.wasClicked()) { onTap(t.y, s, m); touched = true; }
  if (M5StackChan.TouchSensor.wasPressed()) { onPat(s, c, m); touched = true; }
  if (touched) {          // 「知道了」以后立刻生效
    xSemaphoreTake(gMux, portMAX_DELAY);
    s = gState;
    xSemaphoreGive(gMux);
    m = computeMode(s, c);
  }

  UiCtx u;
  u.page = gPage;
  u.detailId = gDetailId;
  u.otaProgress = gOta;
  u.ssid = netSsid();
  for (auto& w : s.waiting) if (!w.acked) {
    uint32_t base = s.now > w.since ? s.now - w.since : 0;
    u.waited = base + (gDemo ? 0 : (millis() - gFetchedAt) / 1000);
    break;
  }
  uiRender(s, c, m, u);
  bodyUpdate(s, c, m);
  applyBrightness(c, m);
  delay(30);
}
