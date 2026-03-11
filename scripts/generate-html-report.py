#!/usr/bin/env python3
"""
generate-html-report.py — Generate comprehensive HTML regression report.

Reads:
  - Comprehensive test JSON for baseline and candidate
  - Regression diff files (from run-regression-tests.sh)
  - System logs (optional)

Outputs: A single self-contained HTML file with:
  - Executive summary with pass/fail badges and SVG charts
  - Failures & Warnings section (prominent)
  - Passed Tests section (collapsible)
  - CLI regression diffs (auto-expanded)
  - System logs (collapsible)
  - CSV export
"""
import json
import html as html_mod
import math
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from collections import OrderedDict

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"WARNING: Could not load {path}: {e}", file=sys.stderr)
        return None

def load_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""

def load_metrics_csv(path):
    """Load metrics CSV into list of dicts."""
    try:
        import csv
        with open(path) as f:
            reader = csv.DictReader(f)
            return [row for row in reader]
    except Exception as e:
        print(f"WARNING: Could not load metrics CSV {path}: {e}", file=sys.stderr)
        return []

def esc(s):
    return html_mod.escape(str(s))

def group_by_category(tests):
    if not tests or 'results' not in tests:
        return OrderedDict()
    groups = OrderedDict()
    for r in tests['results']:
        cat = r.get('category', 'Other')
        groups.setdefault(cat, []).append(r)
    return groups

def svg_pie(passed, failed, warnings=0, size=140):
    total = passed + failed + warnings
    if total == 0:
        return '<svg width="0" height="0"></svg>'
    cx, cy, r = size/2, size/2, size/2 - 10
    r2 = r - 15

    segments = []
    if passed > 0:
        segments.append(('#22c55e', passed / total))
    if failed > 0:
        segments.append(('#ef4444', failed / total))
    if warnings > 0:
        segments.append(('#f59e0b', warnings / total))

    paths = []
    start_angle = -90
    for color, fraction in segments:
        angle = fraction * 360
        end_angle = start_angle + angle
        large_arc = 1 if angle > 180 else 0

        sx = cx + r * math.cos(math.radians(start_angle))
        sy = cy + r * math.sin(math.radians(start_angle))
        ex = cx + r * math.cos(math.radians(end_angle))
        ey = cy + r * math.sin(math.radians(end_angle))
        isx = cx + r2 * math.cos(math.radians(end_angle))
        isy = cy + r2 * math.sin(math.radians(end_angle))
        iex = cx + r2 * math.cos(math.radians(start_angle))
        iey = cy + r2 * math.sin(math.radians(start_angle))

        if fraction >= 0.999:
            mx = cx + r * math.cos(math.radians(start_angle + 180))
            my = cy + r * math.sin(math.radians(start_angle + 180))
            imx = cx + r2 * math.cos(math.radians(start_angle + 180))
            imy = cy + r2 * math.sin(math.radians(start_angle + 180))
            d = (f"M {sx:.1f},{sy:.1f} A {r},{r} 0 0,1 {mx:.1f},{my:.1f} "
                 f"A {r},{r} 0 0,1 {ex:.1f},{ey:.1f} "
                 f"L {isx:.1f},{isy:.1f} "
                 f"A {r2},{r2} 0 0,0 {imx:.1f},{imy:.1f} "
                 f"A {r2},{r2} 0 0,0 {iex:.1f},{iey:.1f} Z")
        else:
            d = (f"M {sx:.1f},{sy:.1f} A {r},{r} 0 {large_arc},1 {ex:.1f},{ey:.1f} "
                 f"L {isx:.1f},{isy:.1f} A {r2},{r2} 0 {large_arc},0 {iex:.1f},{iey:.1f} Z")

        paths.append(f'<path d="{d}" fill="{color}" stroke="none"/>')
        start_angle = end_angle

    pct = round(passed / total * 100) if total > 0 else 0
    return f'''<svg width="{size}" height="{size}" viewBox="0 0 {size} {size}">
    {"".join(paths)}
    <text x="{cx}" y="{cy-4}" text-anchor="middle" fill="#e2e8f0" font-size="22" font-weight="700">{pct}%</text>
    <text x="{cx}" y="{cy+14}" text-anchor="middle" fill="#94a3b8" font-size="10">pass rate</text>
</svg>'''

def category_bar_chart(groups, width=600, bar_height=22):
    if not groups:
        return ''
    cats = list(groups.keys())
    n = len(cats)
    margin_left = 130
    chart_w = width
    total_h = n * (bar_height + 6) + 20

    max_count = max(len(v) for v in groups.values()) or 1
    bars = []
    y = 10
    for cat in cats:
        results = groups[cat]
        passed = sum(1 for r in results if r['status'] == 'PASS')
        failed = len(results) - passed
        pw = (passed / max_count) * (chart_w - margin_left - 60)
        fw = (failed / max_count) * (chart_w - margin_left - 60)
        bars.append(f'<text x="{margin_left - 8}" y="{y + bar_height/2 + 4}" text-anchor="end" fill="#94a3b8" font-size="11">{esc(cat)}</text>')
        if pw > 0:
            bars.append(f'<rect x="{margin_left}" y="{y}" width="{pw:.1f}" height="{bar_height}" rx="3" fill="#22c55e" opacity="0.85"/>')
        if fw > 0:
            bars.append(f'<rect x="{margin_left + pw:.1f}" y="{y}" width="{fw:.1f}" height="{bar_height}" rx="3" fill="#ef4444" opacity="0.85"/>')
        bars.append(f'<text x="{margin_left + pw + fw + 6:.1f}" y="{y + bar_height/2 + 4}" fill="#94a3b8" font-size="10">{passed}/{len(results)}</text>')
        y += bar_height + 6

    return f'''<svg width="{chart_w}" height="{total_h}" viewBox="0 0 {chart_w} {total_h}" style="max-width:100%">
    {"".join(bars)}
</svg>'''

def render_diff_block(content):
    lines = []
    for line in content.split('\n'):
        if line.startswith('+') and not line.startswith('+++'):
            lines.append(f'<span class="add">{esc(line)}</span>')
        elif line.startswith('-') and not line.startswith('---'):
            lines.append(f'<span class="del">{esc(line)}</span>')
        elif line.startswith('@@'):
            lines.append(f'<span class="hdr">{esc(line)}</span>')
        else:
            lines.append(esc(line))
    return '\n'.join(lines)

def svg_line_chart(metrics, fields, colors, labels, y_label, width=700, height=220):
    """Render an SVG line chart from metrics data."""
    if not metrics or len(metrics) < 2:
        return '<p style="color:var(--text-dim)">Insufficient data for chart.</p>'

    margin = {'top': 20, 'right': 120, 'bottom': 40, 'left': 60}
    plot_w = width - margin['left'] - margin['right']
    plot_h = height - margin['top'] - margin['bottom']
    n = len(metrics)

    all_vals = []
    for field in fields:
        for row in metrics:
            try:
                all_vals.append(float(row.get(field, 0)))
            except (ValueError, TypeError):
                pass

    if not all_vals:
        return '<p style="color:var(--text-dim)">No numeric data for chart.</p>'

    y_min = 0
    y_max = max(all_vals) * 1.1 or 1

    svg = [f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}" style="max-width:100%">']
    svg.append(f'<rect x="{margin["left"]}" y="{margin["top"]}" width="{plot_w}" height="{plot_h}" fill="var(--surface)" rx="4"/>')

    # Grid lines
    for i in range(6):
        y = margin['top'] + plot_h - (i / 5) * plot_h
        val = y_min + (i / 5) * (y_max - y_min)
        svg.append(f'<line x1="{margin["left"]}" y1="{y:.1f}" x2="{margin["left"] + plot_w}" y2="{y:.1f}" stroke="var(--border)" stroke-width="0.5" stroke-dasharray="4,4"/>')
        svg.append(f'<text x="{margin["left"] - 8}" y="{y:.1f}" text-anchor="end" fill="var(--text-dim)" font-size="9" dominant-baseline="middle">{val:.0f}</text>')

    # Y-axis label
    svg.append(f'<text x="14" y="{margin["top"] + plot_h / 2}" text-anchor="middle" fill="var(--text-dim)" font-size="10" transform="rotate(-90, 14, {margin["top"] + plot_h / 2})">{esc(y_label)}</text>')

    # X-axis labels
    step = max(1, n // 6)
    for i in range(0, n, step):
        x = margin['left'] + (i / max(n - 1, 1)) * plot_w
        ts = metrics[i].get('timestamp', '')
        label_text = ts.split('T')[-1].replace('Z', '') if 'T' in ts else ts[-8:]
        svg.append(f'<text x="{x:.1f}" y="{height - 8}" text-anchor="middle" fill="var(--text-dim)" font-size="9">{esc(label_text)}</text>')

    # Plot each field as a line
    for fi, field in enumerate(fields):
        points = []
        for i, row in enumerate(metrics):
            try:
                val = float(row.get(field, 0))
            except (ValueError, TypeError):
                val = 0
            x = margin['left'] + (i / max(n - 1, 1)) * plot_w
            y = margin['top'] + plot_h - ((val - y_min) / (y_max - y_min)) * plot_h
            points.append(f'{x:.1f},{y:.1f}')
        svg.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="{colors[fi]}" stroke-width="1.5" stroke-linejoin="round"/>')

    # Legend
    legend_x = margin['left'] + plot_w + 12
    for fi, lbl in enumerate(labels):
        ly = margin['top'] + 16 + fi * 18
        svg.append(f'<rect x="{legend_x}" y="{ly - 6}" width="12" height="12" rx="2" fill="{colors[fi]}"/>')
        svg.append(f'<text x="{legend_x + 18}" y="{ly + 3}" fill="var(--text-dim)" font-size="10">{esc(lbl)}</text>')

    svg.append('</svg>')
    return '\n'.join(svg)

def extract_probe_data(tests):
    """Extract HTTP probe timing and SSL data from test results."""
    timing = {}
    ssl = {}
    headers = {}
    if not tests or 'results' not in tests:
        return timing, ssl, headers
    for r in tests['results']:
        cat = r.get('category', '')
        if cat == 'HTTPProbe':
            name = r['test']
            if name in ('tcp_connect_time', 'tls_handshake_time', 'time_to_first_byte', 'total_response_time'):
                try:
                    timing[name] = int(r.get('actual', '0').replace('ms', ''))
                except (ValueError, AttributeError):
                    pass
            elif name == 'https_response_status':
                timing['status'] = r.get('actual', '')
            elif name == 'timing_breakdown':
                timing['breakdown'] = r.get('detail', '')
        elif cat == 'SSLProbe':
            ssl[r['test']] = r.get('actual', '')
        elif cat == 'HeaderValidation':
            headers[r['test']] = {'status': r['status'], 'actual': r.get('actual', '')}
    return timing, ssl, headers


def load_probe_timings(csv_path):
    """Load probe timing CSV into list of dicts with numeric conversion."""
    try:
        import csv as csvmod
        with open(csv_path) as f:
            rows = []
            for row in csvmod.DictReader(f):
                for k in ('time_connect_ms', 'time_tls_ms', 'time_ttfb_ms', 'time_total_ms'):
                    try:
                        row[k] = float(row.get(k, 0))
                    except (ValueError, TypeError):
                        row[k] = 0.0
                for k in ('request_num', 'http_status'):
                    try:
                        row[k] = int(row.get(k, 0))
                    except (ValueError, TypeError):
                        row[k] = 0
                # Parse pipe-delimited response headers into list
                raw_hdrs = row.get('response_headers', '')
                row['response_headers'] = [h.strip() for h in raw_hdrs.split('|') if h.strip()] if raw_hdrs else []
                rows.append(row)
            return rows
    except Exception as e:
        print(f"WARNING: Could not load probe timings {csv_path}: {e}", file=sys.stderr)
        return []


def fmt_ms(val):
    """Format millisecond value — show 2 decimals for sub-1ms, 1 decimal for sub-10ms, integer for >=10ms."""
    if val == 0:
        return '0'
    if val < 1:
        return f'{val:.2f}'
    if val < 10:
        return f'{val:.1f}'
    return f'{val:.0f}'


def render_side_by_side_chart(b_probes, c_probes, width=1100, height=440):
    """Render a side-by-side SVG comparison chart — baseline vs candidate for each scenario group."""
    if not b_probes and not c_probes:
        return '<p style="color:var(--text-dim)">No probe timing data available.</p>'

    colors = {
        'normal': '#22c55e', 'api': '#3b82f6', 'static': '#a855f7',
        'redirect': '#f59e0b', 'bot': '#ef4444', 'cors': '#06b6d4',
        'method': '#f97316', 'burst': '#10b981',
    }
    group_labels = {
        'normal': 'Normal', 'api': 'API', 'static': 'Static',
        'redirect': 'Redirect', 'bot': 'Bot', 'cors': 'CORS',
        'method': 'Methods', 'burst': 'Burst',
    }

    # Build groups for both datasets
    all_probes = b_probes or c_probes
    seen_order = []
    b_groups, c_groups = {}, {}
    for row in (b_probes or []):
        sc = row.get('scenario', 'normal')
        if sc not in b_groups:
            if sc not in seen_order:
                seen_order.append(sc)
            b_groups[sc] = []
        b_groups[sc].append(row)
    for row in (c_probes or []):
        sc = row.get('scenario', 'normal')
        if sc not in c_groups:
            if sc not in seen_order:
                seen_order.append(sc)
            c_groups[sc] = []
        c_groups[sc].append(row)

    n_groups = len(seen_order)
    margin = {'top': 40, 'right': 30, 'bottom': 80, 'left': 65}
    plot_w = width - margin['left'] - margin['right']
    plot_h = height - margin['top'] - margin['bottom']

    # Global max total time across both datasets (use total, not just TTFB)
    all_totals = [r.get('time_total_ms', 0) for r in (b_probes or [])] + [r.get('time_total_ms', 0) for r in (c_probes or [])]
    max_val = max(all_totals) if all_totals else 1
    max_val = max(1, max_val * 1.2)

    # Calculate group widths based on max request count per scenario
    group_sizes = []
    for sc in seen_order:
        n = max(len(b_groups.get(sc, [])), len(c_groups.get(sc, [])))
        group_sizes.append(n)
    total_slots = sum(group_sizes)
    group_gap = 16
    usable_w = plot_w - group_gap * (n_groups - 1)

    svg = [f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}" style="max-width:100%;display:block;margin:0 auto;">']
    svg.append(f'<rect x="{margin["left"]}" y="{margin["top"]}" width="{plot_w}" height="{plot_h}" fill="var(--surface)" rx="4"/>')

    # Grid lines + Y labels
    n_gridlines = 6
    for i in range(n_gridlines):
        y = margin['top'] + plot_h - (i / (n_gridlines - 1)) * plot_h
        val = (i / (n_gridlines - 1)) * max_val
        svg.append(f'<line x1="{margin["left"]}" y1="{y:.1f}" x2="{margin["left"] + plot_w}" y2="{y:.1f}" stroke="var(--border)" stroke-width="0.5" stroke-dasharray="4,4"/>')
        svg.append(f'<text x="{margin["left"] - 8}" y="{y:.1f}" text-anchor="end" fill="var(--text-dim)" font-size="10" font-family="monospace" dominant-baseline="middle">{fmt_ms(val)}</text>')

    svg.append(f'<text x="16" y="{margin["top"] + plot_h / 2}" text-anchor="middle" fill="var(--text-dim)" font-size="11" transform="rotate(-90, 16, {margin["top"] + plot_h / 2})">Time (ms)</text>')

    # Softer color scheme — cyan/violet, easy on dark backgrounds
    b_color = '#67e8f9'   # cyan-300 for baseline
    c_color = '#a78bfa'   # violet-400 for candidate

    # Draw grouped paired bars — two-tone: solid=TTFB, lighter extension=total time
    x_cursor = margin['left']
    for gi, sc in enumerate(seen_order):
        b_rows = sorted(b_groups.get(sc, []), key=lambda r: r.get('request_num', 0))
        c_rows = sorted(c_groups.get(sc, []), key=lambda r: r.get('request_num', 0))
        n_pairs = max(len(b_rows), len(c_rows))
        group_w = (n_pairs / total_slots) * usable_w
        sc_color = colors.get(sc, '#94a3b8')

        # Group background stripe
        svg.append(f'<rect x="{x_cursor:.1f}" y="{margin["top"]}" width="{group_w:.1f}" height="{plot_h}" fill="{sc_color}" opacity="0.04" rx="3"/>')

        # Each pair: baseline bar (left) + candidate bar (right)
        pair_w = group_w / max(1, n_pairs)
        bar_w = max(3, pair_w * 0.38)
        pair_gap = pair_w * 0.06

        for pi in range(n_pairs):
            px = x_cursor + pi * pair_w + pair_w * 0.08

            # Baseline bar (two-tone: total=light, TTFB=solid) — blocked requests in red
            if pi < len(b_rows):
                row = b_rows[pi]
                ttfb = row.get('time_ttfb_ms', 0)
                total = row.get('time_total_ms', 0)
                total_h = (total / max_val) * plot_h if max_val > 0 else 0
                ttfb_h = (ttfb / max_val) * plot_h if max_val > 0 else 0
                by_total = margin['top'] + plot_h - total_h
                by_ttfb = margin['top'] + plot_h - ttfb_h
                status = row.get('http_status', '?')
                is_blocked = row.get('blocked') == 'true'
                bar_fill = '#ef4444' if is_blocked else b_color
                blocked_tag = ' | BLOCKED (expected)' if is_blocked else ''
                b_key = f"b-{row.get('request_num', pi+1)}"
                tip = f"Baseline #{row.get('request_num', pi+1)} {sc} | HTTP {status}{blocked_tag} | TTFB: {fmt_ms(ttfb)}ms | Total: {fmt_ms(total)}ms — click for details"
                # Light extension for total time
                if total_h > ttfb_h:
                    svg.append(f'<rect x="{px:.1f}" y="{by_total:.1f}" width="{bar_w:.1f}" height="{max(0.5, total_h - ttfb_h):.1f}" rx="1" fill="{bar_fill}" opacity="0.25" '
                               f'style="cursor:pointer" onclick="showProbeDetail(\'{b_key}\')"/>')
                # Solid bar for TTFB
                svg.append(f'<rect x="{px:.1f}" y="{by_ttfb:.1f}" width="{bar_w:.1f}" height="{max(0.5, ttfb_h):.1f}" rx="1" fill="{bar_fill}" opacity="0.85" '
                           f'style="cursor:pointer" onclick="showProbeDetail(\'{b_key}\')" '
                           f'onmouseover="this.setAttribute(\'opacity\',\'1\');this.setAttribute(\'stroke\',\'white\');this.setAttribute(\'stroke-width\',\'1\')" '
                           f'onmouseout="this.setAttribute(\'opacity\',\'0.85\');this.removeAttribute(\'stroke\');this.removeAttribute(\'stroke-width\')">'
                           f'<title>{esc(tip)}</title></rect>')

            # Candidate bar (two-tone: total=light, TTFB=solid) — blocked requests in red
            if pi < len(c_rows):
                row = c_rows[pi]
                ttfb = row.get('time_ttfb_ms', 0)
                total = row.get('time_total_ms', 0)
                total_h = (total / max_val) * plot_h if max_val > 0 else 0
                ttfb_h = (ttfb / max_val) * plot_h if max_val > 0 else 0
                by_total = margin['top'] + plot_h - total_h
                by_ttfb = margin['top'] + plot_h - ttfb_h
                status = row.get('http_status', '?')
                is_blocked = row.get('blocked') == 'true'
                bar_fill = '#ef4444' if is_blocked else c_color
                blocked_tag = ' | BLOCKED (expected)' if is_blocked else ''
                c_key = f"c-{row.get('request_num', pi+1)}"
                tip = f"Candidate #{row.get('request_num', pi+1)} {sc} | HTTP {status}{blocked_tag} | TTFB: {fmt_ms(ttfb)}ms | Total: {fmt_ms(total)}ms — click for details"
                cx = px + bar_w + pair_gap
                if total_h > ttfb_h:
                    svg.append(f'<rect x="{cx:.1f}" y="{by_total:.1f}" width="{bar_w:.1f}" height="{max(0.5, total_h - ttfb_h):.1f}" rx="1" fill="{bar_fill}" opacity="0.25" '
                               f'style="cursor:pointer" onclick="showProbeDetail(\'{c_key}\')"/>')
                svg.append(f'<rect x="{cx:.1f}" y="{by_ttfb:.1f}" width="{bar_w:.1f}" height="{max(0.5, ttfb_h):.1f}" rx="1" fill="{bar_fill}" opacity="0.85" '
                           f'style="cursor:pointer" onclick="showProbeDetail(\'{c_key}\')" '
                           f'onmouseover="this.setAttribute(\'opacity\',\'1\');this.setAttribute(\'stroke\',\'white\');this.setAttribute(\'stroke-width\',\'1\')" '
                           f'onmouseout="this.setAttribute(\'opacity\',\'0.85\');this.removeAttribute(\'stroke\');this.removeAttribute(\'stroke-width\')">'
                           f'<title>{esc(tip)}</title></rect>')

        # Group label below x-axis
        mid = x_cursor + group_w / 2
        label_y = margin['top'] + plot_h + 16
        lbl = group_labels.get(sc, sc)
        svg.append(f'<text x="{mid:.1f}" y="{label_y}" text-anchor="middle" fill="{sc_color}" font-size="11" font-weight="600">{lbl}</text>')

        # Avg TTFB comparison below label
        b_avg = sum(r.get('time_ttfb_ms', 0) for r in b_rows) / max(1, len(b_rows)) if b_rows else 0
        c_avg = sum(r.get('time_ttfb_ms', 0) for r in c_rows) / max(1, len(c_rows)) if c_rows else 0
        b_avg_total = sum(r.get('time_total_ms', 0) for r in b_rows) / max(1, len(b_rows)) if b_rows else 0
        c_avg_total = sum(r.get('time_total_ms', 0) for r in c_rows) / max(1, len(c_rows)) if c_rows else 0
        svg.append(f'<text x="{mid:.1f}" y="{label_y + 13}" text-anchor="middle" fill="{b_color}" font-size="8" font-family="monospace">B:{fmt_ms(b_avg)}/{fmt_ms(b_avg_total)}ms</text>')
        svg.append(f'<text x="{mid:.1f}" y="{label_y + 24}" text-anchor="middle" fill="{c_color}" font-size="8" font-family="monospace">C:{fmt_ms(c_avg)}/{fmt_ms(c_avg_total)}ms</text>')

        # Diff indicator
        if b_rows and c_rows:
            diff = c_avg - b_avg
            if b_avg > 0:
                pct = diff / b_avg * 100
                sign = '+' if diff > 0 else ''
                dcolor = '#ef4444' if diff > 0.5 else ('#22c55e' if diff < -0.5 else 'var(--text-dim)')
                svg.append(f'<text x="{mid:.1f}" y="{label_y + 36}" text-anchor="middle" fill="{dcolor}" font-size="8" font-weight="600" font-family="monospace">{sign}{pct:.0f}%</text>')

        # Avg dashed lines across group
        if b_rows:
            avg_y = margin['top'] + plot_h - (b_avg / max_val) * plot_h
            svg.append(f'<line x1="{x_cursor + 2:.1f}" y1="{avg_y:.1f}" x2="{x_cursor + group_w - 2:.1f}" y2="{avg_y:.1f}" stroke="{b_color}" stroke-width="1.2" stroke-dasharray="3,3" opacity="0.5"/>')
        if c_rows:
            avg_y = margin['top'] + plot_h - (c_avg / max_val) * plot_h
            svg.append(f'<line x1="{x_cursor + 2:.1f}" y1="{avg_y:.1f}" x2="{x_cursor + group_w - 2:.1f}" y2="{avg_y:.1f}" stroke="{c_color}" stroke-width="1.2" stroke-dasharray="3,3" opacity="0.5"/>')

        x_cursor += group_w + group_gap

    # Legend — shows both TTFB (solid) and Total (light) meaning
    leg_x = margin['left'] + 10
    leg_y = margin['top'] + 12
    svg.append(f'<rect x="{leg_x}" y="{leg_y - 8}" width="10" height="10" rx="2" fill="{b_color}" opacity="0.85"/>')
    svg.append(f'<text x="{leg_x + 14}" y="{leg_y}" fill="var(--text-dim)" font-size="10" dominant-baseline="middle">Baseline</text>')
    svg.append(f'<rect x="{leg_x + 80}" y="{leg_y - 8}" width="10" height="10" rx="2" fill="{c_color}" opacity="0.85"/>')
    svg.append(f'<text x="{leg_x + 94}" y="{leg_y}" fill="var(--text-dim)" font-size="10" dominant-baseline="middle">Candidate</text>')
    svg.append(f'<rect x="{leg_x + 175}" y="{leg_y - 8}" width="10" height="10" rx="2" fill="#ef4444" opacity="0.85"/>')
    svg.append(f'<text x="{leg_x + 189}" y="{leg_y}" fill="var(--text-dim)" font-size="10" dominant-baseline="middle">Blocked (expected)</text>')
    svg.append(f'<text x="{leg_x + 310}" y="{leg_y}" fill="var(--text-dim)" font-size="9" dominant-baseline="middle">(solid = TTFB, faded = total)</text>')

    # Title
    b_count = len(b_probes or [])
    c_count = len(c_probes or [])
    svg.append(f'<text x="{margin["left"] + plot_w / 2}" y="16" text-anchor="middle" fill="var(--text)" font-size="13" font-weight="600">Baseline vs Candidate — {max(b_count, c_count)} requests by scenario</text>')

    svg.append('</svg>')
    return '\n'.join(svg)


def render_test_table(results, label):
    """Render a table of test results."""
    if not results:
        return '<p style="color:var(--text-dim);padding:1rem;">No tests in this section.</p>'
    rows = []
    for r in results:
        status = r['status']
        badge_cls = 'badge-pass' if status == 'PASS' else ('badge-fail' if status == 'FAIL' else 'badge-warn')
        rows.append(f'''<tr data-status="{status}" data-search="{esc(r.get('category',''))} {esc(r['test'])} {esc(r['expected'])} {esc(r['actual'])}">
    <td>{esc(r.get('category', ''))}</td>
    <td>{esc(r['test'])}</td>
    <td><span class="badge {badge_cls}">{status}</span></td>
    <td><code>{esc(r['expected'])}</code></td>
    <td><code>{esc(r['actual'])}</code></td>
    <td>{esc(r.get('detail', ''))}</td>
</tr>''')
    return f'''<table>
<thead><tr><th>Category</th><th>Test</th><th>Status</th><th>Expected</th><th>Actual</th><th>Detail</th></tr></thead>
<tbody>
{''.join(rows)}
</tbody></table>'''


def generate_html(baseline_tests, candidate_tests, regression_dir, output_path, logs_dir=None, metrics_csv=None, baseline_json_path=None, candidate_json_path=None):
    now = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')

    # Load host resource metrics
    metrics = load_metrics_csv(metrics_csv) if metrics_csv else []

    # Collect regression diffs
    diffs = {}
    diffs_dir = os.path.join(regression_dir, 'diffs') if regression_dir else ''
    if diffs_dir and os.path.isdir(diffs_dir):
        for f in sorted(os.listdir(diffs_dir)):
            if f.endswith('.diff'):
                content = load_text(os.path.join(diffs_dir, f))
                if content:
                    name = f.replace('.diff', '').replace('_', ' ')
                    diffs[name] = content

    # Collect logs
    logs = {}
    if logs_dir and os.path.isdir(logs_dir):
        for label in ['baseline', 'candidate']:
            label_dir = os.path.join(logs_dir, label)
            if os.path.isdir(label_dir):
                for f in sorted(os.listdir(label_dir)):
                    if f.endswith('.txt'):
                        content = load_text(os.path.join(label_dir, f))
                        if content and content != 'LOG_COLLECTION_FAILED':
                            name = f.replace('.txt', '').replace('_', ' ')
                            logs.setdefault(name, {})[label] = content

    # Summary stats
    b_total = baseline_tests.get('total', 0) if baseline_tests else 0
    b_passed = baseline_tests.get('passed', 0) if baseline_tests else 0
    b_failed = baseline_tests.get('failed', 0) if baseline_tests else 0
    b_warnings = baseline_tests.get('warnings', 0) if baseline_tests else 0
    c_total = candidate_tests.get('total', 0) if candidate_tests else 0
    c_passed = candidate_tests.get('passed', 0) if candidate_tests else 0
    c_failed = candidate_tests.get('failed', 0) if candidate_tests else 0
    c_warnings = candidate_tests.get('warnings', 0) if candidate_tests else 0

    total_failed = b_failed + c_failed
    total_warnings = b_warnings + c_warnings
    overall_status = "PASS" if total_failed == 0 else "FAIL"

    b_groups = group_by_category(baseline_tests)
    c_groups = group_by_category(candidate_tests)
    all_categories = list(OrderedDict.fromkeys(list(b_groups.keys()) + list(c_groups.keys())))

    # Separate failures/warnings from passes
    b_failures = [r for r in (baseline_tests or {}).get('results', []) if r['status'] in ('FAIL', 'WARN')]
    c_failures = [r for r in (candidate_tests or {}).get('results', []) if r['status'] in ('FAIL', 'WARN')]
    b_passes = [r for r in (baseline_tests or {}).get('results', []) if r['status'] == 'PASS']
    c_passes = [r for r in (candidate_tests or {}).get('results', []) if r['status'] == 'PASS']

    # Build all results for CSV export
    all_results_json = []
    for label, tests in [("Baseline", baseline_tests), ("Candidate", candidate_tests)]:
        if tests:
            for r in tests.get('results', []):
                all_results_json.append({
                    'vpx': label, 'category': r.get('category', ''),
                    'test': r['test'], 'status': r['status'],
                    'expected': r['expected'], 'actual': r['actual'],
                    'detail': r.get('detail', '')
                })

    # --- Build HTML ---
    html_parts = []
    html_parts.append(f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>VPX Regression Report &mdash; {now}</title>
<style>
:root {{
    --bg: #0f172a;
    --surface: #1e293b;
    --surface2: #334155;
    --text: #e2e8f0;
    --text-dim: #94a3b8;
    --border: #475569;
    --green: #22c55e;
    --red: #ef4444;
    --amber: #f59e0b;
    --blue: #3b82f6;
}}
* {{ margin:0; padding:0; box-sizing:border-box; }}
body {{
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.6; padding: 2rem;
}}
.container {{ max-width: 1400px; margin: 0 auto; }}
h1 {{ font-size: 1.75rem; margin-bottom: 0.5rem; }}
h2 {{ font-size: 1.35rem; margin: 2rem 0 1rem; border-bottom: 1px solid var(--border); padding-bottom: 0.5rem; }}
h3 {{ font-size: 1.1rem; margin: 1.5rem 0 0.75rem; color: var(--text-dim); }}
a {{ color: var(--blue); text-decoration: none; }} a:hover {{ text-decoration: underline; }}
.header {{
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 2rem; padding-bottom: 1rem; border-bottom: 2px solid var(--border);
}}
.header-info {{ color: var(--text-dim); font-size: 0.875rem; }}
.badge {{
    display: inline-block; padding: 2px 10px; border-radius: 9999px;
    font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em;
}}
.badge-pass {{ background: var(--green); color: #052e16; }}
.badge-fail {{ background: var(--red); color: #450a0a; }}
.badge-warn {{ background: var(--amber); color: #451a03; }}
.overall-badge {{ font-size: 1.25rem; padding: 6px 20px; color: white; }}
.toc {{ background: var(--surface); border-radius: 12px; padding: 1.5rem; margin-bottom: 2rem; border: 1px solid var(--border); }}
.toc ul {{ list-style: none; display: flex; flex-wrap: wrap; gap: 0.5rem 1.5rem; }}
.toc li {{ font-size: 0.875rem; }}
.summary-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1.5rem; margin-bottom: 2rem; }}
.summary-card {{
    background: var(--surface); border-radius: 12px; padding: 1.5rem; border: 1px solid var(--border);
}}
.summary-card h3 {{ margin: 0 0 1rem; color: var(--text); }}
.stat-row {{ display: flex; justify-content: space-between; padding: 0.4rem 0; border-bottom: 1px solid var(--surface2); }}
.stat-row:last-child {{ border: none; }}
.stat-label {{ color: var(--text-dim); }}
.stat-value {{ font-weight: 600; font-variant-numeric: tabular-nums; }}
.chart-row {{ display: flex; align-items: center; gap: 1.5rem; justify-content: center; }}
/* Tabs */
.tab-group {{ display: flex; gap: 0.5rem; margin-bottom: 1rem; }}
.tab {{
    padding: 0.5rem 1.25rem; background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px 8px 0 0; cursor: pointer; color: var(--text-dim); font-weight: 600; font-size: 0.875rem;
}}
.tab.active {{ background: var(--surface2); color: var(--text); border-bottom-color: var(--surface2); }}
.tab-panel {{ display: none; }}
.tab-panel.active {{ display: block; }}
/* Tables */
table {{ width: 100%; border-collapse: collapse; font-size: 0.85rem; margin-bottom: 1.5rem; }}
th {{
    text-align: left; padding: 0.5rem 0.6rem; background: var(--surface);
    color: var(--text-dim); font-weight: 600; font-size: 0.75rem;
    text-transform: uppercase; letter-spacing: 0.05em; border-bottom: 2px solid var(--border);
    position: sticky; top: 0;
}}
td {{ padding: 0.4rem 0.6rem; border-bottom: 1px solid var(--surface2); vertical-align: top; }}
td code {{ background: var(--surface2); padding: 1px 5px; border-radius: 3px; font-size: 0.8rem; }}
tr:hover td {{ background: var(--surface); }}
tr.hidden {{ display: none; }}
/* Category sections */
.category-header {{
    display: flex; justify-content: space-between; align-items: center;
    cursor: pointer; padding: 0.6rem 1rem; background: var(--surface);
    border-radius: 8px; margin-bottom: 0.25rem; border: 1px solid var(--border);
}}
.category-header:hover {{ background: var(--surface2); }}
.category-header .count {{ color: var(--text-dim); font-size: 0.85rem; }}
details summary {{ list-style: none; }}
details summary::-webkit-details-marker {{ display: none; }}
details[open] .category-header {{ border-radius: 8px 8px 0 0; margin-bottom: 0; }}
details[open] .category-body {{
    border: 1px solid var(--border); border-top: none;
    border-radius: 0 0 8px 8px; padding: 0.5rem; margin-bottom: 0.5rem;
}}
/* Search & filter */
.search-box {{
    width: 100%; padding: 0.6rem 1rem; background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; color: var(--text); font-size: 0.875rem; margin-bottom: 1rem; outline: none;
}}
.search-box:focus {{ border-color: var(--blue); }}
.filter-bar {{ display: flex; gap: 0.5rem; margin-bottom: 1rem; flex-wrap: wrap; }}
.filter-btn {{
    padding: 4px 12px; background: var(--surface); border: 1px solid var(--border);
    border-radius: 6px; color: var(--text-dim); cursor: pointer; font-size: 0.8rem;
}}
.filter-btn.active {{ background: var(--blue); color: white; border-color: var(--blue); }}
/* Diffs */
.diff-block {{
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 1rem; margin-bottom: 1rem; overflow-x: auto;
}}
.diff-block pre {{ font-family: 'SF Mono','Fira Code','Consolas',monospace; font-size: 0.8rem; line-height: 1.5; white-space: pre-wrap; }}
.diff-block .add {{ color: var(--green); }} .diff-block .del {{ color: var(--red); }} .diff-block .hdr {{ color: var(--blue); }}
/* Log block */
.log-block {{
    background: #0c0c0c; border: 1px solid var(--border);
    border-radius: 8px; padding: 1rem; overflow-x: auto; max-height: 500px; overflow-y: auto;
}}
.log-block pre {{ font-family: 'SF Mono','Fira Code','Consolas',monospace; font-size: 0.75rem; line-height: 1.4; white-space: pre-wrap; color: #d4d4d4; }}
/* Alert box for failures */
.alert-fail {{
    background: rgba(239, 68, 68, 0.1); border: 1px solid var(--red); border-radius: 8px;
    padding: 1rem; margin-bottom: 1rem;
}}
.alert-pass {{
    background: rgba(34, 197, 94, 0.1); border: 1px solid var(--green); border-radius: 8px;
    padding: 1rem; margin-bottom: 1rem;
}}
/* Export */
.export-btn {{
    display: inline-block; padding: 6px 16px; background: var(--surface); border: 1px solid var(--border);
    border-radius: 6px; color: var(--text); cursor: pointer; font-size: 0.8rem; text-decoration: none;
}}
.export-btn:hover {{ background: var(--surface2); }}
footer {{
    margin-top: 3rem; padding-top: 1rem; border-top: 1px solid var(--border);
    color: var(--text-dim); font-size: 0.8rem; text-align: center;
}}
/* Probe detail modal */
.modal-overlay {{
    display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.7);
    z-index: 1000; justify-content: center; align-items: center;
}}
.modal-overlay.active {{ display: flex; }}
.modal-content {{
    background: var(--bg); border: 1px solid var(--border); border-radius: 12px;
    max-width: 620px; width: 92%; max-height: 85vh; overflow-y: auto;
    padding: 1.5rem; position: relative; box-shadow: 0 20px 60px rgba(0,0,0,0.5);
}}
.modal-close {{
    position: absolute; top: 0.75rem; right: 1rem; background: none; border: none;
    color: var(--text-dim); font-size: 1.4rem; cursor: pointer; line-height: 1;
}}
.modal-close:hover {{ color: var(--text); }}
.modal-title {{
    font-size: 1.1rem; font-weight: 700; color: var(--text); margin-bottom: 1.2rem;
    padding-right: 2rem;
}}
.modal-title .scenario-badge {{
    display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem;
    font-weight: 600; margin-left: 0.5rem; vertical-align: middle;
}}
.modal-section {{
    margin-bottom: 1rem;
}}
.modal-section-label {{
    font-size: 0.7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em;
    color: var(--text-dim); margin-bottom: 0.4rem;
}}
.modal-kv {{
    display: flex; justify-content: space-between; padding: 0.25rem 0;
    border-bottom: 1px solid rgba(255,255,255,0.04); font-size: 0.85rem;
}}
.modal-kv .kv-label {{ color: var(--text-dim); }}
.modal-kv .kv-value {{ color: var(--text); font-family: monospace; text-align: right; max-width: 65%; word-break: break-all; }}
.modal-timing-bar {{
    height: 18px; border-radius: 4px; margin-top: 0.5rem; display: flex; overflow: hidden;
}}
.modal-timing-bar span {{
    display: block; height: 100%; min-width: 2px;
}}
.modal-headers-list {{
    font-family: monospace; font-size: 0.78rem; color: var(--text-dim); line-height: 1.6;
    max-height: 200px; overflow-y: auto; padding: 0.5rem; background: var(--surface);
    border-radius: 6px; border: 1px solid var(--border);
}}
</style>
</head>
<body>
<div class="modal-overlay" id="probeModal" onclick="if(event.target===this)closeProbeDetail()">
  <div class="modal-content">
    <button class="modal-close" onclick="closeProbeDetail()">&times;</button>
    <div id="probeModalBody"></div>
  </div>
</div>
<div class="container">

<div class="header">
    <div>
        <h1>VPX Firmware Regression Report</h1>
        <div class="header-info">Generated {now} &bull; {b_total + c_total} total assertions</div>
    </div>
    <div>
        <span class="badge overall-badge" style="background:{'var(--green)' if overall_status == 'PASS' else 'var(--red)'}">
            {overall_status}
        </span>
    </div>
</div>

<div class="toc">
    <strong>Contents:</strong>
    <ul>
        <li><a href="#summary">Executive Summary</a></li>
        <li><a href="#charts">Category Breakdown</a></li>
        <li><a href="#failures">Failures &amp; Warnings</a></li>
        <li><a href="#probing">HTTP Probing</a></li>
        <li><a href="#loadprofile">Load Profile (50 Requests)</a></li>
        <li><a href="#diffs">CLI Differences</a></li>
        <li><a href="#resources">Resource Usage</a></li>
        <li><a href="#passed">Passed Tests</a></li>
        <li><a href="#logs">System Logs</a></li>
    </ul>
</div>
""")

    # --- Executive Summary ---
    html_parts.append(f"""
<h2 id="summary">Executive Summary</h2>
<div class="summary-grid">
    <div class="summary-card">
        <h3>Baseline ({esc(baseline_tests.get('nsip', 'N/A') if baseline_tests else 'N/A')})</h3>
        <div class="chart-row">
            {svg_pie(b_passed, b_failed, b_warnings)}
            <div>
                <div class="stat-row"><span class="stat-label">Total</span><span class="stat-value">{b_total}</span></div>
                <div class="stat-row"><span class="stat-label">Passed</span><span class="stat-value" style="color:var(--green)">{b_passed}</span></div>
                <div class="stat-row"><span class="stat-label">Failed</span><span class="stat-value" style="color:{'var(--red)' if b_failed > 0 else 'var(--text)'}">{b_failed}</span></div>
                <div class="stat-row"><span class="stat-label">Warnings</span><span class="stat-value" style="color:{'var(--amber)' if b_warnings > 0 else 'var(--text)'}">{b_warnings}</span></div>
            </div>
        </div>
    </div>
    <div class="summary-card">
        <h3>Candidate ({esc(candidate_tests.get('nsip', 'N/A') if candidate_tests else 'N/A')})</h3>
        <div class="chart-row">
            {svg_pie(c_passed, c_failed, c_warnings)}
            <div>
                <div class="stat-row"><span class="stat-label">Total</span><span class="stat-value">{c_total}</span></div>
                <div class="stat-row"><span class="stat-label">Passed</span><span class="stat-value" style="color:var(--green)">{c_passed}</span></div>
                <div class="stat-row"><span class="stat-label">Failed</span><span class="stat-value" style="color:{'var(--red)' if c_failed > 0 else 'var(--text)'}">{c_failed}</span></div>
                <div class="stat-row"><span class="stat-label">Warnings</span><span class="stat-value" style="color:{'var(--amber)' if c_warnings > 0 else 'var(--text)'}">{c_warnings}</span></div>
            </div>
        </div>
    </div>
    <div class="summary-card">
        <h3>Regression Comparison</h3>
        <div class="stat-row"><span class="stat-label">CLI Diffs</span>
            <span class="stat-value" style="color:{'var(--red)' if len(diffs) > 0 else 'var(--green)'}">{len(diffs)}</span></div>
        <div class="stat-row"><span class="stat-label">Config Parity</span>
            <span class="stat-value">{'YES' if len(diffs) == 0 else 'NO'}</span></div>
        <div class="stat-row"><span class="stat-label">Categories</span>
            <span class="stat-value">{len(all_categories)}</span></div>
        <div class="stat-row"><span class="stat-label">Logs Collected</span>
            <span class="stat-value">{len(logs)}</span></div>
        <div class="stat-row"><span class="stat-label">Metrics Samples</span>
            <span class="stat-value">{len(metrics)}</span></div>
        <div style="margin-top:1rem;">
            <button class="export-btn" onclick="exportCSV()">Export CSV</button>
        </div>
    </div>
</div>
""")

    # --- Category Breakdown ---
    html_parts.append('<h2 id="charts">Category Breakdown</h2>\n')
    html_parts.append('<div class="tab-group" data-group="charts">')
    html_parts.append('    <div class="tab active" onclick="switchTab(\'charts\', \'chart-baseline\')">Baseline</div>')
    html_parts.append('    <div class="tab" onclick="switchTab(\'charts\', \'chart-candidate\')">Candidate</div>')
    html_parts.append('</div>')
    html_parts.append(f'<div id="chart-baseline" class="tab-panel active" data-group="charts">{category_bar_chart(b_groups)}</div>')
    html_parts.append(f'<div id="chart-candidate" class="tab-panel" data-group="charts">{category_bar_chart(c_groups)}</div>')

    # --- Failures & Warnings Section ---
    html_parts.append('<h2 id="failures">Failures &amp; Warnings</h2>\n')

    if total_failed == 0 and total_warnings == 0:
        html_parts.append('<div class="alert-pass"><strong>All tests passed.</strong> No failures or warnings detected on either VPX.</div>\n')
    else:
        html_parts.append(f'<div class="alert-fail"><strong>{total_failed} failure(s)</strong> and <strong>{total_warnings} warning(s)</strong> detected across both VPXs.</div>\n')

        html_parts.append('<div class="tab-group" data-group="failures">')
        if b_failures:
            html_parts.append(f'    <div class="tab active" onclick="switchTab(\'failures\', \'fail-baseline\')">Baseline ({len(b_failures)})</div>')
        if c_failures:
            active = ' active' if not b_failures else ''
            html_parts.append(f'    <div class="tab{active}" onclick="switchTab(\'failures\', \'fail-candidate\')">Candidate ({len(c_failures)})</div>')
        html_parts.append('</div>')

        if b_failures:
            html_parts.append(f'<div id="fail-baseline" class="tab-panel active" data-group="failures">\n')
            html_parts.append(render_test_table(b_failures, "Baseline"))
            html_parts.append('</div>\n')
        if c_failures:
            active = ' active' if not b_failures else ''
            html_parts.append(f'<div id="fail-candidate" class="tab-panel{active}" data-group="failures">\n')
            html_parts.append(render_test_table(c_failures, "Candidate"))
            html_parts.append('</div>\n')

    # --- Load probe timing CSVs ---
    b_probe_csv = baseline_json_path.replace('.json', '-probe-timings.csv') if baseline_json_path else ''
    c_probe_csv = candidate_json_path.replace('.json', '-probe-timings.csv') if candidate_json_path else ''
    # Also check output dir for sample data naming convention
    if not os.path.exists(b_probe_csv):
        b_probe_csv = os.path.join(os.path.dirname(output_path), 'baseline-probe-timings.csv')
    if not os.path.exists(c_probe_csv):
        c_probe_csv = os.path.join(os.path.dirname(output_path), 'candidate-probe-timings.csv')
    b_probes = load_probe_timings(b_probe_csv) if os.path.exists(b_probe_csv) else []
    c_probes = load_probe_timings(c_probe_csv) if os.path.exists(c_probe_csv) else []

    # --- HTTP Probing Section ---
    b_timing, b_ssl, b_headers = extract_probe_data(baseline_tests)
    c_timing, c_ssl, c_headers = extract_probe_data(candidate_tests)

    if b_timing or c_timing or b_ssl or c_ssl:
        html_parts.append('<h2 id="probing">HTTP Probing</h2>\n')
        html_parts.append('<p style="color:var(--text-dim);margin-bottom:1rem;">Live HTTP request timing and SSL comparison between baseline and candidate firmware.</p>\n')

        # Timing comparison cards
        if b_timing or c_timing:
            html_parts.append('<h3>Response Timing</h3>\n')
            html_parts.append('<div class="summary-grid">')
            timing_metrics = [
                ('tcp_connect_time', 'TCP Connect'),
                ('tls_handshake_time', 'TLS Handshake'),
                ('time_to_first_byte', 'TTFB'),
                ('total_response_time', 'Total Time'),
            ]
            for key, label in timing_metrics:
                b_val = b_timing.get(key)
                c_val = c_timing.get(key)
                if b_val is not None and c_val is not None:
                    diff = c_val - b_val
                    diff_pct = (diff / b_val * 100) if b_val > 0 else 0
                    if diff > 0:
                        diff_color = 'var(--red)'
                        diff_label = f'+{diff}ms ({diff_pct:+.0f}%)'
                    elif diff < 0:
                        diff_color = 'var(--green)'
                        diff_label = f'{diff}ms ({diff_pct:+.0f}%)'
                    else:
                        diff_color = 'var(--text)'
                        diff_label = 'identical'
                else:
                    diff_color = 'var(--text-dim)'
                    diff_label = 'N/A'
                html_parts.append(f'''    <div class="summary-card">
        <h3>{esc(label)}</h3>
        <div class="stat-row"><span class="stat-label">Baseline</span><span class="stat-value">{b_val if b_val is not None else "N/A"}{"ms" if b_val is not None else ""}</span></div>
        <div class="stat-row"><span class="stat-label">Candidate</span><span class="stat-value">{c_val if c_val is not None else "N/A"}{"ms" if c_val is not None else ""}</span></div>
        <div class="stat-row"><span class="stat-label">Difference</span><span class="stat-value" style="color:{diff_color}">{diff_label}</span></div>
    </div>''')
            html_parts.append('</div>\n')

        # SSL connection details
        if b_ssl or c_ssl:
            html_parts.append('<h3>SSL Connection Details</h3>\n')
            html_parts.append('<div class="summary-grid">')
            for label_name, ssl_data in [("Baseline", b_ssl), ("Candidate", c_ssl)]:
                if ssl_data:
                    html_parts.append(f'''    <div class="summary-card">
        <h3>{label_name}</h3>
        <div class="stat-row"><span class="stat-label">Protocol</span><span class="stat-value">{esc(ssl_data.get("negotiated_protocol", "N/A"))}</span></div>
        <div class="stat-row"><span class="stat-label">Cipher</span><span class="stat-value" style="font-size:0.75rem">{esc(ssl_data.get("negotiated_cipher", "N/A"))}</span></div>
        <div class="stat-row"><span class="stat-label">Subject</span><span class="stat-value" style="font-size:0.75rem">{esc(ssl_data.get("cert_subject", "N/A"))}</span></div>
        <div class="stat-row"><span class="stat-label">Issuer</span><span class="stat-value" style="font-size:0.75rem">{esc(ssl_data.get("cert_issuer", "N/A"))}</span></div>
        <div class="stat-row"><span class="stat-label">Expires</span><span class="stat-value">{esc(ssl_data.get("cert_not_after", "N/A"))}</span></div>
        <div class="stat-row"><span class="stat-label">Key Size</span><span class="stat-value">{esc(ssl_data.get("cert_key_size", "N/A"))}</span></div>
        <div class="stat-row"><span class="stat-label">Signature</span><span class="stat-value" style="font-size:0.75rem">{esc(ssl_data.get("cert_signature_alg", "N/A"))}</span></div>
        <div class="stat-row"><span class="stat-label">Chain</span><span class="stat-value">{esc(ssl_data.get("cert_chain_depth", "N/A"))}</span></div>
    </div>''')
            html_parts.append('</div>\n')

        # Security headers checklist
        all_hdrs = set(list(b_headers.keys()) + list(c_headers.keys()))
        response_hdrs = sorted([h for h in all_hdrs if h.startswith('response_header:')])
        removed_hdrs = sorted([h for h in all_hdrs if h.startswith('removed_header:')])

        if response_hdrs or removed_hdrs:
            html_parts.append('<h3>Security Headers</h3>\n')
            html_parts.append('<table>\n<thead><tr><th>Header</th><th>Baseline</th><th>Candidate</th></tr></thead>\n<tbody>')
            for hdr in response_hdrs + removed_hdrs:
                hdr_name = hdr.split(':', 1)[1] if ':' in hdr else hdr
                b_info = b_headers.get(hdr, {})
                c_info = c_headers.get(hdr, {})
                b_badge = 'badge-pass' if b_info.get('status') == 'PASS' else ('badge-fail' if b_info.get('status') == 'FAIL' else 'badge-warn')
                c_badge = 'badge-pass' if c_info.get('status') == 'PASS' else ('badge-fail' if c_info.get('status') == 'FAIL' else 'badge-warn')
                b_val = b_info.get('actual', 'N/A')
                c_val = c_info.get('actual', 'N/A')
                html_parts.append(f'<tr><td><code>{esc(hdr_name)}</code></td>')
                if b_info:
                    html_parts.append(f'<td><span class="badge {b_badge}">{b_info.get("status","")}</span> <code style="font-size:0.7rem">{esc(b_val)}</code></td>')
                else:
                    html_parts.append('<td style="color:var(--text-dim)">N/A</td>')
                if c_info:
                    html_parts.append(f'<td><span class="badge {c_badge}">{c_info.get("status","")}</span> <code style="font-size:0.7rem">{esc(c_val)}</code></td>')
                else:
                    html_parts.append('<td style="color:var(--text-dim)">N/A</td>')
                html_parts.append('</tr>\n')
            html_parts.append('</tbody></table>\n')

    # --- HTTP Load Profile Charts (Side-by-Side Comparison) ---
    if b_probes or c_probes:
        html_parts.append('<h2 id="loadprofile">HTTP Load Profile (50 Requests)</h2>\n')
        html_parts.append('<p style="color:var(--text-dim);margin-bottom:1rem;">50 HTTP requests per VPX — side-by-side comparison of baseline (cyan) vs candidate (violet). Red bars = blocked by bot responder (expected). Grouped by scenario type. <strong style="color:var(--text)">Click any bar</strong> for full request details including timing breakdown and response headers.</p>\n')

        # Side-by-side chart
        html_parts.append(render_side_by_side_chart(b_probes, c_probes))

        # Embed probe data as JSON for modal click-through
        probe_data = {}
        for prefix, probes in [('b', b_probes), ('c', c_probes)]:
            for row in (probes or []):
                key = f"{prefix}-{row.get('request_num', 0)}"
                probe_data[key] = {
                    'instance': 'Baseline' if prefix == 'b' else 'Candidate',
                    'request_num': row.get('request_num', 0),
                    'scenario': row.get('scenario', ''),
                    'host': row.get('host', ''),
                    'method': row.get('method', ''),
                    'user_agent': row.get('user_agent', ''),
                    'http_status': row.get('http_status', 0),
                    'blocked': row.get('blocked', 'false') == 'true',
                    'time_connect_ms': row.get('time_connect_ms', 0),
                    'time_tls_ms': row.get('time_tls_ms', 0),
                    'time_ttfb_ms': row.get('time_ttfb_ms', 0),
                    'time_total_ms': row.get('time_total_ms', 0),
                    'response_headers': row.get('response_headers', []),
                }
        html_parts.append(f'<script>const PROBE_DATA = {json.dumps(probe_data)};</script>\n')

        # Comparison stats table
        b_ttfbs = [r['time_ttfb_ms'] for r in b_probes] if b_probes else []
        c_ttfbs = [r['time_ttfb_ms'] for r in c_probes] if c_probes else []
        b_blocked = sum(1 for r in (b_probes or []) if r.get('blocked') == 'true')
        c_blocked = sum(1 for r in (c_probes or []) if r.get('blocked') == 'true')
        b_totals = [r['time_total_ms'] for r in b_probes] if b_probes else []
        c_totals = [r['time_total_ms'] for r in c_probes] if c_probes else []

        b_avg = sum(b_ttfbs) / len(b_ttfbs) if b_ttfbs else 0
        c_avg = sum(c_ttfbs) / len(c_ttfbs) if c_ttfbs else 0
        b_p95 = sorted(b_ttfbs)[int(len(b_ttfbs) * 0.95)] if b_ttfbs else 0
        c_p95 = sorted(c_ttfbs)[int(len(c_ttfbs) * 0.95)] if c_ttfbs else 0

        diff = c_avg - b_avg
        diff_pct = (diff / b_avg * 100) if b_avg > 0 else 0
        if diff > 0.5:
            diff_str = f'+{fmt_ms(diff)}ms ({diff_pct:+.0f}%)'
            diff_color = 'var(--red)'
        elif diff < -0.5:
            diff_str = f'{fmt_ms(diff)}ms ({diff_pct:+.0f}%)'
            diff_color = 'var(--green)'
        else:
            diff_str = f'{fmt_ms(abs(diff))}ms (identical)'
            diff_color = 'var(--text)'

        html_parts.append(f'''
<div class="summary-grid" style="margin-top:1.5rem;">
    <div class="summary-card"><h3 style="color:#67e8f9">Baseline</h3>
        <div class="stat-row"><span class="stat-label">Requests</span><span class="stat-value">{len(b_probes or [])}</span></div>
        <div class="stat-row"><span class="stat-label">Blocked (expected)</span><span class="stat-value" style="color:{'var(--green)' if b_blocked == 10 else 'var(--red)'}">{b_blocked}/10</span></div>
        <div class="stat-row"><span class="stat-label">Avg TTFB</span><span class="stat-value">{fmt_ms(b_avg)}ms</span></div>
        <div class="stat-row"><span class="stat-label">P95 TTFB</span><span class="stat-value">{fmt_ms(b_p95)}ms</span></div>
        <div class="stat-row"><span class="stat-label">Max TTFB</span><span class="stat-value">{fmt_ms(max(b_ttfbs) if b_ttfbs else 0)}ms</span></div>
        <div class="stat-row"><span class="stat-label">Min TTFB</span><span class="stat-value">{fmt_ms(min(b_ttfbs) if b_ttfbs else 0)}ms</span></div>
    </div>
    <div class="summary-card"><h3 style="color:#a78bfa">Candidate</h3>
        <div class="stat-row"><span class="stat-label">Requests</span><span class="stat-value">{len(c_probes or [])}</span></div>
        <div class="stat-row"><span class="stat-label">Blocked (expected)</span><span class="stat-value" style="color:{'var(--green)' if c_blocked == 10 else 'var(--red)'}">{c_blocked}/10</span></div>
        <div class="stat-row"><span class="stat-label">Avg TTFB</span><span class="stat-value">{fmt_ms(c_avg)}ms</span></div>
        <div class="stat-row"><span class="stat-label">P95 TTFB</span><span class="stat-value">{fmt_ms(c_p95)}ms</span></div>
        <div class="stat-row"><span class="stat-label">Max TTFB</span><span class="stat-value">{fmt_ms(max(c_ttfbs) if c_ttfbs else 0)}ms</span></div>
        <div class="stat-row"><span class="stat-label">Min TTFB</span><span class="stat-value">{fmt_ms(min(c_ttfbs) if c_ttfbs else 0)}ms</span></div>
    </div>
    <div class="summary-card"><h3>Comparison</h3>
        <div class="stat-row"><span class="stat-label">TTFB Diff</span><span class="stat-value" style="color:{diff_color}">{diff_str}</span></div>
        <div class="stat-row"><span class="stat-label">Blocked Match</span><span class="stat-value" style="color:{'var(--green)' if b_blocked == c_blocked == 10 else 'var(--red)'}">{"PASS (10/10)" if b_blocked == c_blocked == 10 else f"{'YES' if b_blocked == c_blocked else 'NO'} ({b_blocked} vs {c_blocked})"}</span></div>
        <div class="stat-row"><span class="stat-label">P95 Diff</span><span class="stat-value">{fmt_ms(abs(c_p95 - b_p95))}ms</span></div>
        <div class="stat-row"><span class="stat-label">Max Diff</span><span class="stat-value">{fmt_ms(abs((max(c_ttfbs) if c_ttfbs else 0) - (max(b_ttfbs) if b_ttfbs else 0)))}ms</span></div>
    </div>
</div>''')

    # --- CLI Differences Section ---
    html_parts.append('<h2 id="diffs">CLI Differences</h2>\n')
    if diffs:
        html_parts.append(f'<p style="color:var(--text-dim);margin-bottom:1rem;">{len(diffs)} configuration difference(s) between baseline and candidate firmware.</p>\n')
        for name, content in diffs.items():
            html_parts.append(f'<details open><summary><div class="category-header"><span>{esc(name)}</span><span class="count">differs</span></div></summary>\n')
            html_parts.append(f'<div class="category-body"><div class="diff-block"><pre>{render_diff_block(content)}</pre></div></div></details>\n')
    else:
        html_parts.append('<div class="alert-pass">No CLI differences detected. Configurations match between firmware versions.</div>\n')

    # --- Resource Usage Section ---
    html_parts.append('<h2 id="resources">Resource Usage</h2>\n')
    if metrics and len(metrics) >= 2:
        html_parts.append(f'<p style="color:var(--text-dim);margin-bottom:1rem;">Host resource usage during pipeline execution ({len(metrics)} samples at 10-second intervals).</p>\n')

        html_parts.append('<h3>CPU Usage</h3>\n')
        html_parts.append(svg_line_chart(metrics, ['cpu_pct'], ['#3b82f6'], ['CPU %'], 'CPU %'))

        html_parts.append('<h3>Memory Usage</h3>\n')
        html_parts.append(svg_line_chart(metrics, ['mem_pct'], ['#a855f7'], ['Memory %'], 'Memory %'))

        html_parts.append('<h3>Network Throughput</h3>\n')
        html_parts.append(svg_line_chart(
            metrics, ['net_rx_mbps', 'net_tx_mbps'],
            ['#22c55e', '#ef4444'], ['RX MB/s', 'TX MB/s'], 'MB/s'
        ))

        html_parts.append('<h3>Disk Usage</h3>\n')
        html_parts.append(svg_line_chart(metrics, ['disk_pct'], ['#f59e0b'], ['Disk %'], 'Disk %'))

        # Summary stats
        cpu_vals = [float(r.get('cpu_pct', 0)) for r in metrics]
        mem_vals = [float(r.get('mem_pct', 0)) for r in metrics]
        html_parts.append(f'''
<div class="summary-grid" style="margin-top:1.5rem;">
    <div class="summary-card">
        <h3>CPU</h3>
        <div class="stat-row"><span class="stat-label">Peak</span><span class="stat-value">{max(cpu_vals):.1f}%</span></div>
        <div class="stat-row"><span class="stat-label">Average</span><span class="stat-value">{sum(cpu_vals)/len(cpu_vals):.1f}%</span></div>
    </div>
    <div class="summary-card">
        <h3>Memory</h3>
        <div class="stat-row"><span class="stat-label">Peak</span><span class="stat-value">{max(mem_vals):.1f}%</span></div>
        <div class="stat-row"><span class="stat-label">Average</span><span class="stat-value">{sum(mem_vals)/len(mem_vals):.1f}%</span></div>
    </div>
</div>
''')
    else:
        html_parts.append('<p style="color:var(--text-dim)">No resource metrics collected.</p>\n')

    # --- Passed Tests Section ---
    html_parts.append('<h2 id="passed">Passed Tests</h2>\n')
    html_parts.append('''
<input type="text" class="search-box" id="searchBox" placeholder="Search passed tests..." oninput="filterTests()">
''')
    html_parts.append('<div class="tab-group" data-group="passed">')
    html_parts.append(f'    <div class="tab active" onclick="switchTab(\'passed\', \'pass-baseline\')">Baseline ({len(b_passes)})</div>')
    html_parts.append(f'    <div class="tab" onclick="switchTab(\'passed\', \'pass-candidate\')">Candidate ({len(c_passes)})</div>')
    html_parts.append('</div>')

    for label, passes, panel_id in [
        ("Baseline", b_passes, "pass-baseline"),
        ("Candidate", c_passes, "pass-candidate"),
    ]:
        active = ' active' if label == 'Baseline' else ''
        html_parts.append(f'<div id="{panel_id}" class="tab-panel{active}" data-group="passed">\n')
        groups = OrderedDict()
        for r in passes:
            groups.setdefault(r.get('category', 'Other'), []).append(r)
        for cat, results in groups.items():
            html_parts.append(f'''<details>
<summary><div class="category-header">
    <span>{esc(cat)}</span>
    <span class="count">{len(results)} passed</span>
</div></summary>
<div class="category-body">
{render_test_table(results, label)}
</div></details>
''')
        html_parts.append('</div>\n')

    # --- System Logs Section ---
    html_parts.append('<h2 id="logs">System Logs</h2>\n')
    if logs:
        for log_name, log_data in logs.items():
            html_parts.append(f'<details><summary><div class="category-header"><span>{esc(log_name)}</span><span class="count">{len(log_data)} VPX(s)</span></div></summary>\n')
            html_parts.append('<div class="category-body">')
            html_parts.append(f'<div class="tab-group" data-group="log-{esc(log_name)}">')
            first = True
            for vpx_label in ['baseline', 'candidate']:
                if vpx_label in log_data:
                    active = ' active' if first else ''
                    html_parts.append(f'<div class="tab{active}" onclick="switchTab(\'log-{esc(log_name)}\', \'log-{esc(log_name)}-{vpx_label}\')">{vpx_label.title()}</div>')
                    first = False
            html_parts.append('</div>')
            first = True
            for vpx_label in ['baseline', 'candidate']:
                if vpx_label in log_data:
                    active = ' active' if first else ''
                    content = log_data[vpx_label]
                    # Truncate very long logs
                    lines = content.split('\n')
                    if len(lines) > 300:
                        content = '\n'.join(lines[-300:])
                        content = f"... (truncated, showing last 300 lines)\n{content}"
                    html_parts.append(f'<div id="log-{esc(log_name)}-{vpx_label}" class="tab-panel{active}" data-group="log-{esc(log_name)}">')
                    html_parts.append(f'<div class="log-block"><pre>{esc(content)}</pre></div>')
                    html_parts.append('</div>')
                    first = False
            html_parts.append('</div></details>\n')
    else:
        html_parts.append('<p style="color:var(--text-dim)">No system logs collected.</p>\n')

    # --- Footer & JavaScript ---
    results_json_str = json.dumps(all_results_json)

    html_parts.append(f"""
<footer>
    VPX Firmware Regression Test &mdash; {now} &bull; {len(all_results_json)} assertions total
</footer>

</div>

<script>
const ALL_RESULTS = {results_json_str};

function switchTab(groupName, panelId) {{
    // Deactivate all tabs and panels in this group
    document.querySelectorAll('.tab-group[data-group="' + groupName + '"] .tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.tab-panel[data-group="' + groupName + '"]').forEach(p => p.classList.remove('active'));
    // Activate the clicked tab and target panel
    const panel = document.getElementById(panelId);
    if (panel) panel.classList.add('active');
    // Find and activate the tab that was clicked
    event.target.classList.add('active');
}}

function filterTests() {{
    const query = document.getElementById('searchBox').value.toLowerCase();
    document.querySelectorAll('#pass-baseline tr[data-search], #pass-candidate tr[data-search]').forEach(row => {{
        const searchText = (row.dataset.search || '').toLowerCase();
        row.classList.toggle('hidden', query && !searchText.includes(query));
    }});
}}

function exportCSV() {{
    const header = 'VPX,Category,Test,Status,Expected,Actual,Detail\\n';
    const rows = ALL_RESULTS.map(r =>
        [r.vpx, r.category, r.test, r.status, r.expected, r.actual, r.detail]
            .map(v => '"' + String(v).replace(/"/g, '""') + '"').join(',')
    ).join('\\n');
    const blob = new Blob([header + rows], {{ type: 'text/csv' }});
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'vpx-regression-results.csv';
    a.click();
}}

// --- Probe detail modal ---
const SCENARIO_COLORS = {{
    normal:'#22c55e', api:'#3b82f6', static:'#a855f7', redirect:'#f59e0b',
    bot:'#ef4444', cors:'#06b6d4', method:'#f97316', burst:'#10b981'
}};

function showProbeDetail(key) {{
    if (typeof PROBE_DATA === 'undefined') return;
    const d = PROBE_DATA[key];
    if (!d) return;
    const sc = d.scenario || 'normal';
    const scColor = SCENARIO_COLORS[sc] || '#94a3b8';
    const statusColor = d.blocked ? '#ef4444' : (d.http_status >= 200 && d.http_status < 400 ? '#22c55e' : '#f59e0b');
    const statusLabel = d.http_status + (d.blocked ? ' BLOCKED' : '');

    // Timing bar segments
    const total = d.time_total_ms || 1;
    const connPct = (d.time_connect_ms / total * 100).toFixed(1);
    const tlsPct = (d.time_tls_ms / total * 100).toFixed(1);
    const serverPct = (Math.max(0, d.time_ttfb_ms - d.time_connect_ms - d.time_tls_ms) / total * 100).toFixed(1);
    const transferPct = (Math.max(0, d.time_total_ms - d.time_ttfb_ms) / total * 100).toFixed(1);

    // Response headers
    const hdrs = (d.response_headers || []);
    const hdrsHtml = hdrs.length > 0
        ? '<div class="modal-headers-list">' + hdrs.map(h => h.replace(/</g,'&lt;').replace(/>/g,'&gt;')).join('<br>') + '</div>'
        : '<div style="color:var(--text-dim);font-size:0.85rem;">No headers captured</div>';

    const html = `
        <div class="modal-title">
            Request #${{d.request_num}} &mdash; ${{d.instance}}
            <span class="scenario-badge" style="background:${{scColor}}22;color:${{scColor}};border:1px solid ${{scColor}}44">${{sc.toUpperCase()}}</span>
        </div>
        <div class="modal-section">
            <div class="modal-section-label">Metadata</div>
            <div class="modal-kv"><span class="kv-label">Instance</span><span class="kv-value">${{d.instance}}</span></div>
            <div class="modal-kv"><span class="kv-label">Host</span><span class="kv-value">${{d.host}}</span></div>
            <div class="modal-kv"><span class="kv-label">Method</span><span class="kv-value">${{d.method}}</span></div>
            <div class="modal-kv"><span class="kv-label">User-Agent</span><span class="kv-value" style="font-size:0.75rem">${{d.user_agent}}</span></div>
            <div class="modal-kv"><span class="kv-label">Status</span><span class="kv-value" style="color:${{statusColor}};font-weight:700">${{statusLabel}}</span></div>
        </div>
        <div class="modal-section">
            <div class="modal-section-label">Timing</div>
            <div class="modal-kv"><span class="kv-label">Connect</span><span class="kv-value">${{d.time_connect_ms}}ms</span></div>
            <div class="modal-kv"><span class="kv-label">TLS</span><span class="kv-value">${{d.time_tls_ms}}ms</span></div>
            <div class="modal-kv"><span class="kv-label">TTFB</span><span class="kv-value">${{d.time_ttfb_ms}}ms</span></div>
            <div class="modal-kv"><span class="kv-label">Total</span><span class="kv-value">${{d.time_total_ms}}ms</span></div>
            <div class="modal-timing-bar">
                <span style="width:${{connPct}}%;background:#3b82f6" title="Connect ${{d.time_connect_ms}}ms"></span>
                <span style="width:${{tlsPct}}%;background:#a855f7" title="TLS ${{d.time_tls_ms}}ms"></span>
                <span style="width:${{serverPct}}%;background:#22c55e" title="Server processing"></span>
                <span style="width:${{transferPct}}%;background:#f59e0b" title="Transfer"></span>
            </div>
            <div style="display:flex;gap:1rem;margin-top:0.3rem;font-size:0.7rem;color:var(--text-dim)">
                <span><span style="color:#3b82f6">&FilledSmallSquare;</span> Connect</span>
                <span><span style="color:#a855f7">&FilledSmallSquare;</span> TLS</span>
                <span><span style="color:#22c55e">&FilledSmallSquare;</span> Server</span>
                <span><span style="color:#f59e0b">&FilledSmallSquare;</span> Transfer</span>
            </div>
        </div>
        <div class="modal-section">
            <div class="modal-section-label">Response Headers</div>
            ${{hdrsHtml}}
        </div>
    `;
    document.getElementById('probeModalBody').innerHTML = html;
    document.getElementById('probeModal').classList.add('active');
}}

function closeProbeDetail() {{
    document.getElementById('probeModal').classList.remove('active');
}}

document.addEventListener('keydown', function(e) {{
    if (e.key === 'Escape') closeProbeDetail();
}});
</script>
</body>
</html>""")

    output = ''.join(html_parts)
    with open(output_path, 'w') as f:
        f.write(output)
    print(f"HTML report written to {output_path}")

if __name__ == '__main__':
    if len(sys.argv) < 4:
        print("Usage: generate-html-report.py BASELINE_JSON CANDIDATE_JSON OUTPUT_DIR [REGRESSION_DIR] [LOGS_DIR] [METRICS_CSV]", file=sys.stderr)
        sys.exit(1)

    baseline_json = sys.argv[1]
    candidate_json = sys.argv[2]
    output_dir = sys.argv[3]
    regression_dir = sys.argv[4] if len(sys.argv) > 4 else output_dir
    logs_dir = sys.argv[5] if len(sys.argv) > 5 else None
    metrics_csv = sys.argv[6] if len(sys.argv) > 6 else None

    baseline_data = load_json(baseline_json)
    candidate_data = load_json(candidate_json)

    os.makedirs(output_dir, exist_ok=True)
    output_path = os.path.join(output_dir, 'regression-report.html')

    generate_html(baseline_data, candidate_data, regression_dir, output_path, logs_dir, metrics_csv, baseline_json, candidate_json)
