// aihelper 固件 2.0：机器人屏幕上的固定文字（中文 / 日文 / 英文）
// 注意：tools/make_fonts.py 会从下面三张表里收集用到的字来切标题字体，改了文字要重新运行它。
#include "i18n.h"

static const char* const ZH[S_COUNT] = {
  "要你批准", "有问题问你", "做完了", "出错停下了", "有新消息",
  "只剩 %d%%", "额度没有更新", "数据停在 %s", "很久以前",
  "连不上 Mac", "可能是 Mac 睡着了", "Mac 休息了", "我也睡一会儿", "正在连接 WiFi",
  "还没和 Mac 配对", "用 USB 线接到 Mac，打开小管家", "按安装向导走一遍就好",
  "摸头 = 知道了", "点屏幕 = 知道了", "已等 %u:%02u", "还有 %d 个", "%d 个在等",
  "全部额度", "已用额度", "%s 已同步", "已用", "还剩", "数据过期了", "点屏幕返回", "暂时读不到", "还没用过",
  "正在升级", "请勿断电 · %d%%", "升级没成功", "机器人照常工作，稍后可以在 Mac 上重试",
  "先帮我连上 WiFi", "1 用 USB 线接到 Mac，", "  打开小管家（推荐）", "2 或者手机扫左边的码，",
  "  连热点 StackChan-Setup", "  在弹出的页面选 WiFi", "没弹出页面就用浏览器打开 192.168.4.1", "要用 2.4G WiFi，并和 Mac 在同一个网络",
  "额度恢复了",
};

static const char* const JA[S_COUNT] = {
  "承認待ち", "質問があります", "完了しました", "エラーで停止", "お知らせ",
  "残り %d%%", "使用量が古いまま", "%s 時点のデータ", "かなり前",
  "Mac につながらない", "Mac がスリープ中かも", "Mac はお休み中", "わたしもひと休み", "WiFi に接続中",
  "Mac と未ペアリング", "USB で Mac につなぎ、Butler を開く", "セットアップの案内に従ってね",
  "頭をなでる = 了解", "画面タップ = 了解", "待ち %u:%02u", "ほか %d 件", "%d 件待ち",
  "残量一覧", "使用量一覧", "%s 同期済み", "使用", "残り", "データが古い", "タップで戻る", "取得できません", "未使用",
  "アップデート中", "電源を切らないで · %d%%", "アップデート失敗", "いつも通り動きます。Mac からやり直せます",
  "まず WiFi につないでね", "1 USB で Mac につなぎ、", "  Butler を開く（おすすめ）", "2 またはスマホで左のコード",
  "  StackChan-Setup に接続", "  表示された画面で WiFi を選択", "画面が出なければ 192.168.4.1 を開く", "2.4G の WiFi で、Mac と同じネットワークに",
  "使用量が回復",
};

static const char* const EN[S_COUNT] = {
  "Needs approval", "Has a question", "Done", "Hit an error", "New message",
  "Only %d%% left", "Usage is stale", "Data from %s", "a while ago",
  "Can't reach Mac", "Mac may be asleep", "Mac is resting", "Taking a nap too", "Connecting to WiFi",
  "Not paired yet", "Connect to Mac by USB, open Butler", "Follow the setup assistant",
  "Pat head = got it", "Tap = got it", "Waiting %u:%02u", "+%d more", "%d waiting",
  "All quotas", "Usage", "Synced %s", "used", "left", "Data is stale", "Tap to go back", "Can't read now", "Not used yet",
  "Updating", "Keep it powered · %d%%", "Update failed", "Still working. Retry from your Mac later",
  "Let's get on WiFi", "1 Connect to Mac by USB", "  and open Butler (best)", "2 Or scan the code with",
  "  your phone: StackChan-Setup", "  then pick your WiFi", "No page? Open 192.168.4.1", "Use 2.4G WiFi, same network as the Mac",
  "Quota is back",
};

static Lang gLang = L_ZH;
void i18nSet(const String& lang) { gLang = lang == "ja" ? L_JA : lang == "en" ? L_EN : L_ZH; }
Lang i18nLang() { return gLang; }
const char* tr(Str k) { return (gLang == L_JA ? JA : gLang == L_EN ? EN : ZH)[k]; }
String trf(Str k, ...) {
  char buf[160];
  va_list ap;
  va_start(ap, k);
  vsnprintf(buf, sizeof buf, tr(k), ap);
  va_end(ap);
  return buf;
}
