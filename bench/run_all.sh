#!/usr/bin/env bash
set -euo pipefail

# =======================
# NetBoost batch runner (single-folder)
# 产物输出到 ../data
# =======================
#
# 用法:
#   bash bench/run_all.sh
#
# 可用环境变量:
BASE_URL="${BASE_URL:-http://139.224.130.188/images}"
COUNT="${COUNT:-50}"
ROUNDS="${ROUNDS:-5}"
MODES=("WIFI_ONLY" "AUTO_SWITCH")
MANUAL="${MANUAL:-1}"                          # 1=手动在设备上点；0/HEADLESS=脚本触发
HEADLESS="${HEADLESS:-0}"
BUNDLE="${BUNDLE:-com.example.netboost}"       # ← 你的实际包名
ABILITY="${ABILITY:-.service.RunnerServiceAbility}"

# 设备上日志候选目录（按优先级）
DEVICE_LOG_DIRS=(
  "/data/app/el2/100/base/com.example.netboost/haps/entry/files"  # ← 已确认的 filesDir
  "/storage/Users/currentUser/Download/com.example.netboost"       # 如有镜像到下载目录，可优先拉
)

# 路径
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="${OUT_ROOT:-$SELF_DIR/..}"
JSON2CSV="$SELF_DIR/json_to_csv.py"
RAW_DIR="$OUT_ROOT/data/raw_json"
CSV_DIR="$OUT_ROOT/data/csv"

mkdir -p "$RAW_DIR" "$CSV_DIR"

command -v hdc >/dev/null 2>&1 || { echo "ERROR: 'hdc' not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: 'python3' not found"; exit 1; }

echo "[i] Using BASE_URL=$BASE_URL COUNT=$COUNT ROUNDS=$ROUNDS"
echo "[i] RAW_DIR=$RAW_DIR CSV_DIR=$CSV_DIR"

device_now() { hdc shell date +%s 2>/dev/null | tr -d '\r\n'; }

# --- 关键函数：从设备拉取 JSON（兼容 Git Bash / MSYS） ---
pull_json_from_device() {
  local out_dir="$1"; shift
  local pulled=0

  mkdir -p "$out_dir"

  for pattern in "${DEVICE_LOG_DIRS[@]}"; do
    echo "[i] Probing: $pattern"
    # 在设备端展开通配并过滤无匹配的结果
    mapfile -t __dirs < <(hdc shell "ls -d $pattern 2>/dev/null" | tr -d '\r' | sed '/\*/d')

    if [ "${#__dirs[@]}" -eq 0 ]; then
      echo "    (no such dir or no match)"
      continue
    fi

    for realdir in "${__dirs[@]}"; do
      [ -n "$realdir" ] || continue
      echo "    -> $realdir"

      mapfile -t __files < <(hdc shell "ls -1 \"$realdir\" 2>/dev/null | grep -E '^netbench_.*\\.json$' || true" | tr -d '\r')
      if [ "${#__files[@]}" -gt 0 ]; then
        echo "[i] Found ${#__files[@]} JSON(s) under $realdir"
        for f in "${__files[@]}"; do
          [ -n "$f" ] || continue
          # 已存在就跳过，避免重复覆盖
          if [ -f "$out_dir/$f" ]; then
            echo "    (exists, skip) $f"
            continue
          fi
          echo "  - recv $realdir/$f"
          # 关键：切换到本地输出目录，用 "." 为目标；并禁用 MSYS 参数改写
          ( cd "$out_dir" && MSYS2_ARG_CONV_EXCL='*' hdc file recv "$realdir/$f" "." ) || true
          pulled=1
        done
      else
        echo "    (no netbench_*.json here)"
      fi
    done
  done

  # 兜底：全盘搜索（最多 50 个）
  if [ "$pulled" = "0" ]; then
    echo "[i] Fallback: searching device with find ..."
    mapfile -t __found < <(hdc shell 'find /data /storage -maxdepth 8 -type f -name "netbench_*.json" 2>/dev/null | head -n 50' | tr -d '\r')
    if [ "${#__found[@]}" -gt 0 ]; then
      echo "[i] Search found ${#__found[@]} file(s)."
      for p in "${__found[@]}"; do
        [[ -z "$p" ]] && continue
        fname="${p##*/}"
        if [ -f "$out_dir/$fname" ]; then
          echo "    (exists, skip) $fname"
          continue
        fi
        echo "  - recv $p"
        ( cd "$out_dir" && MSYS2_ARG_CONV_EXCL='*' hdc file recv "$p" "." ) || true
        pulled=1
      done
    fi
  fi

  # 返回码：拉到=成功(0)，没拉到=失败(1)
  if [ "$pulled" -eq 1 ]; then
    return 0
  else
    return 1
  fi
}

# ======================= 主流程 =======================
for MODE in "${MODES[@]}"; do
  echo
  echo "===== MODE: $MODE ====="
  START_SEC="$(device_now || echo 0)"
  echo "[i] Device start time (sec): $START_SEC"

  if [ "$HEADLESS" = "1" ]; then
    echo "[i] Headless trigger via Ability"
    # 通过 Ability 触发（注意 JSON 引号转义）
    hdc shell aa start -b "$BUNDLE" -a "$ABILITY" -d "{\"mode\":\"$MODE\",\"baseUrl\":\"$BASE_URL\",\"count\":$COUNT,\"rounds\":$ROUNDS}" || true
    # 简单等待：按你的轮次估算（需要的话加大）
    sleep $((ROUNDS * 5 + 5))
  else
    echo "[i] MANUAL mode: on device choose '$MODE' and tap 'Run x5'. Press ENTER when finished."
    read -r _
  fi

  echo "[i] Pulling device logs..."
  if ! pull_json_from_device "$RAW_DIR"; then
    echo "[i] No JSON found on device in all known dirs."
  fi

  echo "[i] JSON -> CSV for MODE=$MODE"
  python3 "$JSON2CSV" \
    --input "$RAW_DIR" \
    --output_prefix "$CSV_DIR/${MODE}" \
    --mode "$MODE" \
    --base_url "$BASE_URL" \
    --count "$COUNT" \
    --since "$((START_SEC * 1000))"
done

echo "[i] Merge summaries to $CSV_DIR/summary_all.csv"
{
  head -n1 "$CSV_DIR/WIFI_ONLY_summary.csv"
  tail -n +2 "$CSV_DIR/WIFI_ONLY_summary.csv"
  tail -n +2 "$CSV_DIR/AUTO_SWITCH_summary.csv"
} > "$CSV_DIR/summary_all.csv"

echo
echo "All done. CSV under $CSV_DIR"
echo "Open the notebook after you run Jupyter:"
echo "  jupyter notebook bench/plot.ipynb"
