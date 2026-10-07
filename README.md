# WORKERS / $WORK contracts

Proof-of-work NFT mine (WorkersNFT) and the WORK/IMD Uniswap v4 hook (WorkHook) for Robinhood Chain (4663).

Based on IMD job `8414d5ca-1d0c-4a68-a3bf-dfa2ea3359a6` (implementation + tests accepted; its deploy manifest failed because WorkersNFT linked external libraries). Changes in this repository:

1. **No linked libraries.** Every `WorkerSale` / `WorkerFinance` function is `internal`, so no deployed contract has `linkReferences`. Built with `via_ir` (WorkersNFT runtime 21.6 KB < 24,576). Tests read time through `vm.getBlockTimestamp()` / `vm.getBlockNumber()` so they are via-IR safe.
2. **Pause** lasts at most 24 h and a new pause needs 24 h unpaused since the last one ended.
3. **WORK emission is never lost.** Emission scheduled while paused or while no worker is activated is carried (`emissionCarry`) and released to activated workers at the next unpaused update. After every era has ended, `releaseMiningRemainder()` (owner, not while paused) sends what is left in the mining pool to the builders address.
4. **Deploy-time hook binding.** During pool initialization, a transaction from the account that deployed WorkersNFT binds the hook (`bindHook`, checked with `tx.origin`); the owner can still bind with `setHook`. The hook trusts `initializer`, `owner` or that deploying account.
5. The test-only `Work` ERC-20 moved to `test/mocks/Work.sol`; the launch token is IMD's.

```
forge build --sizes
forge test            # 76 tests
```
