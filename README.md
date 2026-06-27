---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: ae470bc42082dedd6ad730ed0d88a024_509ca223717f11f1986d525400d9a7a1
    ReservedCode1: YMUITLaCoAmqzGGp+/Mp79D/2SPXU0y1MyrUVwMXS0E1cBKqyJMeSVnz4YWGylOGqx8KVrbf7+741vaPIVKQ0eRlh1WSqZr77OwXhlb6e0vbW+GEscB+bn5B9YIYbPUICrjlTqFypA5SaN5PJ3xBa48LRSpLEp49ZRq6vx/g2q9gTPnVlMzHNNwYB6o=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: ae470bc42082dedd6ad730ed0d88a024_509ca223717f11f1986d525400d9a7a1
    ReservedCode2: YMUITLaCoAmqzGGp+/Mp79D/2SPXU0y1MyrUVwMXS0E1cBKqyJMeSVnz4YWGylOGqx8KVrbf7+741vaPIVKQ0eRlh1WSqZr77OwXhlb6e0vbW+GEscB+bn5B9YIYbPUICrjlTqFypA5SaN5PJ3xBa48LRSpLEp49ZRq6vx/g2q9gTPnVlMzHNNwYB6o=
---

# Cloudflare IP 优选 + hosts 更新 + 订阅生成

基于 [CloudflareST](https://github.com/XIU2/CloudflareSpeedTest) 的自动化 IP 优选工具链，实现**多池测速 → 历史评分 → hosts 写入 → v2rayN 订阅生成**的全流程闭环。

---

## 目录结构

```
speedtest/
├── bin/                          # CloudflareST.exe 及依赖
├── ippools/                      # IP 池文件（.txt）
│   ├── ip_best.txt               # 历史高分 /22 精选
│   ├── ip_expanded_cf22.txt      # 官方 CIDR 展开
│   ├── ip_expanded_23.txt        # 历史 /23 聚合
│   ├── ip_history_expanded.txt   # 历史 /24 全展开
│   ├── ip_double.txt             # 多源合并池
│   └── ip_full.txt               # 原始基线池
├── config/
│   ├── profiles.json             # 测速菜单配置（6 种 profile）
│   ├── domains.json              # 需要绑定优选 IP 的域名列表
│   └── subscription.json         # 订阅模板（VLESS 链接）
├── output/
│   ├── result.csv                # 最新一次测速结果
│   └── update-history.log        # hosts 更新日志
├── test-menu.ps1                 # 交互式测速菜单脚本
├── update-hosts-asian.ps1       # 测速 + hosts + 订阅生成脚本
├── start-sub.ps1                 # 本地订阅服务脚本
├── 启动优选IP.bat                 # test-menu.ps1 启动器（小白入口）
├── update-ip.bat                  # update-hosts-asian.ps1 启动器
├── start-sub.bat                  # start-sub.ps1 启动器
├── ip_history.csv                # IP 历史记录（自动生成，48h 窗口）
├── 优选订阅.txt                   # 订阅文件（Base64 编码）
└── 即时订阅.txt                   # 即时订阅文件（仅手动模式生成）
```

---

## 三个 BAT 脚本功能说明

### 1. 启动优选IP.bat → `test-menu.ps1`

交互式测速菜单，从 `config/profiles.json` 读取 6 种 IP 池配置，供用户选择执行。

| 选项 | 行为 |
|------|------|
| `[1]~[6]` | 执行对应 profile 的 CloudflareST 测速，结果写入 `output/result.csv` |
| `[H]` | 历史 IP 全量重测：提取 `ip_history.csv` 中所有唯一 IP，一次性全量测速，结果写入 hosts + 订阅（**不写入** ip_history） |
| `[0]` | 退出 |

**参数说明**：
- `-FeedHistory`：普通测速完成后，追加结果到 ip_history.csv 并生成订阅。不带此参数仅测速不记录。

### 2. update-ip.bat → `update-hosts-asian.ps1`

核心全自动脚本，完成测速 → 历史评分 → hosts 写入 → 订阅生成。

**工作流程（4 步）**：

```
[1/4] testing       → CloudflareST 测速（亚洲边缘节点）
[2/4] recording     → 记录历史 CSV，48h 窗口内最多保留 5000 条
[3/4] scoring       → 多时段稳定性评分（全时池 + 高峰池取 min）
[4/4] writing       → 写入系统 hosts + 生成 Base64 订阅
```

**评分机制**：

- 每 IP 计算平均速度、平均延迟、标准差（CV）、历史出现频次、丢包惩罚
- `StabilityScore = avgSpeed × freqBonus × lossPenalty / (1 + cvSpeed + cvDelay×0.3)`，归一化到 0~100
- 高峰时段（18:00-22:59）单独计算 PeakScore
- **FinalScore = min(AllScore, PeakScore)**，取两者最小值确保全天候稳定性
- 优先选历史出现 ≥3 次的"成熟"IP，新 IP 降权排在后面

**参数说明**：

| 参数 | 作用 |
|------|------|
| `-Scheduled` | 计划任务模式：使用 1000 线程 + ip_double.txt 池 + 限 3 个节点，hosts 优先取历史评分 IP |
| `-SkipTest` | 跳过测速，直接基于已有 `output/result.csv` 生成订阅 |
| `-NoHistory` | 不将本次结果写入 ip_history.csv（但注入评分计算） |

**手动模式 vs 计划任务模式对比**：

| 维度 | 手动模式 | 计划任务 (-Scheduled) |
|------|---------|---------------------|
| IP 池 | ip_expanded_cf22.txt | ip_double.txt |
| 线程数 | 200 | 1000 |
| 边缘节点 | 9 个（HKG,NRT,KIX,ICN,TPE,SIN,MNL,BKK,SGN） | 3 个（HKG,NRT,KIX） |
| 测速下限 | speed ≥ 1 MB/s | speed ≥ 0.5 MB/s（高峰时段） |
| hosts 选 IP | 本次测速 top 3 | 历史评分 top 3 |
| 即时订阅 | 生成 即时订阅.txt（top 15） | 不生成 |

### 3. start-sub.bat → `start-sub.ps1`

基于 .NET `HttpListener` 启动本地 HTTP 服务，监听 `127.0.0.1:18081`，供 v2rayN 等客户端直接订阅。

**两个端点**：

| URL | 返回内容 | 文件来源 |
|-----|---------|---------|
| `http://127.0.0.1:18081/` | 全量历史评分订阅（Base64） | 优选订阅.txt |
| `http://127.0.0.1:18081/instant` | 本次测速 top 15 即时订阅（Base64） | 即时订阅.txt |

每次请求会打印访问日志：`HH:mm:ss /路径 -> 标签`

---

## 配置文件说明

### domains.json — 域名映射

定义需要绑定优选 IP 的域名列表。脚本会将前 3 个最优 IP 按顺序分配给这些域名，多余域名回退到第 1 个 IP。

```json
{
  "domains": [
    "kerong.hondac.top",
    "x-ui.hondac.top",
    "sd.hondac.top",
    "sdtv.hondac.top"
  ]
}
```

### profiles.json — 测速菜单配置

`test-menu.ps1` 读取此文件生成 6 个测速选项。每个 profile 包含：

| 字段 | 说明 |
|------|------|
| `name` | 菜单显示名称 |
| `file` | 关联的 IP 池文件 |
| `args` | CloudflareST 启动参数 |
| `desc` | 菜单中显示的描述文字 |

#### 6 个 Profile 用途说明

| # | Profile | IP 池 | 特征 | 适用场景 |
|---|---------|-------|------|---------|
| 1 | 优选 /22 | ip_best.txt | 历史高分 /22 精选，速度最稳 | 日常优选，稳定性优先 |
| 2 | 历史 /23 | ip_expanded_23.txt | 历史 /24 向上聚合一级 | 在精度和覆盖之间折中 |
| 3 | 历史 /24 | ip_history_expanded.txt | 历史高分 IP 所在 /24 全展开 | 细粒度精准优选 |
| 4 | CF IP 段 | ip.txt | 从 ip.txt 读取 CIDR 段展开 | 自定义 IP 段池 |
| 5 | 全量原始池 | ip_full.txt | 原始基线 IP 池，速度门槛放宽 | 兜底场景 |
| 6 | 双倍合并池 | ip_double.txt | 多源 IP 合并扩充，大并发 | 计划任务默认池，大批量扫 |

> 所有 profile 共用相同参数：`-cfcolo HKG,NRT,KIX,ICN,TPE,SIN`（亚洲 6 节点）、`-url https://test.hondac.top/10mb.bin`、`-sl 1 -dn 10 -p 15`（pool 5/6 sl=0.5）。

### subscription.json — 订阅模板

定义 v2rayN 订阅链接的完整模板。脚本自动替换 IP 和标签部分。

```json
{
  "template": "vless://uuid@sdtv.hondac.top:443?params...#PLACEHOLDER"
}
```

**模板解析逻辑**：
- `scheme://uuid@` → 固定前缀（`linkPrefix`）
- `:port` → 固定端口（`linkPort`）
- `?params` → 固定查询串（`linkQuery`）
- `#PLACEHOLDER` → 替换为 `CF-{序号}[s{评分}] {速度}M`

**自定义方法**：修改 `template` 字段即可，保持 `@` 后的 HOST:PORT 和 `#` 后的占位符结构不变。脚本会自动提取前缀/端口/查询串并拼接实际 IP 和标签。

---

## 计划任务部署

使用 Windows 任务计划程序定时执行，实现无人值守自动化。

**创建步骤**（PowerShell 管理员）：

```powershell
$action  = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"D:\myproject\cloudflared\speedtest\update-hosts-asian.ps1`" -Scheduled"
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "Cloudflare-优选IP" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest
```

**关键参数**：
- `-Scheduled`：切换为计划任务模式（1000 线程 + ip_double.txt + 历史评分选 IP）
- `-WindowStyle Hidden`：后台静默运行，无窗口
- `-RunLevel Highest`：以最高权限运行（hosts 写入需要管理员权限）

**建议频率**：每日 1 次（凌晨时段网络空闲，评分数据更稳定）。

---

## 订阅端点使用

### v2rayN 配置

1. 启动订阅服务：双击 `启动订阅后台.bat`
2. v2rayN → 订阅分组 → 添加订阅 → 填入 URL：

| 用途 | URL |
|------|-----|
| 长期稳定订阅（全量历史评分 IP） | `http://127.0.0.1:18081/` |
| 即时测速订阅（本次 top 15） | `http://127.0.0.1:18081/instant` |

3. 更新订阅即可获取最新优选节点

> 保持命令行窗口开启，关闭即停止服务。

---

## 依赖

- **CloudflareST.exe**（[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)）：位于 `bin/` 目录
- **PowerShell 5.1+**（Windows 10/11 内置）
- **管理员权限**：hosts 写入操作需要
*（内容由AI生成，仅供参考）*
