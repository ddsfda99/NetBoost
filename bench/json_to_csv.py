import argparse, json, os, glob, csv
from datetime import datetime

def load_jsons(folder):
    files = sorted(glob.glob(os.path.join(folder, "netbench_*.json")))
    for fp in files:
        try:
            with open(fp, "r", encoding="utf-8") as f:
                data = json.load(f)
                yield fp, data
        except Exception as e:
            print(f"[warn] skip {fp}: {e}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="folder with netbench_*.json pulled from device")
    ap.add_argument("--output_prefix", required=True, help="prefix for CSV outputs, e.g., data/csv/WIFI_ONLY")
    ap.add_argument("--mode", required=True, choices=["WIFI_ONLY","AUTO_SWITCH"])
    ap.add_argument("--base_url", required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--since", type=int, default=0, help="only include runs with record.ts >= since (ms since epoch)")
    args = ap.parse_args()

    summary_rows = []
    perfile_rows = []

    for fp, rec in load_jsons(args.input):
        ts = int(rec.get("ts", 0))
        if ts < args.since:
            continue
        if str(rec.get("baseUrl","")).rstrip("/") != args.base_url.rstrip("/"):
            continue
        if int(rec.get("count", -1)) != args.count:
            continue
        mode = rec.get("mode", "WIFI_ONLY")
        if mode != args.mode:
            continue

        totalTime = float(rec.get("totalTime", 0.0))
        totalBytes = int(rec.get("totalBytes", 0))
        perFile = rec.get("perFile", [])

        cellBytes = sum(int(x.get("bytes",0)) for x in perFile if x.get("path") == "cell")
        wifiBytes = sum(int(x.get("bytes",0)) for x in perFile if x.get("path") == "wifi")
        succ = sum(1 for x in perFile if float(x.get("t", -1)) >= 0)
        fail = len(perFile) - succ

        summary_rows.append({
            "ts": ts,
            "ts_iso": datetime.utcfromtimestamp(ts/1000.0).isoformat()+"Z",
            "mode": mode,
            "baseUrl": rec.get("baseUrl",""),
            "count": rec.get("count",0),
            "totalTime_s": totalTime,
            "totalBytes_B": totalBytes,
            "wifiBytes_B": wifiBytes,
            "cellBytes_B": cellBytes,
            "success": succ,
            "fail": fail,
        })

        for x in perFile:
            perfile_rows.append({
                "ts": ts,
                "mode": mode,
                "url": x.get("url",""),
                "t_s": x.get("t",-1),
                "bytes_B": x.get("bytes",0),
                "path": x.get("path",""),
            })

    sum_fp = args.output_prefix + "_summary.csv"
    pf_fp  = args.output_prefix + "_files.csv"
    os.makedirs(os.path.dirname(sum_fp), exist_ok=True)

    import csv as _csv
    with open(sum_fp, "w", newline="", encoding="utf-8") as f:
        w = _csv.DictWriter(f, fieldnames=[
            "ts","ts_iso","mode","baseUrl","count","totalTime_s","totalBytes_B",
            "wifiBytes_B","cellBytes_B","success","fail"
        ])
        w.writeheader(); w.writerows(summary_rows)

    with open(pf_fp, "w", newline="", encoding="utf-8") as f:
        w = _csv.DictWriter(f, fieldnames=["ts","mode","url","t_s","bytes_B","path"])
        w.writeheader(); w.writerows(perfile_rows)

    print(f"[i] Wrote {sum_fp} and {pf_fp} (runs={len(summary_rows)}, files={len(perfile_rows)})")

if __name__ == "__main__":
    main()
