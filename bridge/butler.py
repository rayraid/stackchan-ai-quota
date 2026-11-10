#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""aihelper 小管家

把两路信息整理成一份很小的状态，给 StackChan（和浏览器里的模拟器）来取：
  1. 额度：全部来自 CodexBar 命令行。只有命令行某一轮没读到某一家时，才用
     CodexBar 应用写出的共享文件顶上（CodexBar 配置里的 shareUsageWithCLI 开关）。
  2. 等你回复：接收 peon-ping 的「手机推送」（我们把推送地址指到了本机）。

只用 Python 自带的库，不需要安装任何东西。运行：python3 butler.py
"""
import datetime
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, 'config.json')

DEFAULTS = {
    'listen': '127.0.0.1',          # 设备接入时改成 0.0.0.0
    'port': 8787,
    'token': '',                    # 非本机访问必须带这个口令，首次运行自动生成
    'codexbar_cli': '/opt/homebrew/bin/codexbar',
    'shared_usage_path': '~/Library/Application Support/CodexBar/CLIUsageCache/usage.json',
    'peon_state_path': '~/.claude/hooks/peon-ping/.state.json',
    'cli_interval': 300,            # 秒：多久跑一次 CodexBar 命令行
    'shared_interval': 15,          # 秒：多久看一次 CodexBar 应用的共享文件
    'stale_minutes': 20,            # 某一家超过这么久没更新，就显示成灰色
    'waiting_ttl_minutes': 120,     # 「等你回复」最多挂这么久
    'low_percent': 15,              # 剩余低于这个百分比算「快用完」
    'mid_percent': 40,
}

PROVIDERS = {
    'codex': ('Codex', 'CX', '#7c9cff'),
    'claude': ('Claude', 'CL', '#e08a63'),
    'cursor': ('Cursor', 'CU', '#cfd4dc'),
    'opencodego': ('OpenCode Go', 'OC', '#5fd3bc'),
    'opencode': ('OpenCode', 'OC', '#5fd3bc'),
    'antigravity': ('Antigravity', 'AG', '#b28cff'),
    'gemini': ('Gemini', 'GM', '#8ab4ff'),
    'copilot': ('Copilot', 'CP', '#9be29b'),
    'grok': ('Grok', 'GK', '#d7dbe0'),
}

# peon-ping 在标题里附带的工具名 → 我们显示的名字
AGENT_NAMES = {
    'Claude Code': 'Claude Code', 'OpenAI Codex': 'Codex', 'Cursor': 'Cursor', 'OpenCode': 'OpenCode',
    'Antigravity': 'Antigravity', 'Gemini CLI': 'Gemini', 'Grok Build': 'Grok', 'GitHub Copilot': 'Copilot',
    'Kilo CLI': 'Kilo', 'Kiro': 'Kiro', 'Windsurf': 'Windsurf', 'Kimi Code': 'Kimi', 'Amp': 'Amp',
    'DeepAgents': 'DeepAgents', 'OpenClaw': 'OpenClaw', 'Rovo Dev CLI': 'Rovo Dev', 'oh-my-pi': 'oh-my-pi',
    'Qwen Code': 'Qwen', 'iFlow CLI': 'iFlow', 'Trae': 'Trae', 'Kiro IDE': 'Kiro', 'ECA': 'ECA',
}
AGENT_MONO = {'Claude Code': 'CL', 'Codex': 'CX', 'Cursor': 'CU', 'OpenCode': 'OC', 'Antigravity': 'AG',
              'Gemini': 'GM', 'Grok': 'GK', 'Copilot': 'CP'}

GENERIC_LABELS = {'session', 'weekly', '5-hour', 'monthly', 'daily', 'hourly', 'primary', 'secondary', 'tertiary'}
# 同一个会话出现这些事件，说明你已经回去了，提醒可以消掉
CLEAR_EVENTS = {'UserPromptSubmit', 'PreToolUse', 'SessionEnd', 'SessionStart'}
SLOTS = ('primary', 'secondary', 'tertiary')
WEEK = '一二三四五六日'


def log(*a):
    print(time.strftime('%H:%M:%S'), *a, flush=True)


def load_config():
    cfg = dict(DEFAULTS)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, encoding='utf-8') as f:
                cfg.update({k: v for k, v in json.load(f).items() if k in DEFAULTS})
        except Exception as e:  # 配置坏了也要能跑
            log('配置文件读不了，先用默认值：', e)
    if not cfg.get('token'):
        cfg['token'] = secrets.token_urlsafe(18)
    with open(CONFIG_PATH, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write('\n')
    return cfg


def parse_iso(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(str(s).replace('Z', '+00:00'))
    except Exception:
        return None


def win_label(minutes):
    if not minutes:
        return ''
    if minutes == 300:
        return '5小时'
    if minutes == 1440:
        return '今天'
    if minutes == 10080:
        return '本周'
    if 40000 <= minutes <= 45000:
        return '本月'
    if minutes < 1440:
        return '%d小时' % round(minutes / 60)
    return '%d天' % round(minutes / 1440)


def reset_text(iso, minutes):
    t = parse_iso(iso)
    if not t:
        return ''
    t = t.astimezone()
    now = datetime.datetime.now().astimezone()
    if t <= now:
        return ''
    verb = '恢复' if minutes and minutes <= 1440 else '重置'
    days = (t.date() - now.date()).days
    hm = t.strftime('%H:%M')
    if days == 0:
        return '%s %s' % (hm, verb)
    if days == 1:
        return '明天 %s %s' % (hm, verb)
    if days < 7:
        return '周%s%s' % (WEEK[t.weekday()], verb)
    return '%d月%d日%s' % (t.month, t.day, verb)


def pace_text(p):
    if not p or p.get('willLastToReset', True):
        return ''
    eta = p.get('etaSeconds')
    if not eta:
        return ''
    if eta >= 86400 * 1.5:
        return '照现在的速度 %d 天后用完' % round(eta / 86400)
    if eta >= 3600:
        return '照现在的速度 %d 小时后用完' % round(eta / 3600)
    return '照现在的速度不到 1 小时用完'


def group_of(label):
    """CodexBar 的窗口名里，像 Gemini Models / Claude and GPT 这种是分组，Weekly 这种不是。"""
    if not label or label.strip().lower() in GENERIC_LABELS:
        return ''
    return label.replace(' Models', '').replace(' and ', '/').replace(' only', '').strip()


def group_from_title(title):
    m = re.match(r'^(.*?)\s+(5-hour|weekly|monthly|daily|hourly)$', title.strip(), re.I)
    return group_of(m.group(1)) if m else group_of(title)


class Store:
    def __init__(self, cfg):
        self.cfg = cfg
        self.lock = threading.RLock()
        self.cli = {}             # provider -> 命令行返回的条目（上一次成功的）
        self.cli_ts = {}          # provider -> 命令行上一次成功读到的时间
        self.order = []           # 订阅的显示顺序（跟 CodexBar 里启用的顺序一致）
        self.cli_bad = set()      # 最近一轮命令行没读到的那几家
        self.shared = {}          # provider -> 应用共享文件里的 usage
        self.shared_ts = {}
        self.shared_mtime = 0
        self.usage_sig = None
        self.waiting = []
        self.seq = 0
        self.peon_mtime = 0
        self.device = None        # 最近一次来取状态的真机：{'ip':…, 'at':…}

    def seen_device(self, ip):
        now = time.time()
        if not self.device or self.device['ip'] != ip or now - self.device['at'] > 60:
            log('真机连上来了：', ip)
        self.device = {'ip': ip, 'at': now}

    # ---------- 额度 ----------
    def run_cli(self):
        """主来源：codexbar usage --format json"""
        cli = self.cfg['codexbar_cli']
        if not os.path.exists(cli):
            log('找不到 CodexBar 命令行：', cli)
            return
        try:
            r = subprocess.run([cli, 'usage', '--format', 'json'], capture_output=True, timeout=180, cwd='/tmp')
            d = json.loads(r.stdout.decode('utf-8', 'replace') or '[]')
        except Exception as e:
            log('CodexBar 命令行没跑成：', e)
            with self.lock:
                self.cli_bad = set(self.order)   # 整轮失败：全部交给备用来源
            return
        now = time.time()
        fresh = {e.get('provider'): e for e in d if isinstance(e, dict) and e.get('provider')}
        with self.lock:
            self.order = list(fresh.keys()) or self.order
            self.cli_bad = set(k for k, v in fresh.items() if 'error' in v)
            for k, v in fresh.items():
                if 'error' not in v:
                    self.cli[k] = v
                    self.cli_ts[k] = now
                # 这一轮没读到的：保留上一轮的数字，时间不更新，过久会变灰
        ok = [k for k, v in fresh.items() if 'error' not in v]
        bad = ['%s（%s）' % (k, str((v.get('error') or {}).get('message', ''))[:60]) for k, v in fresh.items() if 'error' in v]
        sig = (tuple(ok), tuple(bad))
        if sig != self.usage_sig:      # 只在情况有变化时写日志
            self.usage_sig = sig
            log('命令行读到：%s%s' % ('、'.join(ok) or '无', ('；读不到：' + '、'.join(bad)) if bad else ''))

    def read_shared(self):
        """兜底来源：CodexBar 应用写出的共享文件（需要 CodexBar 配置里 shareUsageWithCLI 为 true）"""
        p = os.path.expanduser(self.cfg['shared_usage_path'])
        try:
            mt = os.path.getmtime(p)
            if mt == self.shared_mtime:
                return
            with open(p, encoding='utf-8') as f:
                d = json.load(f)
        except Exception as e:
            if self.shared_mtime != -1:
                log('读不到 CodexBar 应用的共享文件：', e)
            self.shared_mtime = -1
            return
        shared, ts = {}, {}
        for e in d.get('entries', []):
            pid, u = e.get('provider'), e.get('usage') or {}
            t = parse_iso(u.get('updatedAt'))
            if pid and t:
                shared[pid], ts[pid] = u, t.timestamp()
        with self.lock:
            if self.shared_mtime in (0, -1):
                log('应用共享文件里有：%s' % ('、'.join(shared) or '无'))
            self.shared, self.shared_ts, self.shared_mtime = shared, ts, mt

    def _level(self, left):
        if left < self.cfg['low_percent']:
            return 'low'
        if left < self.cfg['mid_percent']:
            return 'mid'
        return 'ok'

    def _windows(self, slots, extras, labels, pace):
        wins, seen = [], set()

        def add(group, w, p, key):
            if key in seen or w.get('usedPercent') is None:
                return
            seen.add(key)
            minutes = w.get('windowMinutes')
            left = max(0, min(100, int(round(100 - float(w['usedPercent'])))))
            wins.append({
                'label': ((group + ' ') if group else '') + win_label(minutes),
                'left': left,
                'level': self._level(left),
                'reset': reset_text(w.get('resetsAt'), minutes),
                'pace': pace_text(p),
                '_g': group, '_m': minutes or 0,
            })

        for slot in SLOTS:
            w = slots.get(slot)
            if not w:
                continue
            g = group_of(labels.get(slot))
            add(g, w, pace.get(slot), (g, w.get('windowMinutes')) if g else ('', slot))
        for x in extras or []:
            w = x.get('window') or {}
            if not w.get('windowMinutes'):
                continue
            g = group_from_title(x.get('title') or '')
            add(g, w, None, (g, w.get('windowMinutes')))

        order = []
        for w in wins:
            if w['_g'] not in order:
                order.append(w['_g'])
        wins.sort(key=lambda w: (order.index(w['_g']), w['_m']))
        for w in wins:
            del w['_g'], w['_m']
        return wins

    def subs(self):
        now = time.time()
        with self.lock:
            ids = list(self.order)
            for k in self.shared:
                if k not in ids:
                    ids.append(k)
            out = []
            for pid in ids:
                c = self.cli.get(pid) or {}
                cu = c.get('usage') or {}
                su = self.shared.get(pid) or {}
                c_ts, s_ts = self.cli_ts.get(pid, 0), self.shared_ts.get(pid, 0)
                # 一律用命令行的数字；只有命令行最近一轮没读到这一家时，才用应用共享文件顶上
                use_shared = bool(su) and (pid in self.cli_bad or not c_ts) and s_ts > c_ts
                base = su if use_shared else cu
                wins = self._windows(base, base.get('extraRateWindows') or cu.get('extraRateWindows'),
                                     c.get('rateWindowLabels') or {}, c.get('pace') or {})
                ts = s_ts if use_shared else c_ts
                name, mono, hue = PROVIDERS.get(pid, (pid.capitalize(), pid[:2].upper(), '#aab2bd'))
                sub = {'id': pid, 'name': name, 'mono': mono, 'hue': hue, 'windows': wins,
                       'ts': int(ts), 'stale': bool(not ts or now - ts > self.cfg['stale_minutes'] * 60),
                       'source': ('备用' if use_shared else '命令行') if ts else '',
                       'plan': cu.get('loginMethod') or ''}
                if wins:
                    t = min(wins, key=lambda w: w['left'])
                    sub.update(left=t['left'], label=t['label'], level=t['level'], reset=t['reset'], pace=t['pace'], error='')
                else:
                    sub.update(left=None, label='', level='na', reset='', pace='', error='暂时读不到')
                out.append(sub)
            return out

    # ---------- 等你回复 ----------
    def _peon_last_active(self):
        try:
            with open(os.path.expanduser(self.cfg['peon_state_path']), encoding='utf-8') as f:
                return (json.load(f) or {}).get('last_active') or {}
        except Exception:
            return {}

    def add_waiting(self, agent, project, kind, text, session_id=''):
        now = time.time()
        with self.lock:
            for w in list(self.waiting):
                same = (session_id and w.get('session_id') == session_id) or \
                       (not session_id and w['agent'] == agent and w['project'] == project)
                if same:
                    self.waiting.remove(w)
            self.seq += 1
            item = {'id': 'w%d' % self.seq, 'agent': agent, 'mono': AGENT_MONO.get(agent, agent[:2].upper()),
                    'project': project, 'kind': kind, 'text': text, 'since': now, 'acked': False,
                    'session_id': session_id}
            self.waiting.append(item)
        log('等你回复 +  %s · %s · %s' % (agent, project, text))
        return item

    def on_peon_push(self, title, body):
        project, agent = title.strip(), ''
        for raw, shown in AGENT_NAMES.items():
            if project.endswith(' - ' + raw):
                project, agent = project[:-len(raw) - 3], shown
                break
        msg = (body or '').strip()
        low = msg.lower()
        if low.startswith('done'):
            kind, text = 'done', '做完了，等你看结果'
        elif low.startswith('needs approval'):
            tool = msg.split(':', 1)[1].strip() if ':' in msg else ''
            kind, text = 'approval', '需要你批准' + (('：' + tool) if tool else '')
        elif low.startswith('question'):
            kind, text = 'question', '有问题要问你'
        elif low.startswith('compacting') or low.startswith('working') or low.startswith('ready'):
            return None
        elif low.startswith('error'):
            kind, text = 'error', '出错停下了'
        else:
            kind, text = 'note', msg[:40] or '有新消息'
        # 这条推送来自哪个会话：peon-ping 刚刚把它写进了自己的状态文件
        la = self._peon_last_active()
        sid = la.get('session_id', '') if abs(time.time() - float(la.get('timestamp', 0) or 0)) < 6 else ''
        return self.add_waiting(agent or 'AI', project or '未知项目', kind, text, sid)

    def sweep(self):
        """清掉已经回复的、挂太久的。"""
        now = time.time()
        ttl = self.cfg['waiting_ttl_minutes'] * 60
        la = None
        p = os.path.expanduser(self.cfg['peon_state_path'])
        try:
            mt = os.path.getmtime(p)
            if mt != self.peon_mtime:
                self.peon_mtime = mt
                la = self._peon_last_active()
        except Exception:
            pass
        with self.lock:
            for w in list(self.waiting):
                if now - w['since'] > ttl:
                    self.waiting.remove(w)
                    log('等你回复 -  %s · %s（挂太久，自动消掉）' % (w['agent'], w['project']))
                elif la and w.get('session_id') and la.get('session_id') == w['session_id'] \
                        and la.get('event') in CLEAR_EVENTS and float(la.get('timestamp', 0) or 0) > w['since'] + 0.5:
                    self.waiting.remove(w)
                    log('等你回复 -  %s · %s（你已经回去了）' % (w['agent'], w['project']))

    def ack(self, wid=None):
        with self.lock:
            for w in self.waiting:
                if wid in (None, '', w['id']):
                    w['acked'] = True

    def clear(self, wid=None):
        with self.lock:
            self.waiting = [w for w in self.waiting if wid not in (None, '', w['id'])]

    # ---------- 给设备的状态 ----------
    def state(self):
        now = time.time()
        subs = self.subs()
        with self.lock:
            waiting = sorted(self.waiting, key=lambda w: (w['acked'], w['kind'] == 'done', w['since']))
            waiting = [{k: v for k, v in w.items() if k != 'session_id'} for w in waiting]
        lows = []
        for s in subs:
            for w in s['windows']:
                if w['level'] == 'low' and not s['stale']:
                    lows.append({'id': s['id'], 'name': s['name'], 'label': w['label'], 'left': w['left'], 'reset': w['reset']})
        latest = max([s['ts'] for s in subs] or [0])
        return {
            'v': 1,
            'now': int(now),
            'time': time.strftime('%H:%M'),
            'ok': bool(latest and now - latest <= self.cfg['stale_minutes'] * 60),
            'data_time': time.strftime('%H:%M', time.localtime(latest)) if latest else '',
            'subs': subs,
            'lows': lows,
            'waiting': waiting,
            'device': {'ip': self.device['ip'], 'ago': int(now - self.device['at'])} if self.device else None,
        }


class Handler(BaseHTTPRequestHandler):
    server_version = 'aihelper-butler/1'
    store = None  # type: Store

    def log_message(self, *a):
        pass

    def _local(self):
        return self.client_address[0] in ('127.0.0.1', '::1')

    def _authed(self, q):
        if self._local():
            return True
        tok = self.store.cfg.get('token') or ''
        got = (q.get('t') or [''])[0] or self.headers.get('X-Token', '')
        auth = self.headers.get('Authorization', '')
        if auth.startswith('Bearer '):
            got = got or auth[7:]
        return bool(tok) and secrets.compare_digest(str(got), tok)

    def _send(self, code, body, ctype='application/json; charset=utf-8'):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n > 0 else b''

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == '/health':
            return self._send(200, {'ok': True})
        if not self._authed(q):
            return self._send(401, {'error': '需要口令'})
        if u.path == '/state':
            if not self._local():
                self.store.seen_device(self.client_address[0])
            return self._send(200, self.store.state())
        if u.path in ('/', '/index.html'):
            try:
                with open(os.path.join(HERE, 'simulator.html'), 'rb') as f:
                    return self._send(200, f.read(), 'text/html; charset=utf-8')
            except Exception:
                return self._send(404, {'error': '没有模拟器页面'})
        return self._send(404, {'error': '没有这个地址'})

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        raw = self._body()
        if not self._authed(q):
            return self._send(401, {'error': '需要口令'})
        if u.path.startswith('/ntfy/'):
            # peon-ping 的「手机推送」：标题是项目名（加工具名），正文是状态
            title = self.headers.get('Title', '').encode('latin-1', 'ignore').decode('utf-8', 'replace')
            item = self.store.on_peon_push(title, raw.decode('utf-8', 'replace'))
            return self._send(200, {'id': item['id'] if item else '', 'event': 'message'})
        try:
            d = json.loads(raw.decode('utf-8') or '{}')
        except Exception:
            d = {}
        if u.path == '/event':
            item = self.store.add_waiting(d.get('agent') or 'AI', d.get('project') or '测试', d.get('kind') or 'done',
                                          d.get('text') or '做完了，等你看结果')
            return self._send(200, {'id': item['id']})
        if u.path == '/ack':
            self.store.ack(d.get('id'))
            return self._send(200, {'ok': True})
        if u.path == '/clear':
            self.store.clear(d.get('id'))
            return self._send(200, {'ok': True})
        return self._send(404, {'error': '没有这个地址'})


def loop(fn, interval, name):
    def run():
        while True:
            try:
                fn()
            except Exception as e:
                log(name, '出错：', e)
            time.sleep(interval)
    t = threading.Thread(target=run, name=name, daemon=True)
    t.start()


def main():
    cfg = load_config()
    store = Store(cfg)
    Handler.store = store
    store.read_shared()
    loop(store.read_shared, cfg['shared_interval'], '共享文件')
    loop(store.run_cli, cfg['cli_interval'], '命令行')
    loop(store.sweep, 1, '清理')
    srv = ThreadingHTTPServer((cfg['listen'], int(cfg['port'])), Handler)
    log('小管家已启动：http://%s:%s/  （模拟器页面）' % (cfg['listen'], cfg['port']))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log('小管家已停止')


if __name__ == '__main__':
    sys.exit(main())
