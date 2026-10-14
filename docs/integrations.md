# Protocol integration evidence

The following verified Ethereum contract sources and ABIs were inspected on 2026-10-14:

- [LaunchFactory](https://etherscan.io/address/0x12C63b581d07093F6126bc02263c58f7EadaA96F#code)
- [ProjectFactory](https://etherscan.io/address/0xfF03410d0Fe5fa8f7F59F743de35E333D9857120#code)
- [Intake V2](https://etherscan.io/address/0xa43e6F75ee006411F79Ac1C84120606C2330DE82#code)

The required excerpts are preserved as ABI data in `protocol-abi.json`. Both factories expose:

```solidity
positionOf(uint64) -> (PoolKey key, int24 tickLower, int24 tickUpper, address requester)
claimFees(uint64) -> (uint256 amount0, uint256 amount1)
withdraw(address account, Currency currency)
```

`PoolKey` encodes `(address,address,uint24,int24,address)`. Both factories inherit the same `PoolFees` behavior: `claimFees` attempts automatic native/token payouts and retains amounts whose transfer failed; `withdraw` retries a specified account's outstanding currency balance. Consequently consumers implement `receive()`, call `claimFees` first, then withdraw both currencies, and account for their actual final balances. The requester, not an arbitrary router caller, controls `setRequester`.

Intake's action argument is `bytes32`; its callback tuple is `(address target, bytes4 selector)`. `requestWithFailure` additionally takes a `bytes4` failure selector followed by asset and amount. Its verified `complete` implementation supplies the action-specific result arguments. For job/launch results these are `(bytes32 requestId, bytes32 resultHash, string uri)`; oracle attestation tuples are a different action and are intentionally absent here. Failure arguments match the six-field signature in the assignment.

Read-only Ethereum calls confirmed deployed LaunchFactory bytecode, a nonzero `poolManager()` response, the IMD symbol `IMD`, and the current `priceOf(bytes32("launch.open@launch-1"), IMD)` response of `500000000000000000`. The concurrent block-number read was `0x18fae65`. The PoolManager is still a constructor argument; its response is not hardcoded into production source or deployment configuration.

The deterministic tests use a real vendored Uniswap v4 PoolManager, plus protocol mocks at the specified factory, IMD and Intake addresses. They do not require a network or a live deployment. They cover successful fee claims, failed or unauthorized commission operations, requester handover, exact Intake approval, callbacks and IMD-pool purchases. A full production factory launch/fork rehearsal was not run and remains part of the launch process, including CREATE2 prediction, policy liquidity seeding and requester handover.

The Medici contracts cannot change their dependencies. Intake itself has protocol-controlled pricing and writer configuration. If the required action stops accepting 0.5 IMD or the service becomes unavailable, commission can fail; the on-chain lapse path remains available and no Medici administrator can silently change the purchased action or price.
