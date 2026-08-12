# 单文件精简发布脚本
# 参考发布结构: CCTVPlayer-publish.rar (sapi_cache + CCTVPlayer.exe + player.html + cctv-proxy.exe + gen_yspticket.* + ts_module_body.js + *.wasm)
$ErrorActionPreference = "Stop"

$projDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir  = Split-Path -Parent $projDir
$proxyDir = Join-Path $rootDir "cctv-proxy"

$publishDir = Join-Path $projDir "publish"              # dotnet publish 临时输出
$releaseDir = Join-Path $projDir "CCTVPlayer-release"   # 最终发布目录
$zipFile    = Join-Path $rootDir "CCTVPlayer-release.zip"

# 1) 清理旧目录
Remove-Item -Recurse -Force $publishDir -ErrorAction Ignore
Remove-Item -Force $zipFile -ErrorAction Ignore
New-Item -ItemType Directory -Force $releaseDir | Out-Null

# 2) 单文件发布 .NET 程序 (含 WebView2 Runtime 检测, 系统自带则不打包)
Write-Host "Publishing single-file self-contained app..."
dotnet publish "$projDir/CCTVPlayer.csproj" `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:PublishReadyToRun=false `
    -p:PublishTrimmed=false `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -o $publishDir

# 3) 复制主程序
Copy-Item (Join-Path $publishDir "CCTVPlayer.exe") (Join-Path $releaseDir "CCTVPlayer.exe") -Force

# 4) 复制 Go 代理 (已编译好的最新版)
$proxyExe = Join-Path $proxyDir "cctv-proxy.exe"
if (-not (Test-Path $proxyExe)) {
    throw "cctv-proxy.exe not found at $proxyExe. Run 'go build' in cctv-proxy first."
}
Copy-Item $proxyExe (Join-Path $releaseDir "cctv-proxy.exe") -Force

# 5) 复制前端资源与 wasm (按项目实际文件名)
$assets = @(
    "player.html",
    "player.served.html",
    "gen_yspticket.cjs",
    "ts_module_body.js",
    "RJq7sO71JF.wasm",
    "keygen_bg.wasm"
)
foreach ($f in $assets) {
    $src = Join-Path $projDir $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $releaseDir $f) -Force
    }
}

# 6) 复制 sapi_cache 缓存目录
$cacheSrc = Join-Path $rootDir "sapi_cache"
if (Test-Path $cacheSrc) {
    Copy-Item -Recurse $cacheSrc (Join-Path $releaseDir "sapi_cache") -Force
}

# 7) 清理 publish 临时目录 (不再需要)
Remove-Item -Recurse -Force $publishDir -ErrorAction Ignore

# 8) 生成 ZIP
Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipFile -Force

# 9) 删除中间发布目录, 只保留 ZIP 分发包 (避免 bin/Release + CCTVPlayer-release 重复)
Remove-Item -Recurse -Force $releaseDir -ErrorAction Ignore

$size = [math]::Round((Get-Item $zipFile).Length / 1MB, 1)
Write-Host ""
Write-Host "ZIP 发布完成: $zipFile ($size MB)"
Write-Host ""
Write-Host "运行: 解压 ZIP 到任意目录, 双击 CCTVPlayer.exe"
Write-Host "要求: Windows 10+ x64 (WebView2 系统自带)"
