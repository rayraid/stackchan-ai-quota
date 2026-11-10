// aihelper 固件 2.0：画面
// 平时的首页有四种样式（设置里选）：A 轻底栏 / B 眼睛就是额度 / C 说给你听 / D 只有脸。
// AI 等你时：整屏变色 + 大眼睛 + 一行大字，停几秒（底部细条倒计时）后回到首页，右上角留一个小 logo。
// 字体是 Noto Sans SC / Inter 截取出来的平滑字体（fonts/*.vlw，见 tools/make_fonts.py）。
#include "app.h"
#include "i18n.h"

M5Canvas cv(&M5.Display);

// ---------- 字体（编译时嵌进固件，见 platformio.ini 的 embed_files） ----------
#define VLW(n) extern const uint8_t n##_vlw[] asm("_binary_fonts_" #n "_vlw_start");
VLW(cn14) VLW(cn16) VLW(cn18b) VLW(cn26b) VLW(cn38b)
VLW(jp14) VLW(jp16) VLW(jp18b) VLW(jp26b) VLW(jp38b)
VLW(num15b) VLW(num18) VLW(num22b) VLW(num28b)

struct VF { lgfx::PointerWrapper w; lgfx::VLWfont f; };
static VF vf[14];
struct FontSet { const lgfx::IFont *f14, *f16, *f18b, *f26b, *f38b; };
static FontSet FS_ZH, FS_JA;     // 英文用中文那一套（里面有完整的英文字母）
static const lgfx::IFont *F14, *F16, *F18B, *F26B, *F38B, *N15B, *N18, *N22B, *N28B;
static const lgfx::IFont* loadVF(int i, const uint8_t* p) { vf[i].w.set(p); vf[i].f.loadFont(&vf[i].w); return &vf[i].f; }
static void useFonts(const FontSet& f) { F14 = f.f14; F16 = f.f16; F18B = f.f18b; F26B = f.f26b; F38B = f.f38b; }

void uiBegin() {
  FS_ZH = {loadVF(0, cn14_vlw), loadVF(1, cn16_vlw), loadVF(2, cn18b_vlw), loadVF(3, cn26b_vlw), loadVF(4, cn38b_vlw)};
  FS_JA = {loadVF(5, jp14_vlw), loadVF(6, jp16_vlw), loadVF(7, jp18b_vlw), loadVF(8, jp26b_vlw), loadVF(9, jp38b_vlw)};
  N15B = loadVF(10, num15b_vlw); N18 = loadVF(11, num18_vlw); N22B = loadVF(12, num22b_vlw); N28B = loadVF(13, num28b_vlw);
  useFonts(FS_ZH);
  cv.setPsram(true);
  cv.setColorDepth(16);
  cv.createSprite(320, 240);
}

// ---------- 颜色 ----------
struct Theme { uint32_t bg1, bg2, fg, dim, panel, track, eye, glow; bool light; };
static const Theme TH_NIGHT = {0x131c2d, 0x090c13, 0xeef2f7, 0x8b95a3, 0x172031, 0x283143, 0xe6f3ff, 0x82c3ff, false};
static const Theme TH_BLACK = {0x000000, 0x000000, 0xf2f2f2, 0x8a8a8a, 0x131313, 0x2a2a2a, 0xffffff, 0xffffff, false};
static const Theme TH_WARM  = {0x251d17, 0x120e0b, 0xf7ede3, 0xa59686, 0x2c231d, 0x3d322a, 0xffe4bf, 0xffb46e, false};
static const Theme TH_LIGHT = {0xf6f8fb, 0xe2e7ee, 0x18212c, 0x5f6b7a, 0xffffff, 0xd3d9e1, 0x1d2633, 0x000000, true};
static const Theme& themeOf(const String& n) {
  if (n == "black") return TH_BLACK;
  if (n == "warm") return TH_WARM;
  if (n == "light") return TH_LIGHT;
  return TH_NIGHT;
}
struct Lv { uint32_t ok, mid, low, na; };
static const Lv LV_DARK = {0x3ddc84, 0xf5c542, 0xff5d5d, 0x59636f};
static const Lv LV_LIGHT = {0x14a35a, 0xc48a00, 0xe03c3c, 0x9aa3ae};
static uint32_t lvc(const Lv& L, const String& lv) { return lv == "ok" ? L.ok : lv == "mid" ? L.mid : lv == "low" ? L.low : L.na; }

static inline uint16_t c565(uint32_t c) { return lgfx::color565((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF); }
static uint32_t mix(uint32_t a, uint32_t b, float k) {   // k=0 → a，k=1 → b
  auto ch = [&](int s) { int x = (a >> s) & 0xFF, y = (b >> s) & 0xFF; return (uint32_t)constrain((int)lroundf(x + (y - x) * k), 0, 255) << s; };
  return ch(16) | ch(8) | ch(0);
}
static uint32_t bgAt(const Theme& T, int y) { return mix(T.bg1, T.bg2, y / 239.0f); }
static void bgFill(const Theme& T) {
  if (T.bg1 == T.bg2) { cv.fillScreen(c565(T.bg1)); return; }
  for (int y = 0; y < 240; y++) cv.drawFastHLine(0, y, 320, c565(bgAt(T, y)));
}

// ---------- 文字：当前语言的字体里没有的字，用另一种语言的字体补上 ----------
static const lgfx::IFont* altOf(const lgfx::IFont* f) {
  const lgfx::IFont* zh[5] = {FS_ZH.f14, FS_ZH.f16, FS_ZH.f18b, FS_ZH.f26b, FS_ZH.f38b};
  const lgfx::IFont* ja[5] = {FS_JA.f14, FS_JA.f16, FS_JA.f18b, FS_JA.f26b, FS_JA.f38b};
  for (int i = 0; i < 5; i++) { if (f == zh[i]) return ja[i]; if (f == ja[i]) return zh[i]; }
  return nullptr;
}
static bool hasGlyph(const lgfx::IFont* f, uint16_t cp) { uint16_t i; return cp == ' ' || ((const lgfx::VLWfont*)f)->getUnicodeIndex(cp, &i); }
struct Run { const lgfx::IFont* f; String s; };
static std::vector<Run> runs(const String& s, const lgfx::IFont* f) {
  std::vector<Run> v;
  const lgfx::IFont* alt = altOf(f);
  for (int i = 0; i < (int)s.length();) {
    uint8_t c0 = s[i];
    int n = c0 < 0x80 ? 1 : (c0 >> 5) == 6 ? 2 : (c0 >> 4) == 14 ? 3 : 4;
    uint32_t cp = n == 1 ? c0 : n == 2 ? (c0 & 0x1F) : n == 3 ? (c0 & 0x0F) : (c0 & 0x07);
    for (int k = 1; k < n && i + k < (int)s.length(); k++) cp = (cp << 6) | (s[i + k] & 0x3F);
    const lgfx::IFont* use = (alt && cp < 0x10000 && !hasGlyph(f, cp) && hasGlyph(alt, cp)) ? alt : f;
    if (v.empty() || v.back().f != use) v.push_back({use, ""});
    v.back().s += s.substring(i, i + n);
    i += n;
  }
  return v;
}
static int tw(const String& s, const lgfx::IFont* f) {
  int w = 0;
  for (auto& r : runs(s, f)) { cv.setFont(r.f); w += cv.textWidth(r.s); }
  return w;
}
static void txt(const String& s, int x, int y, const lgfx::IFont* f, uint32_t col, textdatum_t d = textdatum_t::top_left) {
  cv.setTextColor(c565(col));
  auto rs = runs(s, f);
  if (rs.size() <= 1) { cv.setFont(f); cv.setTextDatum(d); cv.drawString(s, x, y); return; }
  int w = tw(s, f), h = d & 3;               // 低两位是左右对齐方式：0 左、1 中、2 右
  x -= h == 1 ? w / 2 : h == 2 ? w : 0;
  textdatum_t dl = (textdatum_t)(d & ~3);
  for (auto& r : rs) { cv.setFont(r.f); cv.setTextDatum(dl); cv.drawString(r.s, x, y); x += cv.textWidth(r.s); }
}
// 太长就从末尾按「整个字」截掉，补省略号
static String fit(const String& s, int maxW, const lgfx::IFont* f) {
  if (tw(s, f) <= maxW) return s;
  String t = s;
  while (t.length() > 0) {
    int i = t.length() - 1;
    while (i > 0 && (((uint8_t)t[i]) & 0xC0) == 0x80) i--;
    t.remove(i);
    if (tw(t + "…", f) <= maxW) return t + "…";
  }
  return "";
}
static void rrect(float x, float y, float w, float h, float r, uint32_t col) {
  if (w < 1 || h < 1) return;
  r = std::min(r, std::min(w, h) / 2);
  cv.fillSmoothRoundRect(lroundf(x), lroundf(y), lroundf(w), lroundf(h), lroundf(r), c565(col));
}
static void wline(float x0, float y0, float x1, float y1, float r, uint32_t col) {
  cv.drawWideLine(lroundf(x0), lroundf(y0), lroundf(x1), lroundf(y1), r, c565(col));
}
static String shortLabel(const String& l) { int i = l.lastIndexOf(' '); return i >= 0 ? l.substring(i + 1) : l; }
static const Sub* findSub(const State& s, const String& id) { for (auto& b : s.subs) if (b.id == id) return &b; return nullptr; }

// 偶尔左右张望：9 秒一轮
static float lookDx(uint32_t t, float amp) {
  float p = (t % 9000) / 9000.0f;
  if (p < .2f) return 0;
  if (p < .27f) return -amp * (p - .2f) / .07f;
  if (p < .45f) return -amp;
  if (p < .55f) return -amp + 2 * amp * (p - .45f) / .1f;
  if (p < .73f) return amp;
  if (p < .8f) return amp * (1 - (p - .73f) / .07f);
  return 0;
}

// ---------- 眼睛 ----------
enum Expr { E_CALM, E_ALERT, E_HAPPY, E_WORRY, E_SLEEP };
struct EyeG { float w, h, r; };
static EyeG eyeG(const String& s) {
  if (s == "round") return {40, 40, 20};
  if (s == "bar") return {18, 58, 9};
  return {44, 60, 20};
}
// glow = 0 表示不发光；bgc 是眼睛周围的底色（发光和「担心」的切角要用）
static void eyes(Expr e, int cx, int cy, int gap, uint32_t col, uint32_t glow, uint32_t bgc, const Cfg& c, uint32_t t, bool canLook, float open = 1, float sc = 1) {
  float xs[2] = {cx - gap / 2.0f, cx + gap / 2.0f};
  if (e == E_SLEEP) { for (float x : xs) rrect(x - 20 * sc, cy - 3, 40 * sc, 6, 3, col); return; }
  if (e == E_HAPPY) {           // 弯弯的笑眼
    for (float x : xs) {
      const int N = 12;
      float px = 0, py = 0;
      for (int i = 0; i <= N; i++) {
        float a = PI * (1.17f + 0.66f * i / N);
        float qx = x + 21 * sc * cosf(a), qy = cy + 12 * sc + 21 * sc * sinf(a);
        if (i) wline(px, py, qx, qy, 5 * sc, col);
        px = qx; py = qy;
      }
    }
    return;
  }
  EyeG g = eyeG(c.eye);
  float w = g.w * sc, h = g.h * sc, r = g.r * sc, y0 = cy;
  if (e == E_ALERT) { w *= 1.22f; h *= 1.12f; r *= 1.22f; }
  float dx = (e == E_CALM && canLook && c.look) ? lookDx(t, 9 * sc) : 0;
  bool blink = c.blink && e != E_ALERT && (t % 4300) > 4140;
  if (open < 1 && !blink) { float nh = std::max(8.0f, h * open); y0 += (h - nh) / 2; h = nh; }   // 犯困：眼睛只睁一半
  if (blink) h = 7;
  r = std::min(r, std::min(w, h) / 2);
  for (int i = 0; i < 2; i++) {
    float x = xs[i] + dx;
    if (glow && e != E_WORRY) {
      static const float A[3] = {.10f, .18f, .30f};
      for (int k = 0; k < 3; k++) { float ex = (3 - k) * 2.5f; rrect(x - w / 2 - ex, y0 - h / 2 - ex, w + 2 * ex, h + 2 * ex, r + ex, mix(bgc, glow, A[k])); }
    }
    if (e == E_WORRY && !blink) {  // 担心：靠里的上角高、靠外的上角低。在一张小画布上画好再贴上，切角不会碰到背景
      static M5Canvas sp(&cv);
      int W = lroundf(w) + 2, H = lroundf(h) + 2;
      if (sp.width() != W || sp.height() != H) { sp.deleteSprite(); sp.setColorDepth(16); sp.createSprite(W, H); }
      int X0 = lroundf(x - w / 2) - 1, Y0 = lroundf(y0 - h / 2) - 1;
      for (int j = 0; j < H; j++) for (int q = 0; q < W; q++) sp.drawPixel(q, j, cv.readPixel(X0 + q, Y0 + j));   // 背景原样拷过来（渐变也对得上）
      uint16_t cutc = cv.readPixel(i == 0 ? X0 : X0 + W - 1, Y0 + (int)(.2f * h));
      sp.fillSmoothRoundRect(1, 1, W - 2, H - 2, lroundf(r), c565(col));
      float sg = i == 0 ? 1 : -1, xin = 1 + (sg > 0 ? w : 0), xout = 1 + (sg > 0 ? 0 : w), top = 1, k = .45f * h / w;
      float ax = xin + sg * 6, ay = top - 6 * k, bx = xout - sg * 6, by = top + .45f * h + 6 * k;
      float vx = bx - ax, vy = by - ay, len = sqrtf(vx * vx + vy * vy), nx = vy / len, ny = -vx / len;
      if (ny > 0) { nx = -nx; ny = -ny; }
      const float R = 14;
      sp.drawWideLine(lroundf(ax + nx * R), lroundf(ay + ny * R), lroundf(bx + nx * R), lroundf(by + ny * R), R, cutc);
      sp.pushSprite(X0, Y0);
    } else rrect(x - w / 2, y0 - h / 2, w, h, r, col);
  }
}
static void zz(int x, int y, uint32_t t, uint32_t col, uint32_t bgc) {
  float k = (t % 2400) / 2400.0f;
  txt("z", x, y - 6 * k, N18, mix(col, bgc, k * .6f));
  txt("z", x + 14, y - 16 - 6 * k, N22B, mix(col, bgc, .1f + k * .5f));
}
static void sweat(int x, int y) {
  cv.fillTriangle(x, y, x - 5, y + 10, x + 5, y + 10, c565(0x6ec1ff));
  cv.fillSmoothCircle(x, y + 11, 5, c565(0x6ec1ff));
}
static uint32_t eyeColor(const Cfg& c, const Theme& T) { return c.eyeColorSet ? c.eyeColor : T.eye; }

// ---------- 图标（官方 logo，由小管家发来；没有就画字母方块） ----------
static bool icon(const String& id, const String& ver, int size, int x, int y, bool darkBg) {
  const uint8_t* px = iconGet(id, ver, size, darkBg);
  if (!px) return false;
  cv.pushAlphaImage(x, y, size, size, (const lgfx::argb8888_t*)px);
  return true;
}
static void letterTile(const Sub& b, int x, int y, int size) {
  rrect(x, y, size, size, size * 0.3f, b.hue);
  txt(b.mono, x + size / 2, y + size / 2 + 1, size >= 36 ? N22B : N15B, 0x0b0e13, textdatum_t::middle_center);
}
static void badge(const Sub& b, int x, int y, int size, bool darkBg) {
  if (!icon(b.id, b.icon, size, x, y, darkBg)) letterTile(b, x, y, size);
}

// ---------- 首页共用 ----------
static int rankOf(const String& k) { return k == "approval" ? 0 : k == "question" ? 1 : k == "error" ? 2 : k == "done" ? 3 : k == "restored" ? 4 : 5; }
// 首页上放哪几家（设置里的第 1/2/3 格；没设就按顺序取）
static std::vector<const Sub*> faceSubs(const State& s, int maxN) {
  std::vector<const Sub*> v;
  for (auto& id : s.face) if (const Sub* b = findSub(s, id)) v.push_back(b);
  if (v.empty()) for (auto& b : s.subs) { if ((int)v.size() >= maxN) break; v.push_back(&b); }
  if ((int)v.size() > maxN) v.resize(maxN);
  return v;
}
struct Val { int val; uint32_t col, num; bool na; };      // 显示的数字、条的颜色、数字的颜色
static Val valOf(const State& s, const Cfg& c, const Theme& T, const Lv& L, const Sub& b, bool grey) {
  bool na = grey || b.left < 0 || b.stale || !s.ok;
  int v = b.left < 0 ? -1 : (c.used ? 100 - b.left : b.left);
  uint32_t col = na ? L.na : lvc(L, b.level);
  return {v, col, na ? T.dim : (b.level == "ok" ? T.fg : col), na};
}
static void numPct(const Val& q, int x, int cy, const lgfx::IFont* nf, const Theme& T, textdatum_t d) {
  String num = q.val < 0 ? String("--") : String(q.val);
  int nw = tw(num, nf), pw = q.val < 0 ? 0 : tw("%", F14) + 2;
  int x0 = d == textdatum_t::middle_right ? x - nw - pw : x;
  txt(num, x0, cy, nf, q.num, textdatum_t::middle_left);
  if (q.val >= 0) txt("%", x0 + nw + 2, cy + 4, F14, T.dim, textdatum_t::middle_left);
}
// 左上角：时钟，或者数据过期时写「数据停在 HH:MM」
static void topLeft(const State& s, const Cfg& c, const Theme& T, bool grey) {
  if (grey) txt(trf(S_STALE_S, s.dataTime.length() ? s.dataTime.c_str() : tr(S_LONG_AGO)), 12, 10, F14, T.dim);
  else if (c.clock && s.time.length()) txt(s.time, 12, 10, N18, T.dim);
}
// 整屏提醒收起后：一个小圆章，里面是在等你的那家 AI 的 logo（没有图标就写字母）
static void waitMark(const State& s, const Theme& T, int x, int y) {
  const Wait* w = nullptr;
  for (auto& x2 : s.waiting) if (!w || rankOf(x2.kind) < rankOf(w->kind) || (rankOf(x2.kind) == rankOf(w->kind) && x2.since < w->since)) w = &x2;
  if (!w) return;
  cv.fillSmoothCircle(x, y, 21, c565(0xffb020));
  cv.fillSmoothCircle(x, y, 18, c565(T.panel));
  if (!icon(w->iconId, w->iconV, 24, x - 12, y - 12, !T.light))
    txt(w->mono.length() ? w->mono : w->agent.substring(0, 2), x, y + 1, N15B, T.fg, textdatum_t::middle_center);
}
// 首页上的红色小胶囊「只剩 8%」（B、D 用：没常驻显示的那一家快用完时才出现）
struct Rect { int x, y, w, h; String id; bool hit(int px, int py) const { return w > 0 && px >= x && px < x + w && py >= y && py < y + h; } };
static Rect gChip;
static const Low* lowNotIn(const State& s, const std::vector<const Sub*>& shown) {
  for (auto& l : s.lows) { bool in = false; for (auto* b : shown) if (b->id == l.id) in = true; if (!in) return &l; }
  return nullptr;
}
static void lowChip(const State& s, const Low& l, const Theme& T, const Lv& L, int cy) {
  String t = trf(S_ONLY_LEFT, l.left);
  int w = 12 + 20 + 6 + tw(t, F16) + 14, x = 160 - w / 2, y = cy - 15;
  uint32_t bgc = bgAt(T, cy);
  rrect(x, y, w, 30, 15, mix(bgc, L.low, .55f));
  rrect(x + 1.5f, y + 1.5f, w - 3, 27, 13.5f, mix(bgc, L.low, .16f));
  if (const Sub* b = findSub(s, l.id)) badge(*b, x + 12, cy - 10, 20, !T.light);
  txt(t, x + 38, cy + 1, F16, L.low, textdatum_t::middle_left);
  gChip = {x, y, w, 30, l.id};
}

// ---------- A 轻底栏：去掉方块，数字像一行小字托在脸下面 ----------
static int aCenter(int i, int n) { return 160 + (int)lroundf((i - (n - 1) / 2.0f) * 104); }
static void homeA(const State& s, const Cfg& c, const Theme& T, const Lv& L, uint32_t t, bool grey, Expr e) {
  bgFill(T);
  eyes(e, 160, 90, 118, eyeColor(c, T), T.light ? 0 : T.glow, bgAt(T, 90), c, t, true, c.sleepy ? .45f : 1, 1.18f);
  if (c.sleepy && e == E_CALM) zz(236, 50, t, T.dim, bgAt(T, 50));
  auto v = faceSubs(s, 3);
  int n = v.size();
  for (int i = 0; i < n; i++) {
    const Sub& b = *v[i];
    int cx = aCenter(i, n);
    Val q = valOf(s, c, T, L, b, grey);
    badge(b, cx - 40, 186, 22, !T.light);
    numPct(q, cx - 12, 198, N22B, T, textdatum_t::middle_left);
    rrect(cx - 40, 218, 82, 3, 1.5f, T.track);
    if (q.val > 0) rrect(cx - 40, 218, std::max(3, 82 * q.val / 100), 3, 1.5f, q.col);
    if (i < n - 1) cv.fillRect(cx + 52, 188, 1, 26, c565(mix(bgAt(T, 200), T.dim, .25f)));
  }
}

// ---------- B 眼睛就是额度：两只眼睛像小水箱，剩多少亮多少 ----------
static EyeG tankG(const String& e) {
  if (e == "round") return {84, 84, 42};
  if (e == "bar") return {38, 100, 19};
  return {64, 102, 30};
}
static const int B_X[2] = {108, 212}, B_CY = 98;
static void tank(float x, int cy, const EyeG& g, int left, uint32_t fill, uint32_t ec, const Theme& T, bool glow) {
  uint32_t bgc = bgAt(T, cy);
  float x0 = x - g.w / 2, y0 = cy - g.h / 2;
  if (glow) for (int k = 0; k < 2; k++) { float ex = (2 - k) * 2.5f; rrect(x0 - ex, y0 - ex, g.w + 2 * ex, g.h + 2 * ex, g.r + ex, mix(bgc, T.glow, k ? .14f : .08f)); }
  rrect(x0, y0, g.w, g.h, g.r, mix(bgc, ec, .24f));                                   // 边
  rrect(x0 + 2, y0 + 2, g.w - 4, g.h - 4, std::max(1.0f, g.r - 2), mix(bgc, ec, .07f));   // 空着的部分
  if (left > 0) {                       // 亮着的部分：整只眼睛的形状，只露出下面那一截
    int top = lroundf(y0 + g.h - g.h * std::min(100, left) / 100.0f);
    cv.setClipRect(lroundf(x0) - 1, top, lroundf(g.w) + 2, lroundf(y0 + g.h) - top + 2);
    rrect(x0, y0, g.w, g.h, g.r, fill);
    cv.clearClipRect();
  }
}
static void homeB(const State& s, const Cfg& c, const Theme& T, const Lv& L, uint32_t t, bool grey, Expr e) {
  bgFill(T);
  uint32_t ec = eyeColor(c, T);
  auto v = faceSubs(s, 2);
  EyeG g = tankG(c.eye);
  float dx = (e == E_CALM && c.look) ? lookDx(t, 7) : 0;
  bool blink = e == E_CALM && c.blink && (t % 4300) > 4140;
  if (e == E_HAPPY) eyes(E_HAPPY, 160, 88, 104, ec, 0, 0, c, t, false, 1, 1.4f);
  for (int i = 0; i < 2; i++) {
    const Sub* b = i < (int)v.size() ? v[i] : nullptr;
    Val q = b ? valOf(s, c, T, L, *b, grey) : Val{-1, ec, T.dim, true};
    uint32_t fill = !b ? ec : q.na ? L.na : (b->level == "low" ? L.low : ec);
    if (e != E_HAPPY) {
      if (blink) rrect(B_X[i] + dx - g.w / 2, B_CY - 3.5f, g.w, 7, 3.5f, fill);
      else tank(B_X[i] + dx, B_CY, g, b ? std::max(0, b->left) : 100, fill, ec, T, !T.light && !q.na);
    }
    if (!b) continue;
    String num = q.val < 0 ? String("--") : String(q.val);
    int total = 20 + 6 + tw(num, N22B) + 2 + tw("%", F14), x0 = B_X[i] - total / 2;
    badge(*b, x0, 167, 20, !T.light);
    numPct(q, x0 + 26, 177, N22B, T, textdatum_t::middle_left);
  }
  if (c.sleepy && e == E_CALM) zz(246, 30, t, T.dim, bgAt(T, 30));
  gChip = {};
  if (const Low* l = lowNotIn(s, v)) lowChip(s, *l, T, L, 216);
}

// ---------- C 说给你听：脸在左边，额度在旁边的对话气泡里 ----------
static const int C_BX = 140, C_BY = 12, C_BW = 172, C_BH = 216;
static int cRowH(int n) { return n ? std::min(68, (C_BH - 12) / n) : 68; }
static int cTop0(int n) { return C_BY + (C_BH - n * cRowH(n)) / 2; }
static void homeC(const State& s, const Cfg& c, const Theme& T, const Lv& L, uint32_t t, bool grey, Expr e) {
  bgFill(T);
  eyes(e, 74, 128, 58, eyeColor(c, T), T.light ? 0 : T.glow, bgAt(T, 128), c, t, true, c.sleepy ? .45f : 1, .72f);
  rrect(C_BX, C_BY, C_BW, C_BH, 18, T.panel);
  cv.fillTriangle(C_BX + 1, 112, 124, 128, C_BX + 1, 144, c565(T.panel));
  auto v = faceSubs(s, 3);
  int n = v.size(), h = cRowH(n), top0 = cTop0(n);
  for (int i = 0; i < n; i++) {
    const Sub& b = *v[i];
    int top = top0 + i * h;
    Val q = valOf(s, c, T, L, b, grey);
    badge(b, 154, top + h / 2 - 24, 24, !T.light);
    numPct(q, 298, top + h / 2 - 12, N28B, T, textdatum_t::middle_right);
    rrect(154, top + h / 2 + 10, 144, 4, 2, T.track);
    if (q.val > 0) rrect(154, top + h / 2 + 10, std::max(4, 144 * q.val / 100), 4, 2, q.col);
    if (i < n - 1) cv.fillRect(154, top + h - 1, 144, 1, c565(mix(T.panel, T.dim, .22f)));
  }
}

// ---------- D 只有脸：额度只在快用完时露出来 ----------
static void homeD(const State& s, const Cfg& c, const Theme& T, const Lv& L, uint32_t t, bool grey, Expr e) {
  bgFill(T);
  const Low* l = s.lows.empty() ? nullptr : &s.lows[0];
  int cy = l ? 96 : 112;
  eyes(e, 160, cy, 124, eyeColor(c, T), T.light ? 0 : T.glow, bgAt(T, cy), c, t, true, c.sleepy ? .45f : 1, 1.36f);
  if (c.sleepy && e == E_CALM) zz(250, cy - 62, t, T.dim, bgAt(T, cy - 62));
  gChip = {};
  if (l) lowChip(s, *l, T, L, 205);
}

static void pageHome(const State& s, const Cfg& c, const Theme& T, const Lv& L, uint32_t t, bool grey, bool happy) {
  Expr e = happy ? E_HAPPY : E_CALM;
  if (c.home == "A") homeA(s, c, T, L, t, grey, e);
  else if (c.home == "C") homeC(s, c, T, L, t, grey, e);
  else if (c.home == "D") homeD(s, c, T, L, t, grey, e);
  else homeB(s, c, T, L, t, grey, e);
  topLeft(s, c, T, grey);
  if (c.home == "C") waitMark(s, T, 74, 66); else waitMark(s, T, 293, 27);
}

bool uiFaceHit(const State& s, const Cfg& c, int x, int y, String& subId) {
  if ((c.home == "B" || c.home == "D" || c.home.length() == 0) && gChip.hit(x, y)) { subId = gChip.id; return true; }
  if (c.home == "A") {
    auto v = faceSubs(s, 3);
    if (y < 166 || v.empty()) return false;
    int best = 0;
    for (int i = 1; i < (int)v.size(); i++) if (abs(x - aCenter(i, v.size())) < abs(x - aCenter(best, v.size()))) best = i;
    subId = v[best]->id; return true;
  }
  if (c.home == "C") {
    auto v = faceSubs(s, 3);
    int n = v.size(), h = cRowH(n), top0 = cTop0(n);
    if (x < C_BX || y < top0 || y >= top0 + n * h) return false;
    subId = v[(y - top0) / h]->id; return true;
  }
  if (c.home == "D") return false;
  auto v = faceSubs(s, 2);                 // B：点某只眼睛（连同下面的数字）
  EyeG g = tankG(c.eye);
  for (int i = 0; i < (int)v.size(); i++)
    if (abs(x - B_X[i]) <= std::max(50.0f, g.w / 2 + 16) && y >= 36 && y <= 196) { subId = v[i]->id; return true; }
  return false;
}

// 额度快用完：顶部红卡片（亮 1 分钟就收进首页）
static void pageLow(const State& s, const Cfg& c, const Theme& T, uint32_t t, const Low& l) {
  bgFill(T);
  eyes(E_WORRY, 160, 156, 110, eyeColor(c, T), T.light ? 0 : T.glow, bgAt(T, 156), c, t, false, 1, 1.1f);
  sweat(246, 112);
  uint32_t cb = LV_DARK.low, cf = 0x2a0606;
  rrect(8, 8, 304, 68, 18, cb);
  cv.fillSmoothCircle(42, 42, 19, c565(cf));
  txt("!", 42, 43, N22B, cb, textdatum_t::middle_center);
  txt(fit(trf(S_ONLY_LEFT, l.left), 230, F26B), 72, 10, F26B, cf);
  txt(fit(l.name + " · " + (l.reset.length() ? l.reset : l.label), 230, F16), 72, 46, F16, mix(cb, cf, .8f));
}
// 有 AI 在等你：整屏变色
static void pageAsk(const State& s, const Cfg& c, const UiCtx& u) {
  uint32_t t = millis();
  const Wait* w = nullptr;
  for (auto& x : s.waiting) if (x.id == u.flashId) w = &x;
  if (!w) return;
  const String& k = w->kind;
  bool green = k == "done" || k == "restored";
  uint32_t bgc = green ? 0x3ddc84 : k == "error" ? 0xff7a6b : 0xffb020;
  uint32_t fg = green ? 0x04210f : k == "error" ? 0x2a0606 : 0x1b1300;
  cv.fillScreen(c565(bgc));
  Expr e = green ? E_HAPPY : k == "error" ? E_WORRY : E_ALERT;
  eyes(e, 160, 72, 100, fg, 0, bgc, c, t, false);
  // 右上角：举着对方的 logo（像来电显示），小圆点里是 ! ? ✓
  cv.fillSmoothCircle(270, 40, 27, c565(fg));
  if (icon(w->iconId, w->iconV, 28, 256, 26, true)) {
    cv.fillSmoothCircle(290, 62, 11, c565(0xffffff));
    if (green) { wline(284, 62, 288, 66, 1.8f, fg); wline(288, 66, 296, 57, 1.8f, fg); }
    else txt(k == "question" ? "?" : "!", 290, 63, N15B, fg, textdatum_t::middle_center);
  } else {
    cv.fillSmoothCircle(270, 40, 27, c565(bgc));      // 没有图标：照旧只画 ! 或 ?
    if (k == "approval") txt("!", 268, 22, F38B, fg, textdatum_t::top_center);
    if (k == "question") txt("?", 268, 22, F38B, fg, textdatum_t::top_center);
  }
  String title = tr(k == "approval" ? S_APPROVAL : k == "question" ? S_QUESTION : k == "done" ? S_DONE : k == "error" ? S_ERROR : k == "restored" ? S_RESTORED : S_NOTE);
  txt(fit(title, 308, F38B), 160, 118, F38B, fg, textdatum_t::top_center);
  String sub = w->agent + " · " + (k == "note" ? w->text : w->project);
  txt(fit(sub, 300, F16), 160, 170, F16, mix(bgc, fg, .82f), textdatum_t::top_center);
  // 底部：倒计时细条（停完自己回到首页）；再提醒时上面写已等多久
  if (u.reminder) txt(trf(S_WAITED, (unsigned)(u.waited / 60), (unsigned)(u.waited % 60)), 160, 196, F14, mix(bgc, fg, .62f), textdatum_t::top_center);
  if (u.flashLeft >= 0) {
    rrect(100, 218, 120, 5, 2.5f, mix(bgc, fg, .18f));
    if (u.flashLeft > 0) rrect(100, 218, std::max(5.0f, 120 * u.flashLeft), 5, 2.5f, mix(bgc, fg, .55f));
  }
}
// 暗下来的画面：连不上、休息、连 WiFi、没配对
static void pageDark(const Cfg& c, const String& title, const String& sub, const String& sub2, uint32_t t, bool sleepy) {
  cv.fillScreen(c565(0x06080c));
  if (sleepy) { eyes(E_SLEEP, 160, 86, 100, 0x4f5867, 0, 0x06080c, c, t, false); zz(222, 62, t, 0x6f7a88, 0x06080c); }
  else eyes(E_CALM, 160, 82, 100, 0x8a94a3, 0, 0x06080c, c, t, false, .7f);
  txt(fit(title, 300, F26B), 160, 120, F26B, 0xc3cad3, textdatum_t::top_center);
  txt(fit(sub, 300, F16), 160, 162, F16, 0x7c8796, textdatum_t::top_center);
  if (sub2.length()) txt(fit(sub2, 300, F14), 160, 192, F14, 0x5d6775, textdatum_t::top_center);
}
static void pageSetup(const UiCtx& u) {
  cv.fillScreen(c565(0x0b0e13));
  txt(tr(S_SETUP_T), 12, 8, F18B, 0xe9edf2);
  rrect(12, 40, 112, 112, 8, 0xffffff);
  cv.qrcode("WIFI:T:nopass;S:StackChan-Setup;;", 18, 46, 100);
  int x = 136;
  const Str lines[] = {S_SETUP_1A, S_SETUP_1B, S_SETUP_2A, S_SETUP_2B, S_SETUP_2C};
  const int ys[] = {40, 58, 84, 102, 120};
  for (int i = 0; i < 5; i++) txt(fit(tr(lines[i]), 180, F14), x, ys[i], F14, 0xb9c1cc);
  txt(fit(tr(S_SETUP_3), 300, F14), 12, 170, F14, 0x8b95a3);
  txt(fit(tr(S_SETUP_4), 300, F14), 12, 192, F14, 0x8b95a3);
}
static void pageOta(int p) {
  cv.fillScreen(c565(0x0b0e13));
  if (p == -2) {
    txt(tr(S_UPDATE_FAIL), 160, 80, F26B, 0xff8a8a, textdatum_t::top_center);
    txt(fit(tr(S_UPDATE_FAIL_S), 304, F14), 160, 128, F14, 0x8b95a3, textdatum_t::top_center);
    return;
  }
  txt(tr(S_UPDATING), 160, 70, F26B, 0xeef2f7, textdatum_t::top_center);
  rrect(40, 120, 240, 10, 5, 0x283143);
  if (p > 0) rrect(40, 120, std::max(10, 240 * p / 100), 10, 5, 0x4aa3ff);
  txt(trf(S_KEEP_POWER, std::max(0, p)), 160, 146, F16, 0x8b95a3, textdatum_t::top_center);
}

// ---------- 明细列表、单个订阅 ----------
static const int LIST_TOP = 40;
static int listRows(const State& s) { return std::min((int)s.subs.size(), 6); }
int uiListHit(const State& s, int y) {
  int n = listRows(s);
  if (!n || y < LIST_TOP) return -1;
  int i = (y - LIST_TOP) / (200 / n);
  return i < n ? i : -1;
}
static void pageList(const State& s, const Cfg& c, const Theme& T, const Lv& L) {
  bgFill(T);
  txt(tr(c.used ? S_ALL_USED : S_ALL), 12, 8, F18B, T.fg);
  if (s.ok) {
    String t = trf(S_SYNCED, s.time.c_str());
    int w = tw(t, F14);
    cv.fillSmoothCircle(308 - w - 9, 20, 3, c565(lvc(T.light ? LV_LIGHT : LV_DARK, "ok")));
    txt(t, 308, 20, F14, T.dim, textdatum_t::middle_right);
  } else txt(trf(S_STALE_S, s.dataTime.c_str()), 308, 20, F14, T.dim, textdatum_t::middle_right);
  int n = listRows(s), h = n ? 200 / n : 200;
  for (int i = 0; i < n; i++) {
    const Sub& b = s.subs[i];
    int y = LIST_TOP + i * h, cy = y + h / 2;
    bool na = !s.ok || b.left < 0 || b.stale;
    uint32_t col = na ? L.na : lvc(L, b.level);
    int val = b.left < 0 ? -1 : (c.used ? 100 - b.left : b.left);
    cv.drawFastHLine(12, y, 296, c565(mix(bgAt(T, y), T.dim, .22f)));
    badge(b, 11, cy - 14, 28, !T.light);
    txt(fit(b.name, 120, F16), 48, cy - 19, F16, T.fg);
    txt(fit(b.left < 0 ? (b.error.length() ? b.error : String(tr(S_CANT_READ))) : b.label, 122, F14), 48, cy + 1, F14, T.dim);
    rrect(176, cy - 3, 58, 6, 3, T.track);
    if (val > 0) rrect(176, cy - 3, std::max(6, 58 * val / 100), 6, 3, col);
    txt(val < 0 ? String("--") : String(val) + "%", 308, cy + 1, N22B, na ? T.dim : (b.level == "ok" ? T.fg : col), textdatum_t::middle_right);
  }
}
static void ring(int cx, int cy, int r, int val, uint32_t col, const Theme& T) {
  cv.fillSmoothCircle(cx, cy, r + 5, c565(T.track));
  cv.fillSmoothCircle(cx, cy, r - 5, c565(bgAt(T, cy)));
  if (val <= 0) return;
  const int N = std::max(2, 72 * val / 100);
  float px = 0, py = 0;
  for (int i = 0; i <= N; i++) {
    float a = -PI / 2 + 2 * PI * (val / 100.0f) * i / N;
    float qx = cx + r * cosf(a), qy = cy + r * sinf(a);
    if (i) wline(px, py, qx, qy, 5, col);
    px = qx; py = qy;
  }
}
static void pageDetail(const State& s, const Cfg& c, const Sub& b, const Theme& T, const Lv& L) {
  bgFill(T);
  badge(b, 10, 6, 40, !T.light);
  txt(fit(b.name, 160, F16), 60, 8, F16, T.fg);
  txt(tr(b.stale ? S_STALE_DATA : (c.used ? S_USED : S_LEFT)), 60, 29, F14, T.dim);
  int n = std::min((int)b.wins.size(), 4);
  if (!n) { txt(b.error.length() ? b.error : String(tr(S_CANT_READ)), 160, 110, F16, T.dim, textdatum_t::top_center); return; }
  if (n <= 3) {
    for (int i = 0; i < n; i++) {
      const Win& w = b.wins[i];
      int cx = 160 + (int)lroundf((i - (n - 1) / 2.0f) * 104), cy = 112;
      bool na = !s.ok || b.stale;
      int val = c.used ? 100 - w.left : w.left;
      ring(cx, cy, 37, val, na ? L.na : lvc(L, w.level), T);
      txt(String(val), cx, cy + 1, N28B, T.fg, textdatum_t::middle_center);
      txt(fit(w.label, 100, F14), cx, 160, F14, T.fg, textdatum_t::top_center);
      txt(fit(w.reset.length() ? w.reset : String(tr(S_UNUSED)), 100, F14), cx, 182, F14, T.dim, textdatum_t::top_center);
      if (w.pace.length() && n == 1) txt(fit(w.pace, 296, F14), 160, 206, F14, L.mid, textdatum_t::top_center);
    }
    return;
  }
  int h = 190 / n;   // 4 个时间段：一行一个，名称和恢复时间在同一行，下面一根条
  for (int i = 0; i < n; i++) {
    const Win& w = b.wins[i];
    int y = 50 + i * h;
    bool na = !s.ok || b.stale;
    uint32_t col = na ? L.na : lvc(L, w.level);
    int val = c.used ? 100 - w.left : w.left;
    String lab = fit(w.label, 150, F16);
    txt(lab, 12, y + 2, F16, T.fg);
    txt(fit(w.reset, 236 - (24 + tw(lab, F16)), F14), 24 + tw(lab, F16), y + 4, F14, T.dim);
    txt(String(val) + "%", 308, y, N22B, w.level == "ok" ? T.fg : col, textdatum_t::top_right);
    rrect(12, y + 28, 296, 7, 3, T.track);
    if (val > 0) rrect(12, y + 28, std::max(7, 296 * val / 100), 7, 3, col);
  }
}

// ---------- 按情况画 ----------
void uiRender(const State& s, const Cfg& c, Mode m, const UiCtx& u) {
  uint32_t t = millis();
  i18nSet(c.lang);
  useFonts(i18nLang() == L_JA ? FS_JA : FS_ZH);
  const Theme& T = themeOf(c.theme);
  const Lv& L = T.light ? LV_LIGHT : LV_DARK;
  auto calmPages = [&](bool grey) {
    if (u.page == P_DETAIL) { if (const Sub* b = findSub(s, u.detailId)) { pageDetail(s, c, *b, T, L); return; } }
    if (u.page != P_FACE) { pageList(s, c, T, L); return; }
    pageHome(s, c, T, L, t, grey, u.happy);
  };
  switch (m) {
    case M_SETUP: pageSetup(u); break;
    case M_NOLINK: pageDark(c, tr(S_NOLINK_T), tr(S_NOLINK_S), tr(S_NOLINK_S2), t, false); break;
    case M_CONNECTING: pageDark(c, tr(S_CONNECTING), u.ssid, "", t, false); break;
    case M_OFF: pageDark(c, tr(S_OFF_T), tr(S_OFF_S), "", t, true); break;
    case M_REST: pageDark(c, tr(S_REST_T), tr(S_REST_S), "", t, true); break;
    case M_UPDATING: pageOta(u.otaProgress); break;
    case M_ASK: pageAsk(s, c, u); break;
    case M_LOW:
      if (u.page != P_FACE || s.lows.empty()) calmPages(!s.ok);
      else pageLow(s, c, T, t, s.lows[0]);
      break;
    case M_STALE: calmPages(true); break;      // 数据过期：数字变灰，左上角写「数据停在 HH:MM」
    default: calmPages(false);
  }
  cv.pushSprite(0, 0);
}
