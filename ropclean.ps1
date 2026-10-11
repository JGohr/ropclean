#Requires -Version 5.1
<#
  ropclean - interactive drive cleanup.
  Lists caches and large removable items on a chosen drive and sends the
  user's picks to the Recycle Bin. Nothing is permanently deleted.
#>
param(
  [string]$Drive,
  [switch]$ScanOnly,
  [switch]$Elevated
)

$ErrorActionPreference = 'SilentlyContinue'
$MinCacheBytes = 10MB
$MinItemBytes  = 500MB
$MinRootBytes  = 1GB

if (-not ('RopRecycle' -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class RopRecycle {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct SHFILEOPSTRUCT {
    public IntPtr hwnd; public uint wFunc; public string pFrom; public string pTo;
    public ushort fFlags; [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
    public IntPtr hNameMappings; public string lpszProgressTitle;
  }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  static extern int SHFileOperation(ref SHFILEOPSTRUCT op);
  // FO_DELETE with ALLOWUNDO (Recycle Bin), no confirm/error UI, but WANTNUKEWARNING
  // so Windows asks before permanently deleting anything too big for the bin.
  public static int Recycle(string path, out bool aborted) {
    var op = new SHFILEOPSTRUCT();
    op.wFunc = 3;
    op.pFrom = path + "\0\0";
    op.fFlags = (ushort)(0x0040 | 0x0010 | 0x0400 | 0x0004 | 0x4000);
    int rc = SHFileOperation(ref op);
    aborted = op.fAnyOperationsAborted;
    return rc;
  }
}
"@
}

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Format-Size([double]$Bytes) {
  if ($Bytes -ge 1GB) { '{0:N1} GB' -f ($Bytes / 1GB) } else { '{0:N0} MB' -f ($Bytes / 1MB) }
}

function Get-Size([string]$Path) {
  $item = Get-Item -LiteralPath $Path -Force
  if (-not $item) { return 0 }
  if (-not $item.PSIsContainer) { return $item.Length }
  $total = 0L
  $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
  $stack.Push($item)
  while ($stack.Count) {
    $dir = $stack.Pop()
    try { foreach ($f in $dir.EnumerateFiles()) { $total += $f.Length } } catch {}
    try {
      foreach ($d in $dir.EnumerateDirectories()) {
        if (-not ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($d) }
      }
    } catch {}
  }
  $total
}

function Test-OnDrive([string]$Path, [string]$Root) {
  $Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)
}

function New-Entry($Kind, $Name, $Paths, $Admin = $false) {
  [pscustomobject]@{ Kind = $Kind; Name = $Name; Paths = @($Paths); Admin = [bool]$Admin; Size = 0L }
}

function Show-Banner {
  Clear-Host
  Write-Host ''
  Write-Host '  ROPCLEAN' -ForegroundColor Cyan
  Write-Host '  Drive cleanup - everything goes to the Recycle Bin' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '  DISCLAIMER: ropclean is not responsible for any data that is lost.' -ForegroundColor Yellow
  Write-Host '  Use this tool at your own risk.' -ForegroundColor Yellow
  Write-Host ''
}

# ---------- scanners ----------

function Get-CacheEntries([string]$Root) {
  $l = $env:LOCALAPPDATA; $r = $env:APPDATA; $pd = $env:ProgramData; $w = $env:windir
  $defs = @(
    @('Windows user temp files',                    "$l\Temp", $false),
    @('App crash dumps',                            "$l\CrashDumps", $false),
    @('NVIDIA shader cache',                        "$l\NVIDIA\DXCache", $false),
    @('NVIDIA GL shader cache',                     "$l\NVIDIA\GLCache", $false),
    @('AMD shader cache',                           "$l\AMD\DxCache", $false),
    @('DirectX shader cache',                       "$l\D3DSCache", $false),
    @('Unreal derived data cache',                  "$l\UnrealEngine\Common\DerivedDataCache", $false),
    @('Unreal Zen cache',                           "$l\UnrealEngine\Common\Zen", $false),
    @('Epic Fab/Vault download cache',              "$pd\Epic\EpicGamesLauncher\VaultCache", $false),
    @('Epic launcher update files',                 "$pd\Epic\EpicGamesLauncher\Data\Update", $false),
    @('NVIDIA App update files',                    "$pd\NVIDIA Corporation\NVIDIA App\UpdateFramework", $false),
    @('NVIDIA driver downloads',                    "$pd\NVIDIA Corporation\Downloader", $false),
    @('Spotify song cache (clears offline songs)',  "$l\Spotify\Data", $false),
    @('CapCut cache',                               "$l\CapCut\User Data\Cache", $false),
    @('CapCut download cache',                      "$l\CapCut\User Data\Download", $false),
    @('npm cache',                                  "$l\npm-cache\_cacache", $false),
    @('pip cache',                                  "$l\pip\cache", $false),
    @('Yarn cache',                                 "$l\Yarn\Cache", $false),
    @('Windows internet cache',                     "$l\Microsoft\Windows\INetCache", $false),
    @('Chrome cache',                               "$l\Google\Chrome\User Data\*\Cache", $false),
    @('Chrome code cache',                          "$l\Google\Chrome\User Data\*\Code Cache", $false),
    @('Edge cache',                                 "$l\Microsoft\Edge\User Data\*\Cache", $false),
    @('Edge code cache',                            "$l\Microsoft\Edge\User Data\*\Code Cache", $false),
    @('Brave cache',                                "$l\BraveSoftware\Brave-Browser\User Data\*\Cache", $false),
    @('Firefox cache',                              "$l\Mozilla\Firefox\Profiles\*\cache2", $false),
    @('Discord cache',                              "$r\discord\Cache", $false),
    @('Discord code cache',                         "$r\discord\Code Cache", $false),
    @('VS Code cache',                              "$r\Code\Cache", $false),
    @('VS Code cached data',                        "$r\Code\CachedData", $false),
    @('Windows temp files',                         "$w\Temp", $true),
    @('Windows Update downloads',                   "$w\SoftwareDistribution\Download", $true),
    @('Windows error reports',                      "$pd\Microsoft\Windows\WER\ReportArchive", $true)
  )
  foreach ($d in $defs) {
    $paths = @(Get-Item -Path $d[1] -Force | Where-Object PSIsContainer | ForEach-Object FullName | Where-Object { Test-OnDrive $_ $Root })
    if ($paths.Count) { New-Entry 'cache' $d[0] $paths $d[2] }
  }
  $steam = Get-SteamRoot
  if ($steam -and (Test-OnDrive $steam $Root)) {
    $p = Join-Path $steam 'appcache\httpcache'
    if (Test-Path -LiteralPath $p) { New-Entry 'cache' 'Steam web cache' $p }
  }
  foreach ($lib in (Get-SteamLibraries | Where-Object { Test-OnDrive $_ $Root })) {
    $p = Join-Path $lib 'steamapps\shadercache'
    if (Test-Path -LiteralPath $p) { New-Entry 'cache' "Steam shader cache ($lib)" $p }
  }
}

function Get-SteamRoot {
  $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam').SteamPath
  if ($p) { [IO.Path]::GetFullPath(($p -replace '/', '\')).TrimEnd('\') }
}

function Get-SteamLibraries {
  $steam = Get-SteamRoot
  if (-not $steam) { return }
  $libs = @($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path -LiteralPath $vdf) {
    foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
      $libs += [IO.Path]::GetFullPath(($m.Groups[1].Value -replace '\\\\', '\')).TrimEnd('\')
    }
  }
  $libs | Sort-Object -Unique
}

function Get-ItemEntries([string]$Root) {
  # Steam games + workshop content (manifest is recycled too, so a restore brings the game back)
  foreach ($lib in (Get-SteamLibraries | Where-Object { Test-OnDrive $_ $Root })) {
    foreach ($acf in (Get-ChildItem -LiteralPath (Join-Path $lib 'steamapps') -Filter 'appmanifest_*.acf')) {
      $c = Get-Content -LiteralPath $acf.FullName -Raw
      $id   = if ($c -match '"appid"\s+"(\d+)"') { $matches[1] }
      $name = if ($c -match '"name"\s+"([^"]+)"') { $matches[1] } else { $id }
      $dir  = if ($c -match '"installdir"\s+"([^"]+)"') { Join-Path $lib "steamapps\common\$($matches[1])" }
      if ($dir -and (Test-Path -LiteralPath $dir)) { New-Entry 'item' "Steam game: $name" @($dir, $acf.FullName) }
      $ws = Join-Path $lib "steamapps\workshop\content\$id"
      if ($id -and (Test-Path -LiteralPath $ws)) {
        $paths = @($ws)
        $wsAcf = Join-Path $lib "steamapps\workshop\appworkshop_$id.acf"
        if (Test-Path -LiteralPath $wsAcf) { $paths += $wsAcf }
        New-Entry 'item' "Steam workshop mods: $name" $paths
      }
    }
  }

  # Epic games
  foreach ($m in (Get-ChildItem -LiteralPath "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests" -Filter '*.item')) {
    $j = Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json
    if ($j.InstallLocation -and (Test-Path -LiteralPath $j.InstallLocation) -and (Test-OnDrive $j.InstallLocation $Root)) {
      New-Entry 'item' "Epic game: $($j.DisplayName)" @($j.InstallLocation, $m.FullName)
    }
  }

  # Large items inside personal folders
  $downloads = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
  $personal = @{
    'Desktop'   = [Environment]::GetFolderPath('Desktop')
    'Documents' = [Environment]::GetFolderPath('MyDocuments')
    'Downloads' = $downloads
    'Videos'    = [Environment]::GetFolderPath('MyVideos')
    'Music'     = [Environment]::GetFolderPath('MyMusic')
    'Pictures'  = [Environment]::GetFolderPath('MyPictures')
  }
  foreach ($k in $personal.Keys) {
    $p = $personal[$k]
    if (-not $p -or -not (Test-OnDrive $p $Root)) { continue }
    foreach ($c in (Get-ChildItem -LiteralPath $p -Force)) { New-Entry 'item' "${k}: $($c.Name)" $c.FullName }
  }

  # Non-system folders at the drive root
  $skip = 'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Users', 'Recovery', 'PerfLogs',
          'System Volume Information', 'Documents and Settings', 'Config.Msi', 'OneDriveTemp', 'WindowsApps', 'WpSystem', 'Windows.old'
  $known = @(Get-SteamLibraries) + @($personal.Values)
  foreach ($c in (Get-ChildItem -LiteralPath $Root -Force -Directory)) {
    if ($c.Name -in $skip -or $c.Name.StartsWith('$')) { continue }
    $prefix = $c.FullName.TrimEnd('\') + '\'
    if ($known | Where-Object { $_ -and ("$_\" -like "$prefix*") }) { continue }
    $e = New-Entry 'item' "Drive root: $($c.Name)" $c.FullName
    $e | Add-Member -NotePropertyName MinSize -NotePropertyValue $MinRootBytes
    $e
  }

  # Hibernation file (system drive only)
  if (Test-OnDrive "$env:SystemDrive\" $Root) {
    $h = Get-ChildItem -LiteralPath $Root -Force -Filter 'hiberfil.sys'
    if ($h) {
      $e = New-Entry 'hiber' 'Hibernation file (turns hibernate off; undo: powercfg /h on)' $h.FullName $true
      $e.Size = $h.Length  # Get-Item is denied on hiberfil.sys, so size it here
      $e
    }
  }
}

function Measure-Entries($Entries, [string]$Label, [long]$Min) {
  $list = @($Entries)
  $i = 0
  foreach ($e in $list) {
    $i++
    Write-Progress -Activity "Scanning $Label" -Status $e.Name -PercentComplete ($i * 100 / [math]::Max($list.Count, 1))
    if (-not $e.Size) { $e.Size = ($e.Paths | ForEach-Object { Get-Size $_ } | Measure-Object -Sum).Sum }
  }
  Write-Progress -Activity "Scanning $Label" -Completed
  $list | Where-Object { $_.Size -ge $(if ($_.MinSize) { $_.MinSize } else { $Min }) } | Sort-Object Size -Descending
}

# ---------- UI ----------

function Show-List($Entries, [string]$Title) {
  Write-Host "  $Title" -ForegroundColor Cyan
  if (-not $Entries.Count) { Write-Host '    (nothing found)' -ForegroundColor DarkGray; Write-Host ''; return }
  $n = 0
  foreach ($e in $Entries) {
    $n++
    $tag = if ($e.Admin -and -not $IsAdmin) { ' [admin]' } else { '' }
    Write-Host ('  {0,4}  {1,9}  {2}' -f $n, (Format-Size $e.Size), $e.Name) -NoNewline
    Write-Host $tag -ForegroundColor DarkYellow
  }
  Write-Host ('        {0,9}  total' -f (Format-Size (($Entries | Measure-Object Size -Sum).Sum))) -ForegroundColor DarkGray
  Write-Host ''
}

function Read-Selection([string]$Prompt, [int]$Count) {
  if (-not $Count) { return }
  while ($true) {
    $in = (Read-Host "  $Prompt (e.g. 1,3,5-7 / all / Enter = none)").Trim().ToLower()
    if ($in -in '', 'none', 'n') { return }
    if ($in -eq 'all') { return 0..($Count - 1) }
    $idx = @(); $ok = $true
    foreach ($part in ($in -split '[,\s]+')) {
      if ($part -match '^(\d+)-(\d+)$') { $idx += [int]$matches[1]..[int]$matches[2] }
      elseif ($part -match '^\d+$') { $idx += [int]$part }
      elseif ($part) { $ok = $false }
    }
    $idx = @($idx | Where-Object { $_ -ge 1 -and $_ -le $Count } | ForEach-Object { $_ - 1 } | Sort-Object -Unique)
    if ($ok -and $idx.Count) { return $idx }
    Write-Host '  Invalid selection, try again.' -ForegroundColor Yellow
  }
}

function Select-Drive {
  $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2 OR DriveType=3' | Sort-Object DeviceID)
  Write-Host '  Select a drive' -ForegroundColor Cyan
  $n = 0
  foreach ($d in $disks) {
    $n++
    $used = $d.Size - $d.FreeSpace
    Write-Host ('  {0,4}  {1}  {2,-16} {3,9} used  {4,9} free' -f $n, $d.DeviceID, $d.VolumeName, (Format-Size $used), (Format-Size $d.FreeSpace))
  }
  if (-not $IsAdmin) { Write-Host '     A  Relaunch as administrator (unlocks [admin] items)' -ForegroundColor DarkYellow }
  Write-Host '     Q  Quit' -ForegroundColor DarkGray
  Write-Host ''
  while ($true) {
    $in = (Read-Host '  Drive').Trim().ToUpper()
    if ($in -eq 'Q') { return }
    if ($in -eq 'A' -and -not $IsAdmin) {
      Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
      return
    }
    if ($in -match '^\d+$' -and [int]$in -ge 1 -and [int]$in -le $disks.Count) { return $disks[[int]$in - 1].DeviceID + '\' }
    if ($in -match '^[A-Z]:?$') {
      $hit = $disks | Where-Object { $_.DeviceID -eq ($in[0] + ':') }
      if ($hit) { return $hit.DeviceID + '\' }
    }
    Write-Host '  Invalid choice.' -ForegroundColor Yellow
  }
}

function Invoke-Clean($Chosen) {
  $done = 0L; $failed = 0; $skipped = @()
  $i = 0
  foreach ($e in $Chosen) {
    $i++
    Write-Progress -Activity 'Sending to Recycle Bin' -Status $e.Name -PercentComplete ($i * 100 / $Chosen.Count)
    if ($e.Admin -and -not $IsAdmin) { $skipped += $e.Name; continue }
    if ($e.Kind -eq 'hiber') {
      powercfg /h off | Out-Null
      if ($LASTEXITCODE -eq 0) { $done += $e.Size } else { $failed++ }
      continue
    }
    $targets = if ($e.Kind -eq 'cache') {
      $e.Paths | ForEach-Object { Get-ChildItem -LiteralPath $_ -Force | ForEach-Object FullName }
    } else { $e.Paths }
    $entryFailed = 0
    foreach ($t in $targets) {
      $aborted = $false
      $rc = [RopRecycle]::Recycle($t, [ref]$aborted)
      if ($rc -ne 0 -or $aborted) { $entryFailed++ }
    }
    $failed += $entryFailed
    if (-not $entryFailed) { $done += $e.Size }
  }
  Write-Progress -Activity 'Sending to Recycle Bin' -Completed
  Write-Host ''
  Write-Host ('  Done. About {0} sent to the Recycle Bin.' -f (Format-Size $done)) -ForegroundColor Green
  if ($failed) { Write-Host "  $failed file(s) were in use or kept (declined) and were left in place." -ForegroundColor Yellow }
  foreach ($s in $skipped) { Write-Host "  Skipped (needs admin): $s" -ForegroundColor DarkYellow }
  Write-Host '  Space is reclaimed once you empty the Recycle Bin. Restore anything from there if needed.' -ForegroundColor Cyan
}

# ---------- main ----------

Show-Banner
if (-not $ScanOnly) {
  $ok = (Read-Host '  Press Enter to accept and continue, or Q to quit').Trim().ToUpper()
  if ($ok -eq 'Q') { return }
  Write-Host ''
}

$root = if ($Drive) { $Drive.TrimEnd('\', ':').ToUpper() + ':\' } else { Select-Drive }
if (-not $root) { return }

Write-Host ''
$caches = @(Measure-Entries (Get-CacheEntries $root) 'caches' $MinCacheBytes)
$items  = @(Measure-Entries (Get-ItemEntries $root) 'large items' $MinItemBytes)

Show-Banner
Write-Host "  Drive $root" -ForegroundColor White
Write-Host ''
Show-List $caches 'CACHES (safe - apps rebuild these)'
Show-List $items  'OTHER ITEMS (games, personal files, folders - review carefully)'

if ($ScanOnly) { return }

$chosen = @()
$chosen += @(Read-Selection 'Caches to clear' $caches.Count | ForEach-Object { $caches[$_] })
$chosen += @(Read-Selection 'Other items to remove' $items.Count | ForEach-Object { $items[$_] })
if (-not $chosen.Count) { Write-Host '  Nothing selected. Bye.'; return }

Write-Host ''
Write-Host '  You chose:' -ForegroundColor Cyan
foreach ($e in $chosen) { Write-Host ('    {0,9}  {1}' -f (Format-Size $e.Size), $e.Name) }
Write-Host ('    {0,9}  total' -f (Format-Size (($chosen | Measure-Object Size -Sum).Sum))) -ForegroundColor DarkGray
Write-Host ''
Write-Host '  Items go to the Recycle Bin. If Windows says something is too big for the' -ForegroundColor Yellow
Write-Host '  Recycle Bin and would be permanently deleted, choose No to keep it.' -ForegroundColor Yellow
if ((Read-Host '  Type YES to continue').Trim() -cne 'YES') { Write-Host '  Cancelled.'; return }

Invoke-Clean $chosen
if ($Elevated) { Read-Host '  Press Enter to close' | Out-Null }
