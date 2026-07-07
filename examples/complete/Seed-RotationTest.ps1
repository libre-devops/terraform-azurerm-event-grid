<#
.SYNOPSIS
    Seeds (or re-triggers) the live rotation test for the complete example.

.DESCRIPTION
    Stores the storage account's CURRENT active key as a Key Vault secret version whose expiry
    sits inside Key Vault's fixed 30 day near-expiry window, tagged with the rotation contract
    (Kind, CredentialId, ProviderAddress). Key Vault then raises SecretNearExpiry on the fast
    path (observed within about five minutes), Event Grid delivers it to the rotor workflow,
    and the rotor regenerates the INACTIVE key, writes it back as a new secret version with a
    fresh expiry (CredentialId flipped, RotatedBy and RotatedAt stamped), and disables the
    version seeded here.

    Safe to run repeatedly: when the secret already exists its current CredentialId tag is
    carried forward, so each pass exercises the key1/key2 alternation. The caller needs
    data-plane secret rights on the vault (Key Vault Administrator or Secrets Officer) and
    control-plane access to the storage keys; the example vault is network-open by design
    (public tier posture), so no firewall dance is needed.

.PARAMETER ResourceGroup
    Resource group holding the example stack.

.PARAMETER VaultName
    The rotor vault seeded with the secret.

.PARAMETER StorageAccountName
    The storage account whose keys rotate.

.PARAMETER SecretName
    Name of the rotated secret.

.PARAMETER ValidityDays
    Days until the seeded version expires. Keep it under 30 so SecretNearExpiry fires
    immediately rather than waiting for the window.

.EXAMPLE
    ./Seed-RotationTest.ps1

.EXAMPLE
    ./Seed-RotationTest.ps1 -ResourceGroup rg-ldo-uks-dev-002 -VaultName kv-ldo-uks-dev-002
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-ldo-uks-dev-002',
    [string]$VaultName = 'kv-ldo-uks-dev-002',
    [string]$StorageAccountName = 'saldouksdevevt002',
    [string]$SecretName = 'storage-account-key',
    [ValidateRange(1, 29)][int]$ValidityDays = 7
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name LibreDevOpsHelpers)) {
    Install-Module LibreDevOpsHelpers -Scope CurrentUser -Force -AllowClobber
}
Import-Module LibreDevOpsHelpers -Force

$saId = az storage account show -g $ResourceGroup -n $StorageAccountName --query id -o tsv
if ($LASTEXITCODE -ne 0) { throw "Storage account $StorageAccountName not found in $ResourceGroup. Is the complete stack deployed?" }

# Carry the active credential forward on re-triggers so every pass alternates the pair.
$credentialId = 'key1'
$existing = az keyvault secret show --vault-name $VaultName --name $SecretName --query 'tags.CredentialId' -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
    $credentialId = $existing
    Write-LdoLog -Level INFO -Message "Secret exists; carrying forward active credential $credentialId."
}

$keyValue = az storage account keys list -g $ResourceGroup -n $StorageAccountName --query "[?keyName=='$credentialId'].value" -o tsv
$expires = (Get-Date).ToUniversalTime().AddDays($ValidityDays).ToString('yyyy-MM-ddTHH:mm:ssZ')

Write-LdoLog -Level INFO -Message "Seeding $SecretName in $VaultName as $credentialId, expiring $expires (inside the 30 day near-expiry window)."
$version = az keyvault secret set `
    --vault-name $VaultName `
    --name $SecretName `
    --value $keyValue `
    --expires $expires `
    --tags "Kind=AzureStorageAccountKey" "CredentialId=$credentialId" "ProviderAddress=$saId" `
    --query 'id' -o tsv
Assert-LdoLastExitCode -Operation "az keyvault secret set ($SecretName)"

$inactive = if ($credentialId -eq 'key1') { 'key2' } else { 'key1' }
Write-LdoLog -Level SUCCESS -Message "Seeded $version."
Write-LdoLog -Level INFO -Message "Key Vault raises SecretNearExpiry within minutes; watch the rotor run history, then verify: a NEW secret version with CredentialId flipped to $inactive, RotatedBy and RotatedAt stamped, expiry restarted to rotation_validity_days; $inactive regenerated on $StorageAccountName (key hash changes, $credentialId untouched); and this seeded version disabled."
