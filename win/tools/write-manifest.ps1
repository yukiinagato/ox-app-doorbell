param(
    [Parameter(Mandatory = $true)][string]$ArtifactRoot,
    [Parameter(Mandatory = $true)][string]$BuildId,
    [Parameter(Mandatory = $true)][string]$SourceDateEpoch,
    [Parameter(Mandatory = $true)][string]$SigningMode
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $ArtifactRoot).Path
$manifest = Join-Path $root 'SHA256SUMS'
$files = Get-ChildItem -LiteralPath $root -File -Recurse |
    Where-Object { $_.FullName -ne $manifest } |
    Sort-Object { $_.FullName.Substring($root.Length).Replace('\', '/') }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("build_id=$BuildId")
$lines.Add("source_date_epoch=$SourceDateEpoch")
$lines.Add("signing_mode=$SigningMode")
foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    $lines.Add("$hash *$relative")
}
[System.IO.File]::WriteAllLines($manifest, $lines,
    (New-Object System.Text.UTF8Encoding($false)))
