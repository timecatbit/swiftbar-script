#!/bin/bash
# <xbar.title>流量监测 NetMeter</xbar.title>
# <xbar.version>1.4.1</xbar.version>
# <xbar.desc>菜单栏固定显示今日上传量；展开是今日上下行、实时速率与近 1 小时走势、Top 域名（下载/上传各前三，直接铺在主页）、更多域名、Top 进程（含全部）、来源拆分、未归因是谁的、网卡明细。</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# 数据由 ~/Library/Application Support/NetMeter/collector.py 采集（LaunchAgent 定时拉起，不需要 root）。
# 本插件只读数据库。
#
# ⚠️ 改这个脚本前必读（踩过的坑，都是真金白银换来的）：
#   1. SwiftBar 把输出里「第一个 --- 之前的所有行」都当成菜单栏标题，多于 1 行就会每隔几秒轮流展示。
#      所以标题行后面必须紧跟一条 ---（见 render() 里第一条分隔线，别删）。
#   2. 菜单栏标题不要用 sfimage。SF Symbol 是贴进 attributedTitle 的图片，鼠标高亮时不会跟着系统反色，
#      图标会直接消失。用文字箭头（下面的 TITLE_PREFIX）才会跟着文本自动反色。
#   3. 【下拉菜单里图标消失的真正原因】同一行绝对不能同时出现 color= 和 sfimage=。
#      SwiftBar 会给带 color 的行套一层自定义 NSAttributedString（MenuTrackingAttributedTitle），
#      内联的图标附件在它身上画不出来 —— 于是「有 color 的行图标全没了，没 color 的行图标正常」。
#      本文件因此严格遵循两条铁律：
#        · 有图标 → 不写 color（走系统默认色，高亮时自动反色）
#        · 要上色 → 不加图标
#      图标走 sfimage（不加 sfconfig）时是 template 图，SwiftBar 会在高亮时自动 tint 成
#      selectedMenuItemTextColor，所以悬停不会消失。
#   4. 颜色一律给「浅色,深色」两个值；中性文字用 DIM，不要用 #8E8E93 这类中灰（白底/深色底都读不清）。
#   5. 菜单背景那层毛玻璃是 macOS 系统的，插件改不了。想更清楚：
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
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import unicodedata
from datetime import datetime

NM_HOME = os.environ.get("NM_HOME") or os.path.expanduser("~/Library/Application Support/NetMeter")
DB_PATH = os.path.join(NM_HOME, "netmeter.db")
CONFIG_PATH = os.path.join(NM_HOME, "config.json")
UI_PATH = os.path.join(NM_HOME, "ui.json")
COLLECTOR = os.path.join(NM_HOME, "collector.py")
PLUGIN = os.environ.get("NM_PLUGIN_PATH", "")
PLUGIN_VERSION = "1.4.1"

DEFAULTS = {
    "total_iface_patterns": ["^en\\d+$", "^pdp_ip\\d+$"],
    "fake_ip_prefixes": ["198.18.", "198.19.", "fdfe:dcba:9876:"],
    "proxy_process_patterns": ["mihomo", "clash", "tailscale"],
    "sample_interval": 20,
}

# ============================================================ 可调开关
# 菜单栏显示哪一项（可选：today_upload / today_download / today_total /
# cum_upload / cum_download / cum_total）。也可以写进 ui.json 的 title_metric。
TITLE_METRIC = "today_upload"

# 菜单栏图标：故意用「文字箭头」而不是 sfimage —— 文字会跟系统自动反色，
# 鼠标扫过高亮时不会消失。见文件头注意事项 2。
TITLE_PREFIX = "↑ "

# 总量口径："physical" = 只算物理出口（默认，不会因为隧道而翻倍）
#           "all"      = 物理 + 隧道网卡全算（会翻倍，仅当你确实想要这个数时改）
TOTAL_MODE = "physical"
TOP_N = 3

# ============================================================ 布局
HOST_W = 24        # Top 域名列表里域名占的列宽
PROC_W = 20        # 进程名占的列宽
VAL_W = 6          # 数值列宽（右对齐）
BAR_W = 8          # Top 列表里的条形宽度
SUM_BAR_W = 10     # 概览里的条形宽度
LIST_N = 30        # 「更多」列表最多列多少条

# ============================================================ 配色
# 每个值都是 "浅色模式,深色模式"。中性文字用 DIM：
#   #3F3F46 在白底对比度约 10.4:1，#CFCFD6 在深色底约 10:1 —— 两端都够读。
BLUE = "#0A5BD3,#7CC0FF"     # 下载
ORANGE = "#A8480A,#FFB454"   # 上传
GREEN = "#136B37,#5FE3A1"    # 直连 / 正常
RED = "#B42318,#FF9A8F"      # 告警
PURPLE = "#6B21A8,#D8B4FE"   # 未归因 / 隧道
DIM = "#3F3F46,#CFCFD6"      # 次要文字
MONO = "Menlo"

# ============================================================ 网卡分类
# 物理出口：真正连到外面的网线 / Wi-Fi / 蜂窝 / USB 共享
IFACE_PHYSICAL = [
    r"^en\d+$", r"^eth\d+$", r"^pdp_ip\d+$", r"^rmnet\d+$", r"^bridge\d+$",
    r"^thunderbolt\d+$", r"^anpi\d+$", r"^ax\d+$", r"^wl[a-z0-9]+$",
]
# 隧道：VPN / 代理软件自己建的通道（这些字节在物理网卡上已经算过一次，默认不重复计入）
IFACE_TUNNEL = [
    r"^utun\d+$", r"^tun\d+$", r"^tap\d+$", r"^wg\d+$", r"^ipsec\d+$",
    r"^ppp\d+$", r"^gpd\d+$", r"^gif\d+$", r"^stf\d+$", r"^tailscale",
    r"^zt[a-z0-9]*$", r"^loon", r"^surge", r"^clash", r"^mihomo", r"^sing",
    r"^hiddify", r"^nekoray", r"^warp",
]
# 回环 / 纯本机：永远不计入总量
IFACE_LOOPBACK = [
    r"^lo\d+$", r"^awdl\d+$", r"^llw\d+$", r"^ap\d+$", r"^vmenet\d+$",
    r"^vmnet\d+$", r"^docker\d*$", r"^br-[0-9a-f]+$",
]

# ============================================================ 代理 / VPN 软件名单
# 这些进程是「中继」：它们自己占的字节不算真实业务归属，
# 否则同一个下载会在「代理进程」和「真实 App」里各算一次。
# 注意 nettop 的进程名会截断到 15 字符，所以用子串匹配（大小写不敏感）。
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
# 常见 fake-ip 网段（目标 IP 落在这些网段，说明流量已经进了代理）
BUILTIN_FAKE_IP = ["198.18.", "198.19.", "fdfe:dcba:9876:", "fd00:1:fd00:1:", "240.0.0."]


# ------------------------------------------------------------------ 小工具
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
    """按显示宽度补齐（中文按 2 列），超出则截断加省略号。

    注意：不能直接用 len() —— 中英混排时 len 相同的两行在菜单里宽度并不相同。
    """
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
        elif val is False or val is None:
            # 显式写出 false：symbolize/emojize/dropdown 都靠它关掉
            if val is False:
                parts.append("%s=false" % key)
        else:
            sval = str(val)
            # 值里有空格必须加引号，否则 SwiftBar 会把它当成下一个参数
            if re.search(r"\s", sval):
                sval = '"%s"' % sval.replace('"', "")
            parts.append("%s=%s" % (key, sval))
    return title + (" | " + " ".join(parts) if parts else "")


def load_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else dict(fallback)
    except Exception:
        return dict(fallback)


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


cfg = dict(DEFAULTS)
cfg.update(load_json(CONFIG_PATH, {}))
TITLE_METRIC = load_json(UI_PATH, {}).get("title_metric") or TITLE_METRIC

# ------------------------------------------------------------------ 交互动作
if len(sys.argv) >= 2 and sys.argv[1] == "--collect":
    if os.path.exists(COLLECTOR):
        try:
            subprocess.run([sys.executable, COLLECTOR], timeout=40,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    sys.exit(0)


# ------------------------------------------------------------------ 规则编译
# 插件自带的名单 + config.json 里的名单取并集：这样 Loon 等软件不用改采集器也能识别
def compile_patterns(extra):
    out = []
    for p in extra:
        try:
            out.append(re.compile(p, re.I))
        except re.error:
            pass
    return out


proxy_pat = compile_patterns(PROXY_PROCESS_PATTERNS + list(cfg.get("proxy_process_patterns", [])))
loop_pat = compile_patterns(IFACE_LOOPBACK)
tun_pat = compile_patterns(IFACE_TUNNEL)
phy_pat = compile_patterns(IFACE_PHYSICAL)
fake_prefix = tuple(BUILTIN_FAKE_IP + list(cfg.get("fake_ip_prefixes", [])))

KIND_LABEL = {"physical": "物理出口", "tunnel": "隧道", "loopback": "回环", "other": "其他"}


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


# 走代理的连接在「代理 API」和「nettop」两边各出现一次，用 (进程, 目标 IP) 去重
clash_index = set()


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


now = time.time()
now_dt = datetime.now()
today = now_dt.strftime("%Y-%m-%d")


def render():
    lines = []
    db = sqlite3.connect(DB_PATH, timeout=5)
    q = lambda sql, args=(): db.execute(sql, args).fetchall()

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
    all_rx, all_tx = iface_sum(today, only_counted=False)   # 含隧道的参考值
    tun_rx = tun_tx = 0
    for name, a, b in q("SELECT iface, rx, tx FROM daily_iface WHERE day=?", (today,)):
        if iface_kind(name) == "tunnel":
            tun_rx += a or 0
            tun_tx += b or 0

    per_day = {}
    for day, name, a, b in q("SELECT day, iface, SUM(rx), SUM(tx) FROM daily_iface GROUP BY day, iface"):
        if iface_counted(name):
            cur = per_day.setdefault(day, [0, 0])
            cur[0] += a or 0
            cur[1] += b or 0

    install = q("SELECT v FROM meta WHERE k='installed_at'")
    install_day = datetime.fromtimestamp(int(install[0][0])).strftime("%m-%d") if install else "—"
    last_run = q("SELECT v FROM meta WHERE k='last_run'")
    last_run = int(last_run[0][0]) if last_run else 0
    coll_ver = q("SELECT v FROM meta WHERE k='version'")
    coll_ver = coll_ver[0][0] if coll_ver else "?"

    # ---------------- 菜单栏标题（只此一行，后面紧跟 --- 见文件头注意事项 1；不要用 sfimage 见 2）
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

    # ============================================================ 今日概览
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
                          tooltip="最近一小时流量走势（每格 5 分钟）；后面的数字是最近一个采样间隔的平均速率"))
    elif tail:
        lines.append(item("即时%s" % tail.strip(), font=MONO, size=12, color=DIM,
                          symbolize=False, emojize=False))

    # ============================================================ Top 域名（前三直接铺在主页）
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
    # 注意：这一行有图标 → 不能写 color（见文件头注意事项 3）
    lines.append(item("Top 域名 · 今天", sfimage="globe", size=13, symbolize=False, emojize=False,
                      tooltip="按代理 API 记录的域名流量，下载/上传各列前三"))
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

    # ---------------- 更多域名（二级菜单）
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

    # ============================================================ 累计与近 7 天
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

    # ============================================================ 进程统计
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

    # ============================================================ 来源拆分 / 未归因
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

    # ============================================================ 导航区（全部带图标，所以都不上色）
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
                              "调小 sample_interval 能减少这一项"))
    lines.append(item("-- 【参考 · 不参与对账】", size=11, color=DIM, symbolize=False, emojize=False))
    lines.append(item("-- %s %s" % (pad("代理软件出口侧", 18), fmt(relay_wire[0]).rjust(7)),
                      font=MONO, size=12, color=PURPLE, symbolize=False, emojize=False,
                      tooltip="nettop 看到的中继进程自身流量；它和「Clash 域名记录」是同一份流量的两种观测，"
                              "只作参考、不参与对账"))
    for idx, (name, pair) in enumerate(
            sorted(relay_by_proc.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:3], 1):
        lines.append(item("-- %s ↓%s ↑%s"
                          % (pad("%d  %s" % (idx, name), 18), fmt(pair[0]).rjust(VAL_W), fmt(pair[1]).rjust(VAL_W)),
                          font=MONO, size=12, color=PURPLE, symbolize=False, emojize=False,
                          tooltip="识别到的代理/中继软件：%s" % name))

    lines.append(item("网卡明细 · 今天", sfimage="network", size=13, symbolize=False, emojize=False,
                      tooltip="全部网卡，含隧道与回环；口径：%s"
                              % ("只算物理出口（不翻倍）" if TOTAL_MODE == "physical" else "含隧道网卡（会翻倍）")))
    iface_rows = q("SELECT iface, SUM(rx), SUM(tx) FROM daily_iface WHERE day=? GROUP BY iface "
                   "ORDER BY SUM(rx)+SUM(tx) DESC", (today,))
    for name, a, b in iface_rows:
        kind = iface_kind(name)
        counted = iface_counted(name)
        tag = "%s·%s" % (KIND_LABEL[kind], "计入" if counted else "不计")
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

    # ============================================================ 底部（带图标 → 不上色）
    lines.append("---")
    lines.append(item("立即采集一次", sfimage="arrow.clockwise", bash=PLUGIN, param1="--collect",
                      terminal="false", refresh=True, size=13))
    lines.append(item("打开数据目录", sfimage="folder", bash="/usr/bin/open", param1=NM_HOME,
                      terminal="false", size=13))
    age = int(now - last_run) if last_run else -1
    if age < 0:
        health, hcolor, htip = "采集器还没跑过", RED, "LaunchAgent 可能没装好"
    elif age > max(180, int(cfg.get("sample_interval", 20)) * 6):
        health, hcolor, htip = "采集器已 %d 秒没更新" % age, RED, "后台采集可能卡住了，点上面的「立即采集一次」试试"
    else:
        health, hcolor, htip = "采集正常 · %d 秒前 · v%s" % (age, PLUGIN_VERSION), DIM, "采集器 v%s" % coll_ver
    lines.append(item(health, size=12, color=hcolor, symbolize=False, emojize=False, tooltip=htip))
    db.close()
    return lines


try:
    print("\n".join(render()))
except Exception as exc:
    print(item("↑ —", color=RED, dropdown=False, symbolize=False, emojize=False))
    print("---")
    print(item("读取数据失败：%r" % (exc,), size=12))
    print(item("重新检查", refresh=True, size=12))
PY
