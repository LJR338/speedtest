$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$subFile = Join-Path $root "优选订阅.txt"
$port = 18081

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
$listener.Start()

Write-Host "订阅服务已启动: http://127.0.0.1:$port/"
Write-Host "按 Ctrl+C 停止"
Write-Host ""

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $sub = Get-Content $subFile -Raw -Encoding UTF8
    $buf = [System.Text.Encoding]::UTF8.GetBytes($sub)
    $ctx.Response.ContentType = "text/plain; charset=utf-8"
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.Close()
    Write-Host "$(Get-Date -Format 'HH:mm:ss') 响应请求"
}
