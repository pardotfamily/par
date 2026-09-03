# par contracts

Smart contracts for par, a token launchpad on Robinhood Chain (chain id 4663). A creator
deploys a token and, in the same transaction, its Uniswap v4 pool opens with the whole supply
in one permanently locked position. There is no bonding curve contract and no migration: the
pool that exists in the first second is the pool the token lives in forever. It has no hook, so
anything that can trade Uniswap v4 can trade it from the first block. Any ERC-20 with a deep
enough Uniswap market on the chain can be the quote asset, not just ETH.

This repository holds the protocol: Solidity sources, tests, deploy scripts and the mainnet
addresses. The interface, indexer and keeper are operated by the team and are not part of this
repository; everything they do can be reproduced from the contracts and events described here.
The docs on the site cover the same surface plus the public indexer API.

## How a launch works on chain

1. `PairPadLaunchFactory.launchToken(params, configId, pairToken)` with `launchFee()`
   (0.0005 ETH) as value. `pairToken` is `address(0)` for native ETH or any ERC-20 the pricer
   accepts. The factory asks `PairPadLaunchDeployer` to CREATE2 a `PairPadLauncherToken` with
   the full 1,000,000,000 supply minted to `PairPadPositionMinter`.
2. The factory works out the opening price from the config's phantom quote reserve
   (1.3557 ETH for config 0, so every token opens at the same market cap) and the supply. For an
   ERC-20 quote, `PairPadQuotePricer` converts the ETH figures into that asset first.
3. The factory initialises a plain v4 pool: no hook, tick spacing 10, LP fee equal to the base
   fee plus the creator's tax (`poolFeeFor(creatorTaxBps)`, 1% with no tax). If someone has
   already initialised that key the launch reverts with `PoolAlreadyExists`.
   `PairPadPositionMinter` mints one position ranged from the opening tick upward that holds
   the entire supply. The position NFT goes to `PairPadLaunchLocker`, which has no withdraw
   function. Any dust the position could not take is locked in the same place. A single-sided
   position of this shape is a constant-product curve with a phantom reserve, so the pool
   behaves like the bonding curves people know, except that it is already a Uniswap pool.
4. Every swap pays the pool's LP fee the ordinary Uniswap way: from the input, so buys pay in
   the quote asset and sells pay in the token. The fee accrues to the liquidity in range, which
   at launch is only the locked position.
5. `PairPadLaunchLocker.collectFees(token)` pulls the position's owed fees out with a
   zero-liquidity decrease and splits them by the terms frozen in the launch record: the
   protocol gets its share (50%) of the base fee part, the creator gets the rest of the base
   fee and the whole creator tax. The protocol's part is paid to its wallet on the spot (if
   that transfer fails it is credited to the escrow instead); the creator's part is credited to
   `PairPadFeeEscrow` and claimed from there. Anyone can call it; the keeper does every fifteen
   minutes and the creator's claim on the token page does it too.

There is no snipe tax, no trading delay and no lock on third party liquidity. The dev buy in
`launchAndBuyWithEth` / `launchAndBuyWithQuote` is the only buy guaranteed to be first, because
it lands in the launch transaction.

### Quote assets without a whitelist

Most launchpads keep an owner-maintained list of approved pair tokens with hand-set economics.
par has no list; `PairPadQuotePricer` decides on chain:

- The pricer looks for a Uniswap pool pairing the asset with WETH, ETH or USDG. Uniswap v3
  pools are found through the v3 factory at the standard fee tiers. Uniswap v4 pools are
  found through reference registries: `PonsReferenceRegistry` reads pool terms from the pons
  factory, so every pons graduate is known without registration, and
  `PairPadReferenceRegistry` does the same for par's own launches. Anyone can also
  `registerV4Pool(key)` for a pool with an allowed hook (none, or the pons hook).
- A pool qualifies when its in-range liquidity on the anchor side is worth at least
  `minReferenceEth` (5 ETH). Two hops are allowed, asset to USDG to ETH, and the USDG leg has
  to clear the same floor priced in USDG. The deepest qualifying pool wins.
- The price is the pool's spot price at the moment of the launch. `describe(token)` returns
  the pool the pricer would use, its depth and the floor it has to clear, which is how the
  interface explains a refusal.
- The factory owner can still set curated economics for an asset with `setPairTokenEconomics`,
  which takes priority over the pricer.

Since the price is a spot price, a launch quoted in an actively traded asset should not pin
`expectedEconomics` (leave it zero); a pin computed one block earlier reverts the moment the
reference pool trades. Launches quoted in ETH or USDG are safe to pin.

Tokens that take a fee on transfer do not work as quotes: the locker moves collected fees in
exact amounts and reverts when less arrives than was sent (`InexactTransfer`). Rebasing tokens
do not work either.

### Paying in ETH for a launch quoted in something else

`PairPadRouter.buyWithEth` takes ETH to the quote asset and on through the launch pool in one
transaction; `sellToEth` is the reverse. The ETH side is described by an `EthLeg`:

```solidity
struct EthLeg {
    bytes v3Path;      // Uniswap v3 hops, WETH -> ... on a buy, ... -> WETH on a sell; may be empty
    PoolKey[] v4Hops;  // Uniswap v4 pools from there to the quote asset, in trade order; may be empty
}
```

The v3 hops run on SwapRouter02 first. The v4 hops and the launch pool then run inside a
single PoolManager unlock, so a quote that only trades on v4 (every PONS graduate, every par
token) is reachable from plain ETH and the buyer never holds it. A quote with a v3 WETH pool
uses `v3Path` alone; a PONS token uses `v4Hops = [its ETH pool]` alone; a token whose only
market is against USDG combines the two. The frontend builds the leg from the same reference
pools `PairPadQuotePricer.describe` reports, so the trade goes where the depth is.

`swapExactIn` is a plain swap through one pool. `launchAndBuyWithEth` and
`launchAndBuyWithQuote` create a launch for the real caller and land the creator's first buy in
the same transaction, so nobody can get in front of it. The router is the factory's trusted
launch forwarder for that purpose and holds no funds between transactions. Nothing else needs
the router: the pools are ordinary v4 pools and Uniswap's own router trades them.

## Reading launches from the chain

Everything an indexer or a trading terminal needs is in events and views. No API of ours is
required.

Factory events:

```
TokenLaunched(address indexed token, bytes32 indexed poolId, address indexed deployer, address pairToken, uint256 launchConfigId, uint24 poolFee)
LaunchPositionMinted(address indexed token, uint256 positionId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenAmount, uint256 phantomQuote)
CreatorFeeRecipientUpdated(address indexed token, address indexed previousRecipient, address indexed newRecipient)
```

Locker event, one per collection that paid something out, amounts in the pool's currency order:

```
FeesCollected(address indexed token, address currency0, address currency1, uint256 protocolAmount0, uint256 protocolAmount1, uint256 creatorAmount0, uint256 creatorAmount1)
```

Trades are ordinary Uniswap v4 `Swap` events on the PoolManager, filtered by pool id. The pool
id is `keccak256(abi.encode(PoolKey))` with `currency0 < currency1` (native ETH is
`address(0)` and always `currency0`), `fee = poolFee` from the launch (10000 pips with no
creator tax), `tickSpacing` from the launch config (10 for config 0) and `hooks = address(0)`.
`factory.poolKeyFor(token)` and `factory.poolIdFor(token)` return both directly. The `fee`
field of the `Swap` event is the LP fee in pips, so the fee a trade paid is
`amountIn * fee / 1e6` of its input currency.

Views: `factory.getLaunchedToken(token)` returns the full record (pair token, deployer, fee
recipient, phantom reserve, pool fee, ticks, liquidity, position id, and the base fee, creator
tax, protocol share and protocol recipient frozen at launch). `locker.pendingFees(token)`
returns the fees the position has earned and not yet collected, per currency, exact to the wei.
`factory.previewQuoteEconomics(configId, pairToken)` returns the phantom reserve a new launch in
that asset would get; `previewLaunchEconomics` hashes it for `expectedEconomics`.

Token metadata is on the token itself. `name()`, `symbol()`, `logo()` (an `ipfs://` URI),
`description()`, `socials()` (twitter, telegram, discord, website, farcaster) and
`getTokenInfo()` returning all of it as one tuple. `contractURI()` returns the same fields as
an ERC-7572 inline JSON data URI with `name`, `symbol`, `description`, `image` and
`external_link`. All of it is set at launch and immutable. Socials are stored as full URLs;
terminals that read them off the token skip anything that is not an absolute link. A launch with
no website gets the token's page on the site as its website, `/t/<first 8 bytes of the salt>`;
the indexer's `GET /resolve?id=` maps that id back to the token.

Each launched token is a fresh contract, so it has to be verified on the explorer on its own.
The indexer does this: after `TokenLaunched` it submits the token's standard JSON input
(`indexer/verification/PairPadLauncherToken.json`) to Blockscout and Sourcify and polls until both
report an exact match. Constructor arguments are recovered from the launch transaction, so the
one artifact covers every launch.

## Mainnet deployment

Robinhood Chain, chain id 4663, deployed at block 53778163. Sources verified on Blockscout and
Sourcify as exact matches.

| Contract | Address |
| --- | --- |
| PairPadLaunchFactory | `0xCE7EF2465E59443CAEB3A2c5fb969A2d3A9a4bd6` |
| PairPadRouter | `0x02CB119ba29f48d606fB68e9bC5330AE9A261596` |
| PairPadLaunchLocker | `0x8d519cC4343079F774ec316B4d84860de71E8F58` |
| PairPadFeeEscrow | `0x4f834Cabf80062f82BEb17B348d975B6acC03375` |
| PairPadQuotePricer | `0x0a8326E90B7dcd588399bB6A391F277d76DC7374` |
| PairPadPositionMinter | `0x68d0b4825F58fD5Ef777739A39765F759c7ef877` |
| PairPadLaunchDeployer | `0xB9Abd5326867ac5B6C28c767d20E2058C7447e3b` |
| PonsReferenceRegistry | `0x6937B1fc81e53E31c94285433435cB02db5474ca` |
| PairPadReferenceRegistry | `0x2D048DD9b2399986E837A5B83e94EB52094Bf078` |

Owner and protocol fee recipient: `0x6053FC7a871AF434F5F26701B206469bAcB03966`. The keeper
that calls `collectFees` runs from `0x0071aC8dBf95770C089fBd52af4Bd5A63293b040`; the call is
open to anyone, the keeper only pays the gas.

External addresses the deploy script hardcodes for 4663: Uniswap v4 PoolManager
`0x8366a39CC670B4001A1121B8F6A443A643e40951`, PositionManager
`0x58daec3116aae6D93017bAAea7749052E8a04fA7`, Permit2
`0x000000000022D473030F116dDEE9F6B43aC78BA3`, Uniswap v3 Factory
`0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`, SwapRouter02
`0xCaf681a66D020601342297493863E78C959E5cb2`, WETH
`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, USDG
`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, pons factory
`0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` and pons hook
`0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044`.

Launch config `0`: supply 1,000,000,000, phantom reserve 1.3557 ETH, tick spacing 10. Fee
terms at deploy: 1% base fee, 50% protocol share, 10% maximum creator tax. Changing them only
affects launches made afterwards; a pool's fee is part of its key and a launch's split is
copied into its record.

The stack is replaced as a set rather than upgraded. Earlier mainnet stacks (bonding-curve
revisions, a v4 stack with a TWAP pricer, and a v4 stack with a fee hook) hold test tokens and
are no longer followed by the interface.

## Building and testing

```
cd contracts
forge build
forge test --no-match-path "test/fork/*"                       # unit tests, mocked Uniswap
forge test --match-path "test/fork/*" --fork-url robinhood     # end to end on a mainnet fork
```

Dependencies under `contracts/lib` are vendored: forge-std as a submodule, and the parts of
OpenZeppelin, v4-core and v4-periphery that the contracts import. Clone with
`--recurse-submodules` or run `git submodule update --init`.

Deploy: `script/Deploy.s.sol` reads `PRIVATE_KEY`, `PROTOCOL_FEE_RECIPIENT` and `FINAL_OWNER`
from the environment, deploys everything, wires it, allows the pons hook and adds both
reference registries to the pricer, adds launch config 0, and starts a two-step ownership
transfer to `FINAL_OWNER`, which then has to call `acceptOwnership()` on the factory, pricer
and locker. On 4663 it refuses overrides of the canonical Uniswap, WETH and USDG addresses.
The `mainnet-*.ps1` scripts in `contracts` wrap the deploy, the ownership acceptance and
Sourcify verification; they read keys and the RPC URL from `contracts/.env.mainnet`, which is
not committed. `script/SmokeLaunch.s.sol` launches and trades a token against a live
deployment and prints the fees the position earned.

## Security

The contracts have not been audited. Liquidity is held by a locker with no withdraw function,
tokens have no owner and no privileged functions, and the factory owner can only change terms
for future launches. The factory owner is a single EOA at the moment. If you find a problem,
use GitHub's private vulnerability reporting on this repository rather than a public issue.

## License

MIT.
