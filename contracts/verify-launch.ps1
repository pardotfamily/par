# Verifies a launched token on Sourcify.
#
#   .\verify-launch.ps1 -Token 0x...
#
# The indexer does this on its own after every TokenLaunched event; this is
# the manual fallback. Sourcify matches on the metadata hash, so no
# constructor arguments are needed. Blockscout imports Sourcify matches and
# then marks every other contract with the same bytecode as verified.
param([Parameter(Mandatory = $true)][string]$Token)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"

Write-Output "== src/v2/PairPadLauncherToken.sol:PairPadLauncherToken $Token"
& $forge verify-contract $Token "src/v2/PairPadLauncherToken.sol:PairPadLauncherToken" --chain 4663 --verifier sourcify --watch
Write-Output "EXIT=$LASTEXITCODE"
