param([Parameter(Mandatory = $true)][string]$Router)
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"
function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}
$rpc = ReadEnv ".env.mainnet" "RPC_URL"
$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$FACTORY = ($j.transactions | Where-Object { $_.contractName -eq "PairPadLaunchFactory" -and $_.transactionType -like "CREATE*" }).contractAddress
$ctor = (& $cast abi-encode "constructor(address,address,address,address)" `
  0x8366a39CC670B4001A1121B8F6A443A643e40951 $FACTORY `
  0xCaf681a66D020601342297493863E78C959E5cb2 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 | Out-String).Trim()
& $forge verify-contract $Router src/v2/PairPadRouter.sol:PairPadRouter `
  --chain-id 4663 --verifier sourcify --constructor-args $ctor --watch 2>&1 | Out-String
Write-Output "VERIFY-EXIT=$LASTEXITCODE"
