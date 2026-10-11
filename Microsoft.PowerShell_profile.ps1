# Keep UTF-8 output from native tools readable in Windows PowerShell.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

# NovaDev helpers
. "$PSScriptRoot\dev.ps1"

