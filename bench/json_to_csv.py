#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
读取 Runner.ts 写出的 netbench_*.json，生成：
- runs.csv     每轮摘要（骚数据主表）
- perfile.csv  逐文件明细（用于必要时追查）
"""
import os, sys, json, argparse, glob, math
import csv
from statistics import median

def safe_float(x, default=0.0):
    try:
        return float(x)
    except Exception:
        return default

def derive_bytes_split(perfile):
    wifi = 0
    cell = 0
    for pf in perfile or []:
        b = int(pf.get("bytes", 0) or 0)
        path = (pf.get("path") or "").lower()
        if path == "cell":
            cell += b
        else:
            wifi += b
    return wifi, cell

def sum_perfile_t(perfile):
    s = 0.0
    for pf in perfile or []:
        t = pf.get("t", 0)
        if isinstance(t, (int, float)) and t >= 0:
            s += float(t)
    return s

def load_jsons(folder):
    files = sorted(glob.glob(os.path.join(folder, "netbench_*.json")))
    for f in files:
        try:
            with open(f, "r", encoding="utf-8") as fp:
                obj = json.load(fp)
                yield f, obj
        except Exception as e:
            print(f"[WARN] 解析失败 {f}: {e}", file=sys.stderr)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="raw_json 目录")
    ap.add_argument("--runs", required=True, help="输出 runs.csv")
    ap.add_argument("--perfile", required=True, help="输出 perfile.csv")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.runs), exist_ok=True)
    os.makedirs(os.path.dirname(args.perfile), exist_ok=True)

    runs_rows = []
    perfile_rows = []

    for f, obj in load_jsons(args.input):
        ts = int(obj.get("ts", 0))
        mode = obj.get("mode", "")
        baseUrl = obj.get("baseUrl", "")
        count = int(obj.get("count", 0))
        wallTime = safe_float(obj.get("wallTime", 0.0))
        pausedMs = safe_float(obj.get("pausedMs", 0.0))
        totalTime = safe_float(obj.get("totalTime", 0.0))
        totalBytes = int(obj.get("totalBytes", 0))
        weak_idx = int(obj.get("weak_detect_index", -1))
        switch_ts = int(obj.get("switch_trigger_ts", 0))

        probes = obj.get("probes") or {}
        probe_count = int(probes.get("count", 0) or 0)
        probe_cost_ms = safe_float(probes.get("costMs", 0.0))

        perfile = obj.get("perFile") or []
        wifi_bytes, cell_bytes = derive_bytes_split(perfile)
        sum_t = sum_perfile_t(perfile)

        # 一致性校验（sum(perFile.t) vs totalTime）
        consistency = (sum_t / totalTime * 100.0) if totalTime > 0 else 0.0
        # 轻探测占比（相对 wallTime）
        probe_ratio_pct = (probe_cost_ms / (wallTime * 1000.0) * 100.0) if wallTime > 0 else 0.0

        runs_rows.append({
            "file": os.path.basename(f),
            "ts": ts,
            "mode": mode,
            "baseUrl": baseUrl,
            "count": count,
            "wallTime_s": f"{wallTime:.3f}",
            "totalTime_s": f"{totalTime:.3f}",
            "paused_s": f"{pausedMs/1000.0:.3f}",
            "totalBytes": totalBytes,
            "wifi_bytes": wifi_bytes,
            "cell_bytes": cell_bytes,
            "weak_detect_index": weak_idx,
            "switch_trigger_ts": switch_ts,
            "probe_count": probe_count,
            "probe_cost_ms": f"{probe_cost_ms:.1f}",
            "probe_ratio_pct": f"{probe_ratio_pct:.3f}",
            "sum_perfile_t_s": f"{sum_t:.3f}",
            "consistency_pct": f"{consistency:.2f}",
        })

        # 逐文件明细
        for pf in perfile:
            perfile_rows.append({
                "file": os.path.basename(f),
                "url": pf.get("url", ""),
                "t_s": pf.get("t", -1),
                "bytes": pf.get("bytes", 0),
                "path": pf.get("path", ""),
                "used_range": pf.get("used_range", False),
                "retried": pf.get("retried", False),
            })

    # 写 runs.csv
    runs_cols = [
        "file","ts","mode","baseUrl","count",
        "wallTime_s","totalTime_s","paused_s",
        "totalBytes","wifi_bytes","cell_bytes",
        "weak_detect_index","switch_trigger_ts",
        "probe_count","probe_cost_ms","probe_ratio_pct",
        "sum_perfile_t_s","consistency_pct"
    ]
    with open(args.runs, "w", newline="", encoding="utf-8") as fp:
        w = csv.DictWriter(fp, fieldnames=runs_cols)
        w.writeheader()
        for r in runs_rows:
            w.writerow(r)

    # 写 perfile.csv
    pf_cols = ["file","url","t_s","bytes","path","used_range","retried"]
    with open(args.perfile, "w", newline="", encoding="utf-8") as fp:
        w = csv.DictWriter(fp, fieldnames=pf_cols)
        w.writeheader()
        for r in perfile_rows:
            w.writerow(r)

    print(f"[OK] 写入 {args.runs} 与 {args.perfile}")

if __name__ == "__main__":
    main()
