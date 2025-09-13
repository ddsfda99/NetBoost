#!/usr/bin/env bash
set -euo pipefail

# === 配置项 ===
DEVICE_DIRS=(
  "/storage/Users/currentUser/Download/com.example.netboost"
  "/storage/Users/currentUser/Download"
)
HOST_RAW_DIR="data/raw_json"
HOST_CSV_DIR="data/csv"
RESULTS_MD="docs/RESULTS.md"

mkdir -p "$HOST_RAW_DIR" "$HOST_CSV_DIR" docs

timestamp() { date +"%Y%m%d-%H%M%S"; }

echo "==> 扫描设备上的 JSON 日志..."
FOUND=0
for d in "${DEVICE_DIRS[@]}"; do
  echo "   - 查找目录: $d"
  # 列出匹配文件（忽略不存在的目录错误）
  LIST=$(hdc shell "ls -1 ${d}/netbench_*.json 2>/dev/null" || true)
  if [[ -n "$LIST" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      base=$(basename "$f")
      echo "      · 拉取 $f"
      hdc file recv "$f" "${HOST_RAW_DIR}/${base}" || true
      FOUND=1
    done <<< "$LIST"
  fi
done

if [[ "$FOUND" -eq 0 ]]; then
  echo "!! 未在设备公共下载目录发现 netbench_*.json"
  echo "   请确认 App 已写镜像：/storage/Users/currentUser/Download/com.example.netboost/"
  exit 2
fi

echo "==> 生成 CSV ..."
python3 bench/json_to_csv.py \
  --input "$HOST_RAW_DIR" \
  --runs "${HOST_CSV_DIR}/runs.csv" \
  --perfile "${HOST_CSV_DIR}/perfile.csv"

echo "==> 汇总结果，写入 ${RESULTS_MD} ..."
python3 bench/summarize.py \
  --runs "${HOST_CSV_DIR}/runs.csv" \
  --out "${RESULTS_MD}"

echo "==> 完成"
echo "    - 原始JSON: ${HOST_RAW_DIR}"
echo "    - 轮级CSV : ${HOST_CSV_DIR}/runs.csv"
echo "    - 明细CSV : ${HOST_CSV_DIR}/perfile.csv"
echo "    - 汇总报告: ${RESULTS_MD}"
