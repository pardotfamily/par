$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"
# Keyed RPC lives in .env.mainnet (gitignored); the public node rate-limits bursts.
$rpc = ((Get-Content (Join-Path $PSScriptRoot ".env.mainnet") | Where-Object { $_ -match "^RPC_URL=" }) -replace "^RPC_URL=", "").Trim()
if (-not $rpc) { $rpc = "https://rpc.mainnet.chain.robinhood.com" }

function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}
$deployerPk = ReadEnv ".env.mainnet" "PRIVATE_KEY"
$deployer   = ReadEnv ".env.mainnet" "DEPLOYER"
$feePk      = ReadEnv ".env.mainnet.fee" "PRIVATE_KEY"
$feeWallet  = ReadEnv ".env.mainnet.fee" "FEE_WALLET"

# Addresses come from the latest broadcast, never from a hardcoded list.
$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$created = @{}
foreach ($t in $j.transactions) {
  if ($t.transactionType -eq "CREATE" -or $t.transactionType -eq "CREATE2") { $created[$t.contractName] = $t.contractAddress }
}
$FACTORY = $created["PairPadLaunchFactory"]
$ROUTER  = $created["PairPadRouter"]
$PRICER  = $created["PairPadQuotePricer"]
$LOCKER  = $created["PairPadLaunchLocker"]
$ESCROW  = $created["PairPadFeeEscrow"]
$blocks = $j.receipts | ForEach-Object { [Convert]::ToInt64($_.blockNumber, 16) }
$gas = ($j.receipts | ForEach-Object { [Convert]::ToInt64($_.gasUsed, 16) } | Measure-Object -Sum).Sum
Write-Output "deploy blocks : $(($blocks | Measure-Object -Minimum).Minimum) .. $(($blocks | Measure-Object -Maximum).Maximum)  (txs: $($j.receipts.Count), gas: $gas)"
Write-Output "factory $FACTORY / router $ROUTER / pricer $PRICER / locker $LOCKER / escrow $ESCROW"

# 1. Fund the fee wallet for its acceptOwnership calls if needed.
$feeBalWei = [decimal](& $cast balance $feeWallet --rpc-url $rpc)
if ($feeBalWei -lt 2000000000000000) {
  Write-Output "--- funding fee wallet with 0.004 ETH from deployer ---"
  $r = & $cast send $feeWallet --rpc-url $rpc --private-key $deployerPk --value 4000000000000000 2>&1 | Out-String
  Write-Output ($r | Select-String "status" | Out-String).Trim()
}

# 2. Complete the two-step ownership transfer from the fee wallet.
foreach ($c in @(@("factory",$FACTORY), @("pricer",$PRICER), @("locker",$LOCKER))) {
  $name, $addr = $c
  $pending = (& $cast call $addr "pendingOwner()(address)" --rpc-url $rpc).Trim()
  if ($pending.ToLower() -ne $feeWallet.ToLower()) { Write-Output "$name : pendingOwner is $pending, skipping"; continue }
  $r = & $cast send $addr --rpc-url $rpc --private-key $feePk "acceptOwnership()" 2>&1 | Out-String
  $st = ($r | Select-String "status" | Out-String).Trim()
  $owner = (& $cast call $addr "owner()(address)" --rpc-url $rpc).Trim()
  Write-Output "$name : $st -> owner $owner"
}

# 3. Sanity.
Write-Output "--- sanity ---"
Write-Output "factory.launchEnabled   : $(& $cast call $FACTORY 'launchEnabled()(bool)' --rpc-url $rpc)"
Write-Output "factory.launchFee       : $(& $cast call $FACTORY 'launchFee()(uint256)' --rpc-url $rpc)"
Write-Output "factory.baseFeeBps      : $(& $cast call $FACTORY 'baseFeeBps()(uint256)' --rpc-url $rpc)"
Write-Output "factory.protocolShare   : $(& $cast call $FACTORY 'protocolFeeShareBps()(uint256)' --rpc-url $rpc)"
Write-Output "factory.feeRecipient    : $(& $cast call $FACTORY 'protocolFeeRecipient()(address)' --rpc-url $rpc)"
Write-Output "factory.maxCreatorTax   : $(& $cast call $FACTORY 'maxCreatorTaxBps()(uint256)' --rpc-url $rpc)"
Write-Output "factory.poolFeeFor(0)   : $(& $cast call $FACTORY 'poolFeeFor(uint16)(uint24)' 0 --rpc-url $rpc)"
Write-Output "factory.forwarder       : $(& $cast call $FACTORY 'launchForwarder()(address)' --rpc-url $rpc)"
Write-Output "factory.locker          : $(& $cast call $FACTORY 'locker()(address)' --rpc-url $rpc)"
Write-Output "locker.factory          : $(& $cast call $LOCKER 'factory()(address)' --rpc-url $rpc)"
Write-Output "pricer.minReferenceEth  : $(& $cast call $PRICER 'minReferenceEth()(uint256)' --rpc-url $rpc)"
Write-Output "pricer.registries       : $(& $cast call $PRICER 'registriesLength()(uint256)' --rpc-url $rpc)"
Write-Output "pricer.hook(PONS)       : $(& $cast call $PRICER 'allowedV4Hooks(address)(bool)' 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044 --rpc-url $rpc)"
Write-Output "config0 preview (ETH)   : $(& $cast call $FACTORY 'previewQuoteEconomics(uint256,address)(uint256)' 0 0x0000000000000000000000000000000000000000 --rpc-url $rpc)"
Write-Output "config0 preview (USDG)  : $(& $cast call $FACTORY 'previewQuoteEconomics(uint256,address)(uint256)' 0 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 --rpc-url $rpc)"
Write-Output "deployer balance        : $(& $cast balance $deployer --rpc-url $rpc --ether) ETH"
