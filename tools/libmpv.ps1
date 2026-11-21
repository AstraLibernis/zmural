# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AstraLibernis
#
# The pinned libmpv for the Windows release (tools/libmpv-pin.txt).
#
#   tools/libmpv.ps1            fetch the pinned build into third_party/mpv,
#                               refusing anything whose hash differs
#   tools/libmpv.ps1 -Verify    no network: every file that names a build names
#                               the pinned one, and the local DLL is that build
#   tools/libmpv.ps1 -Check     is the pin still upstream, and is there a newer build?
#   tools/libmpv.ps1 -Update    move the pin to the newest upstream build, fetch
#                               it, and rewrite the files that name it
#
# Works in Windows PowerShell 5.1 and PowerShell 7.
param([switch]$Verify, [switch]$Check, [switch]$Update)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $PSScriptRoot
$pinFile = Join-Path $PSScriptRoot 'libmpv-pin.txt'
$dest = Join-Path $root 'third_party\mpv'
$dll = Join-Path $dest 'libmpv-2.dll'
# The files that name the pinned build in words, for people.
$docs = 'THIRD_PARTY_NOTICES.md', 'licenses\libmpv-credits.txt'
$tagPattern = '\d{4}-\d{2}-\d{2}-[0-9a-f]{10}'
$assetPattern = 'mpv-dev-lgpl-x86_64-\d{8}-git-[0-9a-f]{10}\.7z'
$utf8 = New-Object System.Text.UTF8Encoding $false

function Read-Pin {
    $pin = @{}
    foreach ($line in [IO.File]::ReadAllLines($pinFile)) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $key, $value = $line -split '=', 2
        $pin[$key.Trim()] = $value.Trim()
    }
    foreach ($need in 'repo', 'tag', 'asset', 'archive_sha256', 'dll_sha256', 'mpv_commit') {
        if (-not $pin.ContainsKey($need)) { throw "tools/libmpv-pin.txt has no '$need'" }
    }
    if ($pin.tag -notmatch "^$tagPattern$") { throw "tools/libmpv-pin.txt: '$($pin.tag)' isn't a build tag" }
    if ($pin.asset -notmatch "^$assetPattern$") { throw "tools/libmpv-pin.txt: '$($pin.asset)' isn't an LGPL dev archive" }
    if ($pin.archive_sha256 -notmatch '^[0-9a-f]{64}$') { throw "tools/libmpv-pin.txt: archive_sha256 isn't a SHA-256" }
    return $pin
}

function Write-Pin($pin) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($pinFile)) {
        if ($line -match '^([a-z0-9_]+)=' -and $pin.ContainsKey($Matches[1])) { $out.Add("$($Matches[1])=$($pin[$Matches[1]])") } else { $out.Add($line) }
    }
    [IO.File]::WriteAllText($pinFile, (($out -join "`n") + "`n"), $utf8)
}

function Get-Sha($path) { return (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-Url($pin) { return "https://github.com/$($pin.repo)/releases/download/$($pin.tag)/$($pin.asset)" }

# Downloads the pinned archive, checks it, and unpacks libmpv-2.dll.
# Returns the DLL's SHA-256.
function Get-Build($pin) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("zmural-libmpv-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        $archive = Join-Path $tmp 'mpv.7z'
        $url = Get-Url $pin
        try { Invoke-WebRequest $url -OutFile $archive -UseBasicParsing } catch {
            throw "can't download $url ($($_.Exception.Message)). Upstream keeps only recent builds: run tools/libmpv.ps1 -Check, then -Update."
        }
        $got = Get-Sha $archive
        if ($got -ne $pin.archive_sha256) { throw "libmpv archive hash differs: got $got, pinned $($pin.archive_sha256)" }
        $out = Join-Path $tmp 'out'
        New-Item -ItemType Directory -Force $out | Out-Null
        $sevenZip = Get-Command 7z -ErrorAction SilentlyContinue
        if ($sevenZip) {
            & $sevenZip.Source e $archive libmpv-2.dll "-o$out" -y | Out-Null
        } else {
            # Windows' own tar (libarchive) reads 7z; Git's tar, first on some PATHs, doesn't.
            & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $out libmpv-2.dll
        }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $out 'libmpv-2.dll'))) { throw "can't unpack libmpv-2.dll from $($pin.asset)" }
        $dllSha = Get-Sha (Join-Path $out 'libmpv-2.dll')
        if ($pin.dll_sha256 -and $dllSha -ne $pin.dll_sha256) { throw "libmpv-2.dll hash differs: got $dllSha, pinned $($pin.dll_sha256)" }
        New-Item -ItemType Directory -Force $dest | Out-Null
        Copy-Item (Join-Path $out 'libmpv-2.dll') $dll -Force
        $source = @(
            "libmpv-2.dll: LGPL build (mpv configured with -Dgpl=false)"
            "From: https://github.com/$($pin.repo)/releases/tag/$($pin.tag)"
            "Asset: $($pin.asset)"
            "Source: $url"
            "SHA-256 of the archive: $($pin.archive_sha256)"
            "SHA-256 of libmpv-2.dll: $dllSha"
            "mpv source: https://github.com/mpv-player/mpv (commit $($pin.mpv_commit))"
        ) -join "`n"
        [IO.File]::WriteAllText((Join-Path $dest 'SOURCE.txt'), "$source`n", $utf8)
        return $dllSha
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# The newest upstream release that has an LGPL dev archive for x86_64.
function Get-Newest($pin) {
    $releases = Invoke-RestMethod "https://api.github.com/repos/$($pin.repo)/releases?per_page=10" -UseBasicParsing
    $pinnedThere = $false
    $newest = $null
    foreach ($r in $releases) {
        if ($r.tag_name -eq $pin.tag) { $pinnedThere = $true }
        if ($newest -or $r.draft -or $r.prerelease) { continue }
        $a = $r.assets | Where-Object { $_.name -match "^$assetPattern$" } | Select-Object -First 1
        if ($a) { $newest = @{ tag = $r.tag_name; asset = $a.name; digest = "$($a.digest)" -replace '^sha256:', '' } }
    }
    if (-not $pinnedThere) {
        # Older than the page: ask for it by name.
        try { Invoke-RestMethod "https://api.github.com/repos/$($pin.repo)/releases/tags/$($pin.tag)" -UseBasicParsing | Out-Null; $pinnedThere = $true } catch { $pinnedThere = $false }
    }
    if (-not $newest) { throw "no release of $($pin.repo) has an LGPL dev archive" }
    return @{ newest = $newest; pinnedThere = $pinnedThere }
}

# Every problem found, as lines; none means the pin, the files and the DLL agree.
function Test-Pin($pin) {
    $problems = @()
    foreach ($rel in $docs) {
        $text = [IO.File]::ReadAllText((Join-Path $root $rel))
        $tags = [regex]::Matches($text, $tagPattern) | ForEach-Object { $_.Value } | Sort-Object -Unique
        $assets = [regex]::Matches($text, $assetPattern) | ForEach-Object { $_.Value } | Sort-Object -Unique
        if (-not $tags) { $problems += "${rel}: names no libmpv build" }
        foreach ($t in $tags) { if ($t -ne $pin.tag) { $problems += "${rel}: names build $t, the pin is $($pin.tag)" } }
        foreach ($a in $assets) { if ($a -ne $pin.asset) { $problems += "${rel}: names $a, the pin is $($pin.asset)" } }
    }
    $workflow = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\ci.yml'))
    if ($workflow -match $tagPattern -or $workflow -match $assetPattern) { $problems += ".github/workflows/ci.yml: names a libmpv build itself; it must run tools/libmpv.ps1" }
    if (-not $pin.dll_sha256) { $problems += "tools/libmpv-pin.txt: dll_sha256 is empty" }
    if (Test-Path $dll) {
        $have = Get-Sha $dll
        if ($pin.dll_sha256 -and $have -ne $pin.dll_sha256) { $problems += "third_party/mpv/libmpv-2.dll isn't the pinned build (got $have): run tools/libmpv.ps1" }
    }
    return $problems
}

$pin = Read-Pin

if ($Verify) {
    $problems = @(Test-Pin $pin)
    if ($problems.Count -gt 0) { $problems | ForEach-Object { Write-Host "FAIL $_" }; exit 1 }
    $local = 'no local DLL'
    if (Test-Path $dll) { $local = 'the local DLL is that build' }
    Write-Host "ok: libmpv pinned at $($pin.tag); every file names it; $local"
    exit 0
}

if ($Check) {
    $state = Get-Newest $pin
    Write-Host "pinned: $($pin.tag)"
    Write-Host "newest: $($state.newest.tag)"
    if (-not $state.pinnedThere) { Write-Host "GONE: the pinned build is no longer upstream; run tools/libmpv.ps1 -Update"; exit 2 }
    if ($state.newest.tag -ne $pin.tag) { Write-Host "the pinned build is still upstream; a newer one exists (tools/libmpv.ps1 -Update)"; exit 0 }
    Write-Host "up to date"
    exit 0
}

if ($Update) {
    $state = Get-Newest $pin
    $new = $state.newest
    if ($new.tag -eq $pin.tag) { Write-Host "already at the newest build, $($pin.tag)"; exit 0 }
    if ($new.asset -notmatch 'git-([0-9a-f]{10})\.7z$') { throw "can't read the mpv commit from $($new.asset)" }
    $commit = $Matches[1]
    $old = $pin.Clone()
    # The archive's hash isn't known before the download: take what upstream
    # publishes for it, and refuse the update when it publishes none.
    if ($new.digest -notmatch '^[0-9a-f]{64}$') { throw "upstream publishes no SHA-256 for $($new.asset); pin it by hand after checking it" }
    $pin.tag = $new.tag; $pin.asset = $new.asset; $pin.archive_sha256 = $new.digest; $pin.mpv_commit = $commit; $pin.dll_sha256 = ''
    $pin.dll_sha256 = Get-Build $pin
    Write-Pin $pin
    foreach ($rel in $docs) {
        $path = Join-Path $root $rel
        $text = [IO.File]::ReadAllText($path)
        $text = $text.Replace($old.asset, $pin.asset).Replace($old.tag, $pin.tag).Replace('`' + $old.mpv_commit + '`', '`' + $pin.mpv_commit + '`')
        [IO.File]::WriteAllText($path, $text, $utf8)
    }
    $problems = @(Test-Pin $pin)
    if ($problems.Count -gt 0) { $problems | ForEach-Object { Write-Host "FAIL $_" }; exit 1 }
    Write-Host "libmpv: $($old.tag) -> $($pin.tag)"
    Write-Host "Still by hand (docs/RELEASING.md, 'The pinned libmpv'): redo licenses/libmpv-credits.txt, run the tests, and do a Windows pass."
    exit 0
}

$dllSha = Get-Build $pin
if (-not $pin.dll_sha256) {
    $pin.dll_sha256 = $dllSha
    Write-Pin $pin
    Write-Host "recorded the DLL's hash in tools/libmpv-pin.txt"
}
Write-Host "libmpv $($pin.tag): third_party/mpv/libmpv-2.dll ($dllSha)"
