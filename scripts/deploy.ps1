#!/usr/bin/env powershell
<#
.SYNOPSIS
  在本地构建 Fuwari，并把静态产物部署到服务器。

.DESCRIPTION
  重要：本脚本【不会碰你本地的 dist/】。
  它把部署用的产物构建到独立目录 deploy-dist/，你继续用 pnpm build + 本地 nginx 调试 dist/ 即可，
  两边互不影响。

  服务器（961MB 内存）不跑 astro build，构建始终在本地完成；服务器只用 nginx 托管
  /srv/fuwari/dist 下的静态文件。

  脚本流程：
    1. SITE_URL=<站点地址> astro build --outDir deploy-dist   （deploy-dist/ 已在 .gitignore）
    2. pagefind --site deploy-dist
    3. 打包 deploy-dist 的内容 -> 系统临时目录
    4. scp 上传到服务器 /tmp
    5. 远端解包到 $WebRoot/dist，修正权限并清理

  静态文件就地替换，nginx 直接读磁盘，因此不需要 reload。

  服务器地址不写死在仓库里（本仓库是公开的），从环境变量读取：
    setx FUWARI_DEPLOY_HOST "nc@1.2.3.4"                       # 必填
    setx FUWARI_DEPLOY_KEY  "%USERPROFILE%\.ssh\fuwari_deploy" # 可选
    setx FUWARI_SITE_URL    "https://blog.example.com/"        # 可选

.EXAMPLE
  powershell -File scripts\deploy.ps1
.EXAMPLE
  powershell -File scripts\deploy.ps1 -BuildOnly      # 只构建 deploy-dist，不上传
.EXAMPLE
  powershell -File scripts\deploy.ps1 -Target nc@1.2.3.4
#>
[CmdletBinding()]
param(
	[string]$Target = $env:FUWARI_DEPLOY_HOST,

	[string]$KeyFile = $(if ($env:FUWARI_DEPLOY_KEY) { $env:FUWARI_DEPLOY_KEY } else { "$env:USERPROFILE\.ssh\fuwari_deploy" }),

	[string]$SiteUrl = $(if ($env:FUWARI_SITE_URL) { $env:FUWARI_SITE_URL } else { "https://blog.anylaze.ccwu.cc/" }),

	# 远端目录，产物会放在 $WebRoot/dist
	[string]$WebRoot = "/srv/fuwari",

	# 部署产物的本地构建目录（相对于仓库根）
	[string]$BuildDir = "deploy-dist",

	# 只本地构建，不上传
	[switch]$BuildOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repoRoot $BuildDir
$tarball = Join-Path $env:TEMP "fuwari-dist-$(Get-Date -Format 'yyyyMMdd-HHmmss').tgz"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "!! $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $repoRoot "package.json"))) {
	Fail "找不到 $repoRoot\package.json，脚本必须在仓库内运行"
}

# ---------- 1. 构建到独立目录（不动 dist/）----------
Step "构建到 $BuildDir（SITE_URL=$SiteUrl）"
Push-Location $repoRoot
try {
	Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
	$env:SITE_URL = $SiteUrl
	& pnpm exec astro build --outDir $BuildDir
	if ($LASTEXITCODE -ne 0) { Fail "astro build 失败（exit $LASTEXITCODE）" }

	& pnpm exec pagefind --site $BuildDir
	if ($LASTEXITCODE -ne 0) { Fail "pagefind 失败（exit $LASTEXITCODE）" }
} finally {
	Remove-Item Env:\SITE_URL -ErrorAction SilentlyContinue
	Pop-Location
}

if (-not (Test-Path (Join-Path $outDir "index.html"))) { Fail "$BuildDir\index.html 不存在，构建异常" }

# 校验产物里的域名，避免误把本地 127.0.0.1 的构建推上去
$sitemap = Join-Path $outDir "sitemap-0.xml"
if (Test-Path $sitemap) {
	$firstLoc = [regex]::Match((Get-Content $sitemap -Raw), "<loc>(.*?)</loc>").Groups[1].Value
	Step "产物首个 URL: $firstLoc"
	if ($firstLoc -notlike "$SiteUrl*") { Fail "sitemap 地址与 SITE_URL 不一致，已中止部署" }
}

# 顺手确认没有污染本地调试用的 dist/
$localSitemap = Join-Path $repoRoot "dist\sitemap-0.xml"
if (Test-Path $localSitemap) {
	$localLoc = [regex]::Match((Get-Content $localSitemap -Raw), "<loc>(.*?)</loc>").Groups[1].Value
	Step "本地 dist/ 未被改动，首个 URL 仍是: $localLoc"
}

if ($BuildOnly) { Step "仅构建完成（-BuildOnly），产物在 $BuildDir"; exit 0 }

# ---------- 2. 打包 ----------
if (-not $Target) { Fail "未指定目标服务器。请设置环境变量 FUWARI_DEPLOY_HOST，或用 -Target user@host" }
if (-not (Test-Path $KeyFile)) { Fail "私钥不存在: $KeyFile" }

Step "打包"
if (Test-Path $tarball) { Remove-Item $tarball -Force }
# 以 deploy-dist 为根打包，解包后直接就是站点文件
& tar -czf $tarball -C $outDir .
if ($LASTEXITCODE -ne 0) { Fail "tar 打包失败" }
Step ("包大小: {0} MB" -f [math]::Round((Get-Item $tarball).Length / 1MB, 2))

$sshOpts = @("-i", $KeyFile, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15")

# ---------- 3. 上传 ----------
Step "上传到 $Target"
& scp @sshOpts $tarball "${Target}:/tmp/fuwari-dist.tgz"
if ($LASTEXITCODE -ne 0) { Remove-Item $tarball -Force -ErrorAction SilentlyContinue; Fail "scp 上传失败" }

# ---------- 4. 远端解包 ----------
Step "远端解包到 $WebRoot/dist"
# 单引号 here-string：不做 PowerShell 插值，$(...) / $uri 等原样交给远端 bash
$remoteTemplate = @'
set -e
sudo mkdir -p __WEBROOT__/dist
sudo rm -rf __WEBROOT__/dist
sudo mkdir -p __WEBROOT__/dist
sudo tar -xzf /tmp/fuwari-dist.tgz -C __WEBROOT__/dist
sudo chown -R $(id -un):$(id -gn) __WEBROOT__/dist
sudo find __WEBROOT__/dist -type d -exec chmod 755 {} \;
sudo find __WEBROOT__/dist -type f -exec chmod 644 {} \;
rm -f /tmp/fuwari-dist.tgz
echo "--- 远端自检 ---"
ls -la __WEBROOT__/dist | head -6
curl -s -o /dev/null -w "nginx 本机 200 检查: %{http_code}\n" -H "Host: __HOST__" http://127.0.0.1/
df -h / | tail -1
'@
$remote = $remoteTemplate.Replace("__WEBROOT__", $WebRoot).Replace("__HOST__", ([uri]$SiteUrl).Host)

$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
& ssh @sshOpts $Target "echo $encoded | base64 -d | bash"
$deployExit = $LASTEXITCODE

Remove-Item $tarball -Force -ErrorAction SilentlyContinue
if ($deployExit -ne 0) { Fail "远端部署失败（exit $deployExit）" }

Step "部署完成 -> $SiteUrl"
