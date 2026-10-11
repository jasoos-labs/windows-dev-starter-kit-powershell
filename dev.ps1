# Dev — universal CGT source/update/build/test/run helpers

function Get-DevRoot {
    $drive = (Get-Location).Drive.Root
    if (-not $drive) { return $null }
    return (Join-Path $drive "dev")
}

function Assert-Dev {
    $devRoot = Get-DevRoot
    if (-not $devRoot -or -not (Test-Path $devRoot -PathType Container)) {
        Write-Host "DEV : FAIL - \dev not found on current drive. Wrong development drive?"
        return $false
    }

    $current = (Get-Location).Path.TrimEnd('\')
    $dev = (Resolve-Path $devRoot).Path.TrimEnd('\')
    if ($current -ne $dev -and -not $current.StartsWith($dev + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "DEV : FAIL - current folder is not under $dev"
        return $false
    }
    return $true
}

function Get-Project {
    $root = (Get-Location).Path
    $name = Split-Path $root -Leaf
    $type = "Unknown"; $build = $null; $test = $null; $run = $null

    $sln = Get-ChildItem $root -Filter *.sln -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $slnx = Get-ChildItem $root -Filter *.slnx -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $csproj = Get-ChildItem $root -Filter *.csproj -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sln -or $slnx -or $csproj) {
        $type = ".NET"; $build = { dotnet build }; $test = { dotnet test --no-build }; $run = { dotnet run }
    }

    $pkgPath = Join-Path $root "package.json"
    if (Test-Path $pkgPath) {
        try {
            $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Host "PROJECT : FAIL - invalid package.json: $($_.Exception.Message)"
            return [PSCustomObject]@{ Name=$name; Root=$root; Type="Unknown"; Build=$null; Test=$null; Run=$null }
        }
        $deps = @()
        if ($pkg.dependencies)    { $deps += $pkg.dependencies.PSObject.Properties.Name }
        if ($pkg.devDependencies) { $deps += $pkg.devDependencies.PSObject.Properties.Name }

        if ($deps -contains "electron") { $type = "Electron" }
        elseif ($deps -contains "expo") { $type = "Expo / React Native" }
        elseif ($deps -contains "react-native") { $type = "React Native" }
        elseif ($deps -contains "vite") { $type = "Vite" }
        elseif ($deps -contains "react") { $type = "React" }
        else { $type = "Node" }

        if ($pkg.scripts.build) { $build = { npm run build } }
        if ($pkg.scripts.test)  { $test = { npm test } }
        if ($pkg.scripts.dev) { $run = { npm run dev } }
        elseif ($pkg.scripts.start) { $run = { npm start } }
    }

    [PSCustomObject]@{ Name=$name; Root=$root; Type=$type; Build=$build; Test=$test; Run=$run }
}

function Get-ProjectInfo {
    $p = Get-Project
    Write-Host ""
    Write-Host "Project : $($p.Name)"
    Write-Host "Root    : $($p.Root)"
    Write-Host "Tech    : $($p.Type)"
    Write-Host ""
}

Set-Alias -Name tech -Value Get-ProjectInfo
Set-Alias -Name gpi -Value Get-ProjectInfo

function Get-DefaultExcludedFolders {
    return @(
        ".git", "node_modules", ".pnpm-store", "bin", "obj", "dist",
        "build", "out", "target", "Debug", "Release", "x64", "x86",
        "coverage", "__pycache__", ".pytest_cache", ".mypy_cache",
        ".ruff_cache", ".tox", ".nox", ".venv", "venv", "env",
        ".gradle", ".kotlin", ".cxx", ".externalNativeBuild",
        "intermediates", "outputs", "captures", "DerivedData", "Pods",
        ".next", ".nuxt", ".output", ".angular", ".svelte-kit",
        ".vite", ".parcel-cache", ".cache", ".terraform", ".serverless",
        ".vs"
    )
}

function Get-DefaultExcludedExtensions {
    return @(
        ".zip", ".7z", ".rar", ".tar", ".gz", ".log", ".tmp", ".cache",
        ".pyc", ".pyo", ".class", ".dll", ".exe", ".pdb", ".obj", ".o",
        ".so", ".dylib", ".apk", ".aab", ".ipa",
        ".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus", ".aac", ".wma", ".aiff", ".aif",
        ".mp4", ".mkv", ".mov", ".avi", ".mpeg", ".mpg", ".webm"
    )
}

function Get-IgnoreFiles {
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = [IO.Path]::GetFullPath($Root)
    $dirs = [System.Collections.Generic.List[string]]::new()
    $cursor = $rootPath
    while ($cursor) {
        $dirs.Add($cursor)
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }

    $files = @()
    foreach ($dir in $dirs) {
        $ignore = Join-Path $dir '.gitignore'
        if (Test-Path -LiteralPath $ignore -PathType Leaf) {
            $files += [pscustomobject]@{ Path=$ignore; Base=$dir }
        }
    }
    return $files
}

function ConvertTo-IgnoreRegex {
    param([string]$Pattern)
    $escaped = [Regex]::Escape($Pattern)
    $escaped = $escaped.Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
    return '^' + $escaped + '$'
}

function Test-IgnoreRuleMatch {
    param([string]$RelativePath, [string]$Pattern, [switch]$DirectoryOnly, [switch]$IsDirectory)

    $relative = $RelativePath.Replace([char]92, '/').TrimStart('/')
    $pattern = $Pattern.Replace([char]92, '/').TrimStart('/')
    if (-not $pattern) { return $false }

    $hasSlash = $pattern.Contains('/')
    $regex = ConvertTo-IgnoreRegex $pattern
    $parts = @($relative -split '/')

    if ($hasSlash) {
        $candidate = $relative
        if ($DirectoryOnly) {
            $lastDirectoryIndex = if ($IsDirectory) { $parts.Count - 1 } else { $parts.Count - 2 }
            for ($i = 0; $i -le $lastDirectoryIndex; $i++) {
                $candidate = ($parts[0..$i] -join '/')
                if ($candidate -match $regex) { return $true }
            }
            return $false
        }
        return $candidate -match $regex
    }

    if ($DirectoryOnly) {
        $lastDirectoryIndex = if ($IsDirectory) { $parts.Count - 1 } else { $parts.Count - 2 }
        if ($lastDirectoryIndex -lt 0) { return $false }
        return @($parts[0..$lastDirectoryIndex] | Where-Object { $_ -match $regex }).Count -gt 0
    }
    return @($parts | Where-Object { $_ -match $regex }).Count -gt 0
}

function Test-SharedExcluded {
    param(
        [Parameter(Mandatory)][string]$FullName,
        [Parameter(Mandatory)][string]$Root,
        [switch]$Full
    )

    if ($Full) { return $false }
    $fullPath = [IO.Path]::GetFullPath($FullName)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([char]92, [char]47)
    if (-not $fullPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $relative = $fullPath.Substring($rootPath.Length).TrimStart([char]92, [char]47)
    $isDirectory = Test-Path -LiteralPath $fullPath -PathType Container
    $ignoreFiles = @(Get-IgnoreFiles -Root $rootPath)

    if ($ignoreFiles.Count -eq 0) {
        $parts = @($relative -split '[\\/]')
        foreach ($part in $parts) {
            if ((Get-DefaultExcludedFolders) -contains $part) { return $true }
        }
        return (Get-DefaultExcludedExtensions) -contains ([IO.Path]::GetExtension($fullPath).ToLowerInvariant())
    }

    $ignored = $false
    foreach ($ignoreFile in ($ignoreFiles | Sort-Object { $_.Base.Length })) {
        $base = [IO.Path]::GetFullPath($ignoreFile.Base).TrimEnd([char]92, [char]47)
        if ($fullPath -ne $base -and -not $fullPath.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $localRelative = $fullPath.Substring($base.Length).TrimStart([char]92, [char]47).Replace([char]92, '/')
        foreach ($line in Get-Content -LiteralPath $ignoreFile.Path) {
            $rule = $line.Trim()
            if (-not $rule -or $rule.StartsWith('#')) { continue }
            $negate = $rule.StartsWith('!')
            if ($negate) { $rule = $rule.Substring(1) }
            if (-not $rule) { continue }
            $directoryOnly = $rule.EndsWith('/')
            $rule = $rule.TrimEnd('/')
            if (Test-IgnoreRuleMatch -RelativePath $localRelative -Pattern $rule -DirectoryOnly:$directoryOnly -IsDirectory:$isDirectory) {
                $ignored = -not $negate
            }
        }
    }
    return $ignored
}

function Get-ProjectFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$Full
    )
    $resolved = [IO.Path]::GetFullPath($Root)
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($resolved)
    while ($pending.Count -gt 0) {
        $folder = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue) {
            if (Test-SharedExcluded -FullName $item.FullName -Root $resolved -Full:$Full) { continue }
            if ($item.PSIsContainer) {
                if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($item.FullName) }
            } else {
                $item
            }
        }
    }
}

function Test-IsTextFile {
    param([Parameter(Mandatory)][string]$Path)
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $buffer = New-Object byte[] 4096
        $read = $stream.Read($buffer, 0, $buffer.Length)
        for ($i = 0; $i -lt $read; $i++) { if ($buffer[$i] -eq 0) { return $false } }
        return $true
    } catch { return $false }
    finally { if ($stream) { $stream.Dispose() } }
}

function Test-SourceExcluded {
    param([string]$FullName, [string]$Root, [switch]$Full)
    return Test-SharedExcluded -FullName $FullName -Root $Root -Full:$Full
}

function Test-SyncConflicts {
    param(
        [string]$Root = (Get-Location).Path,
        [switch]$IgnoreGenerated
    )

    $conflicts = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -Filter '*.sync-conflict-*' -ErrorAction SilentlyContinue)

    if ($IgnoreGenerated) {
        $conflicts = @($conflicts | Where-Object {
            $relative = $_.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
            $parts = $relative -split '[\\/]'
            -not (($parts -contains 'bin') -or ($parts -contains 'obj'))
        })
    }

    if ($conflicts.Count -eq 0) { return $true }

    Write-Host "SYNC : FAIL - Syncthing conflict files found"
    $conflicts | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host $_ }
    return $false
}

# sclean — interactively remove Syncthing conflict copies under the current folder
function Clean-SyncConflicts {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    $root = (Get-Location).Path
    $conflicts = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File `
        -Filter '*.sync-conflict-*' -ErrorAction SilentlyContinue)

    if ($conflicts.Count -eq 0) {
        Write-Host "SCLEAN : no Syncthing conflict files under $root"
        return
    }

    Write-Host "SCLEAN : found $($conflicts.Count) Syncthing conflict file(s):"
    $conflicts | ForEach-Object { Write-Host "  $($_.FullName)" }

    $removed = 0
    foreach ($file in $conflicts) {
        if ($PSCmdlet.ShouldProcess($file.FullName, 'Delete Syncthing conflict file')) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $removed++
            }
            catch {
                Write-Warning "Could not delete '$($file.FullName)': $($_.Exception.Message)"
            }
        }
    }

    if ($WhatIfPreference) {
        Write-Host "SCLEAN : preview complete; no files deleted"
    }
    else {
        Write-Host "SCLEAN : deleted $removed of $($conflicts.Count) conflict file(s)"
    }
}

Set-Alias -Name sclean -Value Clean-SyncConflicts
Set-Alias -Name csc -Value Clean-SyncConflicts
Set-Alias -Name scclean -Value Clean-SyncConflicts

function New-SourcePackage {
    [CmdletBinding()]
    param([switch]$Full)

    if (-not (Assert-Dev)) { return }
    if (-not (Test-SyncConflicts)) {
        Write-Host "SRC : FAIL - resolve conflicts before packaging source"
        return
    }
    $p = Get-Project
    $devRoot = Get-DevRoot
    $outDir = Join-Path $devRoot "source"
    New-Item $outDir -ItemType Directory -Force | Out-Null
    $suffix = if ($Full) { "-full-src.zip" } else { "-src.zip" }
    $zip = Join-Path $outDir "$($p.Name)-$(Get-Date -Format 'yyyyMMdd-HHmmss')$suffix"

    $files = @(Get-ProjectFiles -Root $p.Root -Full:$Full | Select-Object -ExpandProperty FullName)

    $sourceRoot = (Join-Path $devRoot "source").TrimEnd('\')
    $files = @($files | Where-Object {
        (Test-Path -LiteralPath $_ -PathType Leaf) -and
        (-not (Test-SourceExcluded -FullName $_ -Root $p.Root -Full:$Full)) -and
        (-not $_.StartsWith($sourceRoot + '\', [System.StringComparison]::OrdinalIgnoreCase))
    })

    if (-not $files -or $files.Count -eq 0) { Write-Host "SRC : FAIL - no source files found"; return }

    $temp = Join-Path $env:TEMP ("DevSrc-" + [guid]::NewGuid())
    New-Item $temp -ItemType Directory -Force | Out-Null
    try {
        foreach ($file in $files) {
            $relative = $file.Substring($p.Root.TrimEnd('\').Length).TrimStart('\')
            $dest = Join-Path $temp $relative
            $destDir = Split-Path $dest -Parent
            if ($destDir) { New-Item $destDir -ItemType Directory -Force | Out-Null }
            Copy-Item $file $dest -Force
        }
        Compress-Archive -Path (Join-Path $temp "*") -DestinationPath $zip -CompressionLevel Optimal
        Write-Host ""; Write-Host "SRC : PASS"; Write-Host "$($files.Count) files"; Write-Host $zip
    } finally {
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Set-Alias -Name src -Value New-SourcePackage

function Apply-Update {
    param([string]$ZipName)

    if (-not (Assert-Dev)) { return }
    $p = Get-Project
    $sourceDir = Join-Path (Get-DevRoot) "source"

    if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
        Write-Host "UPD : FAIL - source folder not found: $sourceDir"
        return
    }

    if ($ZipName) {
        $candidatePath = if ([IO.Path]::IsPathRooted($ZipName)) {
            $ZipName
        } else {
            Join-Path $sourceDir $ZipName
        }
        $candidate = Get-Item -LiteralPath $candidatePath -File -ErrorAction SilentlyContinue
    } else {
        $candidate = Get-ChildItem -LiteralPath $sourceDir -Filter "$($p.Name)-*-upd.zip" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }

    if (-not $candidate) {
        Write-Host ""; Write-Host "UPD : FAIL"
        Write-Host "No $($p.Name)-*-upd.zip found in $sourceDir"
        return
    }

    if ($candidate.Extension -ne ".zip") {
        Write-Host "UPD : FAIL - update must be a .zip file"
        return
    }

    if ($candidate.Name -notlike "$($p.Name)-*-upd.zip") {
        Write-Host "UPD : FAIL - ZIP name does not match current project '$($p.Name)'"
        Write-Host $candidate.Name
        return
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($candidate.FullName)
        $entries = @($archive.Entries | Where-Object { $_.Name })

        if ($entries.Count -eq 0) {
            Write-Host "UPD : FAIL - ZIP contains no files"
            return
        }

        foreach ($entry in $entries) {
            $rel = $entry.FullName.Replace('/', '\').TrimStart('\')

            if ([IO.Path]::IsPathRooted($entry.FullName) -or
                $rel -match '(^|\\)\.\.(\\|$)' -or
                $rel.Contains(':')) {
                Write-Host "UPD : FAIL - unsafe ZIP path: $($entry.FullName)"
                return
            }
        }

        # Require project-relative paths. Catch the common flattened-file mistake:
        # a root ZIP file whose same filename already exists below a project subfolder.
        foreach ($entry in $entries) {
            $rel = $entry.FullName.Replace('/', '\').TrimStart('\')
            if ($rel -notmatch '\\') {
                $rootTarget = Join-Path $p.Root $rel
                if (-not (Test-Path -LiteralPath $rootTarget -PathType Leaf)) {
                    $sameName = @(Get-ChildItem -LiteralPath $p.Root -Recurse -File -Filter $entry.Name -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.FullName -notmatch '[\\](bin|obj|node_modules|\.git)[\\]'
                        })
                    if ($sameName.Count -gt 0) {
                        Write-Host "UPD : FAIL - probable flattened path: $rel"
                        Write-Host "Existing project file(s):"
                        $sameName | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host $_ }
                        Write-Host "Update ZIP files must use full paths relative to the project root."
                        return
                    }
                }
            }
        }

        Write-Host ""
        Write-Host "Update : $($candidate.Name)"
        Write-Host "Project: $($p.Root)"
        Write-Host "About to update:"
        $entries | ForEach-Object {
            Write-Host ("  " + $_.FullName.Replace('/', '\'))
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
    }

    Write-Host ""
    Write-Host "ENTER = proceed now | Ctrl+C = cancel"
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $remaining = [Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        Write-Host -NoNewline ("`rAuto proceed in {0,2}s... " -f $remaining)
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) { break }
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "`rProceeding...          "

    $temp = Join-Path $env:TEMP ("DevUpd-" + [guid]::NewGuid())
    New-Item $temp -ItemType Directory -Force | Out-Null

    try {
        Expand-Archive -LiteralPath $candidate.FullName -DestinationPath $temp -Force

        # ZIP entries are always project-relative. Never strip a top-level
        # directory; doing so would flatten paths such as Shell\File.cs.
        $source = $temp

        $profileDir = Split-Path $PROFILE -Parent
        $target = if (Test-Path -LiteralPath (Join-Path $source "dev.ps1") -PathType Leaf) {
            $profileDir
        } else {
            $p.Root
        }

        # Final containment check after extraction.
        $sourceRoot = (Resolve-Path -LiteralPath $source).Path.TrimEnd('\')
        $targetRoot = [IO.Path]::GetFullPath($target).TrimEnd('\')

        foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
            $dest = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
            if ($dest -ne $targetRoot -and
                -not $dest.StartsWith($targetRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "UPD : FAIL - destination escapes target: $relative"
                return
            }
        }

        New-Item -Path $target -ItemType Directory -Force | Out-Null

        # Copy each extracted file explicitly by its project-relative path.
        # Never flatten subdirectories.
        foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
            $dest = Join-Path $targetRoot $relative
            $destDir = Split-Path -Parent $dest

            if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
                New-Item -Path $destDir -ItemType Directory -Force | Out-Null
            }

            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        }

        Write-Host "UPD PASS : $($candidate.Name)"
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Set-Alias -Name upd -Value Apply-Update

function Invoke-DevCheck {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [Parameter(Mandatory = $true)][string]$Label
    )

    # Reset stale native-command status. Send output to the console so the
    # caller receives only the final Boolean result.
    $global:LASTEXITCODE = 0
    try {
        & $Command 2>&1 | Out-Host
        $commandSucceeded = $?
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Host "$Label : FAIL - $($_.Exception.Message)"
        return $false
    }

    if ($commandSucceeded -and $exitCode -eq 0) {
        Write-Host "$Label : PASS"
        return $true
    }

    Write-Host "$Label : FAIL (exit code $exitCode)"
    return $false
}

function Build-Project {
    if (-not (Assert-Dev)) { return $false }
    if (-not (Test-SyncConflicts)) {
        Write-Host "BUILD : FAIL - remove or resolve conflicts, then run bld again."
        return $false
    }

    $p = Get-Project
    if (-not $p.Build) { Write-Host "BUILD : N/A"; return $true }

    return (Invoke-DevCheck -Command $p.Build -Label "BUILD")
}

function Test-Project {
    if (-not (Assert-Dev)) { return $false }
    if (-not (Test-SyncConflicts)) {
        Write-Host "TEST : FAIL - remove or resolve conflicts, then run tst again."
        return $false
    }
    $p = Get-Project
    if (-not $p.Test) { Write-Host "TEST : N/A"; return $true }

    return (Invoke-DevCheck -Command $p.Test -Label "TEST")
}

function Run-Project {
    if (-not (Assert-Dev)) { return }
    if (-not (Test-SyncConflicts)) {
        Write-Host "RUN : FAIL - remove or resolve conflicts, then run again."
        return
    }
    $p = Get-Project
    if (-not $p.Run) { Write-Host "RUN : FAIL - no run command detected"; return }
    Write-Host "RUN : $($p.Type)"
    & $p.Run
}

function Build-Test-Run {
    if (-not (Assert-Dev)) { return }
    if (-not (Build-Project)) {
        Write-Host "GO : STOPPED - build failed; tests and run were skipped."
        return
    }
    if (-not (Test-Project)) {
        Write-Host "GO : STOPPED - tests failed; run was skipped."
        return
    }

    Write-Host "GO : BUILD AND TEST PASSED; starting the app."
    Run-Project
}

Set-Alias -Name bld -Value Build-Project
Set-Alias -Name tst -Value Test-Project
Set-Alias -Name run -Value Run-Project
Set-Alias -Name go -Value Build-Test-Run

function Select-Project {
    $devRoot = $null

    foreach ($candidate in @("D:\dev", "E:\dev")) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $devRoot = $candidate
            break
        }
    }

    if (-not $devRoot) {
        Write-Host "CDD : FAIL - neither D:\dev nor E:\dev exists"
        return
    }

    $folders = @(
        Get-ChildItem -LiteralPath $devRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "source" } |
        Sort-Object Name
    )

    if ($folders.Count -eq 0) {
        Write-Host "CDD : FAIL - no project folders found under $devRoot"
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "CDD - $devRoot"
    $form.Width = 420
    $form.Height = 500
    $form.StartPosition = "CenterScreen"
    $form.KeyPreview = $true

    $list = New-Object System.Windows.Forms.ListBox
    $list.Dock = "Fill"
    $list.Font = New-Object System.Drawing.Font("Segoe UI", 12)

    foreach ($folder in $folders) {
        [void]$list.Items.Add($folder.Name)
    }

    $form.Controls.Add($list)

    $choose = {
        if ($list.SelectedItem) {
            $form.Tag = $list.SelectedItem.ToString()
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    }

    $list.Add_DoubleClick($choose)
    $list.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            & $choose
            $_.SuppressKeyPress = $true
        }
    })

    $form.Add_Shown({
        $form.Activate()
        $list.Focus()
        if ($list.Items.Count -gt 0) {
            $list.SelectedIndex = 0
        }
    })

    $result = $form.ShowDialog()

    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $form.Tag) {
        $target = Join-Path $devRoot $form.Tag
        Set-Location -LiteralPath $target
        Write-Host "CDD : $target"
    }

    $form.Dispose()
}

Set-Alias -Name cdd -Value Select-Project

function Find-File {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)][string]$Pattern = '*',
        [string]$Path = '.',
        [switch]$Full
    )
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $matches = @(Get-ProjectFiles -Root $root -Full:$Full |
        Where-Object { $_.Name -like $Pattern } |
        Sort-Object LastWriteTime -Descending)
    if ($matches.Count -eq 0) { Write-Host "FFF : no files matching '$Pattern' under $root"; return }
    $matches | Select-Object FullName, LastWriteTime, @{Name='SizeKB';Expression={[math]::Round($_.Length / 1KB, 1)}}
}
Set-Alias -Name fff -Value Find-File

function Find-Text {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)][string]$Text,
        [string]$Path = '.',
        [switch]$Full
    )
    $root = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $files = Get-ProjectFiles -Root $root -Full:$Full
    $results = foreach ($file in $files) {
        if (-not (Test-IsTextFile -Path $file.FullName)) { continue }
        try {
            Select-String -LiteralPath $file.FullName -SimpleMatch -Pattern $Text -ErrorAction Stop |
                Select-Object Path, LineNumber, Line
        } catch { }
    }
    if (-not $results) { Write-Host "FFT : no text match for '$Text' under $root"; return }
    $results
}
Set-Alias -Name fft -Value Find-Text

function Get-ProjectStatus {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host 'GPS : git is not installed'; return }
    git status --short --branch
}
Set-Alias -Name pjs -Value Get-ProjectStatus

function Set-ConsoleUtf8 {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
    Write-Host "UTF : console input, output, and native pipeline set to UTF-8"
}
Set-Alias -Name utf -Value Set-ConsoleUtf8

function Get-TerminalInfo {
    $windowSize = $null
    try { $windowSize = $Host.UI.RawUI.WindowSize } catch { }
    [pscustomobject]@{
        PowerShell      = $PSVersionTable.PSVersion.ToString()
        Host            = $Host.Name
        Folder          = (Get-Location).Path
        ConsoleInput    = [Console]::InputEncoding.EncodingName
        ConsoleOutput   = [Console]::OutputEncoding.EncodingName
        NativePipe      = $OutputEncoding.EncodingName
        WindowSize      = if ($windowSize) { "{0} x {1}" -f $windowSize.Width, $windowSize.Height } else { "Not available" }
    } | Format-List
}
Set-Alias -Name tif -Value Get-TerminalInfo

function Open-CurrentFolder {
    [CmdletBinding()]
    param([string]$Path = (Get-Location).Path)

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    $folder = if ($item.PSIsContainer) { $item.FullName } else { Split-Path -Parent $item.FullName }
    Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $folder)
}
Set-Alias -Name ocf -Value Open-CurrentFolder

function Show-Processes {
    Get-Process |
        Sort-Object ProcessName |
        Select-Object ProcessName, Id,
            @{Name='MemoryMB';Expression={[math]::Round($_.WorkingSet64 / 1MB, 1)}},
            MainWindowTitle |
        Format-Table -AutoSize
}
Set-Alias -Name pro -Value Show-Processes

function Find-Process {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position=0)][string]$Name)

    $matches = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName.IndexOf($Name, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Sort-Object ProcessName)
    if ($matches.Count -eq 0) {
        Write-Host "FPR : no running process name contains '$Name'"
        return
    }
    $matches |
        Select-Object ProcessName, Id,
            @{Name='MemoryMB';Expression={[math]::Round($_.WorkingSet64 / 1MB, 1)}},
            MainWindowTitle |
        Format-Table -AutoSize
}
Set-Alias -Name fpr -Value Find-Process

function Stop-ProjectProcess {
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
    param([Parameter(Mandatory, Position=0)][int]$Id)

    $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if (-not $process) {
        Write-Host "SPP : no running process found with ID $Id"
        return
    }
    Write-Host "Selected: $($process.ProcessName) (PID $Id)"
    if ($PSCmdlet.ShouldProcess("$($process.ProcessName) (PID $Id)", 'Stop process')) {
        try {
            Microsoft.PowerShell.Management\Stop-Process -Id $Id -ErrorAction Stop
            Write-Host "SPP : stopped $($process.ProcessName) (PID $Id)"
        } catch {
            Write-Warning "Could not stop process $Id : $($_.Exception.Message)"
        }
    }
}
Set-Alias -Name spp -Value Stop-ProjectProcess

function Dev-Help {
    $commands = @(
        [pscustomobject]@{ Alias='dev'; Description='Show this command list'; FullName='Dev-Help' }
        [pscustomobject]@{ Alias='gpi'; Description='Show project name and technology'; FullName='Get-ProjectInfo' }
        [pscustomobject]@{ Alias='cdd'; Description='Choose a project folder'; FullName='Select-Project' }
        [pscustomobject]@{ Alias='sht'; Description='Browse the project folders and files'; FullName='Show-Tree' }
        [pscustomobject]@{ Alias='fff'; Description='Find files by name or wildcard'; FullName='Find-File' }
        [pscustomobject]@{ Alias='fft'; Description='Search inside readable text files'; FullName='Find-Text' }
        [pscustomobject]@{ Alias='pjs'; Description='Show Git branch and changes'; FullName='Get-ProjectStatus' }
        [pscustomobject]@{ Alias='rpj'; Description='Show recently changed project folders'; FullName='Get-RecentProjects' }
        [pscustomobject]@{ Alias='src'; Description='Package project source files'; FullName='New-SourcePackage' }
        [pscustomobject]@{ Alias='upd'; Description='Apply a project update ZIP'; FullName='Apply-Update' }
        [pscustomobject]@{ Alias='bld'; Description='Build the project'; FullName='Build-Project' }
        [pscustomobject]@{ Alias='tst'; Description='Run project tests'; FullName='Test-Project' }
        [pscustomobject]@{ Alias='run'; Description='Run the project'; FullName='Run-Project' }
        [pscustomobject]@{ Alias='go'; Description='Build, test, then run'; FullName='Build-Test-Run' }
        [pscustomobject]@{ Alias='lsc'; Description='List Syncthing conflict copies'; FullName='List-SyncConflicts' }
        [pscustomobject]@{ Alias='csc'; Description='Remove conflict copies with confirmation'; FullName='Clean-SyncConflicts' }
        [pscustomobject]@{ Alias='utf'; Description='Set console and pipe encoding to UTF-8'; FullName='Set-ConsoleUtf8' }
        [pscustomobject]@{ Alias='tif'; Description='Show terminal and PowerShell details'; FullName='Get-TerminalInfo' }
        [pscustomobject]@{ Alias='ocf'; Description='Open a folder in File Explorer'; FullName='Open-CurrentFolder' }
        [pscustomobject]@{ Alias='pro'; Description='List running processes'; FullName='Show-Processes' }
        [pscustomobject]@{ Alias='fpr'; Description='Find a running process by name'; FullName='Find-Process' }
        [pscustomobject]@{ Alias='spp'; Description='Stop one process by ID; asks first'; FullName='Stop-ProjectProcess' }
    )

    Write-Host "`nWINDOWS DEV STARTER KIT — COMMANDS`n"
    $commands | Format-Table Alias, Description, @{Label='Full command';Expression={$_.FullName}} -AutoSize
    Write-Host @'
Examples:
  fff '*seaport*'          Find files with “seaport” in the name
  fff '*.pptx'             Find PowerPoint files
  fft 'sea terminal'       Search file contents
  fpr chrome              Find Chrome processes
  spp 1234 -WhatIf        Preview stopping process 1234
  dev                     Show this list again

File commands use additive .gitignore rules from the project folder up to the drive root.
If none are found, built-in filters skip common generated folders and large artifacts.
Use -Full to include filtered files. Text search still skips binary files.
'@
}

Set-Alias -Name dev -Value Dev-Help

# Show-Tree — project tree with generated folders excluded by default
function Show-Tree {
    [CmdletBinding()]
    param(
        [string]$Path = ".",
        [int]$Depth = 100,
        [switch]$Lines,
        [Alias("Folder")]
        [switch]$FoldersOnly,
        [Alias("All")]
        [switch]$Full,
        [switch]$Upload
    )

    $resolvedRoot = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $root = $resolvedRoot.Path
    $rootItem = Get-Item -LiteralPath $root -Force


    function Write-TreeBranch {
        param(
            [string]$Folder,
            [string]$Prefix,
            [int]$CurrentDepth
        )

        if ($CurrentDepth -ge $Depth) { return }

        $children = @(Get-ChildItem -LiteralPath $Folder -Force -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.PSIsContainer -or -not $FoldersOnly) -and
                -not (Test-SharedExcluded -FullName $_.FullName -Root $root -Full:$Full)
            } |
            Sort-Object @{ Expression = { -not $_.PSIsContainer } }, Name)

        for ($i = 0; $i -lt $children.Count; $i++) {
            $child = $children[$i]
            $last = $i -eq ($children.Count - 1)
            $branch = if ($last) { "└── " } else { "├── " }
            $label = $child.Name

            if ($Lines -and -not $child.PSIsContainer) {
                try {
                    $lineCount = ([System.IO.File]::ReadLines($child.FullName) |
                        Measure-Object -Line).Lines
                    $label += " [$lineCount lines]"
                }
                catch {
                    $label += " [read error]"
                }
            }

            Write-Output ($Prefix + $branch + $label)

            if ($child.PSIsContainer -and
                -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $nextPrefix = $Prefix + $(if ($last) { "    " } else { "│   " })
                Write-TreeBranch -Folder $child.FullName -Prefix $nextPrefix -CurrentDepth ($CurrentDepth + 1)
            }
        }
    }

    $rootLabel = if ($rootItem.Parent) { $rootItem.Name } else { $rootItem.FullName }
    Write-Output $rootLabel
    Write-TreeBranch -Folder $root -Prefix "" -CurrentDepth 0
}

Set-Alias -Name sht -Value Show-Tree

function Get-RecentProjects {
    $root = (Get-Location).Path
    $folders = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-SharedExcluded -FullName $_.FullName -Root $root) })

    if ($folders.Count -eq 0) {
        Write-Host "RECENT : no folders found"
        return
    }

    $results = foreach ($folder in $folders) {
        $latest = $folder.LastWriteTime

        $latestFile = Get-ProjectFiles -Root $folder.FullName |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($latestFile -and $latestFile.LastWriteTime -gt $latest) {
            $latest = $latestFile.LastWriteTime
        }

        [pscustomobject]@{
            Folder     = $folder.Name
            LastWorked = $latest
        }
    }

    $results |
        Sort-Object LastWorked -Descending |
        Format-Table Folder, @{Label="Last Worked"; Expression={$_.LastWorked.ToString("MM/dd/yyyy HH:mm")}} -AutoSize
}

# slist — list actual Syncthing conflict copies under the current folder
Set-Alias -Name recent -Value Get-RecentProjects
Set-Alias -Name rpj -Value Get-RecentProjects

function List-SyncConflicts {
    $root = (Get-Location).Path
    $conflicts = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File `
        -Filter '*.sync-conflict-*' -ErrorAction SilentlyContinue)

    if ($conflicts.Count -eq 0) {
        Write-Host "SLIST : no Syncthing conflict files under $root"
        return
    }

    $conflicts |
        Sort-Object LastWriteTime -Descending |
        Select-Object FullName, Length, LastWriteTime
}


Set-Alias -Name slist -Value List-SyncConflicts
Set-Alias -Name lsc -Value List-SyncConflicts
