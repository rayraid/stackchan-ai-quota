// aihelper 固件 2.0：各部分共用的数据结构
#pragma once
#include <M5Unified.h>
#include <M5StackChan.h>
#include <ArduinoJson.h>
#include <vector>

#define FW_VERSION "2.1.2"

struct Win  { String label, level, reset, pace; int left = 0; int mins = 0; };   // mins：这个额度的周期（分钟），0 = 不知道
struct Sub  { String id, name, mono, label, level, reset, error, icon; uint32_t hue = 0xaab2bd; int left = -1; bool stale = false; std::vector<Win> wins; };
struct Wait { String id, agent, mono, project, kind, text, iconId, iconV; uint32_t since = 0; bool acked = false; };
struct Low  { String id, name, label, reset; int left = 0; };

// 机器人上的设置（小管家随状态下发，见 docs/protocol.md）
struct Cfg {
  int rev = -1;
  String home = "B";        // 首页样式：A 轻底栏 / B 眼睛就是额度 / C 说给你听 / D 只有脸
  String list = "A";        // 全部额度页：A 两列小卡片 / B 一行一家 / C 竖条对比
  String detail = "A";      // 明细页：A 大圆环（周期最短的那个）+ 旁边几行 / B 统一横条
  int alertSecs = 10;       // 整屏提醒停几秒，0 = 一直到你回去
  String alertStyle = "now"; // 提醒画面：now 整屏变色 / B 柔和变色 / C 脸 + 底部卡片
  bool doneFlash = true;    // 「做完了」整屏提醒完就熄（不留 logo 和灯）
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
  int touch = 0;            // 平时摸头：0 开心一下 / 1 切换页面 / 2 什么都不做（整屏提醒时摸头总是提前收起）
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
extern String gAckId;             // 要告诉小管家「已知道」的那一条（受 gMux 保护，空 = 没有）
extern std::vector<String> gClearIds;   // 摸头熄掉的提醒（受 gMux 保护）：小管家删掉之前，收到的状态里先把它们去掉
extern std::vector<String> gClearSend;  // 还没告诉小管家的那几条（受 gMux 保护）
extern std::vector<String> gDoneSend;   // 「做完了」提醒完自己熄掉的，还没告诉小管家的（受 gMux 保护）
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
  String flashId;          // 正在整屏提醒的那一条
  float flashLeft = -1;    // 整屏提醒还剩几成时间（0~1），-1 = 一直显示到你回去
  bool reminder = false;   // 这次是「没回去，再提醒一次」
  bool happy = false;      // 刚被摸头：眯眼笑
  int otaProgress = -1;
  bool portal = false;
  String ssid;
  int batt = -1;           // 电量百分比，-1 = 读不到（首页左上角用）
  bool power = false;      // 插着线（正在充电或已充满）
};
void uiBegin();
void uiRender(const State& s, const Cfg& c, Mode m, const UiCtx& u);
int uiListHit(const State& s, const Cfg& c, int x, int y);   // 全部额度页点到第几家，没点到返回 -1（-2 = 顶部标题栏）
// 首页上点了哪里：返回 true 并给出订阅 id = 看那一家的明细；false = 进「全部额度」
bool uiFaceHit(const State& s, const Cfg& c, int x, int y, String& subId);
extern M5Canvas cv;

// ---------- body.cpp：头、灯、声音 ----------
void bodyUpdate(const State& s, const Cfg& c, Mode m, int flashSeq);   // flashSeq 变了 = 新开始一次整屏提醒
void bodyDo(const String& what, const Cfg& c);   // nod / shake / chime / find / droop / idle / wiggle
void bodyNoteActivity();
uint32_t bodyLastActivity();
// 电池：身体里的 INA226 测电压和电流（放电为正、充电为负），每秒读一次
struct Batt { int pct = -1; bool power = false; int mv = 0, ma = 0; };
void battUpdate();
Batt battGet();                       // 主循环和联网任务都能调用
bool battSerial(const String& cmd);   // 串口：batt 15 / batt 64 chg / batt real（截图用）
