param(
  [switch]$Broadcast
)
$ErrorActionPreference = "Stop"
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"
# Keyed RPC lives in .env.mainnet (gitignored); the public node rate-limits bursts.
$rpc = ((Get-Content (Join-Path $PSScriptRoot ".env.mainnet") | Where-Object { $_ -match "^RPC_URL=" }) -replace "^RPC_URL=", "").Trim()
if (-not $rpc) { $rpc = "https://rpc.mainnet.chain.robinhood.com" }

# Never let testnet overrides leak into a mainnet run.
foreach ($n in "POOL_MANAGER","POSITION_MANAGER","PERMIT2","V3_FACTORY","SWAP_ROUTER_02","WETH","USDG","LAUNCH_FEE","PRIVATE_KEY","PROTOCOL_FEE_RECIPIENT","FINAL_OWNER","DEPLOYER","KEEPER_ADDRESS") {
  Remove-Item "Env:$n" -ErrorAction SilentlyContinue
}
Get-Content .env.mainnet | Where-Object { $_ -match "^[A-Z_]+=" } | ForEach-Object {
  $k, $v = $_ -split "=", 2
  Set-Item "Env:$k" $v
}

Write-Output "chainId       : $(& $cast chain-id --rpc-url $rpc)"
Write-Output "deployer      : $env:DEPLOYER"
Write-Output "deployer bal  : $(& $cast balance $env:DEPLOYER --rpc-url $rpc --ether) ETH"
Write-Output "fee recipient : $env:PROTOCOL_FEE_RECIPIENT"
Write-Output "final owner   : $env:FINAL_OWNER"
$c2 = & $cast code 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url $rpc
Write-Output "CREATE2 deployer code bytes: $(($c2.Trim().Length - 2) / 2)"

if ($Broadcast) {
  Write-Output "=== BROADCAST ==="
  & $forge script script/Deploy.s.sol --rpc-url $rpc --broadcast --slow
} else {
  Write-Output "=== SIMULATION (no broadcast) ==="
  & $forge script script/Deploy.s.sol --rpc-url $rpc
}
