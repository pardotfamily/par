# Live smoke test of the deployed stack: launch on the production config with
# an opening buy, buy again, sell half back. Addresses come from the latest
# broadcast; the deployer key pays.
#
#   .\mainnet-smoke.ps1              simulate only
#   .\mainnet-smoke.ps1 -Broadcast   send it
#
# Optional metadata for the launched token: TOKEN_NAME, TOKEN_SYMBOL,
# TOKEN_LOGO (ipfs:// URI), TOKEN_DESCRIPTION, TOKEN_WEBSITE, TOKEN_TWITTER,
# TOKEN_TELEGRAM, TOKEN_DISCORD, TOKEN_FARCASTER as environment variables.
param([switch]$Broadcast, [switch]$Resume, [int]$ConfigId = 0)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"

function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}
# The public node: the keyed provider lags on the pending nonce and forge then
# fails the second transaction of a run with "nonce too low".
$rpc = "https://rpc.mainnet.chain.robinhood.com"
$env:PRIVATE_KEY = ReadEnv ".env.mainnet" "PRIVATE_KEY"

$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$created = @{}
foreach ($t in $j.transactions) {
  if ($t.transactionType -eq "CREATE" -or $t.transactionType -eq "CREATE2") { $created[$t.contractName] = $t.contractAddress }
}
$env:FACTORY = $created["PairPadLaunchFactory"]
# The router can be replaced on its own; the factory always knows the current one.
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"
$env:ROUTER = (& $cast call $env:FACTORY "launchForwarder()(address)" --rpc-url $rpc | Out-String).Trim()
$env:CONFIG_ID = "$ConfigId"
Write-Output "factory $env:FACTORY / router $env:ROUTER / config $ConfigId"

if ($Resume) {
  # Picks up the transactions of the last run that were not yet confirmed.
  & $forge script script/SmokeLaunch.s.sol --rpc-url $rpc --broadcast --resume
} elseif ($Broadcast) {
  & $forge script script/SmokeLaunch.s.sol --rpc-url $rpc --broadcast --slow
} else {
  & $forge script script/SmokeLaunch.s.sol --rpc-url $rpc
}
