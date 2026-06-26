$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$subFile    = Join-Path $root "优选订阅.txt"
$instantFile = Join-Path $root "即时订阅.txt"
$port = 18081

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

Write-Host "订阅服务已启动:"
Write-Host "  优选订阅: http://127.0.0.1:$port/"
Write-Host "  即时订阅: http://127.0.0.1:$port/instant"
Write-Host "按 Ctrl+C 停止"
Write-Host ""

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $path = $ctx.Request.Url.AbsolutePath.TrimStart('/').ToLower()
    
    if ($path -eq "instant") {
        $file = $instantFile
        $label = "即时订阅"
    } else {
        $file = $subFile
        $label = "优选订阅"
    }

    if (Test-Path $file) {
        $sub = Get-Content $file -Raw -Encoding UTF8
    } else {
        $sub = "subscription file not found"
    }
    
    $buf = [System.Text.Encoding]::UTF8.GetBytes($sub)
    $ctx.Response.ContentType = "text/plain; charset=utf-8"
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.Close()
    Write-Host "$(Get-Date -Format 'HH:mm:ss') /$path -> $label"
}
