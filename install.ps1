param(
  [Alias("p", "Profile")][string]$ProfilePath = "",
  [Alias("l")][switch]$Link,
  [Alias("u")][switch]$Uninstall,
  [switch]$NoMigrate,
  [Alias("n")][switch]$DryRun,
  [Alias("f")][switch]$Force,
  [Alias("h")][switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$Name = "tahoefox"
$SrcDir = $PSScriptRoot
$Files = @("userChrome.css", "userContent.css")
$BlockBegin = "// ${Name}:begin"
$BlockEnd = "// ${Name}:end"
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Show-Usage {
  @"
Usage: .\install.ps1 [options]

  -ProfilePath PATH   Install into this profile folder instead of the default one
  -Link               Link the CSS files instead of copying them (handy while editing)
  -Uninstall          Remove the theme and its preferences from the profile
  -NoMigrate          Do not carry over existing gwfox.* preferences
  -DryRun             Show what would happen without changing anything
  -Force              Run even if Firefox appears to be open
  -Help               Show this help

Firefox should be closed while the installer runs.
"@ | Write-Host
}

function Say([string]$Text) {
  Write-Host $Text
}

function Invoke-Step([string]$Description, [scriptblock]$Action) {
  if ($DryRun) {
    Say "  [dry run] $Description"
  } else {
    & $Action
  }
}

function Get-FirefoxRoots {
  if ($env:FIREFOX_ROOT) {
    return @($env:FIREFOX_ROOT)
  }
  $roots = @()
  if ($env:APPDATA) {
    $roots += Join-Path $env:APPDATA "Mozilla\Firefox"
  }
  if ($env:LOCALAPPDATA) {
    $packages = Join-Path $env:LOCALAPPDATA "Packages"
    if (Test-Path -LiteralPath $packages -PathType Container) {
      foreach ($package in Get-ChildItem -LiteralPath $packages -Directory -Filter "Mozilla.Firefox*") {
        $roots += Join-Path $package.FullName "LocalCache\Roaming\Mozilla\Firefox"
      }
    }
  }
  return $roots
}

function Resolve-ProfileDir([string]$Root, [string]$Path, [string]$Relative) {
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $local = $Path.Replace("/", $sep).Replace("\", $sep)
  if ($Relative -eq "0") {
    return $local
  }
  return Join-Path $Root $local
}

function Get-DefaultProfile([string]$Root) {
  $ini = Join-Path $Root "profiles.ini"
  if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) {
    return $null
  }
  $section = ""
  $install = ""
  $marked = ""
  $paths = @{}
  $relative = @{}
  foreach ($line in [System.IO.File]::ReadAllLines($ini)) {
    if ($line.StartsWith("[")) {
      $section = $line
      continue
    }
    $eq = $line.IndexOf("=")
    if ($eq -lt 0) {
      continue
    }
    $key = $line.Substring(0, $eq)
    $value = $line.Substring($eq + 1)
    if ($section.StartsWith("[Install")) {
      if ($key -eq "Default") { $install = $value }
    } elseif ($section.StartsWith("[Profile")) {
      if ($key -eq "Path") { $paths[$section] = $value }
      elseif ($key -eq "IsRelative") { $relative[$section] = $value }
      elseif ($key -eq "Default" -and $value -eq "1") { $marked = $section }
    }
  }
  if ($install) {
    $rel = "1"
    foreach ($s in $paths.Keys) {
      if ($paths[$s] -eq $install -and $relative.ContainsKey($s)) { $rel = $relative[$s] }
    }
    return Resolve-ProfileDir $Root $install $rel
  }
  if ($marked -and $paths.ContainsKey($marked)) {
    $rel = "1"
    if ($relative.ContainsKey($marked)) { $rel = $relative[$marked] }
    return Resolve-ProfileDir $Root $paths[$marked] $rel
  }
  return $null
}

function Find-Profile {
  foreach ($root in Get-FirefoxRoots) {
    $found = Get-DefaultProfile $root
    if ($found -and (Test-Path -LiteralPath $found -PathType Container)) {
      return $found
    }
  }
  return $null
}

function Test-FirefoxRunning {
  return [bool](Get-Process -Name "firefox" -ErrorAction SilentlyContinue)
}

function Read-Lines([string]$File) {
  if (Test-Path -LiteralPath $File -PathType Leaf) {
    [System.IO.File]::ReadAllLines($File)
  }
}

function Write-Lines([string]$File, [string[]]$Lines) {
  $text = ""
  if ($Lines -and $Lines.Count -gt 0) {
    $text = ($Lines -join "`r`n") + "`r`n"
  }
  [System.IO.File]::WriteAllText($File, $text, $Utf8)
}

function Get-StrippedLines([string]$File) {
  $skip = $false
  foreach ($line in Read-Lines $File) {
    if ($line.StartsWith($BlockBegin)) { $skip = $true; continue }
    if ($line -eq $BlockEnd) { $skip = $false; continue }
    if (-not $skip) { $line }
  }
}

function Get-BlockPrefs([string]$Dir) {
  $inside = $false
  foreach ($line in Read-Lines (Join-Path $Dir "user.js")) {
    if ($line.StartsWith($BlockBegin)) { $inside = $true; continue }
    if ($line -eq $BlockEnd) { $inside = $false; continue }
    if ($inside -and $line.StartsWith('user_pref("tahoefox.')) { $line }
  }
}

function Get-MigratedPrefs([string]$Dir) {
  if ($NoMigrate) {
    return
  }
  foreach ($line in Read-Lines (Join-Path $Dir "prefs.js")) {
    if ($line -match '^user_pref\("gwfox\.[^"]+", ' -and -not $line.Contains('"gwfox.safari"')) {
      'user_pref("tahoefox.' + $line.Substring('user_pref("gwfox.'.Length)
    }
  }
}

function Copy-CarriedPrefs([string]$Dir) {
  $prefs = Join-Path $Dir "prefs.js"
  $existing = @(Read-Lines $prefs)
  $seen = @{}
  foreach ($line in @(Get-BlockPrefs $Dir) + @(Get-MigratedPrefs $Dir)) {
    $name = $line.Substring('user_pref("'.Length)
    $name = $name.Substring(0, $name.IndexOf('"'))
    if ($seen.ContainsKey($name)) { continue }
    $seen[$name] = $true
    $prefix = 'user_pref("' + $name + '",'
    if (@($existing | Where-Object { $_.StartsWith($prefix) }).Count -gt 0) { continue }
    Say "Setting $name in prefs.js"
    if (-not $DryRun) {
      [System.IO.File]::AppendAllText($prefs, $line + "`r`n", $Utf8)
    }
  }
}

function Get-PrefBlock {
  $BlockBegin
  'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'
  'user_pref("svg.context-properties.content.enabled", true);'
  'user_pref("widget.windows.mica", true);'
  'user_pref("widget.windows.mica.toplevel-backdrop", 2);'
  $BlockEnd
}

function Get-Backups([string]$Dir) {
  Get-ChildItem -LiteralPath $Dir -Directory -Filter "chrome.$Name-backup-*" -ErrorAction SilentlyContinue | Sort-Object Name
}

function Install-Theme([string]$Dir) {
  $chrome = Join-Path $Dir "chrome"
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"

  $hasFiles = (Test-Path -LiteralPath $chrome -PathType Container) -and @(Get-ChildItem -LiteralPath $chrome -Force).Count -gt 0
  if ($hasFiles -and @(Get-Backups $Dir).Count -eq 0) {
    $backup = Join-Path $Dir "chrome.$Name-backup-$stamp"
    Say "Backing up the current chrome folder to $(Split-Path -Leaf $backup)"
    Invoke-Step "copy $chrome to $backup" { Copy-Item -LiteralPath $chrome -Destination $backup -Recurse }
  }
  Invoke-Step "create $chrome" { New-Item -ItemType Directory -Path $chrome -Force | Out-Null }

  foreach ($f in $Files) {
    $src = Join-Path $SrcDir $f
    $dst = Join-Path $chrome $f
    Invoke-Step "remove $dst" {
      if (Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath $dst -Force
      }
    }
    if ($Link) {
      $done = $false
      if ($f -ne "userContent.css") {
        Say "Linking $f"
        if ($DryRun) {
          Say "  [dry run] symlink $dst -> $src"
          continue
        }
        try {
          New-Item -ItemType SymbolicLink -Path $dst -Target $src | Out-Null
          $done = $true
        } catch {
          Say "Could not create a symbolic link (turn on Developer Mode to allow it), trying a hard link"
        }
      }
      if (-not $done) {
        Say "Hard-linking $f"
        if ($DryRun) {
          Say "  [dry run] hard link $dst -> $src"
          continue
        }
        try {
          New-Item -ItemType HardLink -Path $dst -Target $src | Out-Null
          $done = $true
        } catch {
          Say "Could not hard-link $f, copying it instead"
        }
      }
      if (-not $done) {
        Copy-Item -LiteralPath $src -Destination $dst
      }
    } else {
      Say "Copying $f"
      Invoke-Step "copy $src to $dst" { Copy-Item -LiteralPath $src -Destination $dst }
    }
  }

  Copy-CarriedPrefs $Dir

  Say "Writing preferences to user.js"
  if ($DryRun) {
    foreach ($line in Get-PrefBlock) { Say "  [dry run] $line" }
  } else {
    $userJs = Join-Path $Dir "user.js"
    Write-Lines $userJs (@(Get-StrippedLines $userJs) + @(Get-PrefBlock))
  }
}

function Uninstall-Theme([string]$Dir) {
  $chrome = Join-Path $Dir "chrome"
  foreach ($f in $Files) {
    $dst = Join-Path $chrome $f
    if (Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue) {
      Say "Removing $f"
      Invoke-Step "remove $dst" { Remove-Item -LiteralPath $dst -Force }
    }
  }
  $first = @(Get-Backups $Dir) | Select-Object -First 1
  if ($first) {
    Say "Restoring files from $($first.Name)"
    Invoke-Step "copy $($first.FullName) into $chrome" {
      New-Item -ItemType Directory -Path $chrome -Force | Out-Null
      Get-ChildItem -LiteralPath $first.FullName -Force | Copy-Item -Destination $chrome -Recurse -Force
    }
  }
  $userJs = Join-Path $Dir "user.js"
  if (Test-Path -LiteralPath $userJs -PathType Leaf) {
    Say "Removing Tahoefox preferences from user.js"
    if (-not $DryRun) {
      Write-Lines $userJs @(Get-StrippedLines $userJs)
    }
  }
  Say "Tahoefox's own about:config switches (tahoefox.*) stay in place; reset them there if you like."
}

if ($Help) {
  Show-Usage
  exit 0
}

$dir = $ProfilePath
if (-not $dir) {
  $dir = Find-Profile
  if (-not $dir) {
    [Console]::Error.WriteLine("Could not find a Firefox profile. Pass one with -ProfilePath (see about:profiles).")
    exit 1
  }
}
if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
  [Console]::Error.WriteLine("Profile folder not found: $dir")
  exit 1
}
$dir = (Resolve-Path -LiteralPath $dir).ProviderPath

if ((Test-FirefoxRunning) -and -not $DryRun -and -not $Force) {
  [Console]::Error.WriteLine("Firefox is running. Quit it first, then run the installer again.")
  exit 1
}

Say "Profile: $dir"
if ($Uninstall) {
  Uninstall-Theme $dir
  Say "Done. Start Firefox to go back to the stock look."
} else {
  Install-Theme $dir
  Say "Done. Start Firefox to see Tahoefox."
}
