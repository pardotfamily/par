param([string]$Quote = "0x66e73ef65528Baf192679222c6D2810D7D7e2c68")
# Simulation only: no --broadcast, nothing is sent.
$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"
$cast = "$env:USERPROFILE\.foundry\bin\cast.exe"
Get-Content .env.mainnet | Where-Object { $_ -match "^[A-Z_]+=" } | ForEach-Object {
  $k, $v = $_ -split "=", 2
  Set-Item "Env:$k" $v
}
$j = Get-Content "broadcast\Deploy.s.sol\4663\run-latest.json" -Raw | ConvertFrom-Json
$env:FACTORY = ($j.transactions | Where-Object { $_.contractName -eq "PairPadLaunchFactory" -and $_.transactionType -like "CREATE*" }).contractAddress
$env:ROUTER = (& $cast call $env:FACTORY "launchForwarder()(address)" --rpc-url $env:RPC_URL | Out-String).Trim()
$env:QUOTE = $Quote
Write-Output "factory $env:FACTORY router $env:ROUTER quote $env:QUOTE"
& $forge script script/DryRunV4Zap.s.sol --rpc-url $env:RPC_URL -vv 2>&1 | Out-String
Write-Output "DRYRUN-EXIT=$LASTEXITCODE"
