// aihelper 固件第一版：StackChan（CoreS3）
// 做三件事：连 WiFi、每 2 秒向 Mac 上的小管家要一次状态、按「A 表情优先」画到屏幕上。
// 有提醒时：转头点头、彩灯变色、响一声；摸头或点屏幕表示「知道了」。
#include <M5Unified.h>
#include <M5StackChan.h>   // 官方驱动库：舵机、彩灯、头顶触摸
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include <ArduinoJson.h>
#include <vector>
#include "build_config.h"

// ---------- 颜色（和原型页一致） ----------
static inline uint16_t C(uint32_t rgb) { return lgfx::color565((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF); }
#define C_BG     C(0x0b0e13)
#define C_WHITE  C(0xf2f5f8)
#define C_TEXT   C(0xe9edf2)
#define C_DIM    C(0x8b95a3)
#define C_SOFT   C(0xb9c1cc)
#define C_LINE   C(0x1c222b)
#define C_BARBG  C(0x252c37)
#define C_OK     C(0x3ddc84)
#define C_MID    C(0xf5c542)
#define C_LOW    C(0xff5d5d)
#define C_NA     C(0x59636f)
#define C_ATTN   C(0xffb020)
#define C_ATTN_T C(0x1b1300)
#define C_BAD_T  C(0x200505)
#define C_MUTE   C(0x39424e)
#define C_SWEAT  C(0x6ec1ff)

#define F_CN12  &fonts::efontCN_12
#define F_CN14  &fonts::efontCN_14
#define F_CN16  &fonts::efontCN_16
#define F_CN16B &fonts::efontCN_16_b
#define F_CN24B &fonts::efontCN_24_b
#define F_N12   &fonts::DejaVu12
#define F_N18   &fonts::DejaVu18
#define F_N24   &fonts::DejaVu24

static const char* AP_NAME = "StackChan-Setup";

// ---------- 状态 ----------
struct Win  { String label, level, reset, pace; int left = 0; };
struct Sub  { String id, name, mono, label, level, reset, error; uint16_t hue = 0xFFFF; int left = -1; bool stale = false; std::vector<Win> wins; };
struct Wait { String id, agent, project, kind, text; uint32_t since = 0; bool acked = false; };
struct Low  { String id, name, label, reset; int left = 0; };
struct State {
  bool valid = false, ok = false;
  String time, dataTime;
  uint32_t now = 0;
  std::vector<Sub> subs;
  std::vector<Wait> waiting;
  std::vector<Low> lows;
};

enum Mode { M_SETUP, M_CONNECTING, M_OFF, M_ASK, M_LOW, M_STALE, M_CALM };
enum Page { P_FACE, P_LIST, P_DETAIL };

static M5Canvas cv(&M5.Display);
static WiFiManager wm;
static SemaphoreHandle_t gMux;
static State gState;                 // 最近一次从小管家拿到的状态（受 gMux 保护）
static volatile bool gOnline = false;
static volatile uint32_t gFetchedAt = 0;
static volatile bool gAckPending = false;
static bool gDemo = false, gDemoOff = false;
static Page gPage = P_FACE;
static String gDetailId, gAckedLow, gLastInfo;
static IPAddress gBridgeIp;

// ---------- 小工具 ----------
static uint16_t hexColor(const char* s) {
  if (!s || s[0] != '#' || strlen(s) < 7) return C(0xaab2bd);
  return C((uint32_t)strtoul(s + 1, nullptr, 16));
}
static uint16_t lvColor(const String& lv) {
  if (lv == "ok") return C_OK;
  if (lv == "mid") return C_MID;
  if (lv == "low") return C_LOW;
  return C_NA;
}
// 文字太长就从末尾按「整个字」截掉，补省略号
static String fit(const String& s, int maxW) {
  if (cv.textWidth(s) <= maxW) return s;
  String t = s;
  while (t.length() > 0) {
    int i = t.length() - 1;
    while (i > 0 && (((uint8_t)t[i]) & 0xC0) == 0x80) i--;
    t.remove(i);
    if (cv.textWidth(t + "…") <= maxW) return t + "…";
  }
  return "";
}
static void text(const String& s, int x, int y, const lgfx::IFont* f, uint16_t col, textdatum_t d = textdatum_t::top_left) {
  cv.setFont(f);
  cv.setTextColor(col);
  cv.setTextDatum(d);
  cv.drawString(s, x, y);
}
static void thickLine(int x0, int y0, int x1, int y1, int w, uint16_t col) {
  float dx = x1 - x0, dy = y1 - y0, len = sqrtf(dx * dx + dy * dy);
  if (len < 1) return;
  float nx = -dy / len * w / 2, ny = dx / len * w / 2;
  cv.fillTriangle(x0 + nx, y0 + ny, x0 - nx, y0 - ny, x1 + nx, y1 + ny, col);
  cv.fillTriangle(x1 + nx, y1 + ny, x1 - nx, y1 - ny, x0 - nx, y0 - ny, col);
}
static String lowKey(const State& s) {
  String k;
  for (auto& l : s.lows) k += l.id + l.label + "|";
  return k;
}

// ---------- 解析小管家的 /state ----------
static bool parseState(const String& body, State& s) {
  JsonDocument doc;
  if (deserializeJson(doc, body)) return false;
  s = State();
  s.valid = true;
  s.ok = doc["ok"] | false;
  s.time = (const char*)(doc["time"] | "");
  s.dataTime = (const char*)(doc["data_time"] | "");
  s.now = doc["now"] | 0;
  JsonArray subsArr = doc["subs"], waitArr = doc["waiting"], lowArr = doc["lows"];
  for (JsonObject o : subsArr) {
    Sub b;
    b.id = (const char*)(o["id"] | "");
    b.name = (const char*)(o["name"] | "");
    b.mono = (const char*)(o["mono"] | "");
    b.label = (const char*)(o["label"] | "");
    b.level = (const char*)(o["level"] | "na");
    b.reset = (const char*)(o["reset"] | "");
    b.error = (const char*)(o["error"] | "");
    b.hue = hexColor(o["hue"] | "#aab2bd");
    b.left = o["left"].isNull() ? -1 : o["left"].as<int>();
    b.stale = o["stale"] | false;
    JsonArray winArr = o["windows"];
    for (JsonObject w : winArr) {
      Win x;
      x.label = (const char*)(w["label"] | "");
      x.level = (const char*)(w["level"] | "na");
      x.reset = (const char*)(w["reset"] | "");
      x.pace = (const char*)(w["pace"] | "");
      x.left = w["left"] | 0;
      b.wins.push_back(x);
    }
    s.subs.push_back(b);
  }
  for (JsonObject o : waitArr) {
    Wait w;
    w.id = (const char*)(o["id"] | "");
    w.agent = (const char*)(o["agent"] | "AI");
    w.project = (const char*)(o["project"] | "");
    w.kind = (const char*)(o["kind"] | "done");
    w.text = (const char*)(o["text"] | "");
    w.since = (uint32_t)(o["since"] | 0.0);
    w.acked = o["acked"] | false;
    s.waiting.push_back(w);
  }
  for (JsonObject o : lowArr) {
    Low l;
    l.id = (const char*)(o["id"] | "");
    l.name = (const char*)(o["name"] | "");
    l.label = (const char*)(o["label"] | "");
    l.reset = (const char*)(o["reset"] | "");
    l.left = o["left"] | 0;
    s.lows.push_back(l);
  }
  return true;
}

// ---------- 画面：脸 ----------
// expr: calm 平时 / done 做完了 / alert 要你批准或提问 / worry 额度快用完 / sleep 连不上
static void drawFace(int top, const char* expr, const char* mark) {
  String e = expr;
  bool blink = (millis() % 4600) > 4460;
  if (e == "alert") {
    cv.fillCircle(107, top + 57, 15, C_WHITE);
    cv.fillCircle(213, top + 57, 15, C_WHITE);
    cv.fillCircle(160, top + 110, 10, C_WHITE);
    cv.fillCircle(160, top + 110, 6, C_BG);
  } else if (e == "done") {
    cv.fillArc(107, top + 64, 13, 18, 215, 325, C_WHITE);
    cv.fillArc(213, top + 64, 13, 18, 215, 325, C_WHITE);
    cv.fillArc(160, top + 96, 21, 26, 45, 135, C_WHITE);
  } else if (e == "sleep") {
    cv.fillRoundRect(94, top + 56, 26, 4, 2, C_WHITE);
    cv.fillRoundRect(200, top + 56, 26, 4, 2, C_WHITE);
    cv.fillRoundRect(152, top + 108, 16, 5, 2, C_WHITE);
    text("z z", 236, top + 14, F_N18, C_DIM);
  } else {
    if (blink) {
      cv.fillRoundRect(96, top + 55, 22, 4, 2, C_WHITE);
      cv.fillRoundRect(202, top + 55, 22, 4, 2, C_WHITE);
    } else {
      cv.fillCircle(107, top + 57, 11, C_WHITE);
      cv.fillCircle(213, top + 57, 11, C_WHITE);
    }
    if (e == "worry") {
      thickLine(143, top + 114, 177, top + 108, 5, C_WHITE);
      cv.fillTriangle(249, top + 24, 244, top + 36, 254, top + 36, C_SWEAT);
      cv.fillCircle(249, top + 38, 5, C_SWEAT);
    } else {
      cv.fillRoundRect(132, top + 108, 56, 5, 2, C_WHITE);
    }
  }
  if (mark && mark[0]) text(mark, 252, top + 16, F_N24, C_ATTN, textdatum_t::top_center);
}

static void drawBubble(uint16_t bb, uint16_t bt, const String& title, const String& sub) {
  cv.fillRoundRect(8, 6, 304, 60, 12, bb);
  cv.fillTriangle(152, 65, 168, 65, 160, 73, bb);
  cv.setFont(F_CN24B);
  text(fit(title, 284), 18, 9, F_CN24B, bt);
  cv.setFont(F_CN16);
  text(fit(sub, 284), 18, 39, F_CN16, bt);
}

static void drawBadge(const State& s) {
  if (s.waiting.empty()) return;
  String t = String((int)s.waiting.size()) + " 个在等";
  cv.setFont(F_CN14);
  int w = cv.textWidth(t) + 30;
  cv.fillRoundRect(312 - w, 6, w, 24, 12, C(0x3a2a05));
  cv.fillCircle(312 - w + 12, 18, 4, C_ATTN);
  text(t, 312 - w + 22, 11, F_CN14, C(0xffcf6b));
}

// 底部额度条：每家一格，上面是缩写，中间是剩余百分比，下面是条
static void drawStrip(const State& s) {
  std::vector<const Sub*> v;
  for (auto& b : s.subs) v.push_back(&b);
  if (v.size() > 5) {      // 超过 5 家时显示最紧张的 5 家
    std::sort(v.begin(), v.end(), [](const Sub* a, const Sub* b) { return (a->left < 0 ? 101 : a->left) < (b->left < 0 ? 101 : b->left); });
    v.resize(5);
  }
  int n = v.size();
  if (!n) return;
  int cw = (300 - 8 * (n - 1)) / n;
  for (int i = 0; i < n; i++) {
    const Sub& b = *v[i];
    int x = 10 + i * (cw + 8);
    uint16_t col = (!s.ok || b.left < 0 || b.stale) ? C_NA : lvColor(b.level);
    text(b.mono, x, 180, F_N18, C_DIM);
    text(b.left < 0 ? String("--") : String(b.left), x, 200, F_N24, col);
    cv.fillRoundRect(x, 229, cw, 6, 3, C_BARBG);
    if (b.left > 0) cv.fillRoundRect(x, 229, max(4, cw * b.left / 100), 6, 3, col);
  }
}

static uint32_t waitedSecs(const State& s, const Wait& w) {
  uint32_t base = s.now > w.since ? s.now - w.since : 0;
  return base + (millis() - gFetchedAt) / 1000;
}

static const int FACE_TOP = 14, FACE_TOP_BUB = 55;   // 有气泡时脸往下挪

static void drawFacePage(const State& s, Mode m) {
  cv.fillScreen(C_BG);
  if (m == M_CONNECTING) {
    drawBubble(C_MUTE, C_TEXT, "正在连接 WiFi", "连上以后就去找 Mac");
    drawFace(FACE_TOP_BUB, "sleep", "");
    return;
  }
  if (m == M_OFF) {
    drawBubble(C_MUTE, C_TEXT, "连不上 Mac", "可能是 Mac 睡着了");
    drawFace(FACE_TOP_BUB, "sleep", "");
    if (s.valid) { State g = s; g.ok = false; drawStrip(g); }
    return;
  }
  if (m == M_ASK) {
    const Wait* w = nullptr;
    int un = 0;
    for (auto& x : s.waiting) if (!x.acked) { if (!w) w = &x; un++; }
    const char* expr = w->kind == "done" ? "done" : (w->kind == "error" ? "worry" : "alert");
    const char* mark = w->kind == "approval" ? "!" : (w->kind == "question" ? "?" : "");
    drawBubble(C_ATTN, C_ATTN_T, w->agent + " 等你回复", w->text + " · " + w->project);   // 原因在前，项目名太长时截掉的是项目名
    drawFace(FACE_TOP_BUB, expr, mark);
    uint32_t sec = waitedSecs(s, *w);
    char buf[48];
    snprintf(buf, sizeof buf, "已等 %u:%02u", (unsigned)(sec / 60), (unsigned)(sec % 60));
    String right = buf;
    if (un > 1) right += " · 还有 " + String(un - 1) + " 个";
    text("摸头 = 知道了", 12, 217, F_CN14, C_SOFT);
    text(right, 308, 217, F_CN14, C_SOFT, textdatum_t::top_right);
    return;
  }
  if (m == M_LOW) {
    const Low& l = s.lows[0];
    String sub = l.label + " 剩 " + String(l.left) + "%";
    if (l.reset.length()) sub += " · " + l.reset;
    drawBubble(C_LOW, C_BAD_T, l.name + " 快用完了", sub);
    drawFace(FACE_TOP_BUB, "worry", "");
    drawStrip(s);
    return;
  }
  if (m == M_STALE) {
    drawBubble(C_MUTE, C_TEXT, "额度没有更新", "数据停在 " + (s.dataTime.length() ? s.dataTime : String("很久以前")));
    drawFace(FACE_TOP_BUB, "sleep", "");
    drawStrip(s);
    return;
  }
  drawFace(FACE_TOP, "calm", "");
  drawBadge(s);
  drawStrip(s);
}

// ---------- 画面：明细列表、单个订阅 ----------
static void drawChip(const Sub& b, int x, int cy) {
  cv.fillRoundRect(x, cy - 13, 26, 26, 6, b.hue);
  text(b.mono, x + 13, cy - 6, F_N12, C_BG, textdatum_t::top_center);
}

static const int LIST_TOP = 36;
static int listRowH(const State& s) { int n = min((int)s.subs.size(), 6); return n ? (240 - LIST_TOP) / n : 204; }

static void drawList(const State& s) {
  cv.fillScreen(C_BG);
  text(s.time, 10, 5, F_N24, C(0xc9d0d9));
  if (!s.waiting.empty()) drawBadge(s);
  else if (s.ok) {
    cv.setFont(F_CN14);
    cv.fillCircle(310 - cv.textWidth("已同步") - 10, 18, 4, C_OK);
    text("已同步", 310, 11, F_CN14, C_DIM, textdatum_t::top_right);
  }
  else text("数据停在 " + s.dataTime, 310, 11, F_CN14, C_DIM, textdatum_t::top_right);
  int n = min((int)s.subs.size(), 6), h = listRowH(s);
  for (int i = 0; i < n; i++) {
    const Sub& b = s.subs[i];
    int y = LIST_TOP + i * h, cy = y + h / 2;
    uint16_t col = (!s.ok || b.left < 0 || b.stale) ? C_NA : lvColor(b.level);
    cv.drawFastHLine(10, y, 300, C_LINE);
    drawChip(b, 10, cy);
    cv.setFont(F_CN16);
    text(fit(b.name, 128), 44, cy - 17, F_CN16, C_TEXT);
    String sub = b.left < 0 ? (b.error.length() ? b.error : String("暂时读不到")) : b.label;
    cv.setFont(F_CN14);
    text(fit(sub, 128), 44, cy + 1, F_CN14, C_DIM);
    cv.fillRoundRect(180, cy - 4, 54, 8, 4, C_BARBG);
    if (b.left > 0) cv.fillRoundRect(180, cy - 4, max(4, 54 * b.left / 100), 8, 4, col);
    text(b.left < 0 ? String("--") : String(b.left) + "%", 310, cy - 12, F_N24, col, textdatum_t::top_right);
  }
}

static void drawDetail(const State& s, const Sub& b) {
  cv.fillScreen(C_BG);
  drawChip(b, 12, 19);
  text(b.name, 46, 8, F_CN16B, C_TEXT);
  text("点屏幕返回", 308, 12, F_CN12, C_DIM, textdatum_t::top_right);
  int n = min((int)b.wins.size(), 4);
  if (!n) { text(b.error.length() ? b.error : String("暂时读不到"), 12, 110, F_CN16, C_SOFT); return; }
  int h = 200 / n;
  for (int i = 0; i < n; i++) {
    const Win& w = b.wins[i];
    int y = 38 + i * h, top = y + h / 2 - 24;
    uint16_t col = (!s.ok || b.stale) ? C_NA : lvColor(w.level);
    cv.drawFastHLine(12, y, 296, C_LINE);
    if (n >= 4) {            // 窗口多的时候用紧凑排法：名称和恢复时间放同一行，下面一根条
      int t2 = y + (h - 40) / 2;
      cv.setFont(F_CN16);
      String lab = fit(w.label, 150);
      int lx = 12 + cv.textWidth(lab) + 10;
      text(lab, 12, t2 + 4, F_CN16, C_TEXT);
      cv.setFont(F_CN14);
      text(fit(w.reset, 238 - lx), lx, t2 + 6, F_CN14, C_DIM);
      text(String(w.left) + "%", 308, t2, F_N24, col, textdatum_t::top_right);
      cv.fillRoundRect(12, t2 + 30, 296, 8, 4, C_BARBG);
      if (w.left > 0) cv.fillRoundRect(12, t2 + 30, max(4, 296 * w.left / 100), 8, 4, col);
      continue;
    }
    cv.setFont(F_CN16);
    text(fit(w.label, 220), 12, top + 2, F_CN16, C_TEXT);
    text(String(w.left) + "%", 308, top - 2, F_N24, col, textdatum_t::top_right);
    cv.fillRoundRect(12, top + 24, 296, 8, 4, C_BARBG);
    if (w.left > 0) cv.fillRoundRect(12, top + 24, max(4, 296 * w.left / 100), 8, 4, col);
    String r = w.reset.length() ? w.reset : String("这个窗口还没用过");
    if (w.pace.length()) r += " · " + w.pace;
    cv.setFont(F_CN14);
    text(fit(r, 296), 12, top + 34, F_CN14, C_DIM);
  }
}

// ---------- 画面：第一次开机，配置 WiFi ----------
static void drawSetup() {
  cv.fillScreen(C_BG);
  text("先帮我连上 WiFi", 12, 8, F_CN24B, C_TEXT);
  cv.fillRoundRect(12, 44, 112, 112, 6, C_WHITE);
  cv.qrcode(String("WIFI:T:nopass;S:") + AP_NAME + ";;", 18, 50, 100);
  text("1 手机扫左边的码，", 136, 44, F_CN14, C_SOFT);
  text("  或连这个热点：", 136, 62, F_CN14, C_SOFT);
  text(AP_NAME, 136, 84, F_N12, C_ATTN);
  text("2 在弹出的页面里选", 136, 106, F_CN14, C_SOFT);
  text("  你家 WiFi 输密码", 136, 124, F_CN14, C_SOFT);
  text("3 保存，我自己连上", 136, 142, F_CN14, C_SOFT);
  text("没弹出页面就用浏览器打开 192.168.4.1", 12, 172, F_CN14, C_DIM);
  text("要用 2.4G WiFi，并和 Mac 在同一个网络", 12, 194, F_CN14, C_DIM);
}

// ---------- 当前该显示什么 ----------
static Mode computeMode(const State& s) {
  if (gDemo) {
    if (gDemoOff || !s.valid) return M_OFF;
  } else {
    if (wm.getConfigPortalActive()) return M_SETUP;
    if (WiFi.status() != WL_CONNECTED) return M_CONNECTING;
    if (!gOnline || !s.valid) return M_OFF;
  }
  for (auto& w : s.waiting) if (!w.acked) return M_ASK;
  if (!s.lows.empty() && lowKey(s) != gAckedLow) return M_LOW;
  if (!s.ok) return M_STALE;
  return M_CALM;
}

static void render(const State& s, Mode m) {
  if (m == M_SETUP) drawSetup();
  else if (m == M_CONNECTING || m == M_OFF || m == M_ASK || gPage == P_FACE) drawFacePage(s, m);
  else if (gPage == P_DETAIL) {
    const Sub* b = nullptr;
    for (auto& x : s.subs) if (x.id == gDetailId) b = &x;
    if (b) drawDetail(s, *b); else drawList(s);
  } else drawList(s);
  cv.pushSprite(0, 0);
}

static void onTap(int x, int y, State& s, Mode m) {
  if (m == M_SETUP || m == M_CONNECTING || m == M_OFF) return;
  if (m == M_ASK) {            // 「知道了」：先在本机标记，再告诉小管家
    for (auto& w : s.waiting) w.acked = true;
    if (!gDemo) gAckPending = true;
    return;
  }
  if (m == M_LOW && gPage == P_FACE) { gAckedLow = lowKey(s); return; }
  if (gPage == P_FACE) gPage = P_LIST;
  else if (gPage == P_LIST) {
    int n = min((int)s.subs.size(), 6), h = listRowH(s), i = (y - LIST_TOP) / h;
    if (y >= LIST_TOP && i >= 0 && i < n) { gDetailId = s.subs[i].id; gPage = P_DETAIL; }
    else gPage = P_FACE;
  } else gPage = P_LIST;
}

// ---------- 联网（独立任务，不卡画面） ----------
static bool resolveBridge() {
  IPAddress ip = MDNS.queryHost(BRIDGE_HOST, 1500);
  if (ip == IPAddress((uint32_t)0)) ip.fromString(BRIDGE_IP_HINT);
  gBridgeIp = ip;
  return ip != IPAddress((uint32_t)0);
}
static String bridgeUrl(const char* path) {
  return String("http://") + gBridgeIp.toString() + ":" + String(BRIDGE_PORT) + path + "?t=" + BRIDGE_TOKEN;
}
static void netTask(void*) {
  int fails = 0;
  for (;;) {
    if (gDemo || WiFi.status() != WL_CONNECTED) { vTaskDelay(pdMS_TO_TICKS(500)); continue; }
    if (gBridgeIp == IPAddress((uint32_t)0) || fails >= 5) { resolveBridge(); if (fails >= 5) fails = 3; }
    WiFiClient client;
    HTTPClient http;
    http.setConnectTimeout(1500);
    http.setTimeout(3000);
    if (gAckPending) {
      if (http.begin(client, bridgeUrl("/ack"))) {
        http.addHeader("Content-Type", "application/json");
        if (http.POST("{}") == 200) gAckPending = false;
        http.end();
      }
    }
    bool good = false;
    if (http.begin(client, bridgeUrl("/state"))) {
      int code = http.GET();
      if (code == 200) {
        String body = http.getString();
        State s;
        if (parseState(body, s)) {
          xSemaphoreTake(gMux, portMAX_DELAY);
          gState = s;
          gFetchedAt = millis();
          xSemaphoreGive(gMux);
          good = true;
        }
      }
      gLastInfo = "HTTP " + String(code);
      http.end();
    }
    if (good) { fails = 0; gOnline = true; }
    else if (++fails >= 3) gOnline = false;
    vTaskDelay(pdMS_TO_TICKS(good ? 2000 : 1500));
  }
}

// ---------- 身体：转头点头、彩灯、提示音 ----------
// 角度单位是 0.1 度。左右 yaw：0 是正前方；上下 pitch：0 最低，官方建议保持在 5~85 度之间。
struct Key { int yaw, pitch, speed; uint16_t ms; };
static const int PITCH_IDLE = 120;                      // 平时微微抬头 12 度
static const Key SEQ_NOD[]   = {{0, 300, 700, 300}, {0, 60, 700, 300}, {0, 220, 600, 260}, {0, PITCH_IDLE, 400, 0}};
static const Key SEQ_SHAKE[] = {{-180, PITCH_IDLE, 300, 700}, {180, PITCH_IDLE, 300, 1000}, {0, PITCH_IDLE, 300, 0}};
static const Key SEQ_DROOP[] = {{0, 50, 250, 0}};
static const Key SEQ_IDLE[]  = {{0, PITCH_IDLE, 300, 0}};
#define PLAY(seq) playSeq(seq, sizeof(seq) / sizeof(seq[0]))

static const Key* gSeq = nullptr;
static int gSeqLen = 0, gSeqIdx = 0;
static uint32_t gSeqNext = 0;
static bool gMotionOn = true, gSoundOn = true;
static String gLastAlertId;
static int gLastBody = -1;

static void playSeq(const Key* seq, int n) { gSeq = seq; gSeqLen = n; gSeqIdx = 0; gSeqNext = 0; }
static void tickSeq() {
  if (!gSeq || millis() < gSeqNext) return;
  const Key& k = gSeq[gSeqIdx++];
  if (gMotionOn) M5StackChan.Motion.move(constrain(k.yaw, -900, 900), constrain(k.pitch, 50, 850), k.speed);
  gSeqNext = millis() + k.ms;
  if (gSeqIdx >= gSeqLen) gSeq = nullptr;
}

enum Led { L_OFF, L_OK, L_ATTN_BREATHE, L_ATTN_DIM, L_BAD };
static uint32_t gLedLast = 0, gLedShown = 0xFFFFFFFF;
static void setLed(uint8_t r, uint8_t g, uint8_t b) {
  uint32_t c = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
  if (c == gLedShown) return;
  gLedShown = c;
  M5StackChan.showRgbColor(r, g, b);
}
static void tickLed(Led mode) {
  if (millis() - gLedLast < 70) return;
  gLedLast = millis();
  switch (mode) {
    case L_OK: setLed(0, 14, 6); break;                 // 微弱的绿色
    case L_ATTN_BREATHE: {                              // 琥珀色慢慢呼吸
      float ph = (millis() % 2400) / 2400.0f;
      float k = 0.12f + 0.88f * (0.5f - 0.5f * cosf(ph * 2 * PI));
      setLed((uint8_t)(120 * k), (uint8_t)(70 * k), (uint8_t)(6 * k));
    } break;
    case L_ATTN_DIM: setLed(36, 20, 2); break;          // 琥珀色常亮：还有 AI 在等
    case L_BAD: setLed(90, 8, 8); break;                // 红色常亮：额度快用完
    default: setLed(0, 0, 0);
  }
}
static void chime() {
  if (!gSoundOn) return;
  M5.Speaker.setVolume(80);
  M5.Speaker.tone(880, 130, 0, true);
  M5.Speaker.tone(1175, 180, 0, false);
}

// 根据当前画面决定身体怎么动（提醒强度「中」：点一下头、响一声，之后只保持灯）
static void updateBody(const State& s, Mode m) {
  int kind; Led led;      // kind: 0 不动  1 平时  2 等你回复  3 已知道但还在等  4 额度快用完  5 连不上
  bool anyWaiting = !s.waiting.empty();
  if (m == M_ASK) { kind = 2; led = L_ATTN_BREATHE; }
  else if (m == M_LOW) { kind = 4; led = L_BAD; }
  else if (m == M_OFF) { kind = 5; led = L_OFF; }
  else if (m == M_CALM) { kind = anyWaiting ? 3 : 1; led = anyWaiting ? L_ATTN_DIM : L_OK; }
  else if (m == M_STALE) { kind = anyWaiting ? 3 : 0; led = anyWaiting ? L_ATTN_DIM : L_OFF; }
  else { kind = 0; led = L_OFF; }

  if (m == M_ASK) {
    String id;
    for (auto& w : s.waiting) if (!w.acked) { id = w.id; break; }
    if (id != gLastAlertId) { gLastAlertId = id; PLAY(SEQ_NOD); chime(); }   // 每条新提醒只动一次、响一次
  } else {
    gLastAlertId = "";
    if (kind != gLastBody) {
      if (kind == 4) PLAY(SEQ_SHAKE);
      else if (kind == 5) PLAY(SEQ_DROOP);
      else if (kind == 1 || kind == 3) PLAY(SEQ_IDLE);
    }
  }
  gLastBody = kind;
  tickSeq();
  tickLed(led);
}

// ---------- 串口命令（开发调试用） ----------
static const char DEMO_JSON[] PROGMEM = R"JSON({"ok":true,"time":"12:00","data_time":"12:00","now":1000,"subs":[
{"id":"codex","name":"Codex","mono":"CX","hue":"#7c9cff","left":98,"label":"本月","level":"ok","reset":"12月9日重置","windows":[{"label":"本月","left":98,"level":"ok","reset":"12月9日重置","pace":""}]},
{"id":"claude","name":"Claude","mono":"CL","hue":"#e08a63","left":74,"label":"5小时","level":"ok","reset":"17:30 恢复","windows":[{"label":"5小时","left":74,"level":"ok","reset":"17:30 恢复","pace":""},{"label":"本周","left":93,"level":"ok","reset":"周四重置","pace":""},{"label":"Fable 本周","left":95,"level":"ok","reset":"周四重置","pace":""}]},
{"id":"cursor","name":"Cursor","mono":"CU","hue":"#cfd4dc","left":98,"label":"本周","level":"ok","reset":"21:12 重置","windows":[{"label":"本周","left":98,"level":"ok","reset":"21:12 重置","pace":""}]},
{"id":"opencodego","name":"OpenCode Go","mono":"OC","hue":"#5fd3bc","left":71,"label":"本月","level":"ok","reset":"12月7日重置","windows":[{"label":"5小时","left":100,"level":"ok","reset":"17:54 恢复","pace":""},{"label":"本周","left":85,"level":"ok","reset":"周一重置","pace":""},{"label":"本月","left":71,"level":"ok","reset":"12月7日重置","pace":"照现在的速度 7 天后用完"}]},
{"id":"antigravity","name":"Antigravity","mono":"AG","hue":"#b28cff","left":8,"label":"Gemini 5小时","level":"low","reset":"16:20 恢复","windows":[{"label":"Gemini 5小时","left":8,"level":"low","reset":"16:20 恢复","pace":""},{"label":"Gemini 本周","left":63,"level":"ok","reset":"周六重置","pace":""},{"label":"Claude/GPT 5小时","left":100,"level":"ok","reset":"20:18 恢复","pace":""},{"label":"Claude/GPT 本周","left":73,"level":"ok","reset":"周日重置","pace":""}]}
],"lows":[],"waiting":[]})JSON";

static void demo(const String& kind) {
  State s;
  parseState(String(FPSTR(DEMO_JSON)), s);
  gDemoOff = false;
  auto wait = [&](const char* agent, const char* proj, const char* k, const char* t) {
    Wait w; w.id = String("d-") + k; w.agent = agent; w.project = proj; w.kind = k; w.text = t; w.since = 958; s.waiting.push_back(w);
  };
  if (kind == "approval") wait("Claude Code", "aihelper", "approval", "需要你批准：Bash");
  else if (kind == "done") wait("Codex", "另一个项目", "done", "做完了，等你看结果");
  else if (kind == "question") wait("Claude Code", "aihelper", "question", "有问题要问你");
  else if (kind == "low") { Low l; l.id = "antigravity"; l.name = "Antigravity"; l.label = "Gemini 5小时"; l.left = 8; l.reset = "16:20 恢复"; s.lows.push_back(l); }
  else if (kind == "stale") s.ok = false;
  else if (kind == "off") gDemoOff = true;
  if (kind != "low") { s.subs[4].left = 63; s.subs[4].label = "Gemini 本周"; s.subs[4].level = "ok"; s.subs[4].wins[0].left = 83; s.subs[4].wins[0].level = "ok"; }
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
    char c = Serial.read();
    if (c == '\r') continue;
    if (c != '\n') { if (buf.length() < 80) buf += c; continue; }
    String cmd = buf; buf = ""; cmd.trim();
    if (cmd == "shot") dumpShot();
    else if (cmd.startsWith("demo ")) { String k = cmd.substring(5); if (k == "exit") gDemo = false; else demo(k); Serial.println("OK demo " + k); }
    else if (cmd == "page face") { gPage = P_FACE; Serial.println("OK"); }
    else if (cmd == "page list") { gPage = P_LIST; Serial.println("OK"); }
    else if (cmd.startsWith("page detail ")) { gDetailId = cmd.substring(12); gPage = P_DETAIL; Serial.println("OK"); }
    else if (cmd == "info") {
      Serial.printf("INFO wifi=%d ssid=%s ip=%s portal=%d bridge=%s online=%d last=%s demo=%d heap=%u psram=%u\n",
        (int)WiFi.status(), WiFi.SSID().c_str(), WiFi.localIP().toString().c_str(), (int)wm.getConfigPortalActive(),
        gBridgeIp.toString().c_str(), (int)gOnline, gLastInfo.c_str(), (int)gDemo, (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getFreePsram());
    }
    else if (cmd == "body") {
      auto in = M5StackChan.TouchSensor.getIntensities();
      Serial.printf("BODY yaw=%d pitch=%d moving=%d touch=%d,%d,%d batt=%.2fV %.0fmA motion=%d sound=%d led=%06x\n",
        M5StackChan.Motion.getCurrentYawAngle(), M5StackChan.Motion.getCurrentPitchAngle(), (int)M5StackChan.Motion.isMoving(),
        in[0], in[1], in[2], M5StackChan.getBatteryVoltage(), M5StackChan.getBatteryCurrent() * 1000, (int)gMotionOn, (int)gSoundOn, (unsigned)gLedShown);
    }
    else if (cmd == "nod") { PLAY(SEQ_NOD); Serial.println("OK"); }
    else if (cmd == "shake") { PLAY(SEQ_SHAKE); Serial.println("OK"); }
    else if (cmd == "droop") { PLAY(SEQ_DROOP); Serial.println("OK"); }
    else if (cmd == "idle") { PLAY(SEQ_IDLE); Serial.println("OK"); }
    else if (cmd == "chime") { chime(); Serial.println("OK"); }
    else if (cmd == "motion on") { gMotionOn = true; Serial.println("OK"); }
    else if (cmd == "motion off") { gMotionOn = false; Serial.println("OK"); }
    else if (cmd == "sound on") { gSoundOn = true; Serial.println("OK"); }
    else if (cmd == "sound off") { gSoundOn = false; Serial.println("OK"); }
    else if (cmd == "wifi reset") { Serial.println("OK 清除 WiFi 设置并重启"); wm.resetSettings(); delay(300); ESP.restart(); }
    else if (cmd == "reboot") { ESP.restart(); }
    else if (cmd.length()) Serial.println("? " + cmd);
  }
}

// ---------- 启动 ----------
void setup() {
  M5StackChan.begin();                                  // 屏幕、舵机电源、彩灯、头顶触摸一起初始化
  M5StackChan.Motion.setAutoTorqueReleaseEnabled(true); // 停下来以后舵机松劲，不会一直嗡嗡响
  M5StackChan.showRgbColor(0, 0, 0);
  Serial.begin(115200);
  M5.Display.setBrightness(110);
  cv.setPsram(true);
  cv.setColorDepth(16);
  cv.createSprite(320, 240);
  gMux = xSemaphoreCreateMutex();

  State empty;
  drawFacePage(empty, M_CONNECTING);
  cv.pushSprite(0, 0);

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  wm.setDebugOutput(false);
  wm.setConfigPortalBlocking(false);   // 配网页面开着的时候，画面和串口照常工作
  wm.setConnectTimeout(15);
  wm.setHostname("stackchan");
  wm.setTitle("StackChan");
  wm.autoConnect(AP_NAME);
  MDNS.begin("stackchan");
  xTaskCreatePinnedToCore(netTask, "net", 12288, nullptr, 1, nullptr, 0);
}

void loop() {
  M5StackChan.update();
  wm.process();
  handleSerial();

  static uint32_t lastRetry = 0;
  if (!gDemo && !wm.getConfigPortalActive() && WiFi.status() != WL_CONNECTED && millis() - lastRetry > 15000) {
    lastRetry = millis();
    WiFi.reconnect();
  }

  xSemaphoreTake(gMux, portMAX_DELAY);
  State s = gState;
  xSemaphoreGive(gMux);
  Mode m = computeMode(s);

  auto t = M5.Touch.getDetail();
  bool tapped = t.wasClicked();
  bool patted = M5StackChan.TouchSensor.wasPressed() && (m == M_ASK || (m == M_LOW && gPage == P_FACE));   // 摸头只用来表示「知道了」
  if (tapped || patted) {
    onTap(tapped ? t.x : -1, tapped ? t.y : -1, s, m);
    if (m == M_ASK) {               // 把「知道了」写回共享状态，下一帧立刻生效
      xSemaphoreTake(gMux, portMAX_DELAY);
      for (auto& w : gState.waiting) w.acked = true;
      xSemaphoreGive(gMux);
    }
    m = computeMode(s);
  }
  render(s, m);
  updateBody(s, m);
  delay(40);
}
