# Verifies every deployed contract on Sourcify with its constructor args.
# Addresses come from the latest broadcast.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"

function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}
$DEPLOYER = ReadEnv ".env.mainnet" "DEPLOYER"
$FEE_RECIPIENT = ReadEnv ".env.mainnet" "PROTOCOL_FEE_RECIPIENT"
$POOL_MANAGER = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
$POSM     = "0x58daec3116aae6D93017bAAea7749052E8a04fA7"
$PERMIT2  = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
$V3_FACTORY = "0x1f7d7550B1b028f7571E69A784071F0205FD2EfA"
$SWAP_ROUTER_02 = "0xCaf681a66D020601342297493863E78C959E5cb2"
$WETH = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"
$USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"

$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$c = @{}
foreach ($t in $j.transactions) {
  if ($t.transactionType -eq "CREATE" -or $t.transactionType -eq "CREATE2") { $c[$t.contractName] = $t.contractAddress }
}
$launchFee = (& $cast call $c["PairPadLaunchFactory"] "launchFee()(uint256)" --rpc-url https://rpc.mainnet.chain.robinhood.com).Split(" ")[0]

function V($addr, $path, $args) {
  Write-Output "=== $path @ $addr"
  if ($args) {
    & $forge verify-contract $addr $path --chain-id 4663 --verifier sourcify --watch --constructor-args $args 2>&1 | Select-String "successfully|already|Status|Error|error|Fail"
  } else {
    & $forge verify-contract $addr $path --chain-id 4663 --verifier sourcify --watch 2>&1 | Select-String "successfully|already|Status|Error|error|Fail"
  }
}

V $c["PairPadFeeEscrow"]    "src/v2/PairPadFeeEscrow.sol:PairPadFeeEscrow" $null
V $c["PairPadQuotePricer"]  "src/v2/PairPadQuotePricer.sol:PairPadQuotePricer" (& $cast abi-encode "c(address,address,address,address,address)" $DEPLOYER $V3_FACTORY $WETH $USDG $POOL_MANAGER)
V $c["PairPadLaunchLocker"] "src/v2/PairPadLaunchLocker.sol:PairPadLaunchLocker" (& $cast abi-encode "c(address,address,address)" $DEPLOYER $POSM $c["PairPadFeeEscrow"])
V $c["PairPadLaunchFactory"] "src/v2/PairPadLaunchFactory.sol:PairPadLaunchFactory" (& $cast abi-encode "c(address,address,address,address,address,address,address,uint256)" $DEPLOYER $POOL_MANAGER $POSM $c["PairPadLaunchLocker"] $c["PairPadFeeEscrow"] $c["PairPadQuotePricer"] $FEE_RECIPIENT $launchFee)
V $c["PairPadPositionMinter"] "src/v2/PairPadPositionMinter.sol:PairPadPositionMinter" (& $cast abi-encode "c(address,address,address,address)" $POSM $PERMIT2 $c["PairPadLaunchLocker"] $c["PairPadLaunchFactory"])
V $c["PairPadLaunchDeployer"] "src/v2/PairPadLaunchDeployer.sol:PairPadLaunchDeployer" (& $cast abi-encode "c(address)" $c["PairPadLaunchFactory"])
V $c["PairPadRouter"]       "src/v2/PairPadRouter.sol:PairPadRouter" (& $cast abi-encode "c(address,address,address,address)" $POOL_MANAGER $c["PairPadLaunchFactory"] $SWAP_ROUTER_02 $WETH)
V $c["PonsReferenceRegistry"] "src/v2/PairPadReferenceRegistries.sol:PonsReferenceRegistry" (& $cast abi-encode "c(address,address)" 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044)
V $c["PairPadReferenceRegistry"] "src/v2/PairPadReferenceRegistries.sol:PairPadReferenceRegistry" (& $cast abi-encode "c(address)" $c["PairPadLaunchFactory"])

Write-Output "--- sourcify status ---"
foreach ($n in $c.Keys) {
  $a = $c[$n]
  $r = & curl.exe -s "https://sourcify.dev/server/v2/contract/4663/$a"
  Write-Output "$n $a : $r"
}
