// aihelper 固件 2.0：联网
// - WiFi、口令、Mac 的位置存在 NVS 里，由 Mac 上的安装向导通过 USB 串口写进来（见 docs/protocol.md）
// - 用 Bonjour（_aihelper._tcp）找 Mac 上的小管家，找不到就用上次的地址
// - 每 2 秒取一次 /state；收到 ota 命令时从小管家下载新固件
#include "app.h"
#include <WiFi.h>
#include <WiFiManager.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <Update.h>

SemaphoreHandle_t gMux;
State gState;
Cfg gCfg;
volatile bool gOnline = false;
volatile uint32_t gFetchedAt = 0;
volatile bool gAckPending = false;
volatile int gOta = -1;
bool gDemo = false;

static WiFiManager wm;
static Preferences prefs;
static const char* AP_NAME = "StackChan-Setup";

struct Link { String ssid, pass, token, macId, host, lastIp; int port = 8787; };
static Link gLink, gPending;
static bool gPendingWifi = false, gPendingLink = false;
static IPAddress gBridgeIp;
static uint16_t gBridgePort = 8787;
static String gLastInfo, gFoundBy;
static volatile bool gWantOta = false;
static volatile bool gReconnect = false;
static bool gMdnsUp = false;

// ---------- 存取配置 ----------
static void linkLoad() {
  prefs.begin("aihelper", true);
  gLink.ssid = prefs.getString("ssid", "");
  gLink.pass = prefs.getString("pass", "");
  gLink.token = prefs.getString("token", "");
  gLink.macId = prefs.getString("macid", "");
  gLink.host = prefs.getString("host", "");
  gLink.lastIp = prefs.getString("lastip", "");
  gLink.port = prefs.getInt("port", 8787);
  String cfg = prefs.getString("cfg", "");
  prefs.end();
  if (cfg.length()) {
    JsonDocument d;
    if (!deserializeJson(d, cfg)) parseCfg(d.as<JsonVariantConst>(), gCfg);
  }
}
static void linkSave() {
  prefs.begin("aihelper", false);
  prefs.putString("ssid", gLink.ssid);
  prefs.putString("pass", gLink.pass);
  prefs.putString("token", gLink.token);
  prefs.putString("macid", gLink.macId);
  prefs.putString("host", gLink.host);
  prefs.putInt("port", gLink.port);
  prefs.end();
}
static void saveLastIp(const String& ip) {
  if (ip == gLink.lastIp) return;
  gLink.lastIp = ip;
  prefs.begin("aihelper", false);
  prefs.putString("lastip", ip);
  prefs.end();
}
static void saveCfg(const String& json) {
  prefs.begin("aihelper", false);
  prefs.putString("cfg", json);
  prefs.end();
}

bool netHasToken() { return gLink.token.length() > 0; }
bool netPortal() { return wm.getConfigPortalActive(); }
bool netHasWifi() { return gLink.ssid.length() > 0 || WiFi.SSID().length() > 0 || wm.getWiFiIsSaved(); }
String netSsid() { return gLink.ssid.length() ? gLink.ssid : WiFi.SSID(); }

// ---------- 解析状态 ----------
static uint32_t hexColor(const char* s, bool& set) {
  set = s && s[0] == '#' && strlen(s) >= 7;
  return set ? (uint32_t)strtoul(s + 1, nullptr, 16) : 0;
}
bool parseCfg(JsonVariantConst o, Cfg& c) {
  if (!o.is<JsonObjectConst>()) return false;
  c.rev = o["rev"] | c.rev;
  c.theme = (const char*)(o["theme"] | c.theme.c_str());
  c.eye = (const char*)(o["eye"] | c.eye.c_str());
  c.name = (const char*)(o["name"] | c.name.c_str());
  c.lang = (const char*)(o["lang"] | c.lang.c_str());
  if (o["eye_color"].is<const char*>()) c.eyeColor = hexColor(o["eye_color"], c.eyeColorSet);
  c.bright = o["bright"] | c.bright;
  c.used = o["used"] | c.used;
  c.clock = o["clock"] | c.clock;
  c.blink = o["blink"] | c.blink;
  c.look = o["look"] | c.look;
  c.sleepy = o["sleepy"] | c.sleepy;
  c.dimAfter = o["dim_after"] | c.dimAfter;
  c.alert = o["alert"] | c.alert;
  c.remind = o["remind"] | c.remind;
  c.motion = o["motion"] | c.motion;
  c.nod = o["nod"] | c.nod;
  c.pitch = o["pitch"] | c.pitch;
  c.wander = o["wander"] | c.wander;
  c.shakeLow = o["shake_low"] | c.shakeLow;
  c.sound = o["sound"] | c.sound;
  c.volume = o["volume"] | c.volume;
  c.tone = o["tone"] | c.tone;
  c.led = o["led"] | c.led;
  c.ledBright = o["led_bright"] | c.ledBright;
  if (o["led_idle"].is<const char*>()) c.ledIdle = hexColor(o["led_idle"], c.ledIdleOn);
  if (o["led_attn"].is<const char*>()) c.ledAttn = hexColor(o["led_attn"], c.ledAttnOn);
  c.touch = o["touch"] | c.touch;
  c.quiet = o["quiet"] | c.quiet;
  c.qStill = o["q_still"] | c.qStill;
  c.qMute = o["q_mute"] | c.qMute;
  c.qDark = o["q_dark"] | c.qDark;
  c.qFace = o["q_face"] | c.qFace;
  c.qBright = o["q_bright"] | c.qBright;
  return true;
}

bool parseState(const String& body, State& s) {
  JsonDocument doc;
  if (deserializeJson(doc, body)) return false;
  s = State();
  s.valid = true;
  s.ok = doc["ok"] | false;
  s.rest = doc["rest"] | false;
  s.time = (const char*)(doc["time"] | "");
  s.dataTime = (const char*)(doc["data_time"] | "");
  s.now = (uint32_t)(doc["now"] | 0.0);
  for (JsonObject o : doc["subs"].as<JsonArray>()) {
    Sub b;
    b.id = (const char*)(o["id"] | "");
    b.name = (const char*)(o["name"] | "");
    b.mono = (const char*)(o["mono"] | "");
    b.label = (const char*)(o["label"] | "");
    b.level = (const char*)(o["level"] | "na");
    b.reset = (const char*)(o["reset"] | "");
    b.error = (const char*)(o["error"] | "");
    bool set;
    b.hue = hexColor(o["hue"] | "#aab2bd", set);
    b.left = o["left"].isNull() ? -1 : o["left"].as<int>();
    b.stale = o["stale"] | false;
    for (JsonObject w : o["windows"].as<JsonArray>()) {
      Win x;
      x.label = (const char*)(w["label"] | "");
      x.left = w["left"] | 0;
      x.level = (const char*)(w["level"] | "na");
      x.reset = (const char*)(w["reset"] | "");
      x.pace = (const char*)(w["pace"] | "");
      b.wins.push_back(x);
    }
    s.subs.push_back(b);
  }
  for (JsonVariant v : doc["face"].as<JsonArray>()) s.face.push_back((const char*)(v | ""));
  for (JsonObject o : doc["waiting"].as<JsonArray>()) {
    Wait w;
    w.id = (const char*)(o["id"] | "");
    w.agent = (const char*)(o["agent"] | "");
    w.project = (const char*)(o["project"] | "");
    w.kind = (const char*)(o["kind"] | "");
    w.text = (const char*)(o["text"] | "");
    w.since = (uint32_t)(o["since"] | 0.0);
    w.acked = o["acked"] | false;
    s.waiting.push_back(w);
  }
  for (JsonObject o : doc["lows"].as<JsonArray>()) {
    Low l;
    l.id = (const char*)(o["id"] | "");
    l.name = (const char*)(o["name"] | "");
    l.label = (const char*)(o["label"] | "");
    l.reset = (const char*)(o["reset"] | "");
    l.left = o["left"] | 0;
    s.lows.push_back(l);
  }
  if (doc["cfg"].is<JsonObject>()) {
    s.cfg = gCfg;
    s.hasCfg = parseCfg(doc["cfg"].as<JsonVariantConst>(), s.cfg);
    if (s.hasCfg && s.cfg.rev != gCfg.rev) {   // 设置变了：记下来，下次开机还用这一份
      String j;
      serializeJson(doc["cfg"], j);
      saveCfg(j);
    }
  }
  if (doc["cmd"].is<JsonObject>()) {
    s.cmdId = doc["cmd"]["id"] | 0;
    s.cmd = (const char*)(doc["cmd"]["do"] | "");
  }
  return true;
}

// ---------- 找小管家 ----------
static bool discover() {
  if (!gMdnsUp) return false;
  int n = MDNS.queryService("aihelper", "tcp");
  int pick = -1;
  for (int i = 0; i < n; i++) {
    String id = MDNS.txt(i, "id");
    if (gLink.macId.length() && id == gLink.macId) { pick = i; break; }
    if (!gLink.macId.length() && pick < 0) pick = i;
  }
  if (pick >= 0) {
    gBridgeIp = MDNS.address(pick);
    gBridgePort = MDNS.port(pick);
    saveLastIp(gBridgeIp.toString());
    gLastInfo = gFoundBy = "bonjour";
    return true;
  }
  if (gLink.host.length()) {
    String h = gLink.host;
    if (h.endsWith(".local")) h.remove(h.length() - 6);
    IPAddress ip = MDNS.queryHost(h, 1500);
    if (ip != IPAddress((uint32_t)0)) {
      gBridgeIp = ip;
      gBridgePort = gLink.port;
      saveLastIp(ip.toString());
      gLastInfo = gFoundBy = "host";
      return true;
    }
  }
  if (gLink.lastIp.length() && gBridgeIp.fromString(gLink.lastIp)) { gBridgePort = gLink.port; gLastInfo = gFoundBy = "lastip"; return true; }
  return false;
}
static String url(const char* path, bool full = false) {
  String u = String("http://") + gBridgeIp.toString() + ":" + String(gBridgePort) + path + "?t=" + gLink.token;
  if (full) u += "&fw=" FW_VERSION "&rssi=" + String(WiFi.RSSI()) + "&up=" + String(millis() / 1000);
  return u;
}

// ---------- 升级 ----------
static void doOta() {
  gOta = 0;
  WiFiClient client;
  HTTPClient http;
  http.setTimeout(15000);
  if (!http.begin(client, url("/firmware.bin"))) { gOta = -2; return; }
  int code = http.GET();
  int len = http.getSize();
  if (code != 200 || len <= 0 || !Update.begin(len)) { http.end(); gOta = -2; return; }
  WiFiClient* st = http.getStreamPtr();
  static uint8_t buf[4096];
  int done = 0;
  uint32_t last = millis();
  while (done < len && millis() - last < 20000) {
    size_t a = st->available();
    if (!a) { delay(5); continue; }
    int r = st->readBytes(buf, std::min(a, sizeof buf));
    if (r <= 0) continue;
    if (Update.write(buf, r) != (size_t)r) break;
    done += r;
    last = millis();
    gOta = (int)((int64_t)done * 100 / len);
  }
  http.end();
  if (done == len && Update.end(true)) { gOta = 100; delay(1200); ESP.restart(); }
  Update.abort();
  gOta = -2;
}

// ---------- 联网任务（独立运行，不卡画面） ----------
static void netTask(void*) {
  int fails = 0;
  for (;;) {
    if (gReconnect) {
      gReconnect = false;
      WiFi.disconnect();
      delay(200);
      WiFi.begin(gLink.ssid.c_str(), gLink.pass.c_str());
    }
    if (gDemo || WiFi.status() != WL_CONNECTED || !netHasToken()) { gOnline = false; vTaskDelay(pdMS_TO_TICKS(500)); continue; }
    if (!gMdnsUp) { gMdnsUp = MDNS.begin("stackchan"); }
    if (gWantOta) { gWantOta = false; doOta(); continue; }
    if (gBridgeIp == IPAddress((uint32_t)0) || fails >= 5) { discover(); if (fails >= 5) fails = 3; }
    WiFiClient client;
    HTTPClient http;
    http.setConnectTimeout(1500);
    http.setTimeout(3000);
    if (gAckPending && http.begin(client, url("/ack"))) {
      http.addHeader("Content-Type", "application/json");
      if (http.POST("{\"id\":\"\"}") == 200) gAckPending = false;
      http.end();
    }
    bool good = false;
    if (http.begin(client, url("/state", true))) {
      int code = http.GET();
      if (code == 200) {
        String body = http.getString();
        State s;
        if (parseState(body, s) && !gDemo) {
          xSemaphoreTake(gMux, portMAX_DELAY);
          gState = s;
          if (s.hasCfg) gCfg = s.cfg;
          gFetchedAt = millis();
          xSemaphoreGive(gMux);
          good = true;
        }
      }
      if (gLastInfo.indexOf("HTTP") < 0 || code != 200) gLastInfo = "HTTP " + String(code);
      http.end();
    }
    if (good) { fails = 0; gOnline = true; }
    else if (++fails >= 3) gOnline = false;
    vTaskDelay(pdMS_TO_TICKS(good ? 2000 : 1500));
  }
}

void netRequestOta() { gWantOta = true; }

void netBegin() {
  gMux = xSemaphoreCreateMutex();
  linkLoad();
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.setHostname("stackchan");
  WiFi.setSleep(false);                // 插着电用，不省电：响应更快，升级下载也快很多
  wm.setDebugOutput(false);
  wm.setConfigPortalBlocking(false);   // 配网页面开着的时候，画面和串口照常工作
  wm.setConnectTimeout(15);
  wm.setHostname("stackchan");
  wm.setTitle("StackChan");
  if (gLink.ssid.length()) WiFi.begin(gLink.ssid.c_str(), gLink.pass.c_str());
  else wm.autoConnect(AP_NAME);        // 没有经 USB 配置过：用以前存的 WiFi，没有就开配网热点
  xTaskCreatePinnedToCore(netTask, "net", 12288, nullptr, 1, nullptr, 0);
}

void netLoop() {
  wm.process();
  static uint32_t lastRetry = 0, lostSince = 0;
  static bool portalSeen = false;
  if (wm.getConfigPortalActive()) portalSeen = true;
  if (gDemo || wm.getConfigPortalActive()) return;
  if (WiFi.status() == WL_CONNECTED) {
    lostSince = 0;
    // 用手机配网成功后，把新的 WiFi 记下来（只在配网热点开过之后）
    if (portalSeen) {
      portalSeen = false;
      if (gLink.ssid.length() && WiFi.SSID().length() && WiFi.SSID() != gLink.ssid) { gLink.ssid = WiFi.SSID(); gLink.pass = WiFi.psk(); linkSave(); }
    }
    return;
  }
  if (!lostSince) lostSince = millis();
  if (millis() - lastRetry > 15000) { lastRetry = millis(); WiFi.reconnect(); }
  // 存的 WiFi 连续 3 分钟连不上（比如搬家换了路由器）：打开配网热点，同时继续重试
  if (millis() - lostSince > 180000 && !wm.getConfigPortalActive()) wm.startConfigPortal(AP_NAME);
}

// ---------- 串口：安装向导用的配置命令 ----------
static String unhex(const String& h) {
  String out;
  for (int i = 0; i + 1 < (int)h.length(); i += 2) out += (char)strtoul(h.substring(i, i + 2).c_str(), nullptr, 16);
  return out;
}
static String hexs(const String& s) {
  String out;
  char b[3];
  for (size_t i = 0; i < s.length(); i++) { snprintf(b, sizeof b, "%02x", (uint8_t)s[i]); out += b; }
  return out;
}
static std::vector<String> words(const String& s) {
  std::vector<String> v;
  int i = 0;
  while (i < (int)s.length()) {
    while (i < (int)s.length() && s[i] == ' ') i++;
    int j = i;
    while (j < (int)s.length() && s[j] != ' ') j++;
    if (j > i) v.push_back(s.substring(i, j));
    i = j;
  }
  return v;
}
String netInfo() {
  char b[220];
  snprintf(b, sizeof b, "wifi=%d ssid=%s ip=%s rssi=%d portal=%d bridge=%s:%u via=%s online=%d last=%s token=%d",
           (int)WiFi.status(), WiFi.SSID().c_str(), WiFi.localIP().toString().c_str(), (int)WiFi.RSSI(), (int)wm.getConfigPortalActive(),
           gBridgeIp.toString().c_str(), gBridgePort, gFoundBy.c_str(), (int)gOnline, gLastInfo.c_str(), (int)netHasToken());
  return b;
}
static void reportWifi(void*) {
  uint32_t start = millis();
  while (millis() - start < 20000 && WiFi.status() != WL_CONNECTED) delay(200);
  if (WiFi.status() == WL_CONNECTED) Serial.printf("WIFI ok %s\n", WiFi.localIP().toString().c_str());
  else Serial.println("WIFI fail");
  vTaskDelete(nullptr);
}

bool netSerial(const String& cmd) {
  auto w = words(cmd);
  if (w.empty()) return false;
  if (w[0] == "hello") {
    Serial.printf("HELLO aihelper fw=%s board=cores3 configured=%d mac=%s\n", FW_VERSION, (int)(netHasToken() && gLink.ssid.length()), WiFi.macAddress().c_str());
    return true;
  }
  if (w[0] != "cfg") return false;
  if (w.size() >= 4 && w[1] == "wifi") { gPending.ssid = unhex(w[2]); gPending.pass = unhex(w[3]); gPendingWifi = true; Serial.println("OK"); }
  else if (w.size() == 3 && w[1] == "wifi") { gPending.ssid = unhex(w[2]); gPending.pass = ""; gPendingWifi = true; Serial.println("OK"); }
  else if (w.size() >= 6 && w[1] == "link") {
    gPending.token = w[2]; gPending.macId = w[3] == "-" ? "" : w[3]; gPending.host = unhex(w[4]); gPending.port = w[5].toInt() ?: 8787;
    gPendingLink = true;
    Serial.println("OK");
  }
  else if (w.size() == 2 && w[1] == "save") {
    if (gPendingWifi) { gLink.ssid = gPending.ssid; gLink.pass = gPending.pass; }
    if (gPendingLink) { gLink.token = gPending.token; gLink.macId = gPending.macId; gLink.host = gPending.host; gLink.port = gPending.port; gBridgeIp = IPAddress((uint32_t)0); }
    linkSave();
    Serial.println("OK");
    if (gPendingWifi) {
      if (wm.getConfigPortalActive()) wm.stopConfigPortal();
      gReconnect = true;
      xTaskCreate(reportWifi, "wifirep", 3072, nullptr, 1, nullptr);
    }
    gPendingWifi = gPendingLink = false;
  }
  else if (w.size() == 2 && w[1] == "show") {
    Serial.printf("CFG ssid=%s mac_id=%s host=%s port=%d token=%s lastip=%s\n", hexs(gLink.ssid).c_str(), gLink.macId.c_str(),
                  hexs(gLink.host).c_str(), gLink.port, netHasToken() ? "yes" : "no", gLink.lastIp.c_str());
  }
  else if (w.size() == 2 && w[1] == "clear") {
    prefs.begin("aihelper", false); prefs.clear(); prefs.end();
    wm.resetSettings();
    Serial.println("OK");
    delay(300);
    ESP.restart();
  }
  else Serial.println("ERR " + cmd);
  return true;
}
