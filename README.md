# par contracts

Smart contracts for par, a token launchpad on Robinhood Chain (chain id 4663). A creator
deploys a token and, in the same transaction, its Uniswap v4 pool opens with the whole supply
in one permanently locked position. There is no bonding curve contract and no migration: the
pool that exists in the first second is the pool the token lives in forever. It has no hook, so
anything that can trade Uniswap v4 can trade it from the first block. Any ERC-20 with a deep
enough Uniswap market on the chain can be the quote asset, not just ETH. A token can also open
against several quote assets at once, one pool per asset, which is how a basket of other tokens
becomes tradable under one address (see "Multi-market launches").

This repository holds the protocol: Solidity sources, tests, deploy scripts and the mainnet
addresses. The interface, indexer and keeper are operated by the team and are not part of this
repository; everything they do can be reproduced from the contracts and events described here.
The docs on the site cover the same surface plus the public indexer API. A TypeScript SDK that
wraps it (launch discovery, pool resolution, ETH-routed trades across every market of a token,
event decoding, indexer client) is at [github.com/pardotfamily/par-sdk](https://github.com/pardotfamily/par-sdk).

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
   fee and the whole creator tax. The protocol's part in the quote asset is paid to its wallet
   on the spot (if that transfer fails it is credited to the escrow instead); the protocol's
   part in the launch token is burned (`ProtocolShareBurned`), so every sell shrinks the
   supply. The creator's part is credited to `PairPadFeeEscrow` and claimed from there. Anyone
   can call it; the keeper does every fifteen minutes and the creator's claim on the token page
   does it too.
6. Where the shares go from there (`contracts/src/fees`, no owners, nothing configurable):
   - `PairPadFeeSplitter` is the protocol fee recipient of every launch created since it was
     set. Anyone may `flush` it: `buybackBps` (60%) of each asset to the buyback wallet, which
     turns it into ETH, buys $par in the $par pool and burns it; the rest to the protocol wallet.
     With the token-side share burned outright, 80% of what the protocol earns on these launches
     is burned or bought back. Launch fees sent by the factories pass straight through to the
     protocol wallet. Launches keep the recipient frozen in their record: the first splitter
     (80/20) keeps receiving from the launches made under it, older launches never pay one.
   - `PairPadHolderVault` is the creator fee recipient a launch may name at creation to give the
     creator's share to the token's holders ("fees to holders"). Only a recipient can change a
     launch's recipient and the vault has no such function, so it is permanent. Anyone may
     `harvest` it: it claims from the escrow and forwards to the holder-rewards wallet, which
     buys the token back with the quote part and sends everything to holders pro rata through
     `PairPadDisperse` (`Dispersed(token, sender, round, total, recipients)`), every hour.
   - `PairPadBurnVault` is the creator fee recipient a launch may name at creation to give the
     creator's share back to the token ("buyback & burn"). Permanent in the same way. It has no
     owner and no function that moves value anywhere except into the token's own launch pool or
     to the zero address: anyone may `burnToken` (claims the token-side share from the escrow
     and burns it); the operator runs `buyback`, which spends the quote-side share buying the
     token in the pool the factory recorded for that pair (never one named by the caller) and
     burns what it bought (`BoughtBack(token, quote, quoteIn, tokensOut)`, `Burned(token, amount)`).

There is no snipe tax, no trading delay and no lock on third party liquidity. The dev buy in
`launchAndBuyWithEth` / `launchAndBuyWithQuote` is the only buy guaranteed to be first, because
it lands in the launch transaction.

### Quote assets without a whitelist

Most launchpads keep an owner-maintained list of approved pair tokens with hand-set economics.
par has no list; `PairPadQuotePricer` decides on chain by pricing the asset in ETH through a
route of Uniswap pools:

- A route is a list of `Hop`s (`libraries/Hop.sol`: a v4 `PoolKey`, or a v3 pool described in
  the same shape with `v3 = true`) from the asset to ETH or WETH, up to four hops, v3 and v4 in
  any order, ETH only at the end. The price is the product of the hops' spot prices at the
  moment of the launch.
- Every hop has to hold at least `minReferenceEth` (5 ETH) worth of its side nearer ETH in
  range, measured in ETH for an ETH or WETH pool and converted through the rest of the route
  otherwise. A route's strength is its weakest hop over that floor.
- The pricer finds short routes on its own: the deepest pool pairing the asset with ETH or
  WETH, or two hops through USDG. Uniswap v3 pools come from the v3 factory at the standard
  fee tiers. Uniswap v4 pools come from reference registries: `PonsReferenceRegistry` reads
  pool terms from the pons factory, so every pons graduate is known without registration,
  `PairPadReferenceRegistry` does the same for par's own launches and
  `PairPadMultiReferenceRegistry` for multi-market launches. Anyone can also
  `registerV4Pool(key)` for an initialized pool whose hook is on the pricer's allow list
  (no hook, or a hook the owner has allowed).
- Longer routes are registered: `registerPath(token, hops)` stores a route anyone can submit,
  after `evaluatePath` has checked it. A stored route is only replaced by a stronger one while
  it still qualifies; once it has fallen under the floor anyone can replace it. When both a
  stored and an automatic route qualify, the stronger one is used.
- `route(token)` returns the hops in use and whether they qualify; `describe(token)` returns
  the same with every hop's depth and floor and, when the asset cannot be priced, which hop
  failed and why. That is how the interface explains a refusal.
- The factory owner can still set curated economics for an asset with `setPairTokenEconomics`,
  which takes priority over the pricer.

Since the price is a spot price, a launch quoted in an actively traded asset should not pin
`expectedEconomics` (leave it zero); a pin computed one block earlier reverts the moment the
reference pool trades. Launches quoted in ETH or USDG are safe to pin.

Tokens that take a fee on transfer do not work as quotes: the locker moves collected fees in
exact amounts and reverts when less arrives than was sent (`InexactTransfer`). Rebasing tokens
do not work either.

### Paying in ETH for a launch quoted in something else

`PairPadRouter.buyWithEth(key, leg, minTokensOut, recipient)` takes ETH along `leg`, a
`Hop[]` from ETH to the quote asset, and on through the launch pool in one transaction;
`sellToEth` is the reverse, launch pool first and ETH last. The leg is the pricer's own route
for the asset (`route(quote)`, reversed for a buy), so the trade goes exactly where the depth
the pricer measured is. v3 hops run on SwapRouter02, v4 hops and the launch pool inside a
single PoolManager unlock, so a quote that only trades on v4 (every PONS graduate, every par
token) is reachable from plain ETH and the buyer never holds it. For a launch quoted in ETH the
leg is empty and the call is a plain buy.

`swapExactIn` is a plain swap through one pool. `launchAndBuyWithEth` and
`launchAndBuyWithQuote` create a launch for the real caller and land the creator's first buy in
the same transaction, so nobody can get in front of it. The router is the factory's trusted
launch forwarder for that purpose and holds no funds between transactions. Nothing else needs
the router: the pools are ordinary v4 pools and Uniswap's own router trades them.

## Multi-market launches

A token does not have to pick one quote asset. `PairPadMultiLaunchFactory.launchToken(params,
configId, pairTokens)` opens up to five plain v4 pools for the same token in one transaction,
one per asset in `pairTokens` (native ETH as `address(0)`, WETH not allowed next to it, no
duplicates). The supply is split equally between the pools and each opens at the same price
with its slice of the phantom reserve, converted into its asset by the same pricer, so the
token has one opening market cap spread over several books. Each pool's position is minted by
`PairPadMultiPositionMinter` and locked in `PairPadMultiLaunchLocker`; the token contract, the
fee escrow and the pricer are shared with the single-market stack, and a token belongs to
exactly one of the two factories.

The pools share a token, so arbitrage keeps their prices together: a buy in one pool that
lifts the price there is met by sellers in the others, and a trade lands on the depth of all of
them. That is what makes a basket possible. A token opened against five other tokens moves with
all five, weighted by how much of the supply each pool still holds, and it can be bought or
sold directly with any of them. The first one on mainnet, INDEX
(`0x7841a0a37834EEB13Ad5DBaD692049C84CD6A73C`), is quoted in the Apple, Microsoft, NVIDIA,
Alphabet and Tesla stock tokens on the chain.

`PairPadMultiRouter` trades several markets in one transaction. A `Leg` is one market's share
of the trade plus the route between ETH and that market's quote asset:

```solidity
struct Leg { uint8 market; Hop[] hops; uint256 amountIn; }

function buyWithEth(address token, Leg[] legs, uint256 minTokensOut, address recipient) payable returns (uint256 tokensOut);
function sellToEth(address token, Leg[] legs, uint256 minEthOut, address recipient) returns (uint256 ethOut);
function sellToQuotes(address token, Leg[] legs, uint256[] minOuts, address recipient);
function buyWithQuote(address token, uint8 market, uint256 quoteIn, uint256 minTokensOut, address recipient) payable returns (uint256 tokensOut);
function launchAndBuyWithEth(TokenParams params, uint256 launchConfigId, address[] pairTokens, Leg[] legs, uint256 minTokensOut) payable returns (address token, uint256 tokensOut);
```

The legs' amounts add up to the input and the floor is on the total; the launch pool itself is
appended by the router. Nothing requires it: each market is an ordinary v4 pool with the key
from `factory.poolKeyFor(token, index)`, and a terminal that quotes the pools picks whichever
is cheapest at that moment.

Fees are collected per market. `locker.pendingFees(token, index)` and
`pendingFeesAll(token)` read them, `collectFees(token)` collects every market and
`collectMarketFees(token, index)` one; the split is the one frozen in the launch record, the
creator's part goes to the shared `PairPadFeeEscrow` in each market's quote asset and in the
token. The factory can be closed to a whitelist by its owner; `canLaunch(address)` says where a
wallet stands. It is open to every wallet at the moment.

Events, same names as the single-market factory and locker but different shapes, so an indexer
keys them by contract address and topic:

```
TokenLaunched(address indexed token, address indexed deployer, uint256 launchConfigId, uint24 poolFee, address[] pairTokens)
MarketOpened(address indexed token, bytes32 indexed poolId, uint256 marketIndex, address pairToken, uint256 positionId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 tokenAmount, uint256 phantomQuote)
FeesCollected(address indexed token, uint256 indexed marketIndex, address currency0, address currency1, uint256 protocolAmount0, uint256 protocolAmount1, uint256 creatorAmount0, uint256 creatorAmount1)
```

One `MarketOpened` per pool precedes the launch's `TokenLaunched` in the same transaction, in
market order. `getLaunchedToken(token)` returns the record (deployer, fee recipient, fee terms,
pool fee, tick spacing, market count) and `getMarkets(token)` the per-market pair token,
phantom reserve, ticks, liquidity and position id.

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

Robinhood Chain, chain id 4663. The single-market stack was deployed at block 53890474, the
multi-market stack at block 55587224. Sources verified on Blockscout and Sourcify as exact
matches.

| Contract | Address |
| --- | --- |
| PairPadLaunchFactory | `0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F` |
| PairPadRouter | `0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120` |
| PairPadLaunchLocker | `0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231` |
| PairPadFeeEscrow | `0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386` |
| PairPadQuotePricer | `0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563` |
| PairPadPositionMinter | `0xDaB26Bb66F29863F2d68CeD54F65cC614c4e65dC` |
| PairPadLaunchDeployer | `0x916C53ae4738196394C2661c5B0C71B84F40e36C` |
| PairPadReferenceRegistry | `0x200EAEa1901407F48eBEaFFCF3aA89E75CA1303B` |
| PonsReferenceRegistry | `0x8a86940B81A9ae6b94011BaFacB121eA2751C890` |
| PairPadMultiLaunchFactory | `0x3ea29975a79900179F3e1aEF93347Ba4210c29C1` |
| PairPadMultiRouter | `0x458D2a59c2F3dd32775a64eE72004561440d64Df` |
| PairPadMultiLaunchLocker | `0x5826FBB6201DaAcD924A3d292841DA9142952D59` |
| PairPadMultiPositionMinter | `0x643C08DD4571Ba24c600e622a9982001D1A05Be4` |
| PairPadLaunchDeployer (multi) | `0x752b04277c1EDF6C1b3Cc81d4F9216d1aF1CaCE9` |
| PairPadMultiReferenceRegistry | `0x616AFc11dbb8c3C4EE719DCEfB645855070101D6` |

The multi-market stack shares the fee escrow and the quote pricer above.

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

The multi-market stack has its own scripts: `script/DeployMulti.s.sol` deploys the factory,
locker, minter, router and reference registry next to an existing escrow and pricer,
`script/WireMulti.s.sol` registers the new registry with the pricer and opens launching,
`script/LaunchMulti.s.sol` and `script/TradeMulti.s.sol` exercise a live deployment, and
`script/LocalMultiDemo.s.sol` runs the whole lifecycle on an anvil fork.
`test/fork/MultiLifecycle.fork.t.sol` covers launching, buying and selling across markets,
the atomic opening buy and per-market fee collection on a mainnet fork.

## Security

The contracts have not been audited. Liquidity is held by a locker with no withdraw function,
tokens have no owner and no privileged functions, and the factory owner can only change terms
for future launches. The factory owner is a single EOA at the moment. If you find a problem,
use GitHub's private vulnerability reporting on this repository rather than a public issue.

## License

MIT.
