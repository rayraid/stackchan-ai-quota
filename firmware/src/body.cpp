// aihelper 固件 2.0：头（舵机）、彩灯、提示音
// 角度单位是 0.1 度。左右 yaw：0 是正前方；上下 pitch：0 最低，官方建议保持在 5~85 度之间。
#include "app.h"

struct Key { int yaw, pitch, speed; uint16_t ms; };
static Key gSeq[8];
static int gSeqLen = 0, gSeqIdx = 0;
static uint32_t gSeqNext = 0;
static bool gStill = false;    // 这一刻不许动（关了动作或勿扰）

static int idlePitch(const Cfg& c) { return constrain(c.pitch, 5, 40) * 10; }
static void play(std::initializer_list<Key> keys) {
  gSeqLen = 0;
  for (auto& k : keys) if (gSeqLen < 8) gSeq[gSeqLen++] = k;
  gSeqIdx = 0;
  gSeqNext = 0;
}
static void tickSeq() {
  if (gSeqIdx >= gSeqLen || millis() < gSeqNext) return;
  const Key& k = gSeq[gSeqIdx++];
  if (!gStill) M5StackChan.Motion.move(constrain(k.yaw, -900, 900), constrain(k.pitch, 50, 850), k.speed);
  gSeqNext = millis() + k.ms;
}
static void nod(const Cfg& c) {
  int p = idlePitch(c);
  if (c.nod <= 0) play({{0, p + 110, 600, 280}, {0, std::max(50, p - 50), 600, 280}, {0, p, 400, 0}});
  else if (c.nod >= 2) play({{0, p + 260, 750, 320}, {0, 50, 750, 320}, {0, p + 160, 650, 280}, {0, p, 400, 0}});
  else play({{0, p + 180, 700, 300}, {0, std::max(50, p - 60), 700, 300}, {0, p + 100, 600, 260}, {0, p, 400, 0}});
}
static void shake(const Cfg& c) { int p = idlePitch(c); play({{-180, p, 300, 700}, {180, p, 300, 1000}, {0, p, 300, 0}}); }
static void droop() { play({{0, 50, 250, 0}}); }
static void idle(const Cfg& c) { play({{0, idlePitch(c), 300, 0}}); }

// ---------- 声音：几个音排队播放，不卡画面 ----------
struct Note { uint16_t f, ms, gap; };
static Note gNotes[6];
static int gNoteLen = 0, gNoteIdx = 0;
static uint32_t gNoteNext = 0;
static void chime(const Cfg& c) {
  gNoteLen = 0; gNoteIdx = 0; gNoteNext = 0;
  auto add = [&](uint16_t f, uint16_t ms, uint16_t gap) { if (gNoteLen < 6) gNotes[gNoteLen++] = {f, ms, gap}; };
  switch (c.tone) {
    case 0: add(1318, 180, 0); break;                                   // 叮
    case 2: add(2093, 70, 70); add(2093, 70, 0); break;                // 两声短哔
    case 3: add(523, 110, 10); add(659, 110, 10); add(784, 200, 0); break;  // 小号角
    default: add(880, 130, 0); add(1175, 180, 0);                       // 叮咚
  }
  M5.Speaker.setVolume((uint8_t)(constrain(c.volume, 0, 100) * 160 / 100));
}
static void tickNotes() {
  if (gNoteIdx >= gNoteLen || millis() < gNoteNext) return;
  const Note& n = gNotes[gNoteIdx++];
  M5.Speaker.tone(n.f, n.ms, 0, true);
  gNoteNext = millis() + n.ms + n.gap;
}

// ---------- 彩灯 ----------
static uint32_t gLedShown = 0xFFFFFFFF, gLedLast = 0, gFindUntil = 0;
static void setLed(uint32_t c) {
  if (c == gLedShown) return;
  gLedShown = c;
  M5StackChan.showRgbColor((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF);
}
static uint32_t scale(uint32_t c, float k) {
  k = constrain(k, 0.0f, 1.0f);
  return ((uint32_t)(((c >> 16) & 0xFF) * k) << 16) | ((uint32_t)(((c >> 8) & 0xFF) * k) << 8) | (uint32_t)((c & 0xFF) * k);
}

// ---------- 对外 ----------
static uint32_t gLastActivity = 0;
void bodyNoteActivity() { gLastActivity = millis(); }

void bodyDo(const String& what, const Cfg& c) {
  if (what == "nod") nod(c);
  else if (what == "shake") shake(c);
  else if (what == "droop") droop();
  else if (what == "idle") idle(c);
  else if (what == "chime") chime(c);
  else if (what == "find") { nod(c); chime(c); gFindUntil = millis() + 3000; }
}

void bodyUpdate(const State& s, const Cfg& c, Mode m) {
  static String lastAlertId;
  static uint32_t lastRemind = 0, nextWander = 0;
  static int lastKind = -1;
  bool quiet = c.quiet || s.rest;
  gStill = !c.motion || (quiet && c.qStill);
  bool mute = !c.sound || (quiet && c.qMute);
  bool dark = !c.led || (quiet && c.qDark);
  float lb = constrain(c.ledBright, 0, 100) / 100.0f;

  // kind：0 不动  1 平时  2 等你  3 已知道但还在等  4 额度快用完  5 连不上 / 休息
  int kind;
  bool anyWaiting = !s.waiting.empty();
  if (m == M_ASK) kind = 2;
  else if (m == M_LOW) kind = 4;
  else if (m == M_OFF || m == M_REST) kind = 5;
  else if (m == M_CALM) kind = anyWaiting ? 3 : 1;
  else if (m == M_STALE) kind = anyWaiting ? 3 : 0;
  else kind = 0;

  if (m == M_ASK) {
    String id;
    for (auto& w : s.waiting) if (!w.acked) { id = w.id; break; }
    int every = c.remind > 0 ? c.remind : (c.alert >= 2 ? 5 : 0);   // 分钟；「强」默认每 5 分钟再来一次
    bool fresh = id != lastAlertId;
    bool again = !fresh && every > 0 && millis() - lastRemind > (uint32_t)every * 60000;
    if (fresh || again) {
      lastAlertId = id;
      lastRemind = millis();
      bodyNoteActivity();
      if (c.alert >= 1) { nod(c); if (!mute) chime(c); }
    }
  } else {
    lastAlertId = "";
    if (kind != lastKind) {
      if (kind == 4 && c.shakeLow) shake(c);
      else if (kind == 5) droop();
      else if (kind == 1 || kind == 3) idle(c);
    }
    // 没事时偶尔转转头
    if (kind == 1 && c.wander && !gStill && gSeqIdx >= gSeqLen) {
      if (!nextWander) nextWander = millis() + random(45000, 90000);
      else if (millis() > nextWander) {
        int side = random(2) ? 150 : -150, p = idlePitch(c);
        play({{side, p + 30, 200, 2600}, {0, p, 200, 0}});
        nextWander = 0;
      }
    }
  }
  lastKind = kind;
  tickSeq();
  tickNotes();

  if (millis() - gLedLast < 60) return;
  gLedLast = millis();
  if (millis() < gFindUntil) { setLed((millis() / 250) % 2 ? 0x606060 : 0); return; }
  if (dark) { setLed(0); return; }
  switch (kind) {
    case 1: setLed(c.ledIdleOn ? scale(c.ledIdle, .09f * lb * 2) : 0); break;
    case 2: {
      if (!c.ledAttnOn) { setLed(0); break; }
      float ph = (millis() % 2400) / 2400.0f;
      float k = 0.12f + 0.88f * (0.5f - 0.5f * cosf(ph * 2 * PI));
      setLed(scale(c.ledAttn, k * .5f * lb * 2));
    } break;
    case 3: setLed(c.ledAttnOn ? scale(c.ledAttn, .14f * lb * 2) : 0); break;
    case 4: setLed(scale(0xff2020, .36f * lb * 2)); break;
    default: setLed(0);
  }
}
uint32_t bodyLastActivity() { return gLastActivity; }
