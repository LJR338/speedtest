# CloudflareST Visual Test Menu
param([switch]$FeedHistory)

$configFile = "$PSScriptRoot\config\profiles.json"
if (-not (Test-Path $configFile)) {
    Write-Host "ERROR: config\profiles.json not found" -ForegroundColor Red
    pause; exit 1
}

$profiles = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
$hArgs   = $profiles.h_args

$subConfigFile = "$PSScriptRoot\config\subscription.json"
if (-not (Test-Path $subConfigFile) -or -not ((Get-Content $subConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json).template)) {
    Write-Host "WARNING: config\subscription.json 未配置订阅模板" -ForegroundColor Yellow
}
$profiles = $profiles.profiles
if ($profiles.Count -eq 0) {
    Write-Host "ERROR: no profiles in config" -ForegroundColor Red
    pause; exit 1
}

function Submit-HistoryAndSubscription {
    param([string]$HistoryCsv = "$PSScriptRoot\ip_history.csv")
    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $results = Get-Content "$PSScriptRoot\output\result.csv" | Select-Object -Skip 1 | ForEach-Object {
        $cols = $_ -split ","
        if ($cols.Count -ge 6) {
            $loss = if ($cols[3] -and $cols[3] -ne "N/A") { $cols[3] } else { "0" }
            "$($cols[0]),$([double]$cols[4]),$([double]$cols[5]),$loss,$now"
        }
    }
    if ($results.Count -gt 0) {
        if (-not (Test-Path $HistoryCsv)) {
            "IP,Delay,Speed,Loss,Timestamp" | Set-Content $HistoryCsv -Encoding UTF8
        } else {
            $oldHeader = Get-Content $HistoryCsv -TotalCount 1 -Encoding UTF8
            if ($oldHeader -eq "IP,Delay,Speed,Timestamp") {
                $existingData = Get-Content $HistoryCsv -Encoding UTF8 | Select-Object -Skip 1
                "IP,Delay,Speed,Loss,Timestamp" | Set-Content $HistoryCsv -Encoding UTF8
                if ($existingData.Count -gt 0) {
                    $existingData | ForEach-Object { "$_,0" } | Add-Content $HistoryCsv -Encoding UTF8
                }
            }
        }
        $results | Add-Content $HistoryCsv -Encoding UTF8
        Write-Host "  Added $($results.Count) records" -ForegroundColor Green
    }
    $header = Get-Content $HistoryCsv -TotalCount 1
    $cleaned = @($header)
    $cleaned += Get-Content $HistoryCsv | Select-Object -Skip 1 | Where-Object {
        $cols = $_ -split ","
        $cols.Count -ge 4 -and [double]$cols[2] -ge 1.0
    }
    $cleaned | Set-Content $HistoryCsv -Encoding UTF8

    Write-Host "Generating subscription..." -ForegroundColor Yellow
    $uaPath = "$PSScriptRoot\update-hosts-asian.ps1"
    if (Test-Path $uaPath) {
        & $uaPath -Scheduled -SkipTest
    } else {
        Write-Host "WARNING: update-hosts-asian.ps1 not found" -ForegroundColor Red
    }
}

# --- 自动启动订阅服务（如未运行） ---
$subPort = 18081
$subRunning = $false
try {
    $conn = Get-NetTCPConnection -LocalPort $subPort -ErrorAction Stop
    if ($conn.State -eq 'Listen') { $subRunning = $true }
} catch {}
if (-not $subRunning) {
    $subScript = "$PSScriptRoot\start-sub.ps1"
    if (Test-Path $subScript) {
        Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$subScript`""
        Write-Host "订阅服务已启动 (http://127.0.0.1:${subPort})" -ForegroundColor DarkGray
    }
}

# --- IP 池计数（支持 CIDR 段展开） ---
function Get-IPPoolCount {
    param([string]$FilePath)
    if ($FilePath -match "ip\.txt$") { return @{ Count = 5955; IsCIDR = $true } }
    $lines = Get-Content $FilePath
    return @{ Count = $lines.Count; IsCIDR = $false }
}

# --- 行数缓存（避免每次循环读大文件） ---
$lineCache = @{}

while ($true) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CloudflareST Test Menu" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # 上次测速摘要
    $histFile = "$PSScriptRoot\ip_history.csv"
    if (Test-Path $histFile) {
        $last = Get-Content $histFile -Tail 1 -Encoding UTF8
        if ($last -match ",") {
            $cols = $last -split ","
            $lastTime = if ($cols[4]) { $cols[4].Trim() } else { "N/A" }
            $lastIP   = $cols[0]
            $lastSpd  = if ($cols[2]) { [math]::Round([double]$cols[2],1) } else { "N/A" }
            Write-Host "  上次: $lastTime | $lastSpd MB/s | $lastIP" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # 订阅服务状态
    $subOnline = $false
    try { $subOnline = (Get-NetTCPConnection -LocalPort $subPort -ErrorAction Stop).State -eq 'Listen' } catch {}
    if ($subOnline) {
        Write-Host "  优选订阅: http://127.0.0.1:${subPort}/" -ForegroundColor Green
        Write-Host "  即时订阅: http://127.0.0.1:${subPort}/instant" -ForegroundColor Green
    } else {
        Write-Host "  订阅: 未运行 (127.0.0.1:${subPort})" -ForegroundColor DarkGray
    }
    Write-Host ""

for ($i = 0; $i -lt $profiles.Count; $i++) {
    $n = $i + 1
    $argsStr = $profiles[$i].args
    $threads = ""
    if ($argsStr -match "-f\s+(\S+)") {
        $ipFile = Join-Path $PSScriptRoot $Matches[1]
        if (Test-Path $ipFile) {
            $fw = (Get-Item $ipFile).LastWriteTime
            if (-not $lineCache[$ipFile] -or $lineCache[$ipFile].Time -ne $fw) {
                $poolInfo = Get-IPPoolCount $ipFile
                $lineCache[$ipFile] = @{ Count = $poolInfo.Count; IsCIDR = $poolInfo.IsCIDR; Time = $fw }
            }
            $lineCount = $lineCache[$ipFile].Count
            $isCIDR = $lineCache[$ipFile].IsCIDR
            $threads = [Math]::Ceiling($lineCount / 20)
        }
    }
    Write-Host "  [$n] " -NoNewline -ForegroundColor Yellow
    Write-Host $profiles[$i].name -NoNewline -ForegroundColor White
    if ($threads) {
        if ($isCIDR) { Write-Host "  (-n $threads / $lineCount 个IP)" -NoNewline -ForegroundColor DarkCyan }
        else { Write-Host "  (-n $threads / $lineCount 行)" -NoNewline -ForegroundColor DarkCyan }
    }
    Write-Host "  $($profiles[$i].desc)" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  [0] Exit" -ForegroundColor DarkGray
Write-Host "  [H] 历史IP全量重测" -ForegroundColor Magenta
Write-Host "  [U] 刷新菜单[1][3][4]IP池 (历史IP → /22/23/24展开)" -ForegroundColor Cyan
Write-Host "  [R] 查看历史数据统计" -ForegroundColor Yellow
Write-Host ""

$choice = Read-Host "Choose [0-$($profiles.Count)] or H/U/R"

if ($choice -eq "0") { break }
if ($choice -eq "") {
    if ($lastChoice) { $choice = $lastChoice; Write-Host "  (repeat: $choice)" -ForegroundColor DarkGray }
    else { Write-Host "  首次使用，请输入 [1-$($profiles.Count)] 或 H/U/R 选择" -ForegroundColor Yellow; continue }
}

if ($choice -eq "U" -or $choice -eq "u") {
    $historyCsv = "$PSScriptRoot\ip_history.csv"
    if (-not (Test-Path $historyCsv)) {
        Write-Host "ERROR: ip_history.csv not found" -ForegroundColor Red
        pause; continue
    }

    Write-Host ""
    Write-Host "=== 历史IP → 多粒度网段展开 ===" -ForegroundColor Cyan

    $rawIps = Get-Content $historyCsv -Encoding UTF8 | Select-Object -Skip 1 |
        ForEach-Object { ($_ -split ",")[0] } | Sort-Object -Unique

    Write-Host "  历史唯一IP: $($rawIps.Count) 个" -ForegroundColor DarkGray

    $masks = @(
        @{ Mask=252; Size=1024; Name="22"; OutFile="ippools\ip_best.txt" }
        @{ Mask=254; Size=512;  Name="23"; OutFile="ippools\ip_expanded_23.txt" }
        @{ Mask=255; Size=256;  Name="24"; OutFile="ippools\ip_history_expanded.txt" }
    )

    foreach ($m in $masks) {
        $subnets = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($ip in $rawIps) {
            $oct = $ip -split '\.'
            $o3 = [int]$oct[2] -band $m.Mask
            [void]$subnets.Add("$($oct[0]).$($oct[1]).$o3.0")
        }
        Write-Host "  /$($m.Name): $($subnets.Count) 网段" -ForegroundColor DarkGray

        $allIps = [System.Collections.Generic.List[string]]::new()
        foreach ($net in $subnets) {
            $parts = $net -split '\.'
            $base = ([int]$parts[0] -shl 24) -bor ([int]$parts[1] -shl 16) -bor ([int]$parts[2] -shl 8)
            for ($i = 0; $i -lt $m.Size; $i++) {
                $v = $base + $i
                [void]$allIps.Add("$((($v -shr 24) -band 255)).$((($v -shr 16) -band 255)).$((($v -shr 8) -band 255)).$(($v -band 255))")
            }
        }

        $outPath = "$PSScriptRoot\$($m.OutFile)"
        [System.IO.File]::WriteAllLines($outPath, $allIps, [System.Text.UTF8Encoding]::new($false))
        Write-Host "    写入 $($allIps.Count) 个IP → $($m.OutFile)" -ForegroundColor Green
    }
    Write-Host ""
    $lastChoice = "U"
    continue
}

if ($choice -eq "R" -or $choice -eq "r") {
    $historyCsv = "$PSScriptRoot\ip_history.csv"
    if (-not (Test-Path $historyCsv)) {
        Write-Host "ERROR: ip_history.csv not found" -ForegroundColor Red
        pause; continue
    }

    Write-Host ""
    Write-Host "=== 历史数据统计 ===" -ForegroundColor Yellow

    $data = Get-Content $historyCsv -Encoding UTF8 | Select-Object -Skip 1 |
        ForEach-Object {
            $cols = $_ -split ","
            [PSCustomObject]@{
                IP    = $cols[0]
                Speed = [double]$cols[2]
                Loss  = [double]$cols[3]
                Time  = try { [datetime]$cols[4].Trim() } catch { $null }
            }
        }

    $total = $data.Count
    $uniqueIPs = ($data | Group-Object IP).Count
    $maxSpeed = ($data | Measure-Object Speed -Maximum).Maximum
    $avgSpeed = ($data | Measure-Object Speed -Average).Average
    $minLoss = ($data | Measure-Object Loss -Minimum).Minimum
    $avgLoss = ($data | Measure-Object Loss -Average).Average
    $earliest = ($data | Sort-Object Time | Select-Object -First 1).Time.ToString("yyyy-MM-dd HH:mm")
    $latest   = ($data | Sort-Object Time -Descending | Select-Object -First 1).Time.ToString("yyyy-MM-dd HH:mm")

    Write-Host "  总记录数: $total" -ForegroundColor White
    Write-Host "  唯一IP数: $uniqueIPs" -ForegroundColor White
    Write-Host "  时间范围: $earliest → $latest" -ForegroundColor DarkGray
    Write-Host "  最大速度: $([math]::Round($maxSpeed,1)) MB/s" -ForegroundColor Green
    Write-Host "  平均速度: $([math]::Round($avgSpeed,1)) MB/s" -ForegroundColor DarkGray
    Write-Host "  最低丢包: $([math]::Round($minLoss,2)) %" -ForegroundColor Green
    Write-Host "  平均丢包: $([math]::Round($avgLoss,2)) %" -ForegroundColor DarkGray

    $topIPs = $data | Group-Object IP | ForEach-Object {
        [PSCustomObject]@{IP=$_.Name; Count=$_.Count; AvgSpeed=[math]::Round(($_.Group | Measure-Object Speed -Average).Average,1); AvgLoss=[math]::Round(($_.Group | Measure-Object Loss -Average).Average,2)}
    } | Sort-Object AvgSpeed -Descending | Select-Object -First 10

    Write-Host ""
    Write-Host "  Top 10 IP (历史均值):" -ForegroundColor Cyan
    $topIPs | ForEach-Object {
        Write-Host "    $($_.IP)  均值 $($_.AvgSpeed) MB/s  出现 $($_.Count) 次  均丢包 $($_.AvgLoss)%" -ForegroundColor Gray
    }
    Write-Host ""
    $lastChoice = "R"
    pause; continue
}

if ($choice -eq "H" -or $choice -eq "h") {
    $historyCsv = "$PSScriptRoot\ip_history.csv"
    if (-not (Test-Path $historyCsv)) {
        Write-Host "ERROR: ip_history.csv not found. Run a normal test first." -ForegroundColor Red
        pause; continue
    }

    Write-Host ""
    Write-Host "=== 历史IP全量重测 ===" -ForegroundColor Magenta
    Write-Host "  步骤1: 提取所有历史唯一IP..." -ForegroundColor DarkGray

    $raw = Get-Content $historyCsv -Encoding UTF8 | Select-Object -Skip 1 |
        ForEach-Object { $cols = $_ -split ","; [PSCustomObject]@{IP=$cols[0]; Speed=[double]$cols[2]} } |
        Group-Object IP |
        ForEach-Object { [PSCustomObject]@{IP=$_.Name; Count=$_.Count; AvgSpeed=[math]::Round(($_.Group | Measure-Object Speed -Average).Average, 1)} } |
        Sort-Object AvgSpeed -Descending

    Write-Host "  历史唯一IP: $($raw.Count) 个，全部纳入测速池" -ForegroundColor DarkGray
    Write-Host "  Top 5 预览:" -ForegroundColor DarkGray
    $raw | Select-Object -First 5 | ForEach-Object {
        Write-Host "    $($_.IP)  (均值 $($_.AvgSpeed) MB/s, 出现$($_.Count)次)" -ForegroundColor Gray
    }

    $tempFile = "$PSScriptRoot\ippools\ip_history_all.txt"
    [System.IO.File]::WriteAllLines($tempFile, [string[]]$raw.IP, [System.Text.UTF8Encoding]::new($false))

    $threads = $raw.Count
    Write-Host "  步骤2: 对 $($raw.Count) 个IP全量测速 (-n $threads 线程)..." -ForegroundColor DarkGray

    Push-Location $PSScriptRoot
    $exeArgs = "-n $threads -f ippools\ip_history_all.txt -o output\result.csv $hArgs".Split(" ")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    "`n" | & .\bin\CloudflareST.exe $exeArgs
    $sw.Stop()
    Write-Host "  耗时: $([math]::Round($sw.Elapsed.TotalSeconds,0))s" -ForegroundColor DarkGray

    if (Test-Path "$PSScriptRoot\output\result.csv") {
        Write-Host ""
        Write-Host "Top 10 结果:" -ForegroundColor Green
        Get-Content "$PSScriptRoot\output\result.csv" -Encoding UTF8 | Select-Object -Skip 1 |
            Select-Object -First 10 | ForEach-Object {
                $cols = $_ -split ","
                Write-Host "  $($cols[0])  速度$($cols[5])MB/s  延迟$($cols[4])ms  丢包$($cols[3])%" -ForegroundColor White
            }
        Write-Host ""

        $confirm = Read-Host "  满意本次结果? [Y/n]（默认Y）"
        if ($confirm -eq "n" -or $confirm -eq "N") {
            Write-Host "  已放弃本次结果" -ForegroundColor Yellow
        } else {
            # H 选项不写入 ip_history.csv，仅更新 hosts + 订阅
            $uaPath = "$PSScriptRoot\update-hosts-asian.ps1"
            if (Test-Path $uaPath) {
                Start-Process powershell -Wait -NoNewWindow -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$uaPath`" -Scheduled -SkipTest -NoHistory"
            }
        }
    } else {
        Write-Host "ERROR: no result.csv output" -ForegroundColor Red
    }
    Pop-Location
    Write-Host ""
    $lastChoice = "H"
    continue
}

$idx = [int]$choice - 1
if ($idx -lt 0 -or $idx -ge $profiles.Count) {
    Write-Host "Invalid choice" -ForegroundColor Red
    pause; continue
}

$profile = $profiles[$idx]

# 动态 -n：行数/20 向上取整（CIDR 段按展开后 IP 数计算）
if ($profile.args -match "-f\s+(\S+)") {
    $ipFile = Join-Path $PSScriptRoot $Matches[1]
    if (Test-Path $ipFile) {
        $fw = (Get-Item $ipFile).LastWriteTime
        if (-not $lineCache[$ipFile] -or $lineCache[$ipFile].Time -ne $fw) {
            $poolInfo = Get-IPPoolCount $ipFile
            $lineCache[$ipFile] = @{ Count = $poolInfo.Count; IsCIDR = $poolInfo.IsCIDR; Time = $fw }
        }
        $lineCount = $lineCache[$ipFile].Count
        $dynN = [Math]::Ceiling($lineCount / 20)
        $dynArgs = $profile.args -replace '-n \d+', "-n $dynN"
    } else {
        $dynArgs = $profile.args
    }
} else {
    $dynArgs = $profile.args
}

$label = if ($lineCache[$ipFile].IsCIDR) { "个IP" } else { "行" }
Write-Host ""
Write-Host "Running: $($profile.name) (-n $dynN / $lineCount $label)" -ForegroundColor Yellow
Write-Host "  File : $($profile.file)" -ForegroundColor DarkYellow
Write-Host "  Args : $dynArgs" -ForegroundColor DarkYellow
Write-Host ""

Push-Location $PSScriptRoot
$exeArgs = $dynArgs -split " "
$sw = [System.Diagnostics.Stopwatch]::StartNew()
"`n" | & .\bin\CloudflareST.exe $exeArgs
$sw.Stop()
Write-Host "  耗时: $([math]::Round($sw.Elapsed.TotalSeconds,0))s" -ForegroundColor DarkGray

if (Test-Path "$PSScriptRoot\output\result.csv") {
    Write-Host ""
    Write-Host "Test complete. output\result.csv generated." -ForegroundColor Green
    Write-Host ""

    $confirm = Read-Host "  满意本次结果? [Y/n]（默认Y）"
    if ($confirm -eq "n" -or $confirm -eq "N") {
        Write-Host "  已放弃本次结果" -ForegroundColor Yellow
    } else {
        if ($FeedHistory) {
            Submit-HistoryAndSubscription
        }
    }
} else {
    Write-Host "ERROR: no result.csv output" -ForegroundColor Red
}

Pop-Location

Write-Host ""
$lastChoice = $choice
continue
}