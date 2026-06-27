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

# Cloudflare IP 优�?+ hosts 更新 + 订阅生成

基于 [CloudflareST](https://github.com/XIU2/CloudflareSpeedTest) 的自动化 IP 优选工具链，实�?*多池测�?�?历史评分 �?hosts 写入 �?v2rayN 订阅生成**的全流程闭环�?

---

## 目录结构

```
speedtest/
├── bin/                          # CloudflareST.exe 及依�?
├── ippools/                      # IP 池文件（.txt�?
�?  ├── ip_best.txt               # 历史高分 /22 精选（菜单[1]�?
�?  ├── ip_expanded_23.txt        # 历史 /23 聚合（菜单[2]�?
�?  ├── ip_history_expanded.txt   # 历史 /24 全展开（菜单[3]�?
�?  ├── ip_custom.txt             # 自定�?CIDR 段（菜单[4]�?
�?  ├── ip_full.txt               # 原始基线池（菜单[5]�?
�?  ├── ip_double.txt             # 多源合并池（菜单[6]�?
�?  └── ip_history_all.txt        # H 选项临时池（自动生成�?
├── config/
�?  ├── profiles.json             # 测速菜单配置（6 �?profile�?
�?  ├── domains.json              # 需要绑定优�?IP 的域名列�?
�?  └── subscription.json         # 订阅模板（VLESS 链接�?
├── output/
�?  ├── result.csv                # 最新一次测速结�?
�?  └── update-history.log        # hosts 更新日志
├── test-menu.ps1                 # 交互式测速菜单脚�?
├── update-hosts-asian.ps1       # 测�?+ hosts + 订阅生成脚本
├── start-sub.ps1                 # 本地订阅服务脚本
├── 启动优选IP.bat                 # test-menu.ps1 启动器（小白入口�?
├── update-ip.bat                  # update-hosts-asian.ps1 启动�?
├── start-sub.bat                  # start-sub.ps1 启动�?
├── ip_history.csv                # IP 历史记录（自动生成，48h 窗口�?
├── 优选订�?txt                   # 订阅文件（Base64 编码�?
└── 即时订阅.txt                   # 即时订阅文件（仅手动模式生成�?
```

---

## 三个 BAT 脚本功能说明

### 1. 启动优选IP.bat �?`test-menu.ps1`

交互式测速菜单，�?`config/profiles.json` 读取 6 �?IP 池配置，供用户选择执行�?

| 选项 | 行为 |
|------|------|
| `[1]~[6]` | 执行对应 profile �?CloudflareST 测速，结果写入 `output/result.csv` |
| `[H]` | 历史 IP 全量重测：提�?`ip_history.csv` 中所有唯一 IP，一次性全量测速，结果写入 hosts + 订阅�?*不写�?* ip_history�?|
| `[0]` | 退�?|

**参数说明**�?
- `-FeedHistory`：普通测速完成后，追加结果到 ip_history.csv 并生成订阅。不带此参数仅测速不记录�?

### 2. update-ip.bat �?`update-hosts-asian.ps1`

核心全自动脚本，完成测�?�?历史评分 �?hosts 写入 �?订阅生成�?

**工作流程�? 步）**�?

```
[1/4] testing       �?CloudflareST 测速（亚洲边缘节点�?
[2/4] recording     �?记录历史 CSV�?8h 窗口内最多保�?5000 �?
[3/4] scoring       �?多时段稳定性评分（全时�?+ 高峰池取 min�?
[4/4] writing       �?写入系统 hosts + 生成 Base64 订阅
```

**评分机制**�?

- �?IP 计算平均速度、平均延迟、标准差（CV）、历史出现频次、丢包惩�?
- `StabilityScore = avgSpeed × freqBonus × lossPenalty / (1 + cvSpeed + cvDelay×0.3)`，归一化到 0~100
- 高峰时段�?8:00-22:59）单独计�?PeakScore
- **FinalScore = min(AllScore, PeakScore)**，取两者最小值确保全天候稳定�?
- 优先选历史出�?�? 次的"成熟"IP，新 IP 降权排在后面

**参数说明**�?

| 参数 | 作用 |
|------|------|
| `-Scheduled` | 计划任务模式：使�?1000 线程 + ip_double.txt �?+ �?3 个节点，hosts 优先取历史评�?IP |
| `-SkipTest` | 跳过测速，直接基于已有 `output/result.csv` 生成订阅 |
| `-NoHistory` | 不将本次结果写入 ip_history.csv（但注入评分计算�?|

**手动模式 vs 计划任务模式对比**�?

| 维度 | 手动模式 | 计划任务 (-Scheduled) |
|------|---------|---------------------|
| IP �?| ip_custom.txt | ip_double.txt |
| 线程�?| 200 | 1000 |
| 边缘节点 | 9 个（HKG,NRT,KIX,ICN,TPE,SIN,MNL,BKK,SGN�?| 3 个（HKG,NRT,KIX�?|
| 测速下�?| speed �?1 MB/s | speed �?0.5 MB/s（高峰时段） |
| hosts �?IP | 本次测�?top 3 | 历史评分 top 3 |
| 即时订阅 | 生成 即时订阅.txt（top 15�?| 不生�?|

### 3. start-sub.bat �?`start-sub.ps1`

基于 .NET `HttpListener` 启动本地 HTTP 服务，监�?`127.0.0.1:18081`，供 v2rayN 等客户端直接订阅�?

**两个端点**�?

| URL | 返回内容 | 文件来源 |
|-----|---------|---------|
| `http://127.0.0.1:18081/` | 全量历史评分订阅（Base64�?| 优选订�?txt |
| `http://127.0.0.1:18081/instant` | 本次测�?top 15 即时订阅（Base64�?| 即时订阅.txt |

每次请求会打印访问日志：`HH:mm:ss /路径 -> 标签`

---

## 配置文件说明

### domains.json �?域名映射

定义需要绑定优�?IP 的域名列表。脚本会将前 3 个最�?IP 按顺序分配给这些域名，多余域名回退到第 1 �?IP�?

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

### profiles.json �?测速菜单配�?

`test-menu.ps1` 读取此文件生�?6 个测速选项。每�?profile 包含�?

| 字段 | 说明 |
|------|------|
| `name` | 菜单显示名称 |
| `file` | 关联�?IP 池文�?|
| `args` | CloudflareST 启动参数 |
| `desc` | 菜单中显示的描述文字 |

#### 6 �?Profile 用途说�?

| # | Profile | IP �?| 特征 | 适用场景 |
|---|---------|-------|------|---------|
| 1 | 优�?/22 | ip_best.txt | 历史高分 /22 精选，速度最�?| 日常优选，稳定性优�?|
| 2 | 历史 /23 | ip_expanded_23.txt | 历史 /24 向上聚合一�?| 在精度和覆盖之间折中 |
| 3 | 历史 /24 | ip_history_expanded.txt | 历史高分 IP 所�?/24 全展开 | 细粒度精准优�?|
| 4 | CF IP �?| ip_custom.txt | �?ip_custom.txt 读取 CIDR 段展开 | 自定�?IP 段池 |
| 5 | 全量原始�?| ip_full.txt | 原始基线 IP 池，速度门槛放宽 | 兜底场景 |
| 6 | 双倍合并池 | ip_double.txt | 多源 IP 合并扩充，大并发 | 计划任务默认池，大批量扫 |

> 所�?profile 共用相同参数：`-cfcolo HKG,NRT,KIX,ICN,TPE,SIN`（亚�?6 节点）、`-url https://test.hondac.top/10mb.bin`、`-sl 1 -dn 10 -p 15`（pool 5/6 sl=0.5）�?

### subscription.json �?订阅模板

定义 v2rayN 订阅链接的完整模板。脚本自动替�?IP 和标签部分�?

```json
{
  "template": "vless://uuid@sdtv.hondac.top:443?params...#PLACEHOLDER"
}
```

**模板解析逻辑**�?
- `scheme://uuid@` �?固定前缀（`linkPrefix`�?
- `:port` �?固定端口（`linkPort`�?
- `?params` �?固定查询串（`linkQuery`�?
- `#PLACEHOLDER` �?替换�?`CF-{序号}[s{评分}] {速度}M`

**自定义方�?*：修�?`template` 字段即可，保�?`@` 后的 HOST:PORT �?`#` 后的占位符结构不变。脚本会自动提取前缀/端口/查询串并拼接实际 IP 和标签�?

---

## 计划任务部署

使用 Windows 任务计划程序定时执行，实现无人值守自动化�?

**创建步骤**（PowerShell 管理员）�?

```powershell
$action  = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"D:\myproject\cloudflared\speedtest\update-hosts-asian.ps1`" -Scheduled"
$trigger = New-ScheduledTaskTrigger -Daily -At "02:00"
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "Cloudflare-优选IP" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest
```

**关键参数**�?
- `-Scheduled`：切换为计划任务模式�?000 线程 + ip_double.txt + 历史评分�?IP�?
- `-WindowStyle Hidden`：后台静默运行，无窗�?
- `-RunLevel Highest`：以最高权限运行（hosts 写入需要管理员权限�?

**建议频率**：每�?1 次（凌晨时段网络空闲，评分数据更稳定）�?

---

## 订阅端点使用

### v2rayN 配置

1. 启动订阅服务：双�?`start-sub.bat`
2. v2rayN �?订阅分组 �?添加订阅 �?填入 URL�?

| 用�?| URL |
|------|-----|
| 长期稳定订阅（全量历史评�?IP�?| `http://127.0.0.1:18081/` |
| 即时测速订阅（本次 top 15�?| `http://127.0.0.1:18081/instant` |

3. 更新订阅即可获取最新优选节�?

> 保持命令行窗口开启，关闭即停止服务�?

---

## 依赖

- **CloudflareST.exe**（[XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)）：位于 `bin/` 目录
- **PowerShell 5.1+**（Windows 10/11 内置�?
- **管理员权�?*：hosts 写入操作需�?
*（内容由AI生成，仅供参考）*
