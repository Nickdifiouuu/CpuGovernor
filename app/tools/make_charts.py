"""Render calibration charts as standalone SVG (no dependencies).

Follows the dataviz mark specs: 2px lines, >=8px markers with a 2px surface ring, <=24px bars with a 4px
rounded data-end (square at the baseline), solid hairline grid, text in ink tokens (never series colour),
legend for >=2 series plus direct end labels, native <title> tooltips on every mark, light + dark values via
CSS custom properties. Input: chart_data.json produced by Build-CalibrationReport.ps1.
"""
import json, math, sys, os
from html import escape

LIGHT = dict(surface="#fcfcfb", ink="#0b0b0b", ink2="#52514e", muted="#898781", grid="#e1e0d9", base="#c3c2b7",
             s1="#2a78d6", s2="#eb6834", s3="#1baf7a")
DARK = dict(surface="#1a1a19", ink="#ffffff", ink2="#c3c2b7", muted="#898781", grid="#2c2c2a", base="#383835",
            s1="#3987e5", s2="#d95926", s3="#199e70")
W, H = 720, 380
ML, MR, MT, MB = 64, 150, 78, 56          # right margin holds direct end-labels


def style():
    def block(p):
        return (f"--surface:{p['surface']};--ink:{p['ink']};--ink2:{p['ink2']};--muted:{p['muted']};--grid:{p['grid']};"
                f"--base:{p['base']};--s1:{p['s1']};--s2:{p['s2']};--s3:{p['s3']};")
    return ("<style>svg{" + block(LIGHT) + "font-family:system-ui,-apple-system,'Segoe UI',sans-serif}"
            "@media (prefers-color-scheme: dark){svg{" + block(DARK) + "}}"
            ".t{fill:var(--ink);font-size:15px;font-weight:600}.st{fill:var(--ink2);font-size:12px}"
            ".ax{fill:var(--muted);font-size:11px;font-variant-numeric:tabular-nums}.lab{fill:var(--ink2);font-size:12px}"
            ".val{fill:var(--ink);font-size:11px;font-weight:600}</style>")


def nice_ticks(lo, hi, n=5):
    span = max(hi - lo, 1e-9)
    raw = span / n
    mag = 10 ** math.floor(math.log10(raw))
    step = min((s * mag for s in (1, 2, 2.5, 5, 10) if s * mag >= raw), default=10 * mag)
    start = math.floor(lo / step) * step
    end = math.ceil(hi / step - 1e-9) * step          # always extend to the first tick >= hi, so marks stay inside the plot
    ticks, v = [], start
    while v <= end + step * 0.001:
        ticks.append(round(v, 6)); v += step
    return ticks


def fmt(v):
    return f"{v:,.0f}" if abs(v) >= 100 or float(v).is_integer() else f"{v:,.1f}"


def frame(title, subtitle, ylabel, yticks, ymap, xticks, xmap, xlabel):
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-label="{escape(title)}">',
           style(), f'<rect width="{W}" height="{H}" fill="var(--surface)"/>',
           f'<text class="t" x="{ML}" y="26">{escape(title)}</text>', f'<text class="st" x="{ML}" y="44">{escape(subtitle)}</text>']
    for t in yticks:
        y = ymap(t)
        out.append(f'<line x1="{ML}" x2="{W-MR}" y1="{y:.1f}" y2="{y:.1f}" stroke="var(--grid)" stroke-width="1"/>')
        out.append(f'<text class="ax" x="{ML-8}" y="{y+4:.1f}" text-anchor="end">{fmt(t)}</text>')
    out.append(f'<line x1="{ML}" x2="{W-MR}" y1="{ymap(yticks[0]):.1f}" y2="{ymap(yticks[0]):.1f}" stroke="var(--base)" stroke-width="1"/>')
    for x, lab in xticks:
        out.append(f'<text class="ax" x="{xmap(x):.1f}" y="{H-MB+18}" text-anchor="middle">{escape(str(lab))}</text>')
    out.append(f'<text class="ax" x="{(ML + W - MR)/2:.1f}" y="{H-14}" text-anchor="middle">{escape(xlabel)}</text>')
    out.append(f'<text class="ax" x="16" y="{(MT + H - MB)/2:.1f}" text-anchor="middle" transform="rotate(-90 16 {(MT + H - MB)/2:.1f})">{escape(ylabel)}</text>')
    return out


def line_chart(path, title, subtitle, ylabel, xlabel, series, xticks, ymin=None, ymax=None, unit=""):
    """series: [{name, slot(1-3), points:[(x, y, tip)]}] — x numeric."""
    xs = [p[0] for s in series for p in s["points"]]; ys = [p[1] for s in series for p in s["points"]]
    x0, x1 = min(xs + [t[0] for t in xticks]), max(xs + [t[0] for t in xticks])
    lo = ymin if ymin is not None else min(0, min(ys)); hi = ymax if ymax is not None else max(ys) * 1.08
    yt = nice_ticks(lo, hi); lo, hi = yt[0], yt[-1]
    xmap = lambda x: ML + 10 + (x - x0) / (x1 - x0) * (W - MR - ML - 20)
    ymap = lambda y: H - MB - (y - lo) / (hi - lo) * (H - MB - MT)
    out = frame(title, subtitle, ylabel, yt, ymap, xticks, xmap, xlabel)
    # legend (>=2 series)
    if len(series) > 1:
        lx = ML
        for s in series:
            out.append(f'<line x1="{lx}" x2="{lx+16}" y1="60" y2="60" stroke="var(--s{s["slot"]})" stroke-width="2" stroke-linecap="round"/>')
            out.append(f'<text class="lab" x="{lx+22}" y="64">{escape(s["name"])}</text>')
            lx += 30 + 7 * len(s["name"])
    ends = []
    for s in series:
        pts = sorted(s["points"])
        d = " ".join(f'{"M" if i == 0 else "L"}{xmap(x):.1f},{ymap(y):.1f}' for i, (x, y, _) in enumerate(pts))
        out.append(f'<path d="{d}" fill="none" stroke="var(--s{s["slot"]})" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>')
        for x, y, tip in pts:
            out.append(f'<g><title>{escape(s["name"])}: {escape(tip)}</title>'
                       f'<circle cx="{xmap(x):.1f}" cy="{ymap(y):.1f}" r="12" fill="transparent"/>'
                       f'<circle cx="{xmap(x):.1f}" cy="{ymap(y):.1f}" r="4" fill="var(--s{s["slot"]})" stroke="var(--surface)" stroke-width="2"/></g>')
        ends.append((ymap(pts[-1][1]), pts[-1], s))
    # direct end labels, spaced to avoid collisions (leader line when moved)
    ends.sort(key=lambda e: e[0]); placed = []
    for y, (x, v, _), s in ends:
        ly = y if not placed else max(y, placed[-1] + 16)
        placed.append(ly)
        ex = xmap(x)
        if abs(ly - y) > 2:
            out.append(f'<line x1="{ex+6:.1f}" y1="{y:.1f}" x2="{ex+14:.1f}" y2="{ly:.1f}" stroke="var(--muted)" stroke-width="1"/>')
        out.append(f'<text class="lab" x="{ex+16:.1f}" y="{ly+4:.1f}">{escape(fmt(v))}{escape(unit)} {escape(s.get("short", ""))}</text>')
    out.append("</svg>")
    open(path, "w", encoding="utf-8").write("\n".join(out))


def bar_chart(path, title, subtitle, ylabel, xlabel, bars, unit=""):
    """bars: [(label, value, tip)] — single series, slot 1, ordered categories."""
    hi = max([b[1] for b in bars] + [1]) * 1.15
    yt = nice_ticks(0, hi); hi = yt[-1]
    n = len(bars); band = (W - MR - ML) / n; bw = min(24, band * 0.5)
    xmap = lambda i: ML + band * (i + 0.5)
    ymap = lambda y: H - MB - y / hi * (H - MB - MT)
    out = frame(title, subtitle, ylabel, yt, ymap, [(i, b[0]) for i, b in enumerate(bars)], xmap, xlabel)
    base = ymap(0)
    for i, (lab, v, tip) in enumerate(bars):
        cx = xmap(i); x = cx - bw / 2; top = ymap(v); r = min(4, (base - top) / 2)
        if v > 0:
            d = (f"M{x:.1f},{base:.1f} L{x:.1f},{top + r:.1f} Q{x:.1f},{top:.1f} {x + r:.1f},{top:.1f} "
                 f"L{x + bw - r:.1f},{top:.1f} Q{x + bw:.1f},{top:.1f} {x + bw:.1f},{top + r:.1f} L{x + bw:.1f},{base:.1f} Z")
            out.append(f'<g><title>{escape(str(lab))}: {escape(tip)}</title><rect x="{cx - band/2:.1f}" y="{MT}" width="{band:.1f}" height="{base - MT:.1f}" fill="transparent"/>'
                       f'<path d="{d}" fill="var(--s1)"/></g>')
            out.append(f'<text class="val" x="{cx:.1f}" y="{top - 6:.1f}" text-anchor="middle">{escape(fmt(v))}{escape(unit)}</text>')
        else:
            out.append(f'<g><title>{escape(str(lab))}: {escape(tip)}</title><rect x="{cx - band/2:.1f}" y="{MT}" width="{band:.1f}" height="{base - MT:.1f}" fill="transparent"/>'
                       f'<text class="val" x="{cx:.1f}" y="{base - 6:.1f}" text-anchor="middle">0</text></g>')
    out.append("</svg>")
    open(path, "w", encoding="utf-8").write("\n".join(out))


if __name__ == "__main__":
    data = json.load(open(sys.argv[1], encoding="utf-8-sig"))
    outdir = sys.argv[2]; os.makedirs(outdir, exist_ok=True)
    for c in data["charts"]:
        W = int(c.get("width", 720))          # per-chart canvas width (module-level W is read by the drawing functions)
        p = os.path.join(outdir, c["file"])
        if c["type"] == "bar":
            bar_chart(p, c["title"], c["subtitle"], c["ylabel"], c["xlabel"], [tuple(b) for b in c["bars"]], c.get("unit", ""))
        else:
            line_chart(p, c["title"], c["subtitle"], c["ylabel"], c["xlabel"],
                       [dict(s, points=[tuple(pt) for pt in s["points"]]) for s in c["series"]],
                       [tuple(t) for t in c["xticks"]], c.get("ymin"), c.get("ymax"), c.get("unit", ""))
        print("wrote", p)
