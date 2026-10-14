# Medici

An immutable native-ETH Uniswap v4 launch: `MediciToken`, `MediciHook`, `MediciTreasury`, and `MediciFeeRouter`. The hook creates its treasury and fee router atomically in its constructor. There is no owner, upgrade, pause, minting entry point, configurable fee, rescue withdrawal, or price service. The only handovers are each role transferring itself and the fee router's verified, one-time launch-number binding.

## Build and test offline

```sh
forge build
forge test
forge fmt --check
python3 tools/check_bundle.py
```

Solidity **0.8.26**, Cancun, optimizer 200 runs, `via_ir = true`, and `bytecode_hash = "none"` are pinned in `foundry.toml`. All imported dependencies are ordinary vendored source files with licenses; no installation, network, environment variables, FFI, filesystem permissions, or submodules are needed. The requested fuzz seed is pinned. Invariant testing uses 128 runs of 64 calls, failing on any revert.

The source bundle omits upstream audit PDFs, package archives, dependency tests, compiler output, and caches. `test/scratch/` is temporary development material and is not part of delivery. Dependency versions are recorded in [dependencies.lock.json](dependencies.lock.json).

## Launch parameters and deployment

| Parameter | Value |
| --- | --- |
| Chain | Ethereum, chain ID 1 |
| Token contract | `MediciToken()` — no constructor arguments |
| Name / symbol / decimals | Medici / MEDICI / 18 |
| Supply | 1,000,000,000 tokens, minted once to the deploying launch factory |
| Distribution | Pool 9,000 bps; policy Merkle distributor 1,000 bps; no team allocation |
| Pair | Native ETH, currency0 = zero address; MEDICI = currency1 |
| Pool fee / tick spacing | 12,500 / 60, independent of the hook fee |
| Hook constructor | `MediciHook(IPoolManager poolManager, address token)` |
| Constructor bindings | `$poolManager`, `$token`; neither is hardcoded or queried during construction |
| Hook address flags | `(uint160(hook) & 0x3fff) == 0x20cc` |
| Child treasury | Created by the hook; read `hook.treasury()` |
| Child fee router | Created by the hook; read `hook.feeRouter()` |
| TEAM | `0x01670a5CfAEEaEE388cD38085C4ADf1Bad45a1c2` |
| KEEPER | `0x16578E0dfAFa219f2B0f52095D8206b5c02F8250` |
| LaunchFactory | `0x12C63b581d07093F6126bc02263c58f7EadaA96F` |
| ProjectFactory | `0xfF03410d0Fe5fa8f7F59F743de35E333D9857120` |
| Intake V2 | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| IMD pool | Native ETH / IMD, fee 10,000, tick spacing 200, no hook |

The authorized launch process deploys the token, mines the hook's CREATE2 salt using the actual token/manager constructor encoding and factory address, and deploys the hook. It must **not separately deploy replacement companions**: the hook deploys and permanently binds the treasury and router. Their constructors take `(manager, token, hook)` and `(hook, token, treasury)` respectively, and are also independently testable. Child creation requires no circular address prediction or setup setter. Each contract fits EIP-170 and the hook creation code, including both children, fits EIP-3860.

The factory opens the pool and seeds the policy allocation. The launch process determines the opening sqrt price from the policy's 10 ETH opening market cap, supply and token address; do not initialize at the manifest's nominal one-to-one placeholder. This repository neither submits transactions nor writes `launch.json`.

After launch:

1. Anyone calls `feeRouter.setLaunchNumber(uint64 n)`. It succeeds once only if LaunchFactory's position for `n` names this hook.
2. The **paying wallet/current requester** calls `LaunchFactory.setRequester(n, feeRouter)`. This cannot be performed by the router or treasury. Previously owed factory fees remain owed to their previous recipient.
3. Anyone can call `feeRouter.harvest()` to collect factory fees. Native ETH is paid to the treasury's current TEAM; MEDICI is sent through the treasury and burned, so it is included in `totalBurned`. If TEAM rejects the ETH, the burn still stands: the ETH waits in the router (`TeamPaymentDeferred`) and anyone can send it later with `feeRouter.payTeam()`, which reverts until TEAM can receive it.
4. Read `openedAt`, role addresses, the pool key and the bound launch number before operating the page or keeper. No additional configuration or privileged activation is required.

## Hook accounting and price

The enabled callbacks are `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. Initialization validates the one permitted pool and every callback authenticates the PoolManager. Liquidity callbacks are disabled, so liquidity provision, withdrawal and zero-liquidity factory fee collection remain unrestricted.

Fees use the absolute native-ETH **pool swap delta**, including the pool's LP fee where it contributes to ETH input. Buys add the hook fee to that input; sells deduct it from output. After the first 900 seconds the hook takes 200 bps: 150 bps to the treasury and 50 bps to TEAM. The buy rate starts at 5,000 bps and falls linearly to 200 bps, rounding the rate down to whole bps. The additional launch-period fee all goes to the treasury. Sells are always 200 bps. Direct swaps whose PoolManager sender is the treasury are exempt; user-supplied hook data cannot impersonate it.

For ETH on the unspecified side, `afterSwap` computes the fee from the settled pool delta. For ETH on the specified side, `beforeSwap` uses a **self-only reverted simulation** of that same pool at the caller's price limit. This determines the actual fill and reserves just its ETH fee; the ordinary PoolManager then executes the real swap. `afterSwap` checks the real delta equals the simulation. The simulation leaves no state or fee-growth changes. A partial fill pays only on the ETH actually exchanged. Exact specified-side budgets round the fee up by at most **two wei** on an exact-in buy (the fee is `specified - floor(specified * 10000 / (10000 + rate))`, which exceeds `floor(base * rate / 10000)` by two whenever the division remainder passes 10,000, a case that only arises at launch rates above 200 bps) and by at most one wei on an exact-out sell; other fees and the 50-bps team allocation round down. `afterSwap` enforces exactly those bounds. The hook never claims the entire swap or replaces its execution.

If the manager already has enough ETH, the hook takes native ETH immediately and pays the treasury with `call`; TEAM accrues as `teamOwed`. On a fresh token-only manager, input has not been paid at callback time: the hook instead mints native-currency ERC-6909 claims. Anyone calls `redeemFees()` after settlement to burn those claims and receive their backing ETH; `claimTeam()` also redeems and pays the treasury before paying the current TEAM. A TEAM contract rejecting ETH makes its claim revert and preserves the debt; it does not block trading. Fee amounts redeemed later become treasury income in their receipt epoch.

The hook records an arithmetic ETH/MEDICI price integral after each swap, with one observation per timestamp. Reads binary-search historical observations and extrapolate the last price across quiet periods. `price()` is the integral over the last 24 hours, or since opening while younger. Settlement fixes the average over the epoch's actual active interval, ending at its final extended end, even if settlement happens later. A same-block swap cannot change any already elapsed portion of a TWAP. The price unit is wei ETH per whole MEDICI, with a minimum fixed-point resolution of one wei. In the opening second, when no time has elapsed, `price()` is the current spot, so proposals and buybacks work from the first block; `twap(start, end)` itself still requires `end > start`.

The in-pool TWAP does not prevent manipulation sustained across time in a thin market. There is deliberately no outside oracle or alternate venue. Buybacks can be split into smaller `maxEth` amounts when price impact would exceed their fixed protection.

## Voting and epochs

Epoch and proposal IDs start at **1**; `currentEpoch()` is 0 before pool initialization. Nominal weekly deadlines are anchored to pool opening: epoch `e` has proposal deadline `openedAt + e * 7 days`. An extension delays the next epoch's active start, but later nominal deadlines do not drift. After an extension the next epoch can therefore have fewer than seven active days. Settlement is independent of advancement; elapsed epochs remain status 0 until someone settles them.

A proposal requires a nonempty title of at most 80 bytes and a nonempty brief of at most 12,000 bytes. The brief is the exact UTF-8 JSON `launch.open` request body; the contract hashes/emits these opaque bytes, and Intake performs semantic validation. Preserve the event's original bytes to commission the winning hash. JSON whitespace or key order changes produce a different hash. Proposal metadata stores the proposer, title, hash, block number and burns. A maximum of 20 proposals is accepted before the **original** weekly deadline.

Proposal cost is `0.002 ETH * 1.15^n / price()`, clamped to 1,000–50,000,000 MEDICI. Integer ETH arithmetic rounds down at each increase. Approval is to the treasury. Proposal cost and later positive votes transfer MEDICI directly from the caller to `0x000000000000000000000000000000000000dEaD`; total ERC-20 supply is unchanged. `totalBurned` counts MEDICI burned through the treasury, including proposals, votes, fee-router harvests, deposited MEDICI, and buybacks. Burns of other launch assets are reported separately by their action events.

Votes require the active epoch and an existing proposal. A vote in the last hour can only **increase** the end, to ten minutes after the vote, capped at original deadline +24 hours. It never shortens an existing end. Proposals' initial votes follow the same rule. KEEPER flags are informational and do not alter ranking.

`settle(e)` is permissionless at or after the final end. Largest burn wins; ties favor the lower, earlier ID. The second-ranked proposal is retained as runner-up. A winner worth less than 0.01 ETH at the fixed epoch TWAP produces status 4. Otherwise status becomes 1 and starts a 14-day launch deadline. The bounty is `min(freeETH / 10, 1 ETH, winner burn value / 2)` and is escrowed.

## Commissioning and backers

| Status | Meaning |
| --- | --- |
| 0 | Not settled, including epochs whose end has passed |
| 1 | Winner awaiting a recorded launch |
| 2 | Launch recorded; claims available until their separate deadline |
| 3 | Lapsed/exhausted; escrow released |
| 4 | No qualifying winner |

KEEPER may commission immediately; everyone else may do so 24 hours after the current winner was selected. The exact brief hash must match. There is at most one commission per selected candidate and one live request per epoch. If the treasury has less than 0.5 IMD, it first buys **exactly 0.5 IMD**, rather than just the deficit, using the specified pool. It accepts no more than `min(0.03 ETH, freeETH)` input and refuses a partial exact-output fill. With enough IMD it does no swap. The approval to Intake is exactly 0.5 IMD and is reset to zero after the request.

The action is right-padded `bytes32("launch.open@launch-1")`, not its hash. The callbacks have the exact requested signatures. Only Intake and the live request ID can call them. Success stores the result hash and a URI truncated to 96 **bytes**, and consumes the live request; it does not certify a launch. Failure promotes the runner-up. Tests exercise both callbacks with a 200,000-gas stipend.

`skip(e, reason)` lets KEEPER promote the runner before commissioning. `lapse(e)` lets anyone do so at the 14-day deadline without a recorded launch, including when a callback was lost. Promotion cancels the old live ID, clears the previous result metadata (retained in events), releases the old bounty, uses the runner's own burns and the original epoch TWAP for quorum/bounty, and starts fresh 24-hour public-commission and 14-day launch windows. There is only one promotion. A missing/exhausted runner produces status 3; a runner failing quorum produces status 4. Released escrow is not counted again as income.

After commission, KEEPER calls `recordCommission(e, n, jobId)` before the current launch deadline. `jobId` must be nonempty. The contract checks the two fixed factories' positions, treasury requester ownership, a valid position range, the non-ETH/non-IMD launch token, and at least 5% of its supply in **unreserved** treasury holdings. MEDICI itself cannot be recorded as a newly commissioned token. The two factories number their positions independently, so recorded launches are keyed by **(factory, number)**: `recordCommission(e, n, jobId)` records whichever factory holds an eligible, unrecorded position `n` (eligible means requester, pair and 5% holding all check out), reverts `AmbiguousLaunch` if both do, and `recordCommissionAt(e, factory, n, jobId)` names the factory in that case. Each (factory, number) is recorded once; `launchOf(e)` returns the pair, `launchToken(factory, n)` the recorded token, and `Recorded` carries the factory. The full available launch-token balance becomes that epoch's backer reserve. KEEPER is responsible for verifying that the recorded job and launch actually implement the winning brief; that semantic relationship is not proved by a factory position.

The bounty is attempted once, with an ETH `call` to the winner's proposer, when the launch is recorded. If the proposer cannot receive it, the treasury keeps it: the escrow is released into free ETH, `BountyPaid` reports `success = false`, and there is no retry. `epochResult.bounty` is the escrowed amount and becomes zero once the launch is recorded. `claimBacker(e)` pays a winning voter `share amount * their burn / winner's total burn`, rounding down, once. Claims stop exactly 90 days after recording. Anyone then calls `burnUnclaimed(e)`, including rounding dust. `backerShare.claimed` continues to report actual voter payouts after the remaining balance is burned. Per-token reserves protect shares across epochs. Permissionless `harvest(n)` claims and withdraws both fee currencies of every recorded launch numbered `n` (one per factory), keeps IMD and ETH, and burns launch tokens above all outstanding reserves.

## ETH budgets and responsibilities

Every ordinary ETH receipt reserves 40% for buybacks, so commissioning, bounties and KEEPER cannot spend a future buyback's funding. `freeETH()` excludes this reserve, pending or vested, and all unpaid bounties. Forced ETH that bypasses `receive()` is free treasury balance, not measured epoch income. Burning deposited MEDICI is permissionless via `burnDeposited()`.

At settlement, 40% of that epoch's received ETH starts vesting linearly for 24 hours. Separate streams retain their own vesting times when epochs settle close together or out of order; unspent amounts carry indefinitely. Prefix sums and binary search keep the view bounded without walking all historical epochs.

`buyback(maxEth)` uses the lesser of unlocked funds and the caller's cap. The caller receives a **0.5% ETH tip out of that budget**; the remaining 99.5% buys MEDICI and is burned. Output must be at least 95% of the amount quoted at the 24-hour TWAP (the fixed 5% margin includes LP fees and price impact). Any partial fill must still meet this minimum; tip and budget consumption are reduced in proportion to actual input. `buybackChunk()` returns unlocked total ETH and the 0.5% tip for consuming all of it. `totalBuybackBurned` counts only the bought MEDICI burned.

KEEPER may withdraw at most 0.01 ETH per active epoch, cumulatively and only from free ETH. TEAM can only call `setTeam(next)`; KEEPER can only call `setKeeper(next)` for its own role. Nonzero destinations are required. A role voluntarily handed to an inaccessible account cannot be recovered by another role.

A keeper or any caller should settle ended epochs, redeem delayed hook fees, harvest both launch types, execute reasonably sized buybacks, and trigger lapses/expired-share burns. KEEPER additionally reviews flags, commissions early, and records verified launches. The winning brief must arrange for the treasury to become the new factory position's requester and receive at least 5% of its token supply; the contracts cannot manufacture those allocations.

See [the security review](docs/security-review.md) and [integration evidence](docs/integrations.md) for the checked boundaries and remaining deployment responsibilities.
