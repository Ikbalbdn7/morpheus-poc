# Morpheus Bug Bounty PoC — Lock Period Reset on Top-Up

Self-contained Foundry test against the deployed Morpheus `DepositPool`
(Ethereum mainnet), pinned to block **26,433,200**, using no privileged accounts.

## Finding

**Top-up resets lock multiplier.** A user who tops up an actively-locked deposit
has `claimLockStart` reset to `block.timestamp` for the *entire* position, which
shortens the effective lock and permanently lowers their reward multiplier.

Measured on fork: a 2-year locked stake topped up 6 months in drops its multiplier
from **3.577x → 2.628x (26.5%)** while adding 20% *more* capital.

## Requirements

- [Foundry](https://book.getfoundry.sh/) (`forge` on PATH)

## Run

```bash
forge test -vvv
```

```
[PASS] testLockReset() (gas: 1348689)
```

## Target (Appendix A)

- stETH DepositPool: `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790`
- implementation: `0xdB10dAEF167eA2233Ba6811457dD24D676FbD670`
- Fork pinned at block `26433200` via `vm.createSelectFork` inside `setUp()`.

## Notes

- RPC URL is `https://eth.drpc.org` (public). Override by editing the
  `vm.createSelectFork(...)` call at the top of `setUp()` if needed.
- Chainlink aggregators are mocked (`vm.mockCall`) to return fresh rounds so the
  test does not trip the staleness guard. This is oracle simulation — no Morpheus
  account, role, or key is impersonated.