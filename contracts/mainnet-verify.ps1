$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot
$forge = "$env:USERPROFILE\.foundry\bin\forge.exe"
Get-Content .env.mainnet | Where-Object { $_ -match "^[A-Z_]+=" } | ForEach-Object {
  $k, $v = $_ -split "=", 2
  Set-Item "Env:$k" $v
}
# --resume with all receipts already present only re-runs the verification step.
& $forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --private-key $env:PRIVATE_KEY --broadcast --resume --verify --verifier sourcify
Write-Output "VERIFY-EXIT=$LASTEXITCODE"
