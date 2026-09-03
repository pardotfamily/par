$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"
# Keyed RPC lives in .env.mainnet (gitignored); the public node rate-limits bursts.
$rpc = ((Get-Content (Join-Path $PSScriptRoot ".env.mainnet") | Where-Object { $_ -match "^RPC_URL=" }) -replace "^RPC_URL=", "").Trim()
if (-not $rpc) { $rpc = "https://rpc.mainnet.chain.robinhood.com" }

function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}

Write-Output "env keys      : $((Get-Content .env.mainnet | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { ($_ -split '=',2)[0] }) -join ', ')"
$deployer = ReadEnv ".env.mainnet" "DEPLOYER"
$feeWallet = ReadEnv ".env.mainnet.fee" "FEE_WALLET"
$keeperPk = ReadEnv "..\keeper\.env" "KEEPER_PRIVATE_KEY"
$keeper = (& $cast wallet address --private-key $keeperPk).Trim()

Write-Output "deployer      : $deployer  $(& $cast balance $deployer --rpc-url $rpc --ether) ETH"
Write-Output "fee wallet    : $feeWallet  $(& $cast balance $feeWallet --rpc-url $rpc --ether) ETH"
Write-Output "keeper        : $keeper  $(& $cast balance $keeper --rpc-url $rpc --ether) ETH"
Write-Output "base fee gwei : $([decimal](& $cast block latest -f baseFeePerGas --rpc-url $rpc) / 1e9)"
Write-Output "head block    : $(& $cast block-number --rpc-url $rpc)"
