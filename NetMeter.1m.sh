#!/bin/bash
# <xbar.title>NetMeter</xbar.title>
# <xbar.version>2.0.0</xbar.version>
# <xbar.desc>菜单栏显示今日上传量；展开有今日上下行、实时速率与近 1 小时走势、Top 域名（下载/上传各前三）、Top 进程、来源拆分、未归因、网卡明细。单文件自带采集，不需要额外的后台服务。</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# ─────────────────────────────────────────────────────────────────────────────
#  NetMeter · 单文件版
#
#  用法：把这个文件丢进 SwiftBar 的插件目录，就完了。
#        不需要装 LaunchAgent，不需要别的文件，不需要 root。
#        数据自动落在 ~/Library/Application Support/NetMeter/。
#
#  文件名里的 10s 是刷新间隔（同时也是采样间隔），想改就改文件名，比如 NetMeter.30s.sh。
#  想改菜单栏显示哪一项，改 ~/Library/Application Support/NetMeter/ui.json。
# ─────────────────────────────────────────────────────────────────────────────
#
#   1. SwiftBar 把输出里「第一个 --- 之前的所有行」都当成菜单栏标题，多于 1 行就会每隔几秒
#      轮流展示。所以标题行后面必须紧跟一条 ---（见 render() 里第一条分隔线，别删）。
#
#   2. 菜单栏标题不要用 sfimage。SF Symbol 是贴进 attributedTitle 的图片，鼠标高亮时不会跟着
#      系统反色，图标会直接消失。用文字箭头（下面的 TITLE_PREFIX）才会跟着文本自动反色。
#
#   3. 【下拉菜单里图标消失的真正原因】同一行绝对不能同时出现 color= 和 sfimage=。
#      SwiftBar 会给带 color 的行套一层自定义 NSAttributedString（MenuTrackingAttributedTitle），
#      内联的图标附件在它身上画不出来 —— 于是「有 color 的行图标全没了，没 color 的行图标正常」。
#      本文件因此严格遵循两条铁律：
#        · 有图标 → 不写 color（走系统默认色，高亮时自动反色）
#        · 要上色 → 不加图标
#
#   4. netstat / nettop 一定要带 -n（数值模式）。不带的话 macOS 会去做反向 DNS，
#      netstat -ib 要 5 秒、nettop 要 5 秒 —— 每次刷新卡 10 秒，菜单根本没法用。
#      带上 -n 之后两个都是 0.02 秒，快 100 倍，而且输出的本来就是数字 IP，不影响统计。
#
#   5. 颜色一律给「浅色,深色」两个值；中性文字用 DIM，不要用 #8E8E93 这类中灰
#      （白底/深色底都读不清）。
#
#   6. 中英混排时不能用 len() 算列宽（中文占 2 列），要按 east_asian_width 算，否则对不齐。
#
#   7. 菜单背景那层毛玻璃是 macOS 系统的，插件改不了。想更清楚：
#      系统设置 → 辅助功能 → 显示 → 降低透明度。

case "$0" in
    /*) NM_PLUGIN_PATH="$0" ;;
    *)  NM_PLUGIN_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
esac
export NM_PLUGIN_PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export PYTHONIOENCODING=utf-8

PYTHON_BIN="$NM_PYTHON"
if [ -z "$PYTHON_BIN" ]; then PYTHON_BIN=$(command -v python3); fi
if [ ! -x "$PYTHON_BIN" ]; then
    printf '%s\n' '↑ — | symbolize=false' '---' '需要 Python 3 才能读取流量数据。' '重新检查 | refresh=true'
    exit 0
fi

exec "$PYTHON_BIN" - "$@" <<'PY'
import csv
import fcntl
import glob
import http.client
import io
import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

APP = "NetMeter"
VERSION = "2.0.0"

NM_HOME = os.environ.get("NM_HOME") or os.path.expanduser("~/Library/Application Support/NetMeter")
DB_PATH = os.path.join(NM_HOME, "netmeter.db")
CONFIG_PATH = os.path.join(NM_HOME, "config.json")
UI_PATH = os.path.join(NM_HOME, "ui.json")
LOG_PATH = os.path.join(NM_HOME, "logs", "collector.log")
LOCK_PATH = os.path.join(NM_HOME, ".collector.lock")
PLUGIN = os.environ.get("NM_PLUGIN_PATH", "")

NETSTAT = "/usr/sbin/netstat"
NETTOP = "/usr/bin/nettop"

DEFAULT_CONFIG = {
    # 采样间隔（秒）。比它短就跳过采样直接渲染，防止连点刷新把采样打乱
    "sample_interval": 10,
    "total_iface_patterns": ["^en\\d+$", "^pdp_ip\\d+$"],
    "fake_ip_prefixes": ["198.18.", "198.19.", "fdfe:dcba:9876:"],
    "proxy_process_patterns": ["mihomo", "clash", "tailscale"],
    "clash_socket_glob": "/tmp/mihomo-party-*.sock",
    "recent_keep_days": 14,
    # 差分快照保留 24 小时：长连接的键要一直在，否则重新出现时会被当成新连接而重复计入
    "state_ttl_seconds": 86400,
    "log_interval": 600,
}

# ============================================================ 显示开关
TITLE_METRIC = "today_upload"   # 也可以写进 ui.json
TITLE_PREFIX = "↑ "             # 用文字箭头，不要用 sfimage（见文件头 2）
TOTAL_MODE = "physical"         # physical = 只算物理出口（不翻倍）；all = 含隧道
TOP_N = 3

HOST_W = 24
PROC_W = 20
VAL_W = 6
BAR_W = 8
SUM_BAR_W = 10
LIST_N = 30

# ============================================================ 配色
# 每个值都是 "浅色模式,深色模式"
BLUE = "#0A5BD3,#7CC0FF"     # 下载
ORANGE = "#A8480A,#FFB454"   # 上传
GREEN = "#136B37,#5FE3A1"    # 直连 / 正常
RED = "#B42318,#FF9A8F"      # 告警
PURPLE = "#6B21A8,#D8B4FE"   # 未归因 / 隧道
DIM = "#3F3F46,#CFCFD6"      # 次要文字
MONO = "Menlo"

# ============================================================ 网卡分类
IFACE_PHYSICAL = [
    r"^en\d+$", r"^eth\d+$", r"^pdp_ip\d+$", r"^rmnet\d+$", r"^bridge\d+$",
    r"^thunderbolt\d+$", r"^anpi\d+$", r"^ax\d+$", r"^wl[a-z0-9]+$",
]
IFACE_TUNNEL = [
    r"^utun\d+$", r"^tun\d+$", r"^tap\d+$", r"^wg\d+$", r"^ipsec\d+$",
    r"^ppp\d+$", r"^gpd\d+$", r"^gif\d+$", r"^stf\d+$", r"^tailscale",
    r"^zt[a-z0-9]*$", r"^loon", r"^surge", r"^clash", r"^mihomo", r"^sing",
    r"^hiddify", r"^nekoray", r"^warp",
]
IFACE_LOOPBACK = [
    r"^lo\d+$", r"^awdl\d+$", r"^llw\d+$", r"^ap\d+$", r"^vmenet\d+$",
    r"^vmnet\d+$", r"^docker\d*$", r"^br-[0-9a-f]+$",
]

# 中继进程：它们自己占的字节不算真实业务归属，否则同一个下载会算两次。
# nettop 的进程名会截断到 15 字符，所以用子串匹配（大小写不敏感）。
PROXY_PROCESS_PATTERNS = [
    "mihomo", "clash", "clashx", "clash party", "clashparty", "clash-verge", "verge",
    "surge", "loon", "stash", "quantumult", "shadowrocket", "shadowsocks",
    "ss-local", "sslocal", "sing-box", "singbox", "sing_box", "hiddify",
    "v2ray", "xray", "trojan", "hysteria", "tuic", "brook", "naive",
    "proxifier", "proxychains", "mitmproxy", "gost", "privoxy", "squid", "snell",
    "wireguard", "tailscale", "zerotier", "openvpn", "tunnelblick", "openconnect",
    "globalprotect", "viscosity", "tunnelbear", "warp", "cloudflared",
    "windscribe", "protonvpn", "nordvpn", "expressvpn", "surfshark", "mullvad",
    "astrill", "shimo", "outline", "nekoray", "nekobox",
    "obdev", "littlesnitch", "little snitch", "dnscrypt", "adguard",
]
BUILTIN_FAKE_IP = ["198.18.", "198.19.", "fdfe:dcba:9876:", "fd00:1:fd00:1:", "240.0.0."]

KIND_LABEL = {"physical": "物理出口", "tunnel": "隧道", "loopback": "回环", "other": "其他"}


# ============================================================ 小工具
def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 512 * 1024:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write("[%s] %s\n" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


def load_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else dict(fallback)
    except Exception:
        return dict(fallback)


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, encoding="utf-8") as fh:
            user = json.load(fh)
        if isinstance(user, dict):
            cfg.update(user)
            missing = {k: v for k, v in DEFAULT_CONFIG.items() if k not in user}
            if missing:
                merged = dict(user)
                merged.update(missing)
                with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
                    json.dump(merged, fh, ensure_ascii=False, indent=2)
    except FileNotFoundError:
        os.makedirs(NM_HOME, exist_ok=True)
        with open(CONFIG_PATH, "w", encoding="utf-8") as fh:
            json.dump(DEFAULT_CONFIG, fh, ensure_ascii=False, indent=2)
    except Exception as exc:
        log("读取配置失败，使用默认配置: %r" % (exc,))
    return cfg


def run(cmd, timeout=15):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return proc.stdout or ""
    except Exception as exc:
        log("命令失败 %s: %r" % (" ".join(cmd), exc))
        return ""


def bucket_ts(now, size=60):
    return now - (now % size)


def day_of(ts):
    return datetime.fromtimestamp(ts).strftime("%Y-%m-%d")


def fmt(num):
    n = float(num or 0)
    if n < 1000:
        return "%dB" % int(n)
    if n < 1024 ** 2:
        return "%.1fK" % (n / 1024)
    if n < 1024 ** 3:
        return "%.1fM" % (n / 1024 ** 2)
    if n < 1024 ** 4:
        return "%.2fG" % (n / 1024 ** 3)
    return "%.2fT" % (n / 1024 ** 4)


def fmt_rate(bps):
    return fmt(bps) + "/s"


def bar(fraction, width=BAR_W):
    fraction = 0.0 if fraction is None else max(0.0, min(1.0, fraction))
    filled = int(round(fraction * width))
    return "█" * filled + "░" * (width - filled)


def spark(values):
    if not values:
        return ""
    top = max(values) or 1
    chars = "▁▂▃▄▅▆▇█"
    return "".join(chars[min(7, int(v / top * 7.999))] for v in values)


def dwidth(text):
    """按显示宽度算长度：中文/全角算 2 列，其余算 1 列。"""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def pad(text, width):
    """按显示宽度补齐。注意不能直接用 len() —— 中英混排时 len 相同的两行在菜单里宽度不同。"""
    text = text or ""
    if dwidth(text) > width:
        while text and dwidth(text + "…") > width:
            text = text[:-1]
        text += "…"
    return text + " " * max(0, width - dwidth(text))


def item(title, **params):
    parts = []
    for key, val in params.items():
        if val is True:
            parts.append("%s=true" % key)
        elif val is False:
            parts.append("%s=false" % key)
        elif val is None:
            continue
        else:
            sval = str(val)
            if re.search(r"\s", sval):
                sval = '"%s"' % sval.replace('"', "")
            parts.append("%s=%s" % (key, sval))
    return title + (" | " + " ".join(parts) if parts else "")


def short_proc(name):
    name = (name or "").strip()
    if "/" in name:
        name = os.path.basename(name)
    return name or "(未知)"


def norm_proc(name):
    return re.sub(r"[^a-z0-9]+", "", short_proc(name).lower())[:8]


def remote_ip(remote):
    if remote.startswith("[") and "]" in remote:
        return remote[1:remote.index("]")]
    return remote.rsplit(":", 1)[0] if ":" in remote else remote


def pct(part, whole):
    return round(part / whole * 100) if whole else 0


# ============================================================ 数据库
SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);

CREATE TABLE IF NOT EXISTS iface_sample (
  ts INTEGER, day TEXT, iface TEXT, rx INTEGER, tx INTEGER,
  PRIMARY KEY (ts, day, iface));
CREATE TABLE IF NOT EXISTS daily_iface (
  day TEXT, iface TEXT, rx INTEGER, tx INTEGER,
  PRIMARY KEY (day, iface));
CREATE TABLE IF NOT EXISTS iface_last (
  iface TEXT PRIMARY KEY, rx INTEGER, tx INTEGER, ts INTEGER);

CREATE TABLE IF NOT EXISTS flow_sample (
  ts INTEGER, day TEXT, proto TEXT, local TEXT, remote TEXT, process TEXT,
  iface TEXT, pid INTEGER, rx INTEGER, tx INTEGER,
  PRIMARY KEY (ts, day, proto, local, remote, process, iface));
CREATE TABLE IF NOT EXISTS daily_flow (
  day TEXT, remote TEXT, proto TEXT, iface TEXT, process TEXT, rx INTEGER, tx INTEGER,
  PRIMARY KEY (day, remote, proto, iface, process));
CREATE TABLE IF NOT EXISTS flow_last (
  key TEXT PRIMARY KEY, rx INTEGER, tx INTEGER, ts INTEGER);

CREATE TABLE IF NOT EXISTS domain_sample (
  ts INTEGER, day TEXT, host TEXT, dest_ip TEXT, port TEXT, process TEXT,
  network TEXT, rule TEXT, chain TEXT, rx INTEGER, tx INTEGER,
  PRIMARY KEY (ts, day, host, dest_ip, port, process));
CREATE TABLE IF NOT EXISTS daily_domain (
  day TEXT, host TEXT, dest_ip TEXT, port TEXT, process TEXT, rule TEXT, chain TEXT,
  network TEXT, rx INTEGER, tx INTEGER,
  PRIMARY KEY (day, host, dest_ip, port, process, rule, chain));
CREATE TABLE IF NOT EXISTS clash_last (
  id TEXT PRIMARY KEY, up INTEGER, down INTEGER, ts INTEGER);

CREATE TABLE IF NOT EXISTS speed_sample (
  ts INTEGER PRIMARY KEY, day TEXT, rx INTEGER, tx INTEGER);

CREATE INDEX IF NOT EXISTS idx_daily_domain_day ON daily_domain(day);
CREATE INDEX IF NOT EXISTS idx_daily_flow_day ON daily_flow(day);
"""


def open_db():
    os.makedirs(NM_HOME, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.executescript(SCHEMA)
    return conn


def add_acc(conn, table, keys, acc, extra=None):
    """按键累加写入：冲突时把 acc 的列相加，extra 的列覆盖为最新值。"""
    extra = extra or {}
    cols = list(keys) + list(acc) + list(extra)
    sets = ["%s = %s + excluded.%s" % (c, c, c) for c in acc]
    sets += ["%s = excluded.%s" % (c, c) for c in extra]
    sql = "INSERT INTO %s(%s) VALUES(%s) ON CONFLICT(%s) DO UPDATE SET %s" % (
        table, ",".join(cols), ",".join("?" for _ in cols), ",".join(keys), ",".join(sets))
    conn.execute(sql, [*keys.values(), *acc.values(), *extra.values()])


def set_meta(conn, key, value):
    conn.execute("INSERT INTO meta(k, v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                 (key, str(value)))


def get_meta(conn, key, default=None):
    row = conn.execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
    return row[0] if row else default


# ============================================================ 采样 1：网卡计数器
LINK_ROW = re.compile(r"^(\S+)\s+(\d+)\s+<Link#\d+>\s*(.*)$")


def parse_netstat(text):
    """返回 {iface: (ibytes, obytes)}。每张网卡有多行（每个地址族一行），只取 <Link#> 那行。"""
    out = {}
    for line in text.splitlines():
        m = LINK_ROW.match(line)
        if not m:
            continue
        iface = m.group(1).rstrip("*")
        toks = m.group(3).split()
        if len(toks) < 7:
            continue
        try:
            _ipkts, _ierrs, ibytes, _opkts, _oerrs, obytes, _coll = [int(t) for t in toks[-7:]]
        except ValueError:
            continue
        out[iface] = (ibytes, obytes)
    return out


def sample_ifaces(conn, now, text, cfg):
    """返回 (计入总量的下行增量, 上行增量)。"""
    counters = parse_netstat(text)
    if not counters:
        return 0, 0
    ts, day = bucket_ts(now), day_of(now)
    prev = {r[0]: (r[1], r[2]) for r in conn.execute("SELECT iface, rx, tx FROM iface_last")}
    pats = [re.compile(p) for p in cfg.get("total_iface_patterns", [])]
    counted_rx = counted_tx = 0
    for iface, (rx, tx) in counters.items():
        if iface in prev:
            prx, ptx = prev[iface]
            drx = rx - prx if rx >= prx else rx     # 计数器归零（重启/重连）→ 当前值即增量
            dtx = tx - ptx if tx >= ptx else tx
        else:
            drx = dtx = 0                            # 第一次见到这张网卡，不把开机以来的历史算进来
        if drx or dtx:
            add_acc(conn, "iface_sample", {"ts": ts, "day": day, "iface": iface}, {"rx": drx, "tx": dtx})
            add_acc(conn, "daily_iface", {"day": day, "iface": iface}, {"rx": drx, "tx": dtx})
            if any(p.search(iface) for p in pats):
                counted_rx += drx
                counted_tx += dtx
        conn.execute(
            "INSERT INTO iface_last(iface, rx, tx, ts) VALUES(?,?,?,?) "
            "ON CONFLICT(iface) DO UPDATE SET rx=excluded.rx, tx=excluded.tx, ts=excluded.ts",
            (iface, rx, tx, now))
    return counted_rx, counted_tx


# ============================================================ 采样 2：nettop
CONN_ROW = re.compile(r"^((?:tcp|udp)[46])\s+(.*?)<->(.*)$")
PROC_ROW = re.compile(r"^(.*)\.(\d+)$")


def parse_nettop(text):
    """解析 nettop 的 CSV 日志输出。

    里面有两类行：
      进程行  apsd.580,,,10695,22987,...                  该进程全部连接合计（累计值）
      连接行  tcp4 198.18.0.1:57490<->17.57.145.152:5223,utun1500,Established,...
    连接行按「进程行在前、其连接随后」的树形顺序展开，所以用最近出现的进程行来归属连接。
    """
    flows, procs = {}, {}
    cur_name, cur_pid = None, None
    for row in csv.reader(io.StringIO(text)):
        if len(row) < 6 or row[0] == "time":
            continue
        label = row[1].strip()
        if not label:
            continue
        try:
            rx = int(row[4]) if row[4] else 0
            tx = int(row[5]) if row[5] else 0
        except ValueError:
            continue
        m = CONN_ROW.match(label)
        if m:
            proto, local, remote = m.group(1), m.group(2).strip(), m.group(3).strip()
            # 同一个 socket 在多张网卡上会各列一行（多播套接字尤其明显），字节数是可加的，
            # 所以键里必须带 interface；完全相同的行只保留数值更大的那条。
            key = "%s|%s|%s|%s|%s" % (proto, local, remote, cur_name or "-", row[2])
            prev = flows.get(key)
            if prev is None or (rx + tx) > (prev["rx"] + prev["tx"]):
                flows[key] = {
                    "proto": proto, "local": local, "remote": remote,
                    "iface": row[2], "process": cur_name or "(未知)", "pid": cur_pid or 0,
                    "rx": rx, "tx": tx,
                }
            continue
        m = PROC_ROW.match(label)
        if m:
            cur_name, cur_pid = m.group(1), int(m.group(2))
            procs[(cur_name, cur_pid)] = (rx, tx)
    return flows, procs


def sample_nettop(conn, now, text):
    flows, _procs = parse_nettop(text)
    if not flows:
        return
    ts, day = bucket_ts(now), day_of(now)
    prev = {r[0]: (r[1], r[2]) for r in conn.execute("SELECT key, rx, tx FROM flow_last")}
    first_run = not prev          # 第一次运行：所有连接都是历史存量，不把安装前的字节算进来
    for key, f in flows.items():
        if key in prev:
            prx, ptx = prev[key]
            drx = f["rx"] - prx if f["rx"] >= prx else f["rx"]
            dtx = f["tx"] - ptx if f["tx"] >= ptx else f["tx"]
        else:
            # 正常运行时，新出现的连接一定建立于安装之后，它的现有字节都该计入；
            # 但如果这是第一次运行，那些连接的字节可能是安装之前产生的，只能从这一轮开始记账。
            drx, dtx = (0, 0) if first_run else (f["rx"], f["tx"])
        if drx or dtx:
            add_acc(conn, "flow_sample",
                    {"ts": ts, "day": day, "proto": f["proto"], "local": f["local"],
                     "remote": f["remote"], "process": f["process"], "iface": f["iface"]},
                    {"rx": drx, "tx": dtx}, {"pid": f["pid"]})
            add_acc(conn, "daily_flow",
                    {"day": day, "remote": f["remote"], "proto": f["proto"],
                     "iface": f["iface"], "process": f["process"]},
                    {"rx": drx, "tx": dtx})
        conn.execute(
            "INSERT INTO flow_last(key, rx, tx, ts) VALUES(?,?,?,?) "
            "ON CONFLICT(key) DO UPDATE SET rx=excluded.rx, tx=excluded.tx, ts=excluded.ts",
            (key, f["rx"], f["tx"], now))


# ============================================================ 采样 3：Clash API
class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, sock_path, timeout=3.0):
        super().__init__("localhost", timeout=timeout)
        self._sock_path = sock_path

    def connect(self):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self._sock_path)
        self.sock = sock


def parse_start(value):
    """Clash 的 start 字段是 RFC3339 字符串，转成 epoch 秒。"""
    text = str(value or "").strip()
    if not text:
        return 0
    if text.isdigit():
        return int(text)
    try:
        return int(datetime.fromisoformat(text).timestamp())
    except Exception:
        return 0


def sample_clash(conn, cfg, now):
    cands = [p for p in glob.glob(cfg.get("clash_socket_glob", "")) if os.path.exists(p)]
    if not cands:
        return
    sock_path = max(cands, key=os.path.getmtime)
    try:
        http = UnixHTTPConnection(sock_path)
        http.request("GET", "/connections")
        resp = http.getresponse()
        if resp.status != 200:
            return
        data = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        return
    ts, day = bucket_ts(now), day_of(now)
    prev = {r[0]: (r[1], r[2]) for r in conn.execute("SELECT id, up, down FROM clash_last")}
    first_run = not prev
    installed_at = int(get_meta(conn, "installed_at", now))
    seen = set()
    for it in data.get("connections") or []:
        cid = str(it.get("id"))
        seen.add(cid)
        rx = int(it.get("download") or 0)     # Clash 的 download = 本机下行
        tx = int(it.get("upload") or 0)       # Clash 的 upload   = 本机上行
        meta = it.get("metadata") or {}
        if cid in prev:
            prx, ptx = prev[cid]
            drx = rx - prx if rx >= prx else rx
            dtx = tx - ptx if tx >= ptx else tx
        else:
            started = parse_start(it.get("start"))
            drx, dtx = (0, 0) if (first_run and started and started < installed_at) else (rx, tx)
        if drx or dtx:
            host = (meta.get("host") or meta.get("sniffHost") or "").strip()
            dest_ip = str(meta.get("destinationIP") or "").strip()
            port = str(meta.get("destinationPort") or "")
            proc = (meta.get("process") or "").strip() or os.path.basename(meta.get("processPath") or "") or "(未知)"
            rule = str(it.get("rule") or "")
            chain = ",".join(it.get("chains") or [])
            label = host or ("(IP) %s" % dest_ip)
            add_acc(conn, "domain_sample",
                    {"ts": ts, "day": day, "host": label, "dest_ip": dest_ip,
                     "port": port, "process": proc},
                    {"rx": drx, "tx": dtx},
                    {"network": str(meta.get("network") or ""), "rule": rule, "chain": chain})
            add_acc(conn, "daily_domain",
                    {"day": day, "host": label, "dest_ip": dest_ip, "port": port,
                     "process": proc, "rule": rule, "chain": chain},
                    {"rx": drx, "tx": dtx}, {"network": str(meta.get("network") or "")})
        conn.execute(
            "INSERT INTO clash_last(id, up, down, ts) VALUES(?,?,?,?) "
            "ON CONFLICT(id) DO UPDATE SET up=excluded.up, down=excluded.down, ts=excluded.ts",
            (cid, rx, tx, now))
    stale = [r[0] for r in conn.execute("SELECT id FROM clash_last") if r[0] not in seen]
    conn.executemany("DELETE FROM clash_last WHERE id=?", [(i,) for i in stale])


# ============================================================ 采样总控
def prune(conn, cfg, now):
    cutoff = bucket_ts(now - int(cfg.get("recent_keep_days", 14)) * 86400, 60)
    ttl = now - int(cfg.get("state_ttl_seconds", 86400))
    conn.execute("DELETE FROM iface_sample WHERE ts < ?", (cutoff,))
    conn.execute("DELETE FROM flow_sample WHERE ts < ?", (cutoff,))
    conn.execute("DELETE FROM domain_sample WHERE ts < ?", (cutoff,))
    conn.execute("DELETE FROM flow_last WHERE ts < ?", (ttl,))
    conn.execute("DELETE FROM clash_last WHERE ts < ?", (ttl,))
    conn.execute("DELETE FROM speed_sample WHERE ts < ?", (cutoff,))


def sample(now, cfg, force=False):
    """跑一轮采样。拿不到锁或距上次太近就跳过。"""
    os.makedirs(os.path.join(NM_HOME, "logs"), exist_ok=True)
    lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False        # 上一轮还没结束
        conn = open_db()
        try:
            with conn:
                if get_meta(conn, "installed_at") is None:
                    set_meta(conn, "installed_at", now)
                last = int(get_meta(conn, "last_sample", 0) or 0)
                if not force and now - last < max(2, int(cfg.get("sample_interval", 10)) - 1):
                    return False
                # netstat 与 nettop 互不依赖，并行跑
                with ThreadPoolExecutor(max_workers=2) as pool:
                    f_netstat = pool.submit(run, [NETSTAT, "-ibn"], 15)
                    f_nettop = pool.submit(run, [NETTOP, "-n", "-L", "1", "-x", "-c", "-s", "1"], 15)
                    netstat_text = f_netstat.result()
                    nettop_text = f_nettop.result()
                counted_rx, counted_tx = sample_ifaces(conn, now, netstat_text, cfg)
                sample_nettop(conn, now, nettop_text)
                sample_clash(conn, cfg, now)
                # 记一份「计入总量的网卡」两个采样之间的增量，供菜单算实时速率和趋势图
                conn.execute("INSERT OR REPLACE INTO speed_sample(ts, day, rx, tx) VALUES(?,?,?,?)",
                             (now, day_of(now), counted_rx, counted_tx))
                if now - int(get_meta(conn, "last_prune", 0) or 0) >= 3600:
                    prune(conn, cfg, now)
                    set_meta(conn, "last_prune", now)
                set_meta(conn, "last_sample", now)
                set_meta(conn, "version", VERSION)
                if now - int(get_meta(conn, "last_log", 0) or 0) >= int(cfg.get("log_interval", 600)):
                    log("采样 ok：本轮网卡增量 ↓%d ↑%d" % (counted_rx, counted_tx))
                    set_meta(conn, "last_log", now)
        finally:
            conn.close()
        return True
    except Exception as exc:
        log("采样失败: %r" % (exc,))
        return False
    finally:
        os.close(lock_fd)


# ============================================================ 规则编译（渲染用）
def compile_patterns(extra):
    out = []
    for p in extra:
        try:
            out.append(re.compile(p, re.I))
        except re.error:
            pass
    return out


def iface_kind(name):
    for p in loop_pat:
        if p.search(name):
            return "loopback"
    for p in tun_pat:
        if p.search(name):
            return "tunnel"
    for p in phy_pat:
        if p.search(name):
            return "physical"
    return "other"


def iface_counted(name):
    kind = iface_kind(name)
    if kind == "loopback":
        return False
    if kind == "tunnel":
        return TOTAL_MODE == "all"
    return True


def is_proxy_proc(name):
    return any(p.search(name or "") for p in proxy_pat)


def classify_flow(row_proc, remote):
    """把 nettop 的一条记录归类，用来解释「未归因流量」到底是谁的。"""
    if not remote or "*" in remote or "%" in remote:
        return "wildcard"
    ip = remote_ip(remote)
    if not ip or ip.startswith("127.") or ip.startswith("::1") or remote.startswith("localhost"):
        return "loopback"
    if ip.startswith("fe80:") or ip.startswith("ff"):
        return "misc"
    head = ip.split(".")[0]
    if head.isdigit() and 224 <= int(head) <= 255:
        return "misc"
    if fake_prefix and ip.startswith(fake_prefix):
        return "fakeip"
    if is_proxy_proc(row_proc):
        return "relay"
    if (norm_proc(row_proc), ip) in clash_index:
        return "clashdup"
    return "direct"


# ============================================================ 渲染
def render(db, now, now_dt, cfg):
    lines = []
    q = lambda sql, args=(): db.execute(sql, args).fetchall()
    today = now_dt.strftime("%Y-%m-%d")

    clash_index.clear()
    for _host, _ip, _proc in q("SELECT host, dest_ip, process FROM daily_domain WHERE day=?", (today,)):
        if _ip:
            clash_index.add((norm_proc(_proc), _ip))

    def iface_sum(day=None, only_counted=True):
        sql, args = "SELECT iface, rx, tx FROM daily_iface", ()
        if day:
            sql, args = sql + " WHERE day=?", (day,)
        rx = tx = 0
        for name, a, b in q(sql, args):
            if only_counted and not iface_counted(name):
                continue
            rx += a or 0
            tx += b or 0
        return rx, tx

    today_rx, today_tx = iface_sum(today)
    cum_rx, cum_tx = iface_sum()
    all_rx, all_tx = iface_sum(today, only_counted=False)
    tun_rx = 0
    for name, a, b in q("SELECT iface, rx, tx FROM daily_iface WHERE day=?", (today,)):
        if iface_kind(name) == "tunnel":
            tun_rx += a or 0

    per_day = {}
    for day, name, a, b in q("SELECT day, iface, SUM(rx), SUM(tx) FROM daily_iface GROUP BY day, iface"):
        if iface_counted(name):
            cur = per_day.setdefault(day, [0, 0])
            cur[0] += a or 0
            cur[1] += b or 0

    install = q("SELECT v FROM meta WHERE k='installed_at'")
    install_day = datetime.fromtimestamp(int(install[0][0])).strftime("%m-%d") if install else "—"
    last_sample = int(get_meta(db, "last_sample", 0) or 0)

    # ---------------- 菜单栏标题（只此一行，后面紧跟 --- 见文件头 1；不要用 sfimage 见 2）
    values = {
        "today_upload": TITLE_PREFIX + fmt(today_tx),
        "today_download": fmt(today_rx),
        "today_total": fmt(today_rx + today_tx),
        "cum_upload": "Σ" + fmt(cum_tx),
        "cum_download": "Σ" + fmt(cum_rx),
        "cum_total": "Σ" + fmt(cum_rx + cum_tx),
    }
    lines.append(item(values.get(TITLE_METRIC, "—"), font=MONO, size=13,
                      dropdown=False, symbolize=False, emojize=False))
    lines.append("---")

    # ---------------- 今日概览
    total = today_rx + today_tx
    share_rx = today_rx / total if total else 0.0
    share_tx = today_tx / total if total else 0.0
    lines.append(item("今日 %s · %s" % (today[5:], now_dt.strftime("%H:%M")),
                      font=MONO, size=12, color=DIM, symbolize=False, emojize=False))
    lines.append(item("下载  %s  %s  %3d%%"
                      % (fmt(today_rx).rjust(8), bar(share_rx, SUM_BAR_W), pct(today_rx, total)),
                      font=MONO, size=12, color=BLUE, symbolize=False, emojize=False,
                      tooltip="今日物理出口网卡收到的字节（隧道不重复计入）"))
    lines.append(item("上传  %s  %s  %3d%%"
                      % (fmt(today_tx).rjust(8), bar(share_tx, SUM_BAR_W), pct(today_tx, total)),
                      font=MONO, size=12, color=ORANGE, symbolize=False, emojize=False,
                      tooltip="今日物理出口网卡发出的字节（隧道不重复计入）"))
    lines.append(item("合计  %s" % fmt(total).rjust(8),
                      font=MONO, size=12, color=DIM, symbolize=False, emojize=False))

    rate_rx = rate_tx = None
    hour_spark = ""
    try:
        rows = q("SELECT ts, rx, tx FROM speed_sample ORDER BY ts DESC LIMIT 2")
        if len(rows) == 2:
            dt = rows[0][0] - rows[1][0]
            if dt > 0:
                rate_rx, rate_tx = (rows[0][1] or 0) / dt, (rows[0][2] or 0) / dt
        buckets = {}
        for ts, rx, tx in q("SELECT ts, rx, tx FROM speed_sample WHERE ts >= ?", (int(now) - 3600,)):
            buckets[ts // 300] = buckets.get(ts // 300, 0) + (rx or 0) + (tx or 0)
        hour_spark = spark([buckets[k] for k in sorted(buckets)[-12:]])
    except sqlite3.Error:
        pass
    tail = ""
    if rate_rx is not None:
        tail = "   ↓%s ↑%s" % (fmt_rate(rate_rx), fmt_rate(rate_tx))
    if hour_spark:
        lines.append(item("近1小时 %s%s" % (hour_spark, tail),
                          font=MONO, size=12, color=DIM, symbolize=False, emojize=False,
                          tooltip="最近一小时流量走势（每格 5 分钟）；后面是最近一个采样间隔的平均速率"))
    elif tail:
        lines.append(item("即时%s" % tail.strip(), font=MONO, size=12, color=DIM,
                          symbolize=False, emojize=False))

    # ---------------- Top 域名（前三直接铺在主页）
    dom = {}
    for host, proc, a, b in q("SELECT host, process, rx, tx FROM daily_domain WHERE day=?", (today,)):
        if host.startswith("(IP) 127.") or host.startswith("(IP) ::1"):
            continue
        info = dom.setdefault(host, {"rx": 0, "tx": 0, "procs": {}})
        info["rx"] += a or 0
        info["tx"] += b or 0
        p = short_proc(proc)
        info["procs"][p] = info["procs"].get(p, 0) + (a or 0) + (b or 0)

    lines.append("---")
    # 这一行有图标 → 不能写 color（见文件头 3）
    lines.append(item("Top 域名 · 今天", sfimage="globe", size=13, symbolize=False, emojize=False,
                      tooltip="按代理记录的域名流量，下载/上传各列前三"))
    if dom:
        for label, key, color in (("↓ 下载前 %d" % TOP_N, "rx", BLUE),
                                  ("↑ 上传前 %d" % TOP_N, "tx", ORANGE)):
            ranked = [(h, i) for h, i in sorted(dom.items(), key=lambda kv: kv[1][key], reverse=True)
                      if i[key] > 0][:TOP_N]
            if not ranked:
                continue
            lines.append(item(label, size=11, color=DIM, symbolize=False, emojize=False))
            peak = ranked[0][1][key] or 1
            for idx, (host, info) in enumerate(ranked, 1):
                lines.append(item("%d  %s %s %s"
                                  % (idx, pad(host, HOST_W), fmt(info[key]).rjust(VAL_W),
                                     bar(info[key] / peak)),
                                  font=MONO, size=12, color=color,
                                  symbolize=False, emojize=False, tooltip=host))
    else:
        lines.append(item("今天还没有代理域名记录", size=12, color=DIM, symbolize=False, emojize=False))

    if len(dom) > TOP_N:
        lines.append(item("更多域名（%d）" % len(dom), sfimage="list.bullet", size=13,
                          symbolize=False, emojize=False,
                          tooltip="全部 %d 个域名，按下载 + 上传排序" % len(dom)))
        for idx, (host, info) in enumerate(
                sorted(dom.items(), key=lambda kv: kv[1]["rx"] + kv[1]["tx"], reverse=True)[:LIST_N], 1):
            proc = max(info["procs"].items(), key=lambda kv: kv[1])[0] if info["procs"] else ""
            lines.append(item("-- %d  %s ↓%s ↑%s"
                              % (idx, pad(host, HOST_W), fmt(info["rx"]).rjust(VAL_W),
                                 fmt(info["tx"]).rjust(VAL_W)),
                              font=MONO, size=12, symbolize=False, emojize=False,
                              tooltip="%s%s" % (host, (" · " + proc) if proc else "")))

    # ---------------- 累计与近 7 天
    lines.append("---")
    lines.append(item("累计 自 %s   ↓%s ↑%s   合计 %s"
                      % (install_day, fmt(cum_rx).rjust(7), fmt(cum_tx).rjust(7),
                         fmt(cum_rx + cum_tx).rjust(7)),
                      font=MONO, size=12, color=DIM, symbolize=False, emojize=False,
                      tooltip="自安装当天起累计"))
    days = sorted(per_day)[-7:]
    if len(days) >= 2:
        avg = sum(per_day[d][0] + per_day[d][1] for d in days) / len(days)
        lines.append(item("近7天 %s   日均 %s" % (spark([per_day[d][0] + per_day[d][1] for d in days]),
                                                 fmt(avg)),
                          font=MONO, size=12, color=DIM, symbolize=False, emojize=False,
                          tooltip="柱越高当天流量越大；日均按最近 %d 天算" % len(days)))
    else:
        avg = (per_day[days[0]][0] + per_day[days[0]][1]) if days else 0
        lines.append(item("近7天 明天开始有对比   日均 %s" % fmt(avg),
                          font=MONO, size=12, color=DIM, symbolize=False, emojize=False))

    # ---------------- 进程统计
    procs = {}
    for proc, a, b in q("SELECT process, SUM(rx), SUM(tx) FROM daily_domain WHERE day=? GROUP BY process", (today,)):
        cur = procs.setdefault(short_proc(proc), [0, 0])
        cur[0] += a or 0
        cur[1] += b or 0
    for proc, remote, a, b in q("SELECT process, remote, rx, tx FROM daily_flow WHERE day=?", (today,)):
        if classify_flow(proc, remote) != "direct":
            continue
        cur = procs.setdefault(short_proc(proc), [0, 0])
        cur[0] += a or 0
        cur[1] += b or 0

    # ---------------- 来源拆分 / 未归因
    clash_rx = clash_tx = 0
    for _h, a, b in q("SELECT host, SUM(rx), SUM(tx) FROM daily_domain WHERE day=? GROUP BY host", (today,)):
        clash_rx += a or 0
        clash_tx += b or 0

    buckets = {}
    relay_by_proc = {}
    relay_wire = [0, 0]
    direct = {}
    for proc, remote, iface, a, b in q(
            "SELECT process, remote, iface, rx, tx FROM daily_flow WHERE day=?", (today,)):
        a, b = a or 0, b or 0
        kind = classify_flow(proc, remote)
        cur = buckets.setdefault(kind, [0, 0])
        cur[0] += a
        cur[1] += b
        if kind == "relay":
            r = relay_by_proc.setdefault(short_proc(proc), [0, 0])
            r[0] += a
            r[1] += b
            if not (iface and iface_kind(iface) == "loopback"):
                relay_wire[0] += a      # 只算出口侧，避免本机回环把账放大
                relay_wire[1] += b
        elif kind == "direct":
            d = direct.setdefault(remote, [0, 0, {}])
            d[0] += a
            d[1] += b
            d[2][short_proc(proc)] = d[2].get(short_proc(proc), 0) + a + b

    fakeip = buckets.get("fakeip", [0, 0])
    direct_rx = sum(v[0] for v in direct.values())
    direct_tx = sum(v[1] for v in direct.values())
    other_rx = max(0, today_rx - clash_rx - direct_rx)
    other_tx = max(0, today_tx - clash_tx - direct_tx)
    rest_rx = max(0, other_rx - fakeip[0])

    # ---------------- 导航区（全部带图标，所以都不上色）
    lines.append("---")
    lines.append(item("Top 进程（%d）" % len(procs), sfimage="cpu", size=13,
                      symbolize=False, emojize=False,
                      tooltip="下载/上传各前 %d，外加全部 %d 个进程" % (TOP_N, len(procs))))
    if procs:
        for label, i, color in (("-- ↓ 下载前 %d" % TOP_N, 0, BLUE), ("-- ↑ 上传前 %d" % TOP_N, 1, ORANGE)):
            ranked = [(n, p) for n, p in sorted(procs.items(), key=lambda kv: kv[1][i], reverse=True)
                      if p[i] > 0][:TOP_N]
            if not ranked:
                continue
            lines.append(item(label, size=11, color=DIM, symbolize=False, emojize=False))
            peak = ranked[0][1][i] or 1
            for idx, (name, pair) in enumerate(ranked, 1):
                lines.append(item("-- %d  %s %s %s"
                                  % (idx, pad(name, PROC_W), fmt(pair[i]).rjust(VAL_W),
                                     bar(pair[i] / peak)),
                                  font=MONO, size=12, color=color,
                                  symbolize=False, emojize=False, tooltip=name))
        lines.append(item("-- ---"))
        lines.append(item("-- 全部 %d 个进程" % len(procs), size=11, color=DIM,
                          symbolize=False, emojize=False))
        for idx, (name, pair) in enumerate(
                sorted(procs.items(), key=lambda kv: kv[1][0] + kv[1][1], reverse=True)[:LIST_N], 1):
            lines.append(item("-- %d  %s ↓%s ↑%s"
                              % (idx, pad(name, PROC_W), fmt(pair[0]).rjust(VAL_W),
                                 fmt(pair[1]).rjust(VAL_W)),
                              font=MONO, size=12, symbolize=False, emojize=False, tooltip=name))
    else:
        lines.append(item("-- 暂无数据", size=12, color=DIM, symbolize=False, emojize=False))

    lines.append(item("来源拆分 · 今天", sfimage="chart.pie", size=13, symbolize=False, emojize=False,
                      tooltip="下载量由哪几块组成"))
    lines.append(item("-- 【下载来源】", size=11, color=DIM, symbolize=False, emojize=False))
    for label, val, color, tip in (
            ("Clash 域名记录", clash_rx, BLUE, "来自代理 API 的连接记录，能拿到域名"),
            ("直连 nettop", direct_rx, GREEN, "没走代理、直接连出去的连接"),
            ("未归因", other_rx, PURPLE, "物理出口总量 − Clash 域名记录 − 直连；展开下面的「未归因」看它由什么组成")):
        lines.append(item("-- %s %s  %3d%%" % (pad(label, 18), fmt(val).rjust(7), pct(val, today_rx)),
                          font=MONO, size=12, color=color, symbolize=False, emojize=False, tooltip=tip))
    big_direct = [(r, v) for r, v in direct.items() if (v[0] + v[1]) >= 10240]
    if big_direct:
        lines.append(item("-- 【直连大流量目标】（≥10 KB）", size=11, color=DIM,
                          symbolize=False, emojize=False))
        for remote, (a, b, plist) in sorted(big_direct, key=lambda kv: -(kv[1][0] + kv[1][1]))[:5]:
            who = max(plist.items(), key=lambda kv: kv[1])[0] if plist else ""
            lines.append(item("-- %s ↓%s ↑%s  %s"
                              % (pad(remote, 24), fmt(a).rjust(VAL_W), fmt(b).rjust(VAL_W), pad(who, 12)),
                              font=MONO, size=12, symbolize=False, emojize=False,
                              tooltip="%s · %s" % (remote, who)))
    if tun_rx:
        lines.append(item("-- 隧道网卡另有 ↓%s（物理网卡已计过，不重复计入）" % fmt(tun_rx),
                          size=11, color=DIM, symbolize=False, emojize=False,
                          tooltip="utun/tun 上的字节与物理网卡是同一份，为避免翻倍默认不重复计入总量"))

    lines.append(item("未归因 · 今天", sfimage="questionmark.circle", size=13,
                      symbolize=False, emojize=False,
                      tooltip="来源拆分里那笔「未归因」到底是什么"))
    lines.append(item("-- %s ↓%s ↑%s" % (pad("合计", 18), fmt(other_rx).rjust(VAL_W),
                                        fmt(other_tx).rjust(VAL_W)),
                      font=MONO, size=12, color=PURPLE, symbolize=False, emojize=False,
                      tooltip="与「来源拆分」里的「未归因」是同一笔账，下面把它拆开"))
    lines.append(item("-- %s %s" % (pad("fake-ip 目标", 18), fmt(fakeip[0]).rjust(7)),
                      font=MONO, size=12, color=ORANGE, symbolize=False, emojize=False,
                      tooltip="目标是 198.18.x.x 这类 fake-ip：确实进了代理，但代理软件没记到"))
    lines.append(item("-- %s %s" % (pad("采样间隙/协议头", 18), fmt(rest_rx).rjust(7)),
                      font=MONO, size=12, color=DIM, symbolize=False, emojize=False,
                      tooltip="未归因减去 fake-ip：采样间隙内开完又关的短连接、TLS/VPN 头部、系统级流量。"
                              "把刷新间隔改小能减少这一项"))
    lines.append(item("-- 【参考 · 不参与对账】", size=11, color=DIM, symbolize=False, emojize=False))
    lines.append(item("-- %s %s" % (pad("代理软件出口侧", 18), fmt(relay_wire[0]).rjust(7)),
                      font=MONO, size=12, color=PURPLE, symbolize=False, emojize=False,
                      tooltip="nettop 看到的中继进程自身流量；它和「Clash 域名记录」是同一份流量的两种观测，"
                              "只作参考、不参与对账"))
    for idx, (name, pair) in enumerate(
            sorted(relay_by_proc.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:3], 1):
        lines.append(item("-- %s ↓%s ↑%s"
                          % (pad("%d  %s" % (idx, name), 18), fmt(pair[0]).rjust(VAL_W),
                             fmt(pair[1]).rjust(VAL_W)),
                          font=MONO, size=12, color=PURPLE, symbolize=False, emojize=False,
                          tooltip="识别到的代理/中继软件：%s" % name))

    lines.append(item("网卡明细 · 今天", sfimage="network", size=13, symbolize=False, emojize=False,
                      tooltip="全部网卡，含隧道与回环；口径：%s"
                              % ("只算物理出口（不翻倍）" if TOTAL_MODE == "physical" else "含隧道网卡（会翻倍）")))
    iface_rows = q("SELECT iface, SUM(rx), SUM(tx) FROM daily_iface WHERE day=? GROUP BY iface "
                   "ORDER BY SUM(rx)+SUM(tx) DESC", (today,))
    for name, a, b in iface_rows:
        kind = iface_kind(name)
        tag = "%s·%s" % (KIND_LABEL[kind], "计入" if iface_counted(name) else "不计")
        if kind == "tunnel":
            color, tip = PURPLE, "隧道：这些字节在物理网卡上已经算过一次，默认不重复计入总量"
        elif kind == "loopback":
            color, tip = DIM, "本机回环：应用与代理之间的本地流量，不是真实出入流量"
        elif kind == "other":
            color, tip = ORANGE, "不在已知名单里的网卡，按「宁可多算也不漏」计入总量"
        else:
            color, tip = GREEN, "物理出口网卡，计入总量"
        lines.append(item("-- %s ↓%s ↑%s  %s"
                          % (pad(name, 10), fmt(a).rjust(VAL_W), fmt(b).rjust(VAL_W), tag),
                          font=MONO, size=12, color=color, symbolize=False, emojize=False, tooltip=tip))
    if not iface_rows:
        lines.append(item("-- 暂无数据", size=12, color=DIM, symbolize=False, emojize=False))
    if all_rx != today_rx or all_tx != today_tx:
        lines.append(item("-- ---"))
        lines.append(item("-- 若把隧道也算进来 ↓%s ↑%s（会翻倍，仅参考）" % (fmt(all_rx), fmt(all_tx)),
                          size=11, color=DIM, symbolize=False, emojize=False,
                          tooltip="当前 TOTAL_MODE=%s" % TOTAL_MODE))

    # ---------------- 底部（带图标 → 不上色）
    lines.append("---")
    lines.append(item("立即采样一次", sfimage="arrow.clockwise", bash=PLUGIN, param1="--force",
                      terminal="false", refresh=True, size=13))
    lines.append(item("打开数据目录", sfimage="folder", bash="/usr/bin/open", param1=NM_HOME,
                      terminal="false", size=13))
    age = int(now - last_sample) if last_sample else -1
    if age < 0:
        health, hcolor, htip = "还没采样过", RED, "等一下就好，或者点上面的「立即采样一次」"
    elif age > max(120, int(cfg.get("sample_interval", 10)) * 6):
        health, hcolor, htip = "已 %d 秒没采样" % age, RED, "SwiftBar 可能没在跑，或者采集出错了"
    else:
        health, hcolor, htip = "采样正常 · %d 秒前 · v%s" % (age, VERSION), DIM, "日志：%s" % LOG_PATH
    lines.append(item(health, size=12, color=hcolor, symbolize=False, emojize=False, tooltip=htip))
    return lines


# ============================================================ 入口
def main():
    args = set(sys.argv[1:])
    cfg = load_config()

    try:
        sample(int(time.time()), cfg, force="--force" in args)
    except Exception as exc:
        log("采样异常: %r" % (exc,))

    now = time.time()
    db = sqlite3.connect(DB_PATH, timeout=10)
    try:
        print("\n".join(render(db, now, datetime.now(), cfg)))
    finally:
        db.close()


proxy_pat = compile_patterns(PROXY_PROCESS_PATTERNS + list(load_json(CONFIG_PATH, {}).get("proxy_process_patterns", [])))
loop_pat = compile_patterns(IFACE_LOOPBACK)
tun_pat = compile_patterns(IFACE_TUNNEL)
phy_pat = compile_patterns(IFACE_PHYSICAL)
fake_prefix = tuple(BUILTIN_FAKE_IP + list(load_json(CONFIG_PATH, {}).get("fake_ip_prefixes", [])))
clash_index = set()
TITLE_METRIC = load_json(UI_PATH, {}).get("title_metric") or TITLE_METRIC

try:
    main()
except Exception as exc:
    print(item("↑ —", color=RED, dropdown=False, symbolize=False, emojize=False))
    print("---")
    print(item("读取数据失败：%r" % (exc,), size=12))
    print(item("重新检查", refresh=True, size=12))
PY
