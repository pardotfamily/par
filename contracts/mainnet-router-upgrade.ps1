param(
  # Pass an already deployed router to skip the deploy step and only rewire.
  [string]$Router = ""
)
# forge and cast print progress on stderr, which PowerShell would otherwise
# turn into terminating errors.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"

function ReadEnv($file, $key) {
  ($(Get-Content $file | Where-Object { $_ -match "^$key=" }) -replace "^$key=", "").Trim()
}
$rpc = ReadEnv ".env.mainnet" "RPC_URL"
if (-not $rpc) { $rpc = "https://rpc.mainnet.chain.robinhood.com" }
$deployerPk = ReadEnv ".env.mainnet" "PRIVATE_KEY"
$ownerPk    = ReadEnv ".env.mainnet.fee" "PRIVATE_KEY"
$ownerAddr  = ReadEnv ".env.mainnet.fee" "FEE_WALLET"

# The rest of the stack stays where the full deploy put it.
$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$created = @{}
foreach ($t in $j.transactions) {
  if ($t.transactionType -eq "CREATE" -or $t.transactionType -eq "CREATE2") { $created[$t.contractName] = $t.contractAddress }
}
$FACTORY   = $created["PairPadLaunchFactory"]
$HOOK      = $created["PairPadLaunchHook"]
$OLDROUTER = (& $cast call $FACTORY "launchForwarder()(address)" --rpc-url $rpc | Out-String).Trim()
$MANAGER   = "0x8366a39CC670B4001A1121B8F6A443A643e40951"
$SWAP02    = "0xCaf681a66D020601342297493863E78C959E5cb2"
$WETH      = "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"

$owner = (& $cast call $HOOK "owner()(address)" --rpc-url $rpc | Out-String).Trim()
if ($owner.ToLower() -ne $ownerAddr.ToLower()) { throw "hook owner is $owner, expected $ownerAddr" }
Write-Output "factory $FACTORY / hook $HOOK / current router $OLDROUTER"

# 1. Deploy the new router (verification runs separately, see mainnet-router-verify.ps1).
if ($Router -eq "") {
  Write-Output "--- deploying PairPadRouter ---"
  $out = & $forge create src/v2/PairPadRouter.sol:PairPadRouter `
    --rpc-url $rpc --private-key $deployerPk --broadcast `
    --constructor-args $MANAGER $FACTORY $SWAP02 $WETH 2>&1 | Out-String
  Write-Output $out
  $m = [regex]::Match($out, "Deployed to:\s*(0x[0-9a-fA-F]{40})")
  if (-not $m.Success) { throw "could not read the new router address" }
  $Router = $m.Groups[1].Value
}
if ($Router.ToLower() -eq $OLDROUTER.ToLower()) { throw "router $Router is already the forwarder" }
$fac = (& $cast call $Router "factory()(address)" --rpc-url $rpc | Out-String).Trim()
if ($fac.ToLower() -ne $FACTORY.ToLower()) { throw "router $Router points at factory $fac" }
Write-Output "new router $Router"

# 2. Point the hook and the factory at it, then retire the old one.
function Send($to, $sig, $callArgs) {
  $r = & $cast send $to --rpc-url $rpc --private-key $ownerPk $sig @callArgs 2>&1 | Out-String
  $st = ($r | Select-String "status" | Out-String).Trim()
  if ($st -eq "") { return $r.Trim() }
  $st
}
Write-Output "hook.setTrustedRouter(new)  : $(Send $HOOK 'setTrustedRouter(address,bool)' @($Router, 'true'))"
Write-Output "factory.setLaunchForwarder   : $(Send $FACTORY 'setLaunchForwarder(address)' @($Router))"
Write-Output "hook.setTrustedRouter(old)  : $(Send $HOOK 'setTrustedRouter(address,bool)' @($OLDROUTER, 'false'))"

# 3. Sanity.
Write-Output "--- sanity ---"
Write-Output "hook.trusted(new) : $(& $cast call $HOOK 'trustedRouters(address)(bool)' $Router --rpc-url $rpc)"
Write-Output "hook.trusted(old) : $(& $cast call $HOOK 'trustedRouters(address)(bool)' $OLDROUTER --rpc-url $rpc)"
Write-Output "factory.forwarder : $(& $cast call $FACTORY 'launchForwarder()(address)' --rpc-url $rpc)"
Write-Output "ROUTER=$Router"
