# Security review and validation

This is the implementation review performed with the delivered work. It is not an independent audit. No transactions were broadcast. An independent adversarial review and the factory's launch rehearsal remain deployment responsibilities.

## Checked boundaries

| Boundary | Implementation and evidence |
| --- | --- |
| Immutable token and contracts | Standard OZ ERC20, one constructor mint; runtime opcode test excludes DELEGATECALL, CALLCODE and SELFDESTRUCT in all four contracts; size checks fit EIP-170. |
| Hook address/callbacks | CREATE2-mined `0x20cc` mask, permission validation at construction, manager-only callbacks, one exact native/MEDICI pool; unauthorized callback and initialization tests. |
| Return-delta permissions | Before-swap delta contains only the native fee; the pool executes the trade. Self-quote always reverts and cannot be called externally. Specified fee is checked against the actual fill afterward. No full-input NoOp path. |
| Native liquidity shortfall | ERC-6909 fallback tested with a token-only initial position and zero manager ETH, followed by redemption and TEAM claim. |
| Fee and balance conservation | All four modes, partial fills at price limits, launch-period decay, fee fuzzing, and stateful invariants over swaps/time/redemption/claims. Invariants require conserved ETH/token supply and exact fee-debt backing. |
| Treasury exemption | Uses actual PoolManager sender, not hookData; real buyback tests verify no hook fee. |
| Factory fee collection | No liquidity-hook flags; real PoolManager zero-liquidity collect succeeds. Both factories' ABI and native payouts checked against verified sources. |
| TWAP | Historical arithmetic accumulator, same-timestamp coalescing, binary search, elapsed-time price; same-block manipulation cannot change past averages. Historical/rolling-window tests. |
| Voting | Positive amounts, valid epoch/ID, capped proposal count and byte lengths, exact ERC20 burns, no arbitrary payer in transferFrom, fixed weekly boundaries, bounded extensions, deterministic tie order. |
| ETH solvency | Buyback funds reserved on receipt; all free-fund consumers exclude buyback reserves and unpaid bounties. Returned escrow does not enter income. Separate vesting streams preserve out-of-order settlement. |
| Commission authentication | Exact winning hash, keeper/public time gate, one attempt per candidate, exact/reset IMD approval, hard input cap and exact-output check. |
| Callbacks | Fixed Intake and live request checks, replay rejection, bounded URI, no external calls on result/failure. Both success and promotion execute under 200,000 gas in tests. |
| Asynchronous failure | Callback loss handled by permissionless lapse; promotion invalidates stale request IDs, recomputes quorum/bounty from runner votes and restarts deadlines. |
| Bounty payout | State changed before call; failed transfer restores escrow; retry destination fixed. Rejecting and reentering proposer tested. |
| Backer reserve | Factory requester proof, supply threshold on unreserved holdings, unique launch recording, per-token reserve aggregation, one claim per voter, 90-day expiry and dust burn. |
| Reentrancy | OZ guard on externally interacting treasury/router entry points and hook fee claims; callback authorization and CEI on payout accounting. No user-provided arbitrary calls or delegatecalls. |
| Role powers | No shared administrator. TEAM and KEEPER can hand over only their own roles. Rejected TEAM claims do not prevent swaps. |
| Offline reproducibility | Pinned compiler/settings and vendored source/licenses; bundle tool checks import resolution and source-size limit. |

## Interpretation and bounded choices

- The fee base is the native pool delta, before adding/subtracting the hook fee; specified-side budgeting permits at most one wei rounding up. All launch-rate excess belongs to the treasury.
- Weeks use a fixed calendar from pool open. A preceding extension shortens the next active epoch, not its original proposal deadline. The epoch TWAP covers its actual active start through its final end.
- IDs start at one; zero indicates no winner or no live request. A separate router `bound` bit makes one-time binding independent of numeric sentinels.
- Price is arithmetic ETH per MEDICI with 18-decimal scaling. Historical observations are never pruned; queries are logarithmic. There is no observation-cardinality exhaustion or dependency on a keeper maintaining the oracle.
- Bounty is unpaid escrow in the public result. The extra permissionless `claimBounty` retries a rejected transfer. Promotion consumes the runner once; no third-place promotion exists.
- Buyback tip is ETH within the unlocked budget; min output allows a fixed 5% deviation, including LP fee. No caller can loosen that bound. The IMD acquisition uses its independent 0.03 ETH absolute ceiling.
- Flags are advisory. The keeper must assess launch/job semantic correctness before recording it. JSON validity and actual production of the requested launch are Intake/keeper responsibilities, not an on-chain parser or external price oracle.

## Residual risks

A pool-derived TWAP can be economically manipulated over time, especially at small liquidity or soon after launch. A malicious keeper can flag/skip candidates and associate an eligible treasury-owned launch with a job identifier; it cannot change economic rules or bypass token/reserve proofs. External factory/Intake availability and compatibility are deployment dependencies. A role transferred to a contract that cannot use it can be lost permanently. Large public buybacks may fail the fixed price bound and need smaller caps. Token donations may be burned; there is no recovery power.

The tests deliberately cover these deterministic contract boundaries, not the off-chain correctness of a commissioned project or future protocol governance. Slither, Mythril, formal verification and an independent audit were not run. Foundry compiler/lint warnings about timestamp comparisons, named ABI outputs, bounded casts, or guarded external calls were reviewed in context; they do not establish an independent security verdict.
