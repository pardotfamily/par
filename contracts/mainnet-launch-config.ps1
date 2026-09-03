# Sets the production launch terms on config 0 and turns the micro rehearsal
# config (id 1) off. Opening market cap is 1.3557 ETH on a 1e9 supply, the
# figure the rest of the chain's launches open at.
#
#   .\mainnet-launch-config.ps1           apply
#   .\mainnet-launch-config.ps1 -Show     print both configs, change nothing
param([switch]$Show)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"

function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}
$rpc = ReadEnv ".env.mainnet" "RPC_URL"
if (-not $rpc) { $rpc = "https://rpc.mainnet.chain.robinhood.com" }
$ownerPk = ReadEnv ".env.mainnet.fee" "PRIVATE_KEY"

$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$FACTORY = ($j.transactions | Where-Object { $_.contractName -eq "PairPadLaunchFactory" -and $_.transactionType -like "CREATE*" }).contractAddress
Write-Output "factory $FACTORY"

$sig = "(uint256,uint256,uint256,int24,bool)"
$supply    = "1000000000000000000000000000"   # 1e9 * 1e18
$phantom   = "1355700000000000000"            # 1.3557 ETH
$threshold = "4200000000000000000"            # 4.2 ETH, milestone only

$count = [int](& $cast call $FACTORY "launchConfigCount()(uint256)" --rpc-url $rpc).Trim()
Write-Output "launchConfigCount = $count"

if (-not $Show) {
  $r = & $cast send $FACTORY --rpc-url $rpc --private-key $ownerPk "updateLaunchConfig(uint256,$sig)" 0 "($supply,$phantom,$threshold,10,true)" 2>&1 | Out-String
  Write-Output "config 0 -> $(($r | Select-String 'status' | Out-String).Trim())"
  if ($count -ge 2) {
    $r = & $cast send $FACTORY --rpc-url $rpc --private-key $ownerPk "updateLaunchConfig(uint256,$sig)" 1 "(1000000000000000000000000000,400000000000000,1000000000000000,10,false)" 2>&1 | Out-String
    Write-Output "config 1 disabled -> $(($r | Select-String 'status' | Out-String).Trim())"
  }
}

for ($i = 0; $i -lt $count; $i++) {
  Write-Output "config ${i}: $((& $cast call $FACTORY "getLaunchConfig(uint256)$sig" $i --rpc-url $rpc) -join ' ')"
}
Write-Output "preview config 0 (ETH): $(& $cast call $FACTORY 'previewQuoteEconomics(uint256,address)(uint256,uint256)' 0 0x0000000000000000000000000000000000000000 --rpc-url $rpc)"
