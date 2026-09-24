<#
.SYNOPSIS
  Rebuilds the Appats Model Tracker (a local HTML page) from live sources.

.DESCRIPTION
  All sources are public; nothing is published anywhere.
    Artificial Analysis  models + API providers leaderboards   intelligence, cost per task, and the cost, token price and
                                                             tool calling of every host it lists
    OpenRouter           model list, per-model endpoints and    live token prices, EU regions and tool calling per host;
                         provider data policies                 whether each host trains on or keeps prompts
    OpenRouter EU        EU model list + per-model endpoints     which models run in the EU, on which host, at what price
    Cheaper Inference    markets page                            marketplace (reseller) prices
  Appats' requirements also come from three files in live_chart\ that the team keeps up to date:
    hosts.csv            each host's DPA (GDPR Art. 28) status and source; optional overrides for training, retention, EU-only
    languages.csv        which makers name Spanish and Catalan as supported languages
    appats_tests.csv     Appats' own Spanish and Catalan test results per model (pass or fail)
  Writes, in the project folder:
    d4_intelligence_vs_cost.html   the page (self-contained; open it in any browser, or send the file)
    d4_intelligence_vs_cost.png    image for the Google Doc, with the filters in $pngView (skip with -NoPng)
    live_chart\data.json           merged data set
    live_chart\summary.txt         model counts, provider pool, DPA coverage and today's trade-off curves, in plain text
  Nothing is replaced unless every required source parsed. Cheaper Inference and the OpenRouter data policies are optional.

.PARAMETER NoPng    Skip the PNG render.
.PARAMETER Open     Open the page in the default browser when done.
.PARAMETER Offline  Rebuild the page (and PNG) from the last live_chart\data.json without fetching anything.
.PARAMETER Public   Build the copy for the public link: hides our internal file paths and asks search engines not to list it.
.PARAMETER OutFile  Where to write the page instead of d4_intelligence_vs_cost.html (the GitHub job writes index.html).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\live_chart\refresh.ps1 -Open
.EXAMPLE
  .\live_chart\refresh.ps1 -NoPng -Public -OutFile index.html
#>
param([switch]$NoPng, [switch]$Open, [switch]$Offline, [switch]$Public, [string]$OutFile)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$here = $PSScriptRoot
$root = Split-Path $here -Parent
$utf8 = New-Object System.Text.UTF8Encoding $false
$inv = [Globalization.CultureInfo]::InvariantCulture

# OpenAI API models with EU data residency (developers.openai.com/api/docs/guides/your-data, checked 23 Sep 2026).
$openAIEU = @('GPT-6 Luna', 'GPT-6 Sol', 'GPT-5.6 Luna')
$maxSupersededAgeDays = 180
# Filters applied in the PNG, as the page's URL parameters: all=1 (every Appats requirement), or any of
# lang=named|tested, dpa=1, eu=1, notrain=1, noretain=1, tools=1. '' shows every model with no filter.
$pngView = 'all=1'
$tierWords = '(\s+(FAST|ULTRA|NVFP4|MXFP8|FP4|FP8|INT4|INT8|BF16|Turbo|Base, FP4|Base|AI Studio|Vertex))+$'
$tagRe = '\((FP4|FP8|MXFP8|NVFP4|BF16|INT4|INT8|FAST|ULTRA|Turbo|Base|Base, FP4|AI Studio|Vertex)\)|\s(AI Studio|Vertex|Base|FP8|BF16|FAST|Turbo)$'
# EU and EEA countries, where the GDPR applies directly.
$euCodes = @('AT', 'BE', 'BG', 'HR', 'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'GR', 'HU', 'IE', 'IT', 'LV', 'LT', 'LU', 'MT', 'NL', 'PL', 'PT', 'RO', 'SK', 'SI', 'ES', 'SE', 'IS', 'LI', 'NO')

# Different sources spell the same host differently; map them to one key so each host is listed once per model.
$alias = @{
  together = 'togetherai'; gmicloud = 'gmi'; friendli = 'friendliai'; moonshotai = 'kimi'; moonshot = 'kimi'
  xai = 'spacexai'; alibaba = 'alibabacloud'; azure = 'microsoftazure'; novitaai = 'novita'
  nebiusaistudio = 'nebius'; nebiustokenfactory = 'nebius'; liquid = 'liquidai'; mistralai = 'mistral'
  zhipu = 'zai'; googleaistudio = 'google'; googlevertex = 'google'; amazon = 'amazonbedrock'; bedrock = 'amazonbedrock'
}

if (-not ('RscScan' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class RscScan {
  // Every balanced JSON object in s that starts with the given prefix, e.g. {"slug":"
  public static List<string> Objects(string s, string prefix) {
    var found = new List<string>();
    int pos = 0;
    while (true) {
      int i = s.IndexOf(prefix, pos, StringComparison.Ordinal);
      if (i < 0) break;
      int depth = 0, j = i; bool inStr = false, esc = false;
      for (; j < s.Length; j++) {
        char c = s[j];
        if (inStr) { if (esc) esc = false; else if (c == '\\') esc = true; else if (c == '"') inStr = false; continue; }
        if (c == '"') inStr = true;
        else if (c == '{') depth++;
        else if (c == '}') { depth--; if (depth == 0) break; }
      }
      if (j < s.Length) found.Add(s.Substring(i, j - i + 1));
      pos = i + 1;
    }
    return found;
  }
}
'@
}

function Get-Page([string]$url) {
  (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Appats Model Tracker)' }).Content
}
function Get-Json([string]$url) { ConvertFrom-Json -InputObject (Get-Page $url) }

# Next.js pages ship their data as self.__next_f.push([1,"..."]) chunks; join the string parts.
function Get-RscText([string]$html) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($m in [regex]::Matches($html, '<script>self\.__next_f\.push\((\[[\s\S]*?\])\)</script>')) {
    try {
      $arr = ConvertFrom-Json -InputObject $m.Groups[1].Value
      if ($arr.Count -ge 2 -and $arr[1] -is [string]) { [void]$sb.Append($arr[1]) }
    } catch { }
  }
  $sb.ToString()
}

function Read-Config([string]$file) {
  $p = Join-Path $here $file
  if (Test-Path $p) { return , @(Import-Csv -Path $p -Encoding UTF8) }
  Write-Warning "live_chart\$file not found; the filters that use it will show no data."
  return , @()
}

# Order-free model key, so "OpenRouter: Claude Haiku 4.5", "claude-haiku-4-5" and "Claude 4.5 Haiku (high)" all match.
# Drops vendor prefixes, the "(reasoning level)" suffix and yymm stamps such as 2512; "3-8" becomes "3.8".
function Get-Key([string]$name) {
  $n = $name.ToLowerInvariant()
  $n = $n -replace '^[^:(]+:\s*', ''
  $n = $n -replace '\s*\(.*$', ''
  $n = [regex]::Replace($n, '(?<!\d)(\d)-(\d)(?!\d)', '$1.$2')
  $n = $n -replace '[-_/]', ' '
  $n = [regex]::Replace($n, '(?<=[a-z])(?=\d)|(?<=\d)(?=[a-z])', ' ')
  $t = @($n -split '\s+' | Where-Object { $_ -and ($_ -notmatch '^2[4-9](0[1-9]|1[0-2])$') })
  ($t | Sort-Object) -join ' '
}

function Get-RawKey([string]$p) { $p.ToLowerInvariant() -replace '[^a-z0-9]', '' }
function Get-ProvKey([string]$p) {
  $k = Get-RawKey ($p -replace $tierWords, '')
  if ($alias.ContainsKey($k)) { $alias[$k] } else { $k }
}

function Round3([double]$v) {
  if ($v -eq 0) { return 0 }
  [double]::Parse($v.ToString('G3', $inv), $inv)
}

# Live cost per task at another price: the reference cost scaled by the blended (3:1 input:output) price ratio.
function Get-Scaled($c, $refIn, $refOut, [double]$pin, [double]$pout) {
  if (-not ($refIn -gt 0 -and $refOut -gt 0)) { return $null }
  Round3 ([double]$c * (3 * $pin + $pout) / (3 * $refIn + $refOut))
}

# Sort [name, cost, ...] entries by cost with LINQ; the pipeline would wrap or unroll the inner arrays.
function Get-SortedByCost($list) {
  # Leading comma: without it a one-item result unrolls into that item's own fields.
  return , ([Linq.Enumerable]::ToArray([Linq.Enumerable]::OrderBy($list, [Func[object, double]] { param($p) if ($null -eq $p[1]) { [double]::MaxValue } else { [double]$p[1] } })))
}

$endpointCache = @{}
function Get-Endpoints([string]$base, [string]$id) {
  $ck = "$base|$id"
  if (-not $endpointCache.ContainsKey($ck)) {
    $eps = @()
    try { $eps = @((Get-Json "$base/api/v1/models/$id/endpoints").data.endpoints); Start-Sleep -Milliseconds 60 }
    catch { Write-Warning "No endpoint list for $id at $base" }
    $endpointCache[$ck] = $eps
  }
  return , $endpointCache[$ck]
}

$pagePath = $(if (-not $OutFile) { Join-Path $root 'd4_intelligence_vs_cost.html' }
  elseif ([IO.Path]::IsPathRooted($OutFile)) { $OutFile }
  else { Join-Path (Get-Location).Path $OutFile })

function Write-Page([string]$metaJson, [string]$dataJson) {
  $template = [IO.File]::ReadAllText((Join-Path $here 'template.html'), $utf8)
  if (-not $template.Contains('/*DATA*/[]/*END*/') -or -not $template.Contains('/*META*/{}/*END*/')) { throw 'Template markers /*DATA*/ or /*META*/ are missing.' }
  $page = $template.Replace('/*META*/{}/*END*/', "/*META*/$metaJson/*END*/").Replace('/*DATA*/[]/*END*/', "/*DATA*/$dataJson/*END*/")
  $page = $page.Replace('/*PUBLIC*/false/*END*/', $(if ($Public) { '/*PUBLIC*/true/*END*/' } else { '/*PUBLIC*/false/*END*/' }))
  $page = $page.Replace('<!--ROBOTS-->', $(if ($Public) { '<meta name="robots" content="noindex, nofollow">' } else { '' }))
  $dirOut = Split-Path $pagePath -Parent
  if ($dirOut -and -not (Test-Path $dirOut)) { [void](New-Item -ItemType Directory -Path $dirOut) }
  [IO.File]::WriteAllText($pagePath, $page, $utf8)
}

# Renders the page's export view (?export=1 plus $pngView) to the PNG with headless Edge. Returns a status line.
function Invoke-Png {
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $edge) { Write-Warning 'Microsoft Edge not found; PNG not rendered.'; return $null }
  $edgeProfile = Join-Path $env:TEMP 'appats-tracker-edge'
  $tmp = Join-Path $env:TEMP 'appats-tracker'
  $url = 'file:///' + ($pagePath -replace '\\', '/') + '?export=1' + $(if ($pngView) { "&$pngView" } else { '' })
  $common = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files', "--user-data-dir=$edgeProfile", '--virtual-time-budget=3000')
  Start-Process -FilePath $edge -ArgumentList ($common + @('--window-size=900,1400', '--dump-dom', "`"$url`"")) -RedirectStandardOutput "$tmp-dom.txt" -RedirectStandardError "$tmp-dom.err" -Wait -NoNewWindow
  $dom = [IO.File]::ReadAllText("$tmp-dom.txt")
  $h = $(if ($dom -match 'data-card-height="(\d+)"') { [int]$Matches[1] } else { 0 })
  if ($h -le 0) { Write-Warning 'The page did not finish rendering in Edge; PNG not updated.'; return $null }
  $png = Join-Path $root 'd4_intelligence_vs_cost.png'
  Start-Process -FilePath $edge -ArgumentList ($common + @('--force-device-scale-factor=2', "--window-size=900,$h", "--screenshot=`"$png`"", "`"$url`"")) -RedirectStandardOutput "$tmp-shot.txt" -RedirectStandardError "$tmp-shot.err" -Wait -NoNewWindow
  "PNG: $png"
}

if ($Offline) {
  $raw = [IO.File]::ReadAllText((Join-Path $here 'data.json'), $utf8)
  $mm = [regex]::Match($raw, '^\{"meta":(?<meta>.*),"models":(?<models>\[.*\])\}$', 'Singleline')
  if (-not $mm.Success) { throw 'live_chart\data.json is missing or not in the expected format; run once without -Offline.' }
  Write-Page $mm.Groups['meta'].Value $mm.Groups['models'].Value
  Write-Host 'Rebuilt the page from live_chart\data.json (nothing fetched). Changes to the .csv files need a full refresh.'
  if (-not $NoPng) { $msg = Invoke-Png; if ($msg) { Write-Host $msg } }
  if ($Open) { Start-Process $pagePath }
  return
}

# --- 1. Artificial Analysis: intelligence and cost per task ------------------------------------
Write-Host 'Artificial Analysis models...'
$rsc = Get-RscText (Get-Page 'https://artificialanalysis.ai/leaderboards/models')
if ($rsc.Length -lt 200000) { throw "Artificial Analysis page data looks incomplete ($($rsc.Length) chars); the site layout may have changed." }
$metrics = @{}
$release = @{}
foreach ($js in [RscScan]::Objects($rsc, '{"slug":"')) {
  $isMetric = $js.Contains('"modelCreatorName"') -and $js.Contains('"intelligenceIndex"')
  if (-not $isMetric -and -not $js.Contains('"releaseDate"')) { continue }
  try { $o = ConvertFrom-Json -InputObject $js } catch { continue }
  if (-not $o.slug) { continue }
  if ($isMetric) { if (-not $metrics.ContainsKey($o.slug)) { $metrics[$o.slug] = $o } }
  elseif (-not $release.ContainsKey($o.slug)) { $release[$o.slug] = $o.releaseDate }
}
if ($metrics.Count -lt 100) { throw "Only $($metrics.Count) models parsed from Artificial Analysis." }

# --- 2. Artificial Analysis: every host it lists, with exact cost per task where measured ------
Write-Host 'Artificial Analysis API providers...'
$provRsc = Get-RscText (Get-Page 'https://artificialanalysis.ai/leaderboards/providers')
$byModel = @{}
$seenEndpoint = @{}
foreach ($js in [RscScan]::Objects($provRsc, '{"id":"')) {
  if (-not ($js.Contains('"hostApiId"') -and $js.Contains('"pricing"'))) { continue }
  try { $o = ConvertFrom-Json -InputObject $js } catch { continue }
  if (-not $o.model.slug -or -not $o.host.name -or $seenEndpoint.ContainsKey($o.id)) { continue }
  $seenEndpoint[$o.id] = $true
  $tags = @([regex]::Matches([string]$o.label, $tagRe) | ForEach-Object { $_.Value.Trim() -replace '[()]', '' })
  $provider = (@([string]$o.host.name) + $tags) -join ' '
  $slug = [string]$o.model.slug
  if (-not $byModel.ContainsKey($slug)) { $byModel[$slug] = New-Object System.Collections.ArrayList }
  [void]$byModel[$slug].Add(@{ p = $provider; c = $o.pricing.costPerTask; pin = $o.pricing.price1mInputTokens; pout = $o.pricing.price1mOutputTokens; fc = $o.features.functionCalling })
}
if ($byModel.Count -lt 50) { throw "Only $($byModel.Count) models parsed from the providers leaderboard." }

# --- 3. OpenRouter: global and EU model lists, and every provider's data policy ---------------
Write-Host 'OpenRouter model lists and provider data policies...'
$orIdByKey = @{}
foreach ($e in (Get-Json 'https://openrouter.ai/api/v1/models').data) {
  if ($e.id -like '*:*') { continue }
  foreach ($k in @((Get-Key $e.name), (Get-Key ($e.id -replace '^[^/]+/', '')))) { if (-not $orIdByKey.ContainsKey($k)) { $orIdByKey[$k] = $e.id } }
}
if ($orIdByKey.Count -lt 100) { throw 'OpenRouter model list came back (nearly) empty.' }
$euByKey = @{}
foreach ($e in (Get-Json 'https://eu.openrouter.ai/api/v1/models').data) {
  if ($e.id -like '*:*') { continue }
  $k = Get-Key $e.name
  if (-not $euByKey.ContainsKey($k)) { $euByKey[$k] = $e }
}
if ($euByKey.Count -lt 5) { throw 'OpenRouter EU model list came back (nearly) empty.' }
$openAIKeys = @($openAIEU | ForEach-Object { Get-Key $_ })

# One entry per host: DPA (hosts.csv), training and retention (OpenRouter's data policy, or hosts.csv), headquarters and
# data centres (OpenRouter). Looked up by several spellings; the first registration of a key wins.
$hostInfo = @{}
function New-HostEntry([string]$name) {
  [ordered]@{ name = $name; dpa = ''; src = ''; note = ''; checked = ''; tr = $null; rt = $null; days = $null; hq = ''; dc = ''; euOnly = $false }
}
function Add-HostKey([string]$k, $entry) { if ($k -and -not $hostInfo.ContainsKey($k)) { $hostInfo[$k] = $entry } }
function Find-Host([string]$name) {
  foreach ($k in @((Get-RawKey $name), (Get-RawKey ($name -replace $tierWords, '')), (Get-ProvKey $name))) { if ($hostInfo.ContainsKey($k)) { return $hostInfo[$k] } }
  $null
}
try {
  $orDC = @{}
  foreach ($p in (Get-Json 'https://openrouter.ai/api/v1/providers').data) { $orDC[[string]$p.slug] = @($p.datacenters | Where-Object { $_ }) }
  $orHosts = New-Object System.Collections.ArrayList
  foreach ($p in (Get-Json 'https://openrouter.ai/api/frontend/v1/all-providers').data) {
    $e = New-HostEntry ([string]$p.displayName)
    if ($null -ne $p.dataPolicy) {
      $e.tr = $(if ($p.dataPolicy.training) { 1 } else { 0 })
      $e.rt = $(if ($p.dataPolicy.retainsPrompts) { 1 } else { 0 })
      $e.days = $p.dataPolicy.retentionDays
    }
    $dcs = @($orDC[[string]$p.slug])
    $e.hq = [string]$p.headquarters
    $e.dc = $dcs -join ', '
    $e.euOnly = ($dcs.Count -gt 0 -and @($dcs | Where-Object { $euCodes -notcontains $_ }).Count -eq 0)
    [void]$orHosts.Add(@($p, $e))
  }
  foreach ($x in $orHosts) { foreach ($n in @($x[0].name, $x[0].displayName, $x[0].slug)) { Add-HostKey (Get-RawKey ([string]$n)) $x[1] } }
  foreach ($x in $orHosts) { foreach ($n in @($x[0].name, $x[0].displayName)) { Add-HostKey (Get-ProvKey ([string]$n)) $x[1] } }
} catch { Write-Warning "OpenRouter provider data policies skipped: $($_.Exception.Message)" }
foreach ($h in (Read-Config 'hosts.csv')) {
  if (-not $h.host) { continue }
  $e = Find-Host $h.host
  if (-not $e) { $e = New-HostEntry $h.host; Add-HostKey (Get-RawKey $h.host) $e; Add-HostKey (Get-ProvKey $h.host) $e }
  $e.dpa = ([string]$h.dpa).Trim().ToLowerInvariant()
  $e.src = [string]$h.source
  $e.note = [string]$h.note
  $e.checked = [string]$h.checked
  if ($h.train) { $e.tr = $(if ($h.train -match '^y') { 1 } else { 0 }) }
  if ($h.retain) { $e.rt = $(if ($h.retain -match '^y') { 1 } else { 0 }) }
  if ($h.eu -match '^y') { $e.euOnly = $true }
}
$openRouterHost = Find-Host 'OpenRouter'
$openAIHost = Find-Host 'OpenAI'

# What one offering (a model at one host) meets: DPA, EU processing, training, retention, tool calling.
function Get-Flags($hostEntry, [bool]$inEU, $tools, $policyEntry) {
  if (-not $policyEntry) { $policyEntry = $hostEntry }
  [ordered]@{
    k   = $(if ($hostEntry) { Get-ProvKey $hostEntry.name } else { '' })
    dpa = $(if ($hostEntry) { $hostEntry.dpa } else { '' })
    tr  = $(if ($policyEntry) { $policyEntry.tr } else { $null })
    rt  = $(if ($policyEntry) { $policyEntry.rt } else { $null })
    eu  = $(if ($inEU -or ($hostEntry -and $hostEntry.euOnly)) { 1 } else { 0 })
    tl  = $tools
  }
}
function Get-Tools($params) { if ($null -eq $params) { return $null } $(if (@($params) -contains 'tools') { 1 } else { 0 }) }

# --- 4. Cheaper Inference marketplace prices (optional) ----------------------------------------
Write-Host 'Cheaper Inference markets...'
$ciByKey = @{}
try {
  $ciRsc = Get-RscText (Get-Page 'https://www.cheaperinference.com/markets')
  foreach ($js in [RscScan]::Objects($ciRsc, '{"id":"')) {
    if (-not $js.Contains('"ourInputPerM"')) { continue }
    try { $o = ConvertFrom-Json -InputObject $js } catch { continue }
    if ($o.type -ne 'text' -or $null -eq $o.ourInputPerM -or $null -eq $o.ourOutputPerM) { continue }
    $k = Get-Key $o.id
    if (-not $ciByKey.ContainsKey($k)) { $ciByKey[$k] = $o }
  }
} catch { Write-Warning "Cheaper Inference skipped: $($_.Exception.Message)" }

# --- 5. Appats' language evidence --------------------------------------------------------------
$langRows = Read-Config 'languages.csv'
$testByName = @{}
$testByKey = @{}
foreach ($t in (Read-Config 'appats_tests.csv')) {
  if (-not $t.model) { continue }
  $testByName[[string]$t.model] = $t
  $fk = Get-Key $t.model
  if (-not $testByKey.ContainsKey($fk)) { $testByKey[$fk] = $t }
}
function Get-Lang([string]$maker, [string]$name) {
  $l = [ordered]@{ es = ''; ca = ''; src = ''; note = ''; test = $null }
  foreach ($r in $langRows) {
    if ($r.maker -and $r.maker -ne $maker) { continue }
    if ($r.match -and $name -notmatch $r.match) { continue }
    $l.es = ([string]$r.spanish).Trim().ToLowerInvariant()
    $l.ca = ([string]$r.catalan).Trim().ToLowerInvariant()
    $l.src = [string]$r.source
    $l.note = [string]$r.note
    break
  }
  $t = $(if ($testByName.ContainsKey($name)) { $testByName[$name] } else { $testByKey[(Get-Key $name)] })
  if ($t) { $l.test = [ordered]@{ es = ([string]$t.spanish).Trim().ToLowerInvariant(); ca = ([string]$t.catalan).Trim().ToLowerInvariant(); date = [string]$t.tested_on; note = [string]$t.notes } }
  $l
}

# --- 6. Merge ----------------------------------------------------------------------------------
Write-Host 'Merging and fetching per-model provider lists...'
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$maxSupersededAgeDays).ToString('yyyy-MM-dd')
$rows = New-Object System.Collections.ArrayList
$zero = New-Object System.Collections.ArrayList
$estRatios = New-Object System.Collections.ArrayList   # measured / estimated cost at hosts AA measured, to check the estimate
foreach ($m in $metrics.Values) {
  if ($null -eq $m.intelligenceIndex -or $m.intelligenceIndexIsEstimated) { continue }
  $c = $m.intelligenceIndexCostPerTask
  if ($null -eq $c) { continue }
  $name = $(if ($m.shortName) { $m.shortName } else { $m.name })
  $key = Get-Key $name
  $keyLong = Get-Key $m.name
  $euHit = $(if ($euByKey.ContainsKey($key)) { $euByKey[$key] } elseif ($euByKey.ContainsKey($keyLong)) { $euByKey[$keyLong] } else { $null })
  $viaOpenAI = ($openAIKeys -contains $key)
  $rd = $release[$m.slug]
  if ($m.deprecated -and (-not ($euHit -or $viaOpenAI) -or ($rd -and $rd -lt $cutoff))) { continue }
  if ([double]$c -le 0) { [void]$zero.Add($name); continue }

  $refIn = [double]$m.price1mInputTokens
  $refOut = [double]$m.price1mOutputTokens
  $maker = [string]$m.modelCreatorName
  $row = [ordered]@{ n = $name; s = $m.slug; cr = $maker; ii = [math]::Round([double]$m.intelligenceIndex, 1); c = (Round3 $c) }
  if ($m.isOpenWeights) { $row.ow = 1 }
  if ($m.deprecated) { $row.dep = 1 }
  if ($rd) { $row.rd = $rd }
  if ($refIn -gt 0 -and $refOut -gt 0) { $row.refIn = Round3 $refIn; $row.refOut = Round3 $refOut }
  $row.lg = Get-Lang $maker $name

  # Every offering of this model. Entry: provider, cost per task, source, note, input and output price per 1M tokens, flags.
  #  - every host Artificial Analysis lists (measured cost where it has one, otherwise an estimate from its token price);
  #  - OpenRouter hosts it does not list (cheapest variant each), plus each host's cheapest EU-region variant;
  #  - OpenAI's EU data residency and OpenRouter's EU in-region routing;
  #  - Cheaper Inference.
  $entries = New-Object 'System.Collections.Generic.List[object]'
  $listed = @{}
  $makerKey = Get-ProvKey $maker
  foreach ($e in @($byModel[$m.slug])) {
    if ($null -eq $e) { continue }
    $pk = Get-ProvKey $e.p
    $pin = [double]$e.pin
    $pout = [double]$e.pout
    $hasPrice = ($pin -gt 0 -or $pout -gt 0)
    if ($null -ne $e.c -and [double]$e.c -gt 0) {
      $cost = Round3 $e.c
      $src = 'AA'
      if ($pk -ne $makerKey -and $hasPrice) {
        $est = Get-Scaled $c $refIn $refOut $pin $pout
        if ($est -gt 0) { [void]$estRatios.Add([double]$e.c / $est) }
      }
    }
    elseif ($hasPrice) {
      $cost = Get-Scaled $c $refIn $refOut $pin $pout
      $src = 'AAP'
      if ($null -eq $cost) { continue }
    }
    else { continue }
    $tools = $(if ($null -eq $e.fc) { $null } elseif ($e.fc) { 1 } else { 0 })
    $entries.Add([object[]]@($e.p, $cost, $src, $null, $(if ($hasPrice) { Round3 $pin } else { $null }), $(if ($hasPrice) { Round3 $pout } else { $null }), (Get-Flags (Find-Host $e.p) $false $tools $null)))
    $listed[$pk] = $true
  }
  $orId = $(if ($orIdByKey.ContainsKey($key)) { $orIdByKey[$key] } elseif ($orIdByKey.ContainsKey($keyLong)) { $orIdByKey[$keyLong] } else { $null })
  if ($orId) {
    $row.or = $orId
    $bestOR = @{}
    foreach ($ep in (Get-Endpoints 'https://openrouter.ai' $orId)) {
      $pk = Get-ProvKey ([string]$ep.provider_name)
      $isEU = ([string]$ep.tag -match '/(eu|europe)')
      if ($listed.ContainsKey($pk) -and -not $isEU) { continue }
      $pin = [double]$ep.pricing.prompt * 1e6
      $pout = [double]$ep.pricing.completion * 1e6
      if ($pin -le 0 -and $pout -le 0) { continue }
      $blend = 3 * $pin + $pout
      $slot = $(if ($isEU) { "$pk|eu" } else { $pk })
      if (-not $bestOR.ContainsKey($slot) -or $blend -lt $bestOR[$slot].blend) {
        $bestOR[$slot] = @{ name = [string]$ep.provider_name; tag = [string]$ep.tag; q = [string]$ep.quantization; pin = $pin; pout = $pout; blend = $blend; eu = $isEU; tl = (Get-Tools $ep.supported_parameters) }
      }
    }
    foreach ($v in $bestOR.Values) {
      $notes = @()
      if ($v.q -and $v.q -ne 'unknown') { $notes += $v.q }
      if ($v.eu) { $region = $v.tag -replace '^[^/]*/', ''; $notes += $(if ($region -eq 'eu') { 'EU region' } else { "EU region $region" }) }
      $label = $(if ($v.eu) { "$($v.name) (EU region)" } else { $v.name })
      $entries.Add([object[]]@($label, (Get-Scaled $c $refIn $refOut $v.pin $v.pout), 'OR', ($notes -join ', '), (Round3 $v.pin), (Round3 $v.pout), (Get-Flags (Find-Host $v.name) $v.eu $v.tl $null)))
    }
  }
  if ($viaOpenAI -and $refIn -gt 0) {
    # EU data residency: +10% for models released from 5 Mar 2026; zero data retention subject to OpenAI's approval.
    $flags = Get-Flags $openAIHost $true 1 $null
    $flags.tr = 0
    $flags.rt = 0
    $entries.Add([object[]]@('OpenAI API, EU data residency', (Round3 ([double]$c * 1.1)), 'EU', '+10%; zero data retention on approval', (Round3 ($refIn * 1.1)), (Round3 ($refOut * 1.1)), $flags))
  }
  if ($euHit) {
    foreach ($ep in (Get-Endpoints 'https://eu.openrouter.ai' $euHit.id)) {
      $pin = [double]$ep.pricing.prompt * 1e6
      $pout = [double]$ep.pricing.completion * 1e6
      if ($pin -le 0 -and $pout -le 0) { continue }
      # OpenRouter signs the DPA; the host it routes to decides training and retention.
      $flags = Get-Flags $openRouterHost $true (Get-Tools $ep.supported_parameters) (Find-Host ([string]$ep.provider_name))
      $entries.Add([object[]]@(('OpenRouter EU via {0}' -f $ep.provider_name), (Get-Scaled $c $refIn $refOut $pin $pout), 'EU', ('EU in-region routing ({0})' -f $ep.tag), (Round3 $pin), (Round3 $pout), $flags))
    }
  }
  $ci = $(if ($ciByKey.ContainsKey($key)) { $ciByKey[$key] } elseif ($ciByKey.ContainsKey($keyLong)) { $ciByKey[$keyLong] } else { $null })
  if ($ci) {
    $cin = [double]$ci.ourInputPerM
    $cout = [double]$ci.ourOutputPerM
    $entries.Add([object[]]@('Cheaper Inference', (Get-Scaled $c $refIn $refOut $cin $cout), 'CI', ('reseller, {0}% below list' -f [math]::Round([double]$ci.discountPercent)), (Round3 $cin), (Round3 $cout), (Get-Flags (Find-Host 'Cheaper Inference') $false $null $null)))
  }
  if ($entries.Count) { $row.pv = Get-SortedByCost $entries }
  [void]$rows.Add([pscustomobject]$row)
}
$rows = @($rows | Sort-Object @{ Expression = { $_.ii }; Descending = $true }, @{ Expression = { $_.c } })
if ($rows.Count -lt 60) { throw "Only $($rows.Count) models survived the merge; keeping the previous page." }

# How good is the estimate (reference cost x price ratio)? Compare it with the hosts AA did measure.
$estCheck = $null
if ($estRatios.Count -ge 20) {
  $sorted = @($estRatios | Sort-Object)
  $pick = { param($q) [math]::Round($sorted[[int][math]::Floor($q * ($sorted.Count - 1))], 2) }
  $estCheck = [ordered]@{
    n      = $sorted.Count
    within = [math]::Round(@($sorted | Where-Object { $_ -ge 0.8 -and $_ -le 1.25 }).Count / $sorted.Count, 2)
    p10    = (& $pick 0.1)
    p50    = (& $pick 0.5)
    p90    = (& $pick 0.9)
  }
}

# --- 7. Provider directory ---------------------------------------------------------------------
$dir = @{}
foreach ($r in $rows) {
  $family = ($r.n -replace '\s*\(.*$', '')   # count models, not each reasoning level
  foreach ($p in @($r.pv)) {
    if ($null -eq $p) { continue }
    $f = $p[6]
    $hostName = $(if ($p[2] -eq 'EU' -and $p[0] -like 'OpenRouter EU via *') { 'OpenRouter' } elseif ($p[2] -eq 'EU') { 'OpenAI' } else { ([string]$p[0] -replace ' \(EU region\)$', '') -replace $tierWords, '' })
    $pk = Get-ProvKey $hostName
    if (-not $dir.ContainsKey($pk)) {
      $dir[$pk] = @{ name = $hostName; models = New-Object 'System.Collections.Generic.HashSet[string]'; src = New-Object 'System.Collections.Generic.HashSet[string]'; eu = $false; info = (Find-Host $hostName) }
    }
    [void]$dir[$pk].models.Add($family)
    [void]$dir[$pk].src.Add([string]$p[2])
    if ($f.eu -eq 1) { $dir[$pk].eu = $true }
  }
}
$provList = New-Object 'System.Collections.Generic.List[object]'
foreach ($v in $dir.Values) {
  $i = $v.info
  $provList.Add([object[]]@($v.name, $v.models.Count, ((@($v.src) | Sort-Object) -join '+'), [bool]$v.eu,
      $(if ($i) { $i.dpa } else { '' }), $(if ($i) { $i.src } else { '' }), $(if ($i) { $i.note } else { '' }),
      $(if ($i) { $i.tr } else { $null }), $(if ($i) { $i.rt } else { $null }), $(if ($i) { $i.days } else { $null }),
      $(if ($i) { $i.hq } else { '' }), $(if ($i) { $i.dc } else { '' })))
}
$provArr = [Linq.Enumerable]::ToArray([Linq.Enumerable]::OrderByDescending($provList, [Func[object, double]] { param($p) [double]$p[1] }))

# --- 8. Today's trade-off curves, for the summary ----------------------------------------------
# The smartest model at each price: sorted by cost, keep each model that beats every cheaper one.
function Get-CurveLine([string]$label, $items) {
  $best = -1
  $parts = @()
  foreach ($it in ($items | Sort-Object @{ Expression = { $_.cost } }, @{ Expression = { $_.ii }; Descending = $true })) {
    if ($it.ii -le $best) { continue }
    $best = $it.ii
    $parts += '{0} ({1}, ${2} at {3})' -f $it.n, $it.ii.ToString('0.0', $inv), $it.cost.ToString($inv), $it.via
  }
  "${label}: " + $(if ($parts.Count) { $parts -join '; ' } else { 'no model qualifies' })
}
function Get-Cheapest($r, [bool]$all) {
  $best = $null
  foreach ($p in @($r.pv)) {
    if ($null -eq $p -or $null -eq $p[1]) { continue }
    $f = $p[6]
    if ($all -and -not (($f.dpa -eq 'yes' -or $f.dpa -eq 'request') -and $f.eu -eq 1 -and $f.tr -eq 0 -and $f.rt -eq 0 -and $f.tl -eq 1)) { continue }
    if (-not $best -or [double]$p[1] -lt [double]$best[1]) { $best = $p }
  }
  $best
}
$anyItems = @(foreach ($r in $rows) { $b = Get-Cheapest $r $false; if ($b) { [pscustomobject]@{ n = $r.n; ii = [double]$r.ii; cost = [double]$b[1]; via = $b[0] } } })
$reqItems = @(foreach ($r in $rows) {
    if ($r.lg.es -ne 'named' -or $r.lg.ca -ne 'named') { continue }
    $b = Get-Cheapest $r $true
    if ($b) { [pscustomobject]@{ n = $r.n; ii = [double]$r.ii; cost = [double]$b[1]; via = $b[0] } }
  })

# --- 9. Write outputs ----------------------------------------------------------------------------
$meta = [ordered]@{
  asOf      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
  ciCount   = $ciByKey.Count
  est       = $estCheck
  zero      = @($zero | Sort-Object)
  providers = $provArr
}
$dataJson = ConvertTo-Json -InputObject $rows -Depth 8 -Compress
$metaJson = ConvertTo-Json -InputObject $meta -Depth 8 -Compress
Write-Page $metaJson $dataJson
[IO.File]::WriteAllText((Join-Path $here 'data.json'), "{""meta"":$metaJson,""models"":$dataJson}", $utf8)

$aaProv = @($provArr | Where-Object { $_[2] -match 'AA' }).Count
$dpaCount = { param($s) @($provArr | Where-Object { $_[4] -eq $s }).Count }
$lines = @(
  "Refreshed $($meta.asOf): $($rows.Count) models."
  "Provider pool: $($provArr.Count) hosts ($aaProv listed by Artificial Analysis, the rest priced from OpenRouter, its EU list or Cheaper Inference); Cheaper Inference prices for $($ciByKey.Count) models."
  ('DPA (hosts.csv): published by {0} hosts, on request at {1}, none at {2}, not found at {3}, not checked at {4}.' -f (& $dpaCount 'yes'), (& $dpaCount 'request'), (& $dpaCount 'no'), (& $dpaCount 'not found'), (& $dpaCount ''))
)
if ($estCheck) { $lines += 'Estimate check: at {0} hosts Artificial Analysis measured, the estimate from token prices was within 25% for {1}% of them (middle 80%: {2}x to {3}x).' -f $estCheck.n, [math]::Round($estCheck.within * 100), $estCheck.p10.ToString($inv), $estCheck.p90.ToString($inv) }
$lines += (Get-CurveLine 'Trade-off curve, every model at its cheapest host' $anyItems)
$lines += (Get-CurveLine 'Trade-off curve, all Appats requirements (ES/CA named, DPA, EU, no training, no retention, tool calling)' $reqItems)
[IO.File]::WriteAllText((Join-Path $here 'summary.txt'), ($lines -join "`r`n") + "`r`n", $utf8)

# --- 10. PNG for the Google Doc ------------------------------------------------------------------
if (-not $NoPng) { $msg = Invoke-Png; if ($msg) { $lines += $msg } }

$lines | ForEach-Object { Write-Host $_ }
if ($Open) { Start-Process $pagePath }
