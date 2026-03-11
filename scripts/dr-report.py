#!/usr/bin/env python3
"""Disaster Recovery Report — compares baseline vs recovery test results
and calculates RTO timing metrics.

Usage:
    python3 dr-report.py --baseline baseline.log --recovery recovery.log \
        --timestamps /tmp/dr-test [--output dr-report.json]
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


def main():
    parser = argparse.ArgumentParser(description="DR Report Generator")
    parser.add_argument("--baseline", required=True, help="Baseline test output")
    parser.add_argument("--recovery", required=True, help="Recovery test output")
    parser.add_argument("--timestamps", required=True, help="Directory with timestamp files")
    parser.add_argument("--output", help="Write JSON report to file")
    args = parser.parse_args()

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    # Parse test results
    baseline = parse_test_output(args.baseline)
    recovery = parse_test_output(args.recovery)

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

    # Compare results
    diffs = compare_tests(baseline, recovery)
    is_identical = (
        baseline["passed"] == recovery["passed"]
        and baseline["failed"] == recovery["failed"]
        and baseline["warnings"] == recovery["warnings"]
        and len(diffs) == 0
    )
    match_status = "IDENTICAL" if is_identical else f"{len(diffs)} DIFFERENCES"

    # DR pass/fail
    dr_pass = is_identical and recovery["gates"] == 0

    # Print report
    print("")
    print("=" * 64)
    print("  DISASTER RECOVERY REPORT")
    print(f"  {now}")
    print("=" * 64)
    print("")
    print("  TIMING")
    print("  " + "-" * 50)
    print(f"  {'VM Destruction:':<30s} {format_duration(destroy_time)}")
    print(f"  {'VM Recovery (terraform):':<30s} {format_duration(vm_recovery)}")
    print(f"  {'NITRO API Warmup:':<30s} {format_duration(api_warmup)}")
    print(f"  {'Config Recovery:':<30s} {format_duration(config_time)}")
    print(f"  {'Test Verification:':<30s} {format_duration(test_time)}")
    print("  " + "-" * 50)
    print(f"  {'RTO (destroy -> configured):':<30s} {format_duration(rto)}")
    print(f"  {'Total DR Cycle:':<30s} {format_duration(total_cycle)}")
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
        print("  DR RESULT: PASS — Full recovery verified")
    else:
        reasons = []
        if not is_identical:
            reasons.append(f"{len(diffs)} test differences")
        if recovery["gates"] > 0:
            reasons.append(f"{recovery['gates']} gate breaches")
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

    if args.output:
        os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
        with open(args.output, "w") as f:
            json.dump(report, f, indent=2)
        print(f"  Report written to: {args.output}")
        print("")

    sys.exit(0 if dr_pass else 1)


if __name__ == "__main__":
    main()
