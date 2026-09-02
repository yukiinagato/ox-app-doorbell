param(
    [Parameter(Mandatory = $true)][string]$ArtifactRoot,
    [Parameter(Mandatory = $true)][string]$CertificateThumbprint
)

$ErrorActionPreference = 'Stop'
$thumbprint = $CertificateThumbprint.Replace(' ', '').ToUpperInvariant()
if ($thumbprint -notmatch '^[0-9A-F]{40}$') {
    throw 'CertificateThumbprint must be a 40-character SHA-1 certificate thumbprint.'
}
$signtool = (Get-Command signtool.exe -ErrorAction Stop).Source
$files = Get-ChildItem -LiteralPath $ArtifactRoot -File -Recurse |
    Where-Object { $_.Extension -in '.exe', '.dll' } |
    Sort-Object FullName
if ($files.Count -eq 0) {
    throw 'The release bundle contains no executable files to sign.'
}
foreach ($file in $files) {
    & $signtool sign /sha1 $thumbprint /fd SHA256 $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $($file.FullName)" }
    & $signtool verify /pa /all $file.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signature verification failed: $($file.FullName)" }
}
