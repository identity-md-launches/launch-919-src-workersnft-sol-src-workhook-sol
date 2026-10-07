"""Fixes 2 (24h pause + 24h gap), 3 (emission carry-forward + final remainder to builders), 5 (deploy-time hook binding)."""
import re
N = r'U:\imd\contracts\src\WorkersNFT.sol'
H = r'U:\imd\contracts\src\WorkHook.sol'
s = open(N, encoding='utf-8').read()
h = open(H, encoding='utf-8').read()


def rep(txt, old, new, cnt=1):
    assert txt.count(old) >= 1, old[:80]
    return txt.replace(old, new, cnt)


# ---------- state: new fields appended to the struct
s = rep(s, "        mapping(uint256 => uint256) workCredit;\n    }\n}", "        mapping(uint256 => uint256) workCredit;\n        uint256 pauseCooldownUntil;\n        uint256 emissionCarry;\n        address hookBinder;\n    }\n}")

# ---------- fix 2: 24h pause, 24h unpaused gap
s = s.replace("uint256 internal constant PAUSE_DURATION = 72 hours;", "uint256 internal constant PAUSE_DURATION = 24 hours;")
s = rep(s, "uint256 public constant PAUSE_DURATION = 72 hours;", "uint256 public constant PAUSE_DURATION = 24 hours;\n    uint256 public constant PAUSE_COOLDOWN = 24 hours;\n    uint256 public constant EMISSION_END = 1785 days;")
s = rep(s, """    /// @notice Pauses minting and accrual for at most 72 hours; transfers and claims remain available.
    function pause() external onlyOwner {
        if (paused()) revert InvalidParameter();
        WorkerFinance._updateMining(s);
        s.pauseStarted = block.timestamp;
        s.pauseUntil = block.timestamp + PAUSE_DURATION;
        emit Paused(s.pauseUntil);
    }

    function unpause() external onlyOwner {
        WorkerFinance._updateMining(s);
        s.pauseUntil = 0;
        s.pauseStarted = 0;
        emit Unpaused();
    }""", """    /// @notice Pauses minting and accrual for at most 24 hours; transfers and claims remain available.
    /// A new pause needs at least 24 hours unpaused since the previous one ended, so the owner cannot
    /// chain pauses. Emission scheduled during a pause is carried forward, never lost.
    function pause() external onlyOwner {
        if (paused() || block.timestamp < s.pauseCooldownUntil) revert InvalidParameter();
        WorkerFinance._updateMining(s);
        s.pauseStarted = block.timestamp;
        s.pauseUntil = block.timestamp + PAUSE_DURATION;
        s.pauseCooldownUntil = s.pauseUntil + PAUSE_COOLDOWN;
        emit Paused(s.pauseUntil);
    }

    function unpause() external onlyOwner {
        if (!paused()) revert InvalidParameter();
        WorkerFinance._updateMining(s);
        s.pauseUntil = 0;
        s.pauseStarted = 0;
        s.pauseCooldownUntil = block.timestamp + PAUSE_COOLDOWN;
        emit Unpaused();
    }

    function pauseCooldownUntil() external view returns (uint256) {
        return s.pauseCooldownUntil;
    }

    function emissionCarry() external view returns (uint256) {
        return s.emissionCarry;
    }

    /// @notice After every era has ended, WORK left in the mining pool (emission carried while nobody was
    /// activated, or rounding dust) can be released to the builders address. Never touches owed WORK.
    function releaseMiningRemainder() external onlyOwner nonReentrant {
        WorkerFinance.releaseMiningRemainder(s);
    }""")

# ---------- fix 3: carry-forward emission
s = rep(s, """    /// @dev Eras are measured from mint end. Paused time and time without active workers
    /// are skipped, with no retroactive distribution on activation or resume.
    function _newEmission(WorkerState.Data storage s) private view returns (uint256 amount) {
        if (!s.mintEnded || s.activeWorkers == 0) return 0;
        amount = scheduledEmission(s, block.timestamp) - scheduledEmission(s, s.lastMiningUpdate);
        uint256 start = s.lastMiningUpdate > s.pauseStarted ? s.lastMiningUpdate : s.pauseStarted;
        uint256 end = block.timestamp < s.pauseUntil ? block.timestamp : s.pauseUntil;
        if (end > start) amount -= scheduledEmission(s, end) - scheduledEmission(s, start);
        if (amount > s.miningPool) amount = s.miningPool;
    }

    function _updateMining(WorkerState.Data storage s) internal {
        uint256 amount = _newEmission(s);
        if (amount != 0) {""", """    /// @dev Eras are measured from mint end. Emission scheduled while paused or while no worker is
    /// activated is held in emissionCarry and released to the activated workers at the first update
    /// that is unpaused with at least one activated worker, so no scheduled WORK is ever lost.
    function _emission(WorkerState.Data storage s) private view returns (uint256 amount, uint256 carry) {
        carry = s.emissionCarry;
        if (!s.mintEnded) return (0, carry);
        amount = scheduledEmission(s, block.timestamp) - scheduledEmission(s, s.lastMiningUpdate);
        uint256 start = s.lastMiningUpdate > s.pauseStarted ? s.lastMiningUpdate : s.pauseStarted;
        uint256 end = block.timestamp < s.pauseUntil ? block.timestamp : s.pauseUntil;
        if (end > start) {
            uint256 held = scheduledEmission(s, end) - scheduledEmission(s, start);
            amount -= held;
            carry += held;
        }
        if (s.activeWorkers == 0) {
            carry += amount;
            amount = 0;
        } else if (block.timestamp >= s.pauseUntil) {
            amount += carry;
            carry = 0;
        }
        if (amount > s.miningPool) amount = s.miningPool;
        if (carry > s.miningPool - amount) carry = s.miningPool - amount;
    }

    function _newEmission(WorkerState.Data storage s) private view returns (uint256 amount) {
        (amount,) = _emission(s);
    }

    function _updateMining(WorkerState.Data storage s) internal {
        (uint256 amount, uint256 carry) = _emission(s);
        s.emissionCarry = carry;
        if (amount != 0) {""")
s = rep(s, """    function pendingWork(WorkerState.Data storage s, uint256 id) internal view returns (uint256) {""", """    function releaseMiningRemainder(WorkerState.Data storage s) internal {
        if (!s.mintEnded || block.timestamp < s.mintEndTime + WorkerConstants.EMISSION_END) revert InvalidParameter();
        _updateMining(s);
        uint256 amount = s.miningPool;
        if (amount == 0) revert InvalidParameter();
        s.miningPool = 0;
        s.emissionCarry = 0;
        WorkTransfer.send(s.work, WorkerConstants.BUILDERS, amount);
        emit MiningRemainderReleased(amount);
    }

    function pendingWork(WorkerState.Data storage s, uint256 id) internal view returns (uint256) {""")
# constants library + events
s = rep(s, "    uint256 internal constant PAUSE_DURATION = 24 hours;", "    uint256 internal constant PAUSE_DURATION = 24 hours;\n    uint256 internal constant EMISSION_END = 1785 days;")
s = rep(s, "    event Swept(address indexed token, uint256 amount);\n    error MintUnavailable();", "    event Swept(address indexed token, uint256 amount);\n    event MiningRemainderReleased(uint256 amount);\n    error MintUnavailable();")

# ---------- fix 5: deploy-time hook binding (same deploying EOA), owner path kept
s = rep(s, "        s.retargetTime = block.timestamp;\n    }\n\n    /// @notice One-time binding, before deposits or minting.", "        s.retargetTime = block.timestamp;\n        s.hookBinder = tx.origin;\n    }\n\n    /// @notice One-time binding, before deposits or minting.")
s = rep(s, """    function fundPools() external nonReentrant {
        WorkerFinance.fundPools(s);
    }""", """    /// @notice Deploy-time binding: the hook calls this while its pool is being initialized, inside a
    /// transaction sent by the same account that deployed this contract (tx.origin cannot be forged).
    function bindHook() external {
        if (tx.origin != s.hookBinder) revert Unauthorized();
        WorkerSale.setHook(s, msg.sender);
    }

    function fundPools() external nonReentrant {
        WorkerFinance.fundPools(s);
    }""")
open(N, 'w', encoding='utf-8').write(s)

# hook side
h = rep(h, "    function hook() external view returns (address);\n", "    function hook() external view returns (address);\n    function bindHook() external;\n")
h = rep(h, "    address public immutable initializer;\n", "    address public immutable initializer;\n    address public immutable deployerOrigin;\n")
h = rep(h, "        initializer = msg.sender;\n", "        initializer = msg.sender;\n        deployerOrigin = tx.origin;\n")
h = rep(h, """    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        if (
            (sender != initializer && sender != owner) || initialized || poolId != bytes32(0)""", """    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        bool trusted = sender == initializer || sender == owner || tx.origin == deployerOrigin;
        if (trusted && workers.hook() == address(0)) workers.bindHook();
        if (
            !trusted || initialized || poolId != bytes32(0)""")
open(H, 'w', encoding='utf-8').write(h)
print("patched")
