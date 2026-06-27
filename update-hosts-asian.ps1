# 优选 IP -> hosts + 订阅（备选池版）
# 计划任务后台运行：加 -Scheduled 参数
# 新增：多时段历史评分，选出全天候稳定 IP 写入 v2rayN 订阅

param([switch]$Scheduled, [switch]$SkipTest, [switch]$NoHistory)

# 自提权（仅前台双击 bat 时触发）
if (-not $Scheduled) {
    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Start-Process PowerShell -Verb RunAs -Wait -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }
}

$cfstDir    = $PSScriptRoot
$resultCsv  = "$cfstDir\output\result.csv"
$hostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"
$historyCsv = "$cfstDir\ip_history.csv"
$subFile    = "$cfstDir\优选订阅.txt"

# 订阅模板（从 config/subscription.json 读取完整 VLESS 链接作为模板，脚本自动替换 IP+标签）
$subConfigFile = "$PSScriptRoot\config\subscription.json"
$skipSubscription = $false
if (-not (Test-Path $subConfigFile)) {
    Write-Host "WARNING: config\subscription.json not found，跳过订阅生成" -ForegroundColor Yellow
    $skipSubscription = $true
} else {
    $subCfg = Get-Content $subConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $template = $subCfg.template
    if (-not $template) {
    Write-Host "WARNING: config\subscription.json 未配置订阅模板，跳过订阅生成" -ForegroundColor Yellow
    $skipSubscription = $true
} else {
    # 解析模板：分离 scheme@prefix、端口、query string
    if ($template -match '^([^@]+@)([^:?\s#]+)(:\d+)?(\?[^#]*)?') {
        $linkPrefix  = $Matches[1]
        $linkPort    = if ($Matches[3]) { $Matches[3] } else { "" }
        $linkQuery   = if ($Matches[4]) { $Matches[4] } else { "" }
    } else {
        Write-Host "WARNING: config\subscription.json 订阅模板格式无效，跳过订阅生成" -ForegroundColor Yellow
        $skipSubscription = $true
    }
    }
}

# 从配置文件读取域名映射
$domainConfigFile = "$PSScriptRoot\config\domains.json"
if (-not (Test-Path $domainConfigFile)) {
    Write-Host "ERROR: config\domains.json not found" -ForegroundColor Red
    if (-not $Scheduled) { pause }
    exit 1
}
$mapping = (Get-Content $domainConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json).domains | ForEach-Object { @{domain=$_} }

$poolSize        = 15
$minHistoryCount = 3

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  IP -> hosts + subscription (pool mode)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# === 时段动态阈值 ===
$hour = (Get-Date).Hour
if ($hour -ge 19 -or $hour -le 1) {
    $sl = 0.5; $dn = 5
    Write-Host "(peak hours: speed>${sl}MB/s, top ${dn})" -ForegroundColor DarkYellow
} else {
    $sl = 1; $dn = 5
}
$ipFile = if ($Scheduled) { "ippools\ip_double.txt" } else { "ippools\ip_expanded_cf22.txt" }
Write-Host "(source: $ipFile)" -ForegroundColor DarkYellow
# ================================================================
# 1. 测速
# ================================================================
if (-not $SkipTest) {
    Write-Host "[1/4] testing (1000 threads / 20 dl / asia edges)..." -ForegroundColor Yellow
    Push-Location $cfstDir
    if ($Scheduled) {
        "" | & .\bin\CloudflareST.exe -n 1000 -f ippools\ip_double.txt -url "https://test.hondac.top/10mb.bin" -httping -cfcolo HKG,NRT,KIX -sl $sl -dn $dn -p 20
    } else {
        & .\bin\CloudflareST.exe -n 200 -f ippools\$ipFile -url "https://test.hondac.top/10mb.bin" -httping -cfcolo HKG,NRT,KIX,ICN,TPE,SIN,MNL,BKK,SGN -sl $sl -dn $dn -p 20
    }

    if (-not (Test-Path $resultCsv)) {
        Write-Host "ERROR: test failed" -ForegroundColor Red
        Pop-Location
        if (-not $Scheduled) { pause }
        exit 1
    }
    Pop-Location
}

# ================================================================
# 2. 解析本次结果 + 兜底
# ================================================================
Write-Host "[2/4] recording history..." -ForegroundColor Yellow
$now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# -SkipTest 时 result.csv 缺失的友好退出
if ($SkipTest -and -not (Test-Path $resultCsv)) {
    Write-Host "ERROR: -SkipTest requires a result.csv from a previous test (not found at $resultCsv)" -ForegroundColor Red
    Write-Host "       Run without -SkipTest first, or place a valid result.csv in output\" -ForegroundColor DarkYellow
    if (-not $Scheduled) { pause }
    exit 1
}

$currentResults = @(Get-Content $resultCsv | Select-Object -Skip 1 | ForEach-Object {
    $cols = $_ -split ","
    if ($cols.Count -ge 6) {
        $loss = if ($cols[3] -and $cols[3] -ne "N/A") { [double]$cols[3] } else { 0.0 }
        [PSCustomObject]@{ IP = $cols[0]; Delay = [double]$cols[4]; Speed = [double]$cols[5]; Loss = $loss }
    }
})

# 兜底
if (-not $SkipTest -and $currentResults.Count -eq 0) {
    Write-Host "WARNING: no IP qualified, fallback..." -ForegroundColor Yellow
    Push-Location $cfstDir
    if ($Scheduled) {
        "" | & .\bin\CloudflareST.exe -n 1000 -f ippools\ip_double.txt -url "https://test.hondac.top/10mb.bin" -httping -cfcolo HKG,NRT,KIX -dn 1 -p 20
    } else {
        & .\bin\CloudflareST.exe -n 500 -f ippools\$ipFile -url "https://test.hondac.top/10mb.bin" -httping -cfcolo HKG,NRT,KIX -dn 1 -p 20
    }
    Pop-Location
    $currentResults = @(Get-Content $resultCsv | Select-Object -Skip 1 | ForEach-Object {
        $cols = $_ -split ","
        if ($cols.Count -ge 6) {
            $loss = if ($cols[3] -and $cols[3] -ne "N/A") { [double]$cols[3] } else { 0.0 }
            [PSCustomObject]@{ IP = $cols[0]; Delay = [double]$cols[4]; Speed = [double]$cols[5]; Loss = $loss }
        }
    })
    if ($currentResults.Count -eq 0) {
        Write-Host "ERROR: fallback also failed" -ForegroundColor Red
        if (-not $Scheduled) { pause }
        exit 1
    }
    Write-Host "  fallback: got 1 IP, 3 domains share it" -ForegroundColor DarkYellow
}

# 追加到历史 CSV
if (-not $NoHistory) {
    $historyLines = $currentResults | ForEach-Object { "$($_.IP),$($_.Delay),$($_.Speed),$($_.Loss),$now" }
    if (Test-Path $historyCsv) {
        # 旧表头升级：4列 → 5列
        $oldHeader = Get-Content $historyCsv -TotalCount 1 -Encoding UTF8
        if ($oldHeader -eq "IP,Delay,Speed,Timestamp") {
            $existingData = Get-Content $historyCsv -Encoding UTF8 | Select-Object -Skip 1
            "IP,Delay,Speed,Loss,Timestamp" | Set-Content $historyCsv -Encoding UTF8
            if ($existingData.Count -gt 0) {
                $existingData | ForEach-Object { "$_,0" } | Add-Content $historyCsv -Encoding UTF8
            }
        }
        $historyLines | Add-Content $historyCsv -Encoding UTF8
    } else {
        "IP,Delay,Speed,Loss,Timestamp" | Set-Content $historyCsv -Encoding UTF8
        $historyLines | Add-Content $historyCsv -Encoding UTF8
    }
    Write-Host "  recorded $($currentResults.Count) IPs" -ForegroundColor Green
}

# ================================================================
# 3. 历史评分
# ================================================================
Write-Host "[3/4] scoring..." -ForegroundColor Yellow

# Load history within 48h (max 5000 rows)
$cutoff = (Get-Date).AddHours(-48)
$history = @(Get-Content $historyCsv -Encoding UTF8 | Select-Object -Skip 1 | Where-Object { $_ -match "," } | ForEach-Object {
    $cols = $_ -split ","
    $ts = try { if ($cols.Count -ge 5) { [datetime]$cols[4] } else { [datetime]$cols[3] } } catch { $null }
    if ($cols.Count -ge 4 -and $ts -and $ts -ge $cutoff) {
        $loss = if ($cols.Count -ge 5) { [double]$cols[3] } else { 0.0 }
        [PSCustomObject]@{ IP = $cols[0]; Delay = [double]$cols[1]; Speed = [double]$cols[2]; Loss = $loss; Timestamp = if ($cols.Count -ge 5) { $cols[4] } else { $cols[3] } }
    }
})

# Clean expired, keep max 5000
$freshLines = $history | ForEach-Object { "$($_.IP),$($_.Delay),$($_.Speed),$($_.Loss),$($_.Timestamp)" }
"IP,Delay,Speed,Loss,Timestamp" | Set-Content $historyCsv -Encoding UTF8
if ($freshLines.Count -gt 0) {
    if ($freshLines.Count -gt 5000) {
        $freshLines = $freshLines | Select-Object -Last 5000
    }
    $freshLines | Add-Content $historyCsv -Encoding UTF8
}

# 当 -NoHistory 时，将当前测速结果注入评分计算（不写入 ip_history.csv）
if ($NoHistory -and $currentResults.Count -gt 0) {
    $history += $currentResults | ForEach-Object {
        $_ | Add-Member -NotePropertyName 'Timestamp' -NotePropertyValue $now -PassThru
    }
}

# Split history: peak (18:00-22:59) vs all
$historyPeak = $history | Where-Object {
    $h = [int]([datetime]$_.Timestamp).Hour
    $h -ge 18 -and $h -le 22
}
$historyAll = $history

Write-Host "  total records: $($history.Count) | peak(18-22): $($historyPeak.Count)" -ForegroundColor Green

# --- 全时池评分 ---
$groupsAll = $historyAll | Group-Object IP
$scoredAll = $groupsAll | ForEach-Object {
    $ip     = $_.Name
    $n      = $_.Count
    $speeds = $_.Group | ForEach-Object { $_.Speed }
    $delays = $_.Group | ForEach-Object { $_.Delay }
    $losses = $_.Group | ForEach-Object { $_.Loss }

    $avgSpeed = ($speeds | Measure-Object -Average).Average
    $avgDelay = ($delays | Measure-Object -Average).Average
    $avgLoss  = ($losses | Measure-Object -Average).Average
    $latest   = ($_.Group | Sort-Object Timestamp -Descending | Select-Object -First 1)

    $stdSpeed = 0; $stdDelay = 0
    if ($n -gt 1) {
        $varSpeed = ($speeds | ForEach-Object { ($_ - $avgSpeed) * ($_ - $avgSpeed) } | Measure-Object -Average).Average
        $stdSpeed = [Math]::Sqrt($varSpeed)
        $varDelay = ($delays | ForEach-Object { ($_ - $avgDelay) * ($_ - $avgDelay) } | Measure-Object -Average).Average
        $stdDelay = [Math]::Sqrt($varDelay)
    }

    $cvSpeed = if ($avgSpeed -gt 0) { $stdSpeed / $avgSpeed } else { 1 }
    $cvDelay = if ($avgDelay -gt 0) { $stdDelay / $avgDelay } else { 1 }

    $freqBonus    = [Math]::Min($n / [Math]::Max($minHistoryCount, 1), 1.0)
    $lossPenalty  = [Math]::Max(0, 1 - $avgLoss / 100)
    $stabilityRaw = $avgSpeed * $freqBonus * $lossPenalty / (1.0 + $cvSpeed + $cvDelay * 0.3)

    [PSCustomObject]@{
        IP           = $ip
        AvgSpeed     = [math]::Round($avgSpeed, 2)
        AvgDelay     = [math]::Round($avgDelay, 0)
        AvgLoss      = [math]::Round($avgLoss, 1)
        StdSpeed     = [math]::Round($stdSpeed, 2)
        Count        = $n
        StabilityRaw = [math]::Round($stabilityRaw, 3)
        LatestSpeed  = $latest.Speed
        LatestDelay  = $latest.Delay
    }
}

# Normalize all
$maxRawAll = ($scoredAll | Measure-Object StabilityRaw -Maximum).Maximum
if ($maxRawAll -gt 0) {
    $scoredAll = $scoredAll | ForEach-Object {
        Add-Member -InputObject $_ -MemberType NoteProperty -Name StabilityScore -Value ([math]::Round($_.StabilityRaw / $maxRawAll * 100, 0))
        $_
    }
} else {
    $scoredAll = $scoredAll | ForEach-Object {
        Add-Member -InputObject $_ -MemberType NoteProperty -Name StabilityScore -Value 0
        $_
    }
}

# --- 高峰池评分 ---
if ($historyPeak.Count -gt 0) {
    $groupsPeak = $historyPeak | Group-Object IP
    $scoredPeak = $groupsPeak | ForEach-Object {
        $ip     = $_.Name
        $n      = $_.Count
        $speeds = $_.Group | ForEach-Object { $_.Speed }
        $delays = $_.Group | ForEach-Object { $_.Delay }
        $losses = $_.Group | ForEach-Object { $_.Loss }

        $avgSpeed = ($speeds | Measure-Object -Average).Average
        $avgDelay = ($delays | Measure-Object -Average).Average
        $avgLoss  = ($losses | Measure-Object -Average).Average
        $latest   = ($_.Group | Sort-Object Timestamp -Descending | Select-Object -First 1)

        $stdSpeed = 0; $stdDelay = 0
        if ($n -gt 1) {
            $varSpeed = ($speeds | ForEach-Object { ($_ - $avgSpeed) * ($_ - $avgSpeed) } | Measure-Object -Average).Average
            $stdSpeed = [Math]::Sqrt($varSpeed)
            $varDelay = ($delays | ForEach-Object { ($_ - $avgDelay) * ($_ - $avgDelay) } | Measure-Object -Average).Average
            $stdDelay = [Math]::Sqrt($varDelay)
        }

        $cvSpeed = if ($avgSpeed -gt 0) { $stdSpeed / $avgSpeed } else { 1 }
        $cvDelay = if ($avgDelay -gt 0) { $stdDelay / $avgDelay } else { 1 }

        $freqBonus    = [Math]::Min($n / [Math]::Max($minHistoryCount, 1), 1.0)
        $lossPenalty  = [Math]::Max(0, 1 - $avgLoss / 100)
        $stabilityRaw = $avgSpeed * $freqBonus * $lossPenalty / (1.0 + $cvSpeed + $cvDelay * 0.3)

        [PSCustomObject]@{
            IP           = $ip
            AvgSpeed     = [math]::Round($avgSpeed, 2)
            AvgDelay     = [math]::Round($avgDelay, 0)
            AvgLoss      = [math]::Round($avgLoss, 1)
            StdSpeed     = [math]::Round($stdSpeed, 2)
            Count        = $n
            StabilityRaw = [math]::Round($stabilityRaw, 3)
            LatestSpeed  = $latest.Speed
            LatestDelay  = $latest.Delay
        }
    }

    $maxRawPeak = ($scoredPeak | Measure-Object StabilityRaw -Maximum).Maximum
    if ($maxRawPeak -gt 0) {
        $scoredPeak = $scoredPeak | ForEach-Object {
            Add-Member -InputObject $_ -MemberType NoteProperty -Name StabilityScore -Value ([math]::Round($_.StabilityRaw / $maxRawPeak * 100, 0))
            $_
        }
    } else {
        $scoredPeak = $scoredPeak | ForEach-Object {
            Add-Member -InputObject $_ -MemberType NoteProperty -Name StabilityScore -Value 0
            $_
        }
    }
}

# --- 合并：finalScore = min(peakScore, allScore) ---
if ($historyPeak.Count -gt 0) {
    $peakMap = @{}
    foreach ($p in $scoredPeak) { $peakMap[$p.IP] = $p.StabilityScore }

    $scored = $scoredAll | ForEach-Object {
        $peakScore = if ($peakMap.ContainsKey($_.IP)) { $peakMap[$_.IP] } else { 0 }
        [PSCustomObject]@{
            IP             = $_.IP
            AvgSpeed       = $_.AvgSpeed
            AvgDelay       = $_.AvgDelay
            AvgLoss        = $_.AvgLoss
            StdSpeed       = $_.StdSpeed
            Count          = $_.Count
            StabilityRaw   = $_.StabilityRaw
            LatestSpeed    = $_.LatestSpeed
            LatestDelay    = $_.LatestDelay
            StabilityScore = $_.StabilityScore
            PeakScore      = $peakScore
            FinalScore     = [Math]::Min($_.StabilityScore, $peakScore)
        }
    }

    $allIPs = @($scored | ForEach-Object { $_.IP })
    $peakOnly = $scoredPeak | Where-Object { $_.IP -notin $allIPs }
    foreach ($p in $peakOnly) {
        $scored += [PSCustomObject]@{
            IP             = $p.IP
            AvgSpeed       = $p.AvgSpeed
            AvgDelay       = $p.AvgDelay
            AvgLoss        = $p.AvgLoss
            StdSpeed       = $p.StdSpeed
            Count          = $p.Count
            StabilityRaw   = $p.StabilityRaw
            LatestSpeed    = $p.LatestSpeed
            LatestDelay    = $p.LatestDelay
            StabilityScore = $p.StabilityScore
            PeakScore      = $p.StabilityScore
            FinalScore     = 0
        }
    }

    $sorted = $scored | Sort-Object FinalScore -Descending
    $stable    = $sorted | Where-Object { $_.Count -ge $minHistoryCount }
    $freshOnly = $sorted | Where-Object { $_.Count -lt $minHistoryCount }
    $ranked    = @($stable) + @($freshOnly)

    Write-Host "  scored: $($scored.Count) IPs | peak: $($scoredPeak.Count) | all: $($scoredAll.Count)" -ForegroundColor Green
} else {
    # No peak data yet, fallback to alltime only
    $scored = $scoredAll
    $stable    = $scored | Where-Object { $_.Count -ge $minHistoryCount } | Sort-Object StabilityScore -Descending
    $freshOnly = $scored | Where-Object { $_.Count -lt $minHistoryCount } | Sort-Object AvgSpeed -Descending
    $ranked    = @($stable) + @($freshOnly)
    Write-Host "  scored: $($scored.Count) IPs (alltime only, no peak data yet)" -ForegroundColor DarkYellow
}

Write-Host "  history IPs: $($scored.Count) | stable(N>=$minHistoryCount): $($stable.Count)" -ForegroundColor Green
if ($ranked.Count -gt 0) {
    Write-Host "  Top 5:" -ForegroundColor Cyan
    $ranked | Select-Object -First 5 | ForEach-Object {
        $info  = "    $($_.IP)  spd:$($_.AvgSpeed)MB/s  lat:$($_.AvgDelay)ms  loss:$($_.AvgLoss)%  cnt:$($_.Count)"
        $info += if ($_.PSObject.Properties.Name -contains 'FinalScore') { "  all:$($_.StabilityScore) pk:$($_.PeakScore) final:$($_.FinalScore)" } else { "  score:$($_.StabilityScore)" }
        Write-Host $info -ForegroundColor Green
    }
}

# ================================================================
# 4. Write hosts + subscription
# ================================================================
Write-Host "[4/4] writing hosts + subscription..." -ForegroundColor Yellow

# -- hosts: top 3 (手动取本次测速最快, 计划任务取历史评分) --
if ($Scheduled) {
    # 如果本次有 >10MB/s 的IP，优先用它们（不用历史评分）
    $fastIPs = $currentResults | Where-Object { $_.Speed -gt 10 } | Sort-Object Speed -Descending
    if ($fastIPs.Count -gt 0) {
        $top3 = $fastIPs | Select-Object -First 3
        Write-Host "  (Scheduled) fast IPs (>10MB/s) from current test: $($fastIPs.Count), using top 3" -ForegroundColor Magenta
    } else {
        $top3 = $ranked | Select-Object -First 3
    }
} else {
    $top3 = $currentResults | Sort-Object Speed -Descending | Select-Object -First 3
}
$hostsContent = Get-Content $hostsPath -Encoding UTF8
$domains = $mapping | ForEach-Object { $_.domain }
$newHosts = @($hostsContent | Where-Object {
    $line = $_
    -not ($domains | Where-Object { $line -match ('^\s*(?:\d+\.\d+\.\d+\.\d+)?\s*' + [regex]::Escape($_) + '(\s|$)') })
})

for ($i = 0; $i -lt $mapping.Count; $i++) {
    $ipIndex = if ($i -lt $top3.Count) { $i } else { 0 }
    $newHosts += "$($top3[$ipIndex].IP) $($mapping[$i].domain)"
    Write-Host "  $($top3[$ipIndex].IP) -> $($mapping[$i].domain)" -ForegroundColor Green
}

try {
    [System.IO.File]::WriteAllLines($hostsPath, $newHosts, [System.Text.UTF8Encoding]::new($false))
    ipconfig /flushdns | Out-Null
} catch {
    Write-Host "WARNING: hosts 写入被拦截，正在自动获取权限..." -ForegroundColor Yellow
    try {
        takeown /f $hostsPath | Out-Null
        icacls $hostsPath /grant "BUILTIN\Administrators:F" | Out-Null
        [System.IO.File]::WriteAllLines($hostsPath, $newHosts, [System.Text.UTF8Encoding]::new($false))
        ipconfig /flushdns | Out-Null
        Write-Host "  hosts 写入成功（已自动获取权限）" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: 自动获取权限失败，hosts 写入未完成" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# -- subscription: all history IPs (deduped) --
if (-not $skipSubscription) {
    $pool = $ranked   # 全量订阅，IP 已去重
    $links = @()
    $idx   = 1
    foreach ($ipObj in $pool) {
        $score = if ($ipObj.PSObject.Properties.Name -contains 'FinalScore') { $ipObj.FinalScore } else { $ipObj.StabilityScore }
        $tag  = "CF-${idx}[s${score}] $([math]::Round($ipObj.LatestSpeed,1))M"
        $link = "${linkPrefix}$($ipObj.IP)${linkPort}${linkQuery}#$tag"
        $links += $link
        $idx++
    }
    $rawContent = $links -join "`r`n"
    $base64Content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($rawContent))
    $base64Content | Set-Content $subFile -Encoding ASCII
    Write-Host "  subscription: $($pool.Count) nodes -> sub.txt (base64)" -ForegroundColor Green

    # -- instant subscription: 本次测速前15（H 选项专用） --
    if ($SkipTest) {
        $instantSubFile = "$cfstDir\即时订阅.txt"
        $instantTop15 = $currentResults | Sort-Object Speed -Descending | Select-Object -First 15
        $instantLinks = @()
        $i = 1
        foreach ($ipObj in $instantTop15) {
            $tag = "CF-H-${i} $([math]::Round($ipObj.Speed,1))M"
            $instantLinks += "${linkPrefix}$($ipObj.IP)${linkPort}${linkQuery}#$tag"
            $i++
        }
        $instantRaw = $instantLinks -join "`r`n"
        $instantBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($instantRaw))
        $instantBase64 | Set-Content $instantSubFile -Encoding ASCII
        Write-Host "  instant sub: top15 -> 即时订阅.txt (base64)" -ForegroundColor Green
    }
}

# -- log --
$logPath = "$cfstDir\output\update-history.log"
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$hostsInfo = ($top3 | ForEach-Object { "$($_.IP)($($_.AvgDelay)ms/$($_.AvgSpeed)MB/s)" }) -join " | "
if (-not $skipSubscription) {
    $bestScore = if ($pool[0].PSObject.Properties.Name -contains 'FinalScore') { $pool[0].FinalScore } else { $pool[0].StabilityScore }
    $poolInfo  = "$($pool.Count)pool maxScore=$bestScore"
} else {
    $poolInfo = "sub skipped (no template)"
}
Add-Content $logPath "$ts | hosts: $hostsInfo | pool: $poolInfo" -Encoding UTF8

Write-Host ""
if (-not $skipSubscription) {
    Write-Host "DONE! hosts(3) + sub($($pool.Count)) updated" -ForegroundColor Cyan
} else {
    Write-Host "DONE! hosts(3) updated (subscription skipped: 未配置订阅模板)" -ForegroundColor Yellow
    Write-Host "  请在 config\subscription.json 中添加 template 字段，格式示例:" -ForegroundColor DarkGray
    Write-Host '  "template": "vless://你的uuid@HOST:443?encryption=none&type=ws&host=sd.hondac.top&path=%2F#TAG"' -ForegroundColor DarkGray
    Write-Host "  其中 HOST 和 #TAG 脚本会自动替换为优选 IP 和标签，其余照抄你的节点链接即可" -ForegroundColor DarkGray
}

if (-not $Scheduled) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}