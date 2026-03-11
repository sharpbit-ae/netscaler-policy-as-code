#!/usr/bin/env python3
"""Disaster Recovery Report — compares baseline vs recovery test results,
calculates RTO timing metrics, evaluates timing thresholds, and analyzes
data plane saturation probes.

Usage:
    python3 dr-report.py --baseline baseline.log --recovery recovery.log \
        --timestamps /tmp/dr-test [--saturation saturation.csv] \
        [--rto-threshold 600] [--output dr-report.json]
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone


def parse_test_output(filepath):
    """Parse test script output into structured results."""
    results = {"passed": 0, "failed": 0, "warnings": 0, "gates": 0, "tests": []}
    if not os.path.exists(filepath):
        return results

    with open(filepath) as f:
        for line in f:
            line = line.rstrip()
            # Match PASS/FAIL/WARN lines
            m = re.match(r"\s+(PASS|FAIL|WARN)\s+(.*)", line)
            if m:
                status = m.group(1)
                detail = m.group(2).strip()
                results["tests"].append({"status": status, "detail": detail})
                if status == "PASS":
                    results["passed"] += 1
                elif status == "FAIL":
                    results["failed"] += 1
                elif status == "WARN":
                    results["warnings"] += 1
            # Match GATE lines
            if "QUALITY GATE BREACH" in line:
                results["gates"] += 1

    # Also parse summary if present
    for line_text in open(filepath):
        m = re.match(r"\s+Total:\s+(\d+)", line_text)
        if m:
            results["total_from_summary"] = int(m.group(1))
        m = re.match(r"\s+Quality Gates:\s+(\d+)", line_text)
        if m:
            results["gates"] = int(m.group(1))

    return results


def read_timestamp(dirpath, filename):
    """Read a Unix timestamp from a file."""
    filepath = os.path.join(dirpath, filename)
    if os.path.exists(filepath):
        with open(filepath) as f:
            return int(f.read().strip())
    return None


def format_duration(seconds):
    """Format seconds as Xm Ys."""
    if seconds is None:
        return "N/A"
    m = seconds // 60
    s = seconds % 60
    if m > 0:
        return f"{m}m {s:02d}s"
    return f"{s}s"


def compare_tests(baseline, recovery):
    """Compare individual test results between baseline and recovery."""
    diffs = []
    max_len = max(len(baseline["tests"]), len(recovery["tests"]))
    for i in range(max_len):
        b = baseline["tests"][i] if i < len(baseline["tests"]) else None
        r = recovery["tests"][i] if i < len(recovery["tests"]) else None
        if b and r:
            if b["status"] != r["status"]:
                diffs.append({
                    "index": i + 1,
                    "test": b["detail"],
                    "baseline": b["status"],
                    "recovery": r["status"],
                })
        elif b and not r:
            diffs.append({
                "index": i + 1,
                "test": b["detail"],
                "baseline": b["status"],
                "recovery": "MISSING",
            })
        elif r and not b:
            diffs.append({
                "index": i + 1,
                "test": r["detail"],
                "baseline": "MISSING",
                "recovery": r["status"],
            })
    return diffs


def parse_saturation(filepath):
    """Parse saturation probe CSV into downtime analysis."""
    if not filepath or not os.path.exists(filepath):
        return None

    probes = []
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if line.startswith('#') or not line:
                continue
            parts = line.split(',')
            if len(parts) >= 3:
                try:
                    probes.append({
                        "timestamp": int(parts[0]),
                        "status": int(parts[1]),
                        "response_ms": int(parts[2]),
                    })
                except (ValueError, IndexError):
                    continue

    if not probes:
        return None

    total = len(probes)
    success = sum(1 for p in probes if p["status"] == 200)
    failed = total - success

    # Find downtime window
    first_failure = None
    last_failure_before_recovery = None
    first_success_after_failure = None

    saw_failure = False
    for i, p in enumerate(probes):
        if p["status"] != 200:
            if first_failure is None:
                first_failure = p["timestamp"]
            last_failure_before_recovery = p["timestamp"]
            saw_failure = True
        elif saw_failure and p["status"] == 200:
            if i > 0 and probes[i - 1]["status"] != 200:
                first_success_after_failure = p["timestamp"]

    downtime_s = None
    if first_failure and first_success_after_failure:
        downtime_s = first_success_after_failure - first_failure

    ttfr_s = None
    if last_failure_before_recovery and first_success_after_failure:
        ttfr_s = first_success_after_failure - last_failure_before_recovery

    # Check for unexpected accessibility during rebuild
    mid_success = 0
    if first_failure and last_failure_before_recovery:
        for p in probes:
            if first_failure < p["timestamp"] < last_failure_before_recovery and p["status"] == 200:
                mid_success += 1

    return {
        "total_probes": total,
        "successful": success,
        "failed": failed,
        "first_failure_ts": first_failure,
        "last_failure_ts": last_failure_before_recovery,
        "first_recovery_ts": first_success_after_failure,
        "downtime_s": downtime_s,
        "time_to_first_recovery_s": ttfr_s,
        "mid_rebuild_successes": mid_success,
    }


def main():
    parser = argparse.ArgumentParser(description="DR Report Generator")
    parser.add_argument("--baseline", required=True, help="Baseline test output")
    parser.add_argument("--recovery", required=True, help="Recovery test output")
    parser.add_argument("--timestamps", required=True, help="Directory with timestamp files")
    parser.add_argument("--saturation", help="Saturation probe CSV file")
    parser.add_argument("--output", help="Write JSON report to file")
    parser.add_argument("--rto-threshold", type=int, default=600,
                        help="Maximum RTO in seconds (default: 600 = 10 min)")
    parser.add_argument("--vm-recovery-threshold", type=int, default=360,
                        help="Maximum VM recovery in seconds (default: 360 = 6 min)")
    parser.add_argument("--api-warmup-threshold", type=int, default=300,
                        help="Maximum API warmup in seconds (default: 300 = 5 min)")
    parser.add_argument("--config-threshold", type=int, default=120,
                        help="Maximum config recovery in seconds (default: 120 = 2 min)")
    args = parser.parse_args()

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    # Parse test results
    baseline = parse_test_output(args.baseline)
    recovery = parse_test_output(args.recovery)

    # Parse saturation data
    saturation = parse_saturation(args.saturation)

    # Read timestamps
    t0 = read_timestamp(args.timestamps, "t0_destroy_start")
    t1 = read_timestamp(args.timestamps, "t1_destroy_end")
    t2 = read_timestamp(args.timestamps, "t2_recover_start")
    t3 = read_timestamp(args.timestamps, "t3_vm_created")
    t4 = read_timestamp(args.timestamps, "t4_api_ready")
    t5 = read_timestamp(args.timestamps, "t5_config_start")
    t6 = read_timestamp(args.timestamps, "t6_config_end")
    t7 = read_timestamp(args.timestamps, "t7_test_start")
    t8 = read_timestamp(args.timestamps, "t8_test_end")

    # Calculate timings
    destroy_time = (t1 - t0) if t0 and t1 else None
    vm_recovery = (t3 - t2) if t2 and t3 else None
    api_warmup = (t4 - t3) if t3 and t4 else None
    config_time = (t6 - t5) if t5 and t6 else None
    test_time = (t8 - t7) if t7 and t8 else None
    rto = (t6 - t1) if t1 and t6 else None
    total_cycle = (t8 - t0) if t0 and t8 else None

    # Threshold evaluation
    thresholds = {}
    threshold_breaches = []

    def check_threshold(name, actual, limit):
        if actual is None:
            return
        passed = actual <= limit
        thresholds[name] = {
            "actual_s": actual,
            "threshold_s": limit,
            "passed": passed,
        }
        if not passed:
            threshold_breaches.append(name)

    check_threshold("VM Recovery", vm_recovery, args.vm_recovery_threshold)
    check_threshold("API Warmup", api_warmup, args.api_warmup_threshold)
    check_threshold("Config Recovery", config_time, args.config_threshold)
    check_threshold("RTO", rto, args.rto_threshold)

    # Compare results
    diffs = compare_tests(baseline, recovery)
    is_identical = (
        baseline["passed"] == recovery["passed"]
        and baseline["failed"] == recovery["failed"]
        and baseline["warnings"] == recovery["warnings"]
        and len(diffs) == 0
    )
    match_status = "IDENTICAL" if is_identical else f"{len(diffs)} DIFFERENCES"

    # DR pass/fail — includes threshold breaches
    dr_pass = is_identical and recovery["gates"] == 0 and len(threshold_breaches) == 0

    # Print report
    print("")
    print("=" * 64)
    print("  DISASTER RECOVERY REPORT")
    print(f"  {now}")
    print("=" * 64)
    print("")
    print("  TIMING")
    print("  " + "-" * 60)
    print(f"  {'Phase':<30s} {'Actual':>10s} {'Threshold':>10s} {'Status':>8s}")
    print("  " + "-" * 60)

    def timing_line(label, actual, threshold_name=None):
        actual_fmt = format_duration(actual)
        if threshold_name and threshold_name in thresholds:
            t = thresholds[threshold_name]
            status = "OK" if t["passed"] else "BREACH"
            thresh_fmt = format_duration(t["threshold_s"])
            print(f"  {label:<30s} {actual_fmt:>10s} {thresh_fmt:>10s} {status:>8s}")
        else:
            print(f"  {label:<30s} {actual_fmt:>10s} {'':>10s} {'':>8s}")

    timing_line("VM Destruction:", destroy_time)
    timing_line("VM Recovery (terraform):", vm_recovery, "VM Recovery")
    timing_line("NITRO API Warmup:", api_warmup, "API Warmup")
    timing_line("Config Recovery:", config_time, "Config Recovery")
    timing_line("Test Verification:", test_time)
    print("  " + "-" * 60)
    timing_line("RTO (destroy -> configured):", rto, "RTO")
    timing_line("Total DR Cycle:", total_cycle)

    # Saturation section
    if saturation:
        print("")
        print("  DATA PLANE SATURATION")
        print("  " + "-" * 50)
        print(f"  {'Total Probes:':<30s} {saturation['total_probes']}")
        print(f"  {'Successful (200):':<30s} {saturation['successful']}")
        print(f"  {'Failed:':<30s} {saturation['failed']}")
        avail = (saturation['successful'] / saturation['total_probes'] * 100
                 ) if saturation['total_probes'] > 0 else 0
        print(f"  {'Availability:':<30s} {avail:.1f}%")
        print(f"  {'Measured Downtime:':<30s} {format_duration(saturation['downtime_s'])}")
        print(f"  {'Time to First Recovery:':<30s}"
              f" {format_duration(saturation['time_to_first_recovery_s'])}")
        if saturation['mid_rebuild_successes'] > 0:
            print(f"  {'MID-REBUILD ACCESS:':<30s}"
                  f" {saturation['mid_rebuild_successes']} probes succeeded during outage!")
            print(f"  {'':30s} ^^^ SECURITY CONCERN: VIP accessible during rebuild")
        else:
            print(f"  {'Mid-rebuild access:':<30s} None (clean outage window)")

    print("")
    print("  TEST COMPARISON")
    print("  " + "-" * 50)
    print(f"  {'Baseline:':<16s} {baseline['passed']} passed,"
          f" {baseline['failed']} failed,"
          f" {baseline['warnings']} warnings")
    print(f"  {'Recovery:':<16s} {recovery['passed']} passed,"
          f" {recovery['failed']} failed,"
          f" {recovery['warnings']} warnings")
    print(f"  {'Match:':<16s} {match_status}")

    if diffs:
        print("")
        print("  DIFFERENCES")
        print("  " + "-" * 50)
        for d in diffs[:20]:  # Show max 20 diffs
            print(f"  #{d['index']:3d}  {d['baseline']:>6s} -> {d['recovery']:<6s}"
                  f"  {d['test'][:50]}")
        if len(diffs) > 20:
            print(f"  ... and {len(diffs) - 20} more")

    print("")
    print(f"  {'Quality Gates:':<16s} {recovery['gates']} breaches"
          f" (baseline: {baseline['gates']})")
    print("  " + "-" * 50)
    if dr_pass:
        print("  DR RESULT: PASS — Full recovery verified within thresholds")
    else:
        reasons = []
        if not is_identical:
            reasons.append(f"{len(diffs)} test differences")
        if recovery["gates"] > 0:
            reasons.append(f"{recovery['gates']} gate breaches")
        if threshold_breaches:
            reasons.append(f"timing: {', '.join(threshold_breaches)}")
        print(f"  DR RESULT: FAIL — {', '.join(reasons)}")
    print("=" * 64)
    print("")

    # Build JSON report
    report = {
        "timestamp": now,
        "timing": {
            "vm_destruction_s": destroy_time,
            "vm_recovery_s": vm_recovery,
            "api_warmup_s": api_warmup,
            "config_recovery_s": config_time,
            "test_verification_s": test_time,
            "rto_s": rto,
            "total_cycle_s": total_cycle,
        },
        "thresholds": thresholds,
        "threshold_breaches": threshold_breaches,
        "baseline": {
            "passed": baseline["passed"],
            "failed": baseline["failed"],
            "warnings": baseline["warnings"],
            "gates": baseline["gates"],
        },
        "recovery": {
            "passed": recovery["passed"],
            "failed": recovery["failed"],
            "warnings": recovery["warnings"],
            "gates": recovery["gates"],
        },
        "comparison": {
            "match": match_status,
            "identical": is_identical,
            "differences": diffs,
        },
        "result": "PASS" if dr_pass else "FAIL",
    }

    if saturation:
        report["saturation"] = saturation

    if args.output:
        os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
        with open(args.output, "w") as f:
            json.dump(report, f, indent=2)
        print(f"  Report written to: {args.output}")
        print("")

    sys.exit(0 if dr_pass else 1)


if __name__ == "__main__":
    main()
