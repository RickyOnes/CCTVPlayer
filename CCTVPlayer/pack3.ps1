$pub = "D:\TV\CCTV\CCTVPlayer\publish"
$pkg = "D:\TV\CCTV\CCTVPlayer\CCTVPlayer-v2"
$zip = "D:\TV\CCTV\CCTVPlayer-v2.zip"

Remove-Item -Recurse -Force $pkg -ErrorAction Ignore
New-Item -ItemType Directory -Force $pkg | Out-Null
Copy-Item -Recurse "$pub\*" $pkg

# 清理多余的 xml 和语言文件夹(保留 zh-Hans)
Remove-Item "$pkg\*.xml" -ErrorAction Ignore
Get-ChildItem $pkg -Directory | Where-Object { $_.Name -match '^(cs|de|es|fr|it|ja|ko|pl|pt-BR|ru|tr|zh-Hant)$' } | Remove-Item -Recurse -Force

Remove-Item $zip -ErrorAction Ignore
Compress-Archive -Path $pkg -DestinationPath $zip
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "ZIP: $zip  ($size MB)"
Write-Host ""
Write-Host "运行: 解压到任意目录, 双击 CCTVPlayer.exe"
Write-Host "要求: Windows 10+ x64 (WebView2 系统自带)"
