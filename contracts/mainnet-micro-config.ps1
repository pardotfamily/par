# Adds (or disables) the small launch config used to rehearse graduations on
# mainnet without spending 4.2 ETH. Same 2.5:1 shape as config 0, so the curve
# and the pool seed behave the same way; only the scale is different.
#
#   .\mainnet-micro-config.ps1            adds the config if it is missing, prints its id
#   .\mainnet-micro-config.ps1 -Disable   disables it so nobody can launch on it any more
param([switch]$Disable)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"

function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}
$rpc = ReadEnv ".env.mainnet" "RPC_URL"
if (-not $rpc) { $rpc = "https://rpc.mainnet.chain.robinhood.com" }
$feePk = ReadEnv ".env.mainnet.fee" "PRIVATE_KEY"

$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$FACTORY = ($j.transactions | Where-Object { $_.contractName -eq "PairPadLaunchFactory" -and $_.transactionType -like "CREATE*" }).contractAddress
Write-Output "factory $FACTORY"

# supply 1e9 * 1e18, phantom 0.0004 ETH, threshold 0.001 ETH, tick spacing 10.
# Fee is the hook's global 1%, not a per-config setting any more.
$supply    = "1000000000000000000000000000"
$phantom   = "400000000000000"
$threshold = "1000000000000000"
$sig = "(uint256,uint256,uint256,int24,bool)"

$count = [int](& $cast call $FACTORY "launchConfigCount()(uint256)" --rpc-url $rpc).Trim()
Write-Output "launchConfigCount = $count"

if ($Disable) {
  if ($count -lt 2) { Write-Output "no config 1 to disable"; exit 0 }
  $r = & $cast send $FACTORY --rpc-url $rpc --private-key $feePk "updateLaunchConfig(uint256,$sig)" 1 "($supply,$phantom,$threshold,10,false)" 2>&1 | Out-String
  Write-Output ($r | Select-String "status" | Out-String).Trim()
} elseif ($count -lt 2) {
  $r = & $cast send $FACTORY --rpc-url $rpc --private-key $feePk "addLaunchConfig($sig)" "($supply,$phantom,$threshold,10,true)" 2>&1 | Out-String
  Write-Output ($r | Select-String "status" | Out-String).Trim()
} else {
  Write-Output "config 1 already exists"
}

Write-Output "config 1: $(& $cast call $FACTORY "getLaunchConfig(uint256)($sig)" 1 --rpc-url $rpc)"
Write-Output "preview (ETH): $(& $cast call $FACTORY 'previewQuoteEconomics(uint256,address)(uint256,uint256)' 1 0x0000000000000000000000000000000000000000 --rpc-url $rpc)"
