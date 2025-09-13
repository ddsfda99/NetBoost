# OpenHarmony 图片加载弱网优化 — NetBoost

## 项目简介

本项目为 OpenHarmony 竞赛训练营“弱网优化”赛题的实现方案。
目标是在弱网环境下（如地库、电梯、Wi-Fi 信号渐弱等场景），通过智能网络预测、网络切换、并发调度与断点续传等手段，缩短图片资源的整体下载完成时间，并保证实验的公平性与可复现性。

## 功能亮点

* **弱网检测器 (WeakNetDetector)**
  采用 EWMA 与 CUSUM 算法判定弱网，结合失败率与吞吐趋势输出置信度
* **智能网络切换 (NetworkSwitcher)**
  支持用户可感迁移，统计等待时间，确保公平评测
* **任务调度与并发自适应 (PriorityPool)**
  小文件优先调度，弱网阶段降低并发，切换后动态提升并发
* **断点续传与轻量探测**
  实现 HTTP Range 断点续传与 1B RTT 探测，降低重传开销
* **性能监控与评测 (PerformanceMonitor)**
  提供标准化 JSON/CSV 输出，支持 wallTime 与 totalTime 双口径统计
* **网络领航员模拟环境 (NetworkNavigator)**
  支持“地库、离家、自定义场景”等典型弱网环境复现


## 项目结构

**客户端：**

```
.
├─ entry/
│  └─ src/main/
│     ├─ ets/
│     │  ├─ pages/
│     │  │  └─ Index.ets                 # 主界面：一键跑5轮 + 日志 + Summary
│     │  └─ navigator/
│     │     └─ NetworkNavigator.ets      # 挑战项：网络领航员软封装
│     └─ common/
│        ├─ Runner.ts                    # 串行切换 + 剔除等待计时 + JSON 日志镜像
│        ├─ HttpDownloader.ts            # 基础下载
│        ├─ RangeDownloader.ts           # 断点续传封装（Range）
│        ├─ WeakNetDetector.ts           # 判弱器（EWMA + CUSUM + fail_rate）
│        ├─ PriorityPool.ts              # 并发池（小文件优先 + 动态并发）
│        ├─ NetProbe.ts                  # 轻探测（Range 1B RTT）
│        └─ PerformanceMonitor.ts        # 本地聚合（可在 UI 展示性能数据）
│
├─ bench/
│  ├─ run_all.sh                         # hdc 拉 JSON → 产出 CSV/RESULTS.md
│  ├─ json_to_csv.py                     # JSON 转换为轮级/明细 CSV
│  └─ summarize.py                       # 聚合结果，生成 docs/RESULTS.md 摘要结论
```

**服务器端：**

* 部署在阿里云 Ubuntu 22.04，使用 Nginx 提供静态资源服务
* 图片目录：`/var/www/images/`（共 155 张，200KB–5MB）
* 支持缓存与跨域，保证实验环境一致性
* 访问地址：[http://139.224.130.188/images/](http://139.224.130.188/images/)

## 使用方法

1. **服务器端**

   ```bash
   # Ubuntu 22.04
   sudo apt install nginx -y
   scp ./images/* user@server:/var/www/images/
   sudo systemctl restart nginx
   ```

   验证访问： [http://139.224.130.188/images/](http://139.224.130.188/images/)

2. **客户端（OpenHarmony 设备）**
   在 DevEco Studio 导入工程，填写服务器地址

   ```
   http://139.224.130.188/images/
   ```

   选择模式（Wi-Fi Only / Auto Switch），点击开始测试

3. **数据收集**

   * 每种模式跑 5 轮，生成 `netbench_*.json`
   * 使用 `bench/json_to_csv.py` 转换为 CSV
   * 使用 `bench/summarize.py` 聚合结果，生成 `docs/RESULTS.md`，包含平均耗时、提升百分比、探测成本等指标


