// aihelper 固件 2.0：各部分共用的数据结构
#pragma once
#include <M5Unified.h>
#include <M5StackChan.h>
#include <ArduinoJson.h>
#include <vector>

#define FW_VERSION "2.0.0"

struct Win  { String label, level, reset, pace; int left = 0; };
struct Sub  { String id, name, mono, label, level, reset, error, icon; uint32_t hue = 0xaab2bd; int left = -1; bool stale = false; std::vector<Win> wins; };
struct Wait { String id, agent, project, kind, text, iconId, iconV; uint32_t since = 0; bool acked = false; };
struct Low  { String id, name, label, reset; int left = 0; };

// 机器人上的设置（小管家随状态下发，见 docs/protocol.md）
struct Cfg {
  int rev = -1;
  String theme = "night", eye = "capsule", name = "StackChan", lang = "zh";
  uint32_t eyeColor = 0; bool eyeColorSet = false;
  int bright = 70;
  bool used = false, clock = false, blink = true, look = true, sleepy = false;
  int dimAfter = 30;
  int alert = 1, remind = 0;
  bool motion = true; int nod = 1, pitch = 12; bool wander = false, shakeLow = true;
  bool sound = true; int volume = 60, tone = 1;
  bool led = true; int ledBright = 50;
  uint32_t ledIdle = 0x3ddc84, ledAttn = 0xffb020; bool ledIdleOn = true, ledAttnOn = true;
  int touch = 0;
  bool quiet = false, qStill = true, qMute = true, qDark = true, qFace = true; int qBright = 10;
};

struct State {
  bool valid = false, ok = false, rest = false, hasCfg = false;
  String time, dataTime;
  uint32_t now = 0;
  std::vector<Sub> subs;
  std::vector<String> face;
  std::vector<Wait> waiting;
  std::vector<Low> lows;
  Cfg cfg;
  int cmdId = 0; String cmd;
};

enum Mode { M_SETUP, M_NOLINK, M_CONNECTING, M_OFF, M_REST, M_UPDATING, M_ASK, M_LOW, M_STALE, M_CALM };
enum Page { P_FACE, P_LIST, P_DETAIL };

// ---------- net.cpp：联网、配置、取状态、升级 ----------
extern SemaphoreHandle_t gMux;
extern State gState;              // 最近一次的状态（受 gMux 保护）
extern Cfg gCfg;                  // 当前生效的设置（受 gMux 保护，离线时用上次保存的）
extern volatile bool gOnline;
extern volatile uint32_t gFetchedAt;
extern volatile bool gAckPending;
extern volatile int gOta;         // 升级进度：-1 没在升级，0~100 进行中，-2 失败
extern bool gDemo;
void netBegin();
void netLoop();
void netRequestOta();
bool netSerial(const String& cmd);   // 处理 hello / cfg … 串口命令
bool netPortal();
bool netHasWifi();
bool netHasToken();
String netSsid();
String netInfo();
bool parseState(const String& body, State& s);
bool parseCfg(JsonVariantConst o, Cfg& c);
// 图标：向小管家要，存在内存里。还没拿到时返回 nullptr（同时排队去取）。每个像素 B、G、R、A
const uint8_t* iconGet(const String& id, const String& ver, int size, bool darkBg);

// ---------- ui.cpp：画面 ----------
struct UiCtx {
  Page page = P_FACE;
  String detailId;
  uint32_t waited = 0;     // 当前提醒已等了几秒
  int otaProgress = -1;
  bool portal = false;
  String ssid;
};
void uiBegin();
void uiRender(const State& s, const Cfg& c, Mode m, const UiCtx& u);
int uiListHit(const State& s, int y);   // 明细列表里点到第几行，没点到返回 -1
extern M5Canvas cv;

// ---------- body.cpp：头、灯、声音 ----------
void bodyUpdate(const State& s, const Cfg& c, Mode m);
void bodyDo(const String& what, const Cfg& c);   // nod / shake / chime / find / droop / idle
void bodyNoteActivity();
uint32_t bodyLastActivity();
