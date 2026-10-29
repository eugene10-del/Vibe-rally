# Eugene Rings · 시연용 로컬 AI 도우미
# 이 PC에 로그인된 Claude Code(claude 명령)로 질문에 답합니다. API 키가 필요 없고, 앱 자료에 없는 질문은 웹 검색으로 찾아 요약합니다.
# 실행: 프로젝트 폴더에서  powershell -NoProfile -ExecutionPolicy Bypass -File server\local-helper.ps1   (또는 시연-AI도우미-시작.cmd 더블클릭)
# 화면: http://localhost:8000   /   GitHub Pages 주소 뒤에 ?api=http://localhost:8000 을 붙여도 이 도우미로 답합니다.
# 시연용입니다. 한 번에 한 질문씩 처리하고, 질문마다 Claude Code를 새로 띄워 5~30초가 걸립니다.
param([int]$Port = 8000, [string]$Model = "", [switch]$Open)
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$utf8 = New-Object Text.UTF8Encoding $false
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeCmd) { Write-Host "claude 명령을 찾지 못했어요. Claude Code를 설치하고 로그인한 뒤 다시 실행하세요."; exit 1 }
$claude = $claudeCmd.Source
# Claude Code 터미널 안에서 실행해도 되도록 중첩 실행 표시를 지움
Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue
Remove-Item Env:CLAUDE_CODE_ENTRYPOINT -ErrorAction SilentlyContinue
$tmp = Join-Path $env:TEMP "eugene-rings-helper"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$types = @{ ".html" = "text/html; charset=utf-8"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"; ".png" = "image/png"; ".webp" = "image/webp"; ".svg" = "image/svg+xml"; ".ico" = "image/x-icon" }

function Send-Bytes($res, $bytes, $type, $status) {
  $res.StatusCode = $status; $res.ContentType = $type; $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.Close()
}
function Send-Json($res, $obj, $status) { Send-Bytes $res $utf8.GetBytes((ConvertTo-Json -InputObject $obj -Depth 8 -Compress)) "application/json; charset=utf-8" $status }
function Add-Cors($res) {
  $res.Headers["Access-Control-Allow-Origin"] = "*"
  $res.Headers["Access-Control-Allow-Headers"] = "content-type"
  $res.Headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  $res.Headers["Access-Control-Allow-Private-Network"] = "true"
}
# 질문 하나를 Claude Code에 보내고 답 글만 돌려줌. 웹 검색이 필요하면 WebSearch·WebFetch 도구를, 이미지가 있으면 Read 도구를 허용
function Invoke-Claude([string]$prompt, [bool]$web, [string[]]$imagePaths) {
  $tools = @()
  if ($web) { $tools += "WebSearch"; $tools += "WebFetch" }
  if ($imagePaths.Count -gt 0) { $tools += "Read" }
  $argv = @("-p", "--output-format", "json", "--max-turns", "6", "--no-session-persistence")
  if ($tools.Count -gt 0) { $argv += "--allowedTools"; $argv += ('"' + ($tools -join ",") + '"') }
  if ($Model) { $argv += "--model"; $argv += $Model }
  $id = [Guid]::NewGuid().ToString("N")
  $pf = Join-Path $tmp "p-$id.txt"; $of = Join-Path $tmp "o-$id.txt"; $ef = Join-Path $tmp "e-$id.txt"
  [IO.File]::WriteAllText($pf, $prompt, $utf8)
  $p = Start-Process -FilePath $claude -ArgumentList ($argv -join " ") -WorkingDirectory $tmp -RedirectStandardInput $pf -RedirectStandardOutput $of -RedirectStandardError $ef -NoNewWindow -PassThru
  if (-not $p.WaitForExit(150000)) { try { $p.Kill() } catch {}; throw "timeout" }
  $raw = [IO.File]::ReadAllText($of, $utf8)
  $err = [IO.File]::ReadAllText($ef, $utf8)
  Remove-Item $pf, $of, $ef -ErrorAction SilentlyContinue
  $s = $raw.IndexOf("{"); $e = $raw.LastIndexOf("}")
  if ($s -lt 0 -or $e -le $s) { throw ("claude 응답 없음: " + ($raw + $err).Trim().Substring(0, [Math]::Min(300, ($raw + $err).Trim().Length))) }
  $r = $raw.Substring($s, $e - $s + 1) | ConvertFrom-Json
  if ($r.is_error -or -not $r.result) { throw ("claude 오류: " + $r.subtype) }
  return [string]$r.result
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch { Write-Host "포트 $Port 을 열지 못했어요: $($_.Exception.Message)"; exit 1 }
Write-Host "Eugene Rings AI 도우미 실행 중 → http://localhost:$Port   (끄려면 이 창에서 Ctrl+C)"
Write-Host "Claude Code: $claude"
if ($Open) { Start-Process "http://localhost:$Port/" }
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext(); $req = $ctx.Request; $res = $ctx.Response
    Add-Cors $res
    try {
      $path = $req.Url.AbsolutePath
      if ($req.HttpMethod -eq "OPTIONS") { $res.StatusCode = 204; $res.Close(); continue }
      if ($path -eq "/api/health") { Send-Json $res @{ ok = $true; kind = "claude-code"; model = $(if ($Model) { $Model } else { "claude-code" }) } 200; continue }
      if ($path -eq "/api/ai" -and $req.HttpMethod -eq "POST") {
        $body = (New-Object IO.StreamReader($req.InputStream, $utf8)).ReadToEnd() | ConvertFrom-Json
        if ($body.input -is [string]) { $prompt = [string]$body.input }
        else { $prompt = "지금까지의 대화입니다. 마지막 고객 질문에 답하세요.`n" + (($body.input | ForEach-Object { "[" + $_.role + "] " + $_.content }) -join "`n") }
        $imgs = @()
        if ($body.images) {
          $i = 0
          foreach ($im in $body.images) {
            $i++; $ext = ".jpg"; if ($im.media_type -match "png") { $ext = ".png" } elseif ($im.media_type -match "webp") { $ext = ".webp" }
            $f = Join-Path $tmp "img-$i$ext"; [IO.File]::WriteAllBytes($f, [Convert]::FromBase64String($im.data)); $imgs += $f
          }
          $prompt = "먼저 Read 도구로 다음 이미지 파일을 읽은 뒤 답하세요: " + ($imgs -join ", ") + "`n`n" + $prompt
        }
        if ($body.json_mode) { $prompt += "`n`n답변은 JSON 값 하나로만 쓰세요. 다른 글은 쓰지 마세요." }
        $web = [bool]$body.web
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $text = Invoke-Claude $prompt $web $imgs
        Write-Host ("[{0}] {1}자 질문 → {2:n1}초{3}" -f (Get-Date -Format "HH:mm:ss"), $prompt.Length, $sw.Elapsed.TotalSeconds, $(if ($web) { " · 웹 검색" } else { "" }))
        $out = @{ text = $text; truncated = $false; sources = @() }
        if ($body.json_mode) {
          $j = $null
          try { $j = $text | ConvertFrom-Json } catch { $m = [regex]::Match($text, "[\[{][\s\S]*[\]}]"); if ($m.Success) { try { $j = $m.Value | ConvertFrom-Json } catch {} } }
          if ($null -eq $j) { Send-Json $res @{ code = "invalid_json"; text = $text } 422; continue }
          $out.json = $j
        }
        Send-Json $res $out 200; continue
      }
      # 화면 파일 (프로젝트 폴더 안의 html·이미지만, 서버 코드와 백업은 내보내지 않음)
      $rel = $path.TrimStart("/"); if (-not $rel) { $rel = "index.html" }
      $file = [IO.Path]::GetFullPath((Join-Path $root $rel))
      $ext = [IO.Path]::GetExtension($file).ToLower()
      $okDir = $file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and ($rel -notmatch "^(server|context|\.claude)([/\\]|$)")
      if ($okDir -and $types.ContainsKey($ext) -and (Test-Path $file)) { Send-Bytes $res ([IO.File]::ReadAllBytes($file)) $types[$ext] 200 }
      else { Send-Json $res @{ code = "not_found" } 404 }
    } catch {
      Write-Host ("오류: " + $_.Exception.Message)
      try { Send-Json $res @{ code = "upstream_error"; message = $_.Exception.Message } 502 } catch {}
    }
  }
} finally { $listener.Stop() }
