# CloudflareST Visual Test Menu
param([switch]$FeedHistory)

$configFile = "$PSScriptRoot\config\profiles.json"
if (-not (Test-Path $configFile)) {
    Write-Host "ERROR: config\profiles.json not found" -ForegroundColor Red
    pause; exit 1
}

$profiles = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
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
        Write-Host "Subscription updated." -ForegroundColor Green
    } else {
        Write-Host "WARNING: update-hosts-asian.ps1 not found" -ForegroundColor Red
    }
}

while ($true) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  CloudflareST Test Menu" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

for ($i = 0; $i -lt $profiles.Count; $i++) {
    $n = $i + 1
    $argsStr = $profiles[$i].args
    $threads = ""
    if ($argsStr -match "-n\s+(\d+)") { $threads = $Matches[1] }
    Write-Host "  [$n] " -NoNewline -ForegroundColor Yellow
    Write-Host $profiles[$i].name -NoNewline -ForegroundColor White
    if ($threads) { Write-Host "  (-n $threads)" -NoNewline -ForegroundColor DarkCyan }
    Write-Host "  $($profiles[$i].desc)" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  [0] Exit" -ForegroundColor DarkGray
Write-Host "  [H] 历史IP全量重测" -ForegroundColor Magenta
Write-Host ""

$choice = Read-Host "Choose [0-$($profiles.Count)] or H"

if ($choice -eq "0" -or $choice -eq "") { break }

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
    $raw.IP | Set-Content $tempFile -Encoding UTF8

    $threads = [Math]::Ceiling(($raw.Count + 1) / 10)
    Write-Host "  步骤2: 对 $($raw.Count) 个IP全量测速 (-n $threads 线程)..." -ForegroundColor DarkGray

    Push-Location $PSScriptRoot
    $exeArgs = "-n $threads -f ippools\ip_history_all.txt -url https://test.hondac.top/10mb.bin -httping -cfcolo HKG,NRT,KIX,ICN,TPE,SIN -sl 1 -dn 10 -p 15".Split(" ")
    & .\bin\CloudflareST.exe $exeArgs

    if (Test-Path "$PSScriptRoot\output\result.csv") {
        Write-Host ""
        Write-Host "Top 10 结果:" -ForegroundColor Green
        Get-Content "$PSScriptRoot\output\result.csv" -Encoding UTF8 | Select-Object -Skip 1 |
            Select-Object -First 10 | ForEach-Object {
                $cols = $_ -split ","
                Write-Host "  $($cols[0])  速度$($cols[5])MB/s  延迟$($cols[4])ms  丢包$($cols[3])%" -ForegroundColor White
            }
        Write-Host ""

        # H 选项不写入 ip_history.csv，仅更新 hosts + 订阅
        $uaPath = "$PSScriptRoot\update-hosts-asian.ps1"
        if (Test-Path $uaPath) {
            Start-Process powershell -Wait -NoNewWindow -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$uaPath`" -Scheduled -SkipTest -NoHistory"
            Write-Host "Hosts + subscription updated." -ForegroundColor Green
        }
    } else {
        Write-Host "ERROR: no result.csv output" -ForegroundColor Red
    }
    Pop-Location
    Write-Host ""
    Write-Host "H option done, returning to menu..." -ForegroundColor Magenta
    Start-Sleep -Seconds 2
    continue
}

$idx = [int]$choice - 1
if ($idx -lt 0 -or $idx -ge $profiles.Count) {
    Write-Host "Invalid choice" -ForegroundColor Red
    pause; continue
}

$profile = $profiles[$idx]
Write-Host ""
Write-Host "Running: $($profile.name)" -ForegroundColor Yellow
Write-Host "  File : $($profile.file)" -ForegroundColor DarkYellow
Write-Host "  Args : $($profile.args)" -ForegroundColor DarkYellow
Write-Host ""

Push-Location $PSScriptRoot
$exeArgs = $profile.args -split " "
& .\bin\CloudflareST.exe $exeArgs

if (Test-Path "$PSScriptRoot\output\result.csv") {
    Write-Host ""
    Write-Host "Test complete. output\result.csv generated." -ForegroundColor Green

    if ($FeedHistory) {
        Submit-HistoryAndSubscription
    }
} else {
    Write-Host "ERROR: no result.csv output" -ForegroundColor Red
}

Pop-Location

Write-Host ""
Write-Host "Test done, returning to menu..." -ForegroundColor Green
Start-Sleep -Seconds 2
continue
}