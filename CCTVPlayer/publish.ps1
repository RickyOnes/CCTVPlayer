# 央视频定制版 打包发布脚本
# 生成自包含部署包，无需 .NET SDK 即可在 Windows x64 上运行

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PublishDir = "$Root\publish"
$PackageDir = "$Root\CCTVPlayer-release"
$PackageZip = "$Root\..\CCTVPlayer-release.zip"

Write-Host "=== 1. 自包含发布 (含 .NET 运行时) ===" -ForegroundColor Cyan
Remove-Item -Recurse -Force $PublishDir -ErrorAction Ignore
Push-Location $Root
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -o $PublishDir
Pop-Location
Write-Host "  OK: $PublishDir" -ForegroundColor Green

Write-Host ""
Write-Host "=== 2. 复制 Go 代理 + 缓存 ===" -ForegroundColor Cyan
$BinDir = "$Root\bin\Debug\net10.0-windows\win-x64"
Remove-Item -Recurse -Force $PackageDir -ErrorAction Ignore
New-Item -ItemType Directory -Force $PackageDir | Out-Null

# 复制发布文件
Copy-Item -Recurse "$PublishDir\*" $PackageDir

# 复制 cctv-proxy.exe (Go 编译产物)
Copy-Item "$BinDir\cctv-proxy.exe" $PackageDir

# 复制 sapi_cache (CMG 脚本缓存)
if (Test-Path "$BinDir\sapi_cache") {
    Copy-Item -Recurse "$BinDir\sapi_cache" "$PackageDir\sapi_cache"
}

# 复制 player.served.html (WebResourceRequested 拦截用)
if (Test-Path "$BinDir\player.served.html") {
    Copy-Item "$BinDir\player.served.html" $PackageDir
}

# 清理调试文件
Remove-Item "$PackageDir\*.pdb" -ErrorAction Ignore
Remove-Item "$PackageDir\*.log" -ErrorAction Ignore
Remove-Item "$PackageDir\sapi_cache\*.orig" -ErrorAction Ignore

Write-Host "  OK: $PackageDir" -ForegroundColor Green

Write-Host ""
Write-Host "=== 3. 打包 ZIP ===" -ForegroundColor Cyan
Remove-Item $PackageZip -ErrorAction Ignore
Compress-Archive -Path $PackageDir -DestinationPath $PackageZip

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "  分发包: $PackageZip"
Write-Host "  安装: 解压到任意目录, 运行 CCTVPlayer.exe"
Write-Host "  要求: Windows 10+ x64, WebView2 Runtime (系统自带或自动安装)"

$size = (Get-Item $PackageZip).Length / 1MB
Write-Host "  大小: $([math]::Round($size, 1)) MB"
