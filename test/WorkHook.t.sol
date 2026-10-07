// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    Work,
    WorkHook,
    WorkOwned,
    IPoolManager,
    IWorkers,
    Currency,
    PoolKey,
    SwapParams,
    BalanceDelta,
    BeforeSwapDelta
} from "src/WorkHook.sol";
import {WorkersNFT} from "src/WorkersNFT.sol";
import {WorkTestBase, TestIMD, TestPoolManager, WorkerFixture} from "./WorkersNFT.t.sol";

contract HookWorkersStandIn {
    function bindHook() external {}

    address public work;
    address public imd;
    IPoolManager public poolManager;
    int24 public tickSpacing = 60;
    address public hook;
    bool public mintEnded;
    uint256 public totalWeight;
    uint256 public notified;
    bool public rejectNotification;

    constructor(address w, address i, IPoolManager m) {
        work = w;
        imd = i;
        poolManager = m;
    }

    function bind(address h) external {
        hook = h;
    }

    function phase(bool ended, uint256 weight) external {
        mintEnded = ended;
        totalWeight = weight;
    }

    function reject(bool enabled) external {
        rejectNotification = enabled;
    }

    function notifyHookReward(uint256 amount) external {
        require(msg.sender == hook && mintEnded && totalWeight != 0 && !rejectNotification, "bad reward");
        notified += amount;
        require(TestIMD(imd).balanceOf(address(this)) >= notified, "unfunded reward");
    }
}

abstract contract HookDeployment is WorkTestBase {
    function _deployHook(IPoolManager m, IWorkers n) internal returns (WorkHook h) {
        bytes32 initHash = keccak256(abi.encodePacked(type(WorkHook).creationCode, abi.encode(m, n, address(this))));
        uint256 salt;
        // Exercise the real constructor's permissions-address check; no etched hook.
        while (true) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash))))
            );
            if (uint160(predicted) & 0x3fff == 0x30cc && predicted.code.length == 0) break;
            ++salt;
        }
        h = new WorkHook{salt: bytes32(salt)}(m, n, address(this));
    }
}

abstract contract HookFixture is HookDeployment {
    TestIMD internal imd;
    Work internal work;
    TestPoolManager internal manager;
    HookWorkersStandIn internal workers;
    WorkHook internal hook;
    PoolKey internal key;
    uint256 internal constant MANAGER_FUNDS = 1e30;
    event FeeChanged(uint16 oldValue, uint16 newValue);
    event StakerShareChanged(uint16 oldValue, uint16 newValue);
    event FeesDistributed(uint256 builders, uint256 stakers);

    function _setupHook(bool imdFirst) internal {
        vm.chainId(31337);
        vm.warp(1000000);
        TestIMD template = new TestIMD(6);
        address imdAddress = imdFirst ? address(0x1000) : address(type(uint160).max - 1);
        vm.etch(imdAddress, address(template).code);
        imd = TestIMD(imdAddress);
        work = new Work();
        manager = new TestPoolManager();
        workers = new HookWorkersStandIn(address(work), address(imd), manager);
        hook = _deployHook(manager, IWorkers(address(workers)));
        workers.bind(address(hook));
        key = PoolKey(
            Currency.wrap(imdFirst ? address(imd) : address(work)),
            Currency.wrap(imdFirst ? address(work) : address(imd)),
            12500,
            60,
            address(hook)
        );
        imd.mint(address(manager), MANAGER_FUNDS);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        vm.prank(address(manager));
        hook.afterInitialize(address(this), key, uint160(1 << 96), 0);
    }

    function _params(uint256 mode, uint256 amount) internal view returns (SwapParams memory p) {
        // 0 = exact IMD input buy; 1 = exact WORK output buy;
        // 2 = exact WORK input sell; 3 = exact IMD output sell.
        bool buy = mode < 2;
        p = SwapParams(buy == hook.imdIs0(), mode == 0 || mode == 2 ? -int256(amount) : int256(amount), 1);
    }

    function _raw(uint256 mode, uint256 specified, uint256 other) internal view returns (BalanceDelta) {
        int128 imdDelta = mode == 0
            ? -int128(int256(specified))
            : mode == 3 ? int128(int256(specified)) : mode == 1 ? -int128(int256(other)) : int128(int256(other));
        int128 workDelta =
            mode < 2 ? int128(int256(mode == 0 ? other : specified)) : -int128(int256(mode == 3 ? other : specified));
        return hook.imdIs0() ? manager.pack(imdDelta, workDelta) : manager.pack(workDelta, imdDelta);
    }

    function _trade(uint256 mode, uint256 specified, uint256 other) internal returns (BalanceDelta) {
        return manager.callbacks(key, _params(mode, specified), _raw(mode, specified, other));
    }
}

abstract contract HookBehaviorTests is HookFixture {
    function test_PermissionsAndBinding() public view {
        eq(uint160(address(hook)) & 0x3fff, 0x30cc);
        WorkHook.Permissions memory p = hook.getHookPermissions();
        require(
            p.beforeInitialize && p.afterInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        require(
            !p.beforeAddLiquidity && !p.afterAddLiquidity && !p.beforeRemoveLiquidity && !p.afterRemoveLiquidity
                && !p.beforeDonate && !p.afterDonate && !p.afterAddLiquidityReturnDelta
                && !p.afterRemoveLiquidityReturnDelta
        );
        eq(hook.feeBps(), 75);
        eq(hook.stakerShareBps(), 10000);
        eq(hook.owner(), address(this));
        eq(hook.poolId(), keccak256(abi.encode(key)));
        require(hook.initialized());
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_FeesAllDirectionsAndSplit(
        uint256 amount,
        uint16 fee,
        uint16 share,
        uint8 mode,
        bool ended,
        bool staked
    ) public virtual {
        amount = bounded(amount, 1, 1e24);
        fee = uint16(bounded(fee, 0, 875));
        share = uint16(bounded(share, 9000, 10000));
        mode %= 4;
        hook.setFeeBps(fee);
        hook.setStakerShareBps(share);
        workers.phase(ended, staked ? 4 : 0);
        uint256 expectedFee = mode == 3 ? (amount * fee + 9999 - fee) / (10000 - fee) : amount * fee / 10000;
        uint256 stakerFee = ended && staked ? expectedFee * share / 10000 : 0;
        if (expectedFee > 0) {
            vm.expectEmit(false, false, false, true, address(hook));
            emit FeesDistributed(expectedFee - stakerFee, stakerFee);
        }
        BalanceDelta callerDelta = _trade(mode, amount, amount);
        eq(imd.balanceOf(B), expectedFee - stakerFee);
        eq(imd.balanceOf(address(workers)), stakerFee);
        eq(workers.notified(), stakerFee);
        eq(imd.balanceOf(address(manager)), MANAGER_FUNDS - expectedFee);
        eq(imd.balanceOf(address(hook)), 0);
        eq(manager.taken(), expectedFee);
        int128 callerIMD =
            hook.imdIs0() ? int128(BalanceDelta.unwrap(callerDelta) >> 128) : int128(BalanceDelta.unwrap(callerDelta));
        int256 expectedDelta = mode == 0
            ? -int256(amount)
            : mode == 3 ? int256(amount) : mode == 1 ? -int256(amount + expectedFee) : int256(amount - expectedFee);
        require(int256(callerIMD) == expectedDelta, "wrong caller settlement");
    }

    function test_DefaultFeeDuringMintAndAfterWithNoStakers() public {
        workers.phase(false, 4);
        _trade(0, 100e6, 1 ether);
        eq(imd.balanceOf(B), 750000);
        eq(workers.notified(), 0);
        workers.phase(true, 0);
        _trade(2, 1 ether, 100e6);
        eq(imd.balanceOf(B), 1500000);
        eq(workers.notified(), 0);
        workers.phase(true, 1);
        _trade(0, 100e6, 1 ether);
        eq(imd.balanceOf(B), 1500000);
        eq(workers.notified(), 750000);
    }

    function test_FeesAreChargedExactlyOnceInCorrectCallback() public {
        SwapParams memory p = _params(0, 100e6);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta d, uint24 overrideFee) = hook.beforeSwap(ALICE, key, p, "");
        require(selector == WorkHook.beforeSwap.selector);
        eq(overrideFee, 0);
        eq(uint256(BeforeSwapDelta.unwrap(d) >> 128), 750000);
        eq(imd.balanceOf(B), 750000);
        int128 input = -int128(100e6 - 750000);
        BalanceDelta raw = hook.imdIs0() ? manager.pack(input, 1 ether) : manager.pack(1 ether, input);
        vm.prank(address(manager));
        (, int128 afterFee) = hook.afterSwap(ALICE, key, p, raw, "");
        require(afterFee == 0);
        eq(imd.balanceOf(B), 750000);
        p = _params(2, 1 ether);
        vm.prank(address(manager));
        (, d,) = hook.beforeSwap(ALICE, key, p, "");
        eq(uint256(BeforeSwapDelta.unwrap(d)), 0);
        raw = _raw(2, 1 ether, 100e6);
        vm.prank(address(manager));
        (, afterFee) = hook.afterSwap(ALICE, key, p, raw, "");
        eq(uint128(afterFee), 750000);
        eq(imd.balanceOf(B), 1500000);
    }

    function test_PartialSpecifiedFillRevertsWholeSwapIncludingFeeTransfers() public {
        workers.phase(true, 1);
        SwapParams memory p = _params(0, 100e6);
        BalanceDelta raw = _raw(0, 99e6, 1 ether);
        vm.expectRevert(WorkHook.PartialSpecifiedSwap.selector);
        manager.callbacks(key, p, raw);
        eq(imd.balanceOf(address(manager)), MANAGER_FUNDS);
        eq(imd.balanceOf(address(workers)), 0);
        eq(workers.notified(), 0);
        p = _params(3, 100e6);
        raw = _raw(3, 99e6, 1 ether);
        vm.expectRevert(WorkHook.PartialSpecifiedSwap.selector);
        manager.callbacks(key, p, raw);
    }

    function test_NotificationFailureRevertsBothLegs() public {
        workers.phase(true, 4);
        workers.reject(true);
        SwapParams memory p = _params(0, 100e6);
        BalanceDelta raw = _raw(0, 100e6, 1 ether);
        vm.expectRevert();
        manager.callbacks(key, p, raw);
        eq(imd.balanceOf(address(manager)), MANAGER_FUNDS);
        eq(imd.balanceOf(address(workers)), 0);
        eq(imd.balanceOf(B), 0);
    }

    function test_ZeroFeeAndRoundingDustDoNotTakeFunds() public {
        _trade(0, 1, 1);
        eq(manager.taken(), 0);
        hook.setFeeBps(0);
        for (uint256 mode; mode < 4; ++mode) {
            _trade(mode, 100e6, 1 ether);
        }
        eq(manager.taken(), 0);
        eq(imd.balanceOf(address(manager)), MANAGER_FUNDS);
    }

    function test_OnlyManagerAndOnlyConfiguredPool() public {
        SwapParams memory p = _params(0, 10);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.beforeSwap(ALICE, key, p, "");
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.afterSwap(ALICE, key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.beforeInitialize(ALICE, key, 1);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.afterInitialize(ALICE, key, 1, 0);
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        hook.beforeSwap(ALICE, wrong, p, "");
        wrong = key;
        wrong.tickSpacing = 10;
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        hook.afterSwap(ALICE, wrong, p, BalanceDelta.wrap(0), "");
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        hook.beforeInitialize(address(this), key, 1);
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        hook.afterInitialize(address(this), key, 1, 0);
    }

    function test_BoundedAdminWithEventsAndTwoStepOwnership() public {
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.setFeeBps(0);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.setStakerShareBps(9000);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        hook.setFeeBps(876);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        hook.setStakerShareBps(8999);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        hook.setStakerShareBps(10001);
        vm.expectEmit(false, false, false, true, address(hook));
        emit FeeChanged(75, 875);
        hook.setFeeBps(875);
        vm.expectEmit(false, false, false, true, address(hook));
        emit StakerShareChanged(10000, 9000);
        hook.setStakerShareBps(9000);
        hook.transferOwnership(BOB);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.acceptOwnership();
        vm.prank(BOB);
        hook.acceptOwnership();
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        hook.setFeeBps(0);
        vm.prank(BOB);
        hook.setFeeBps(0);
        eq(hook.feeBps(), 0);
    }

    function test_SpecifiedSignedEdgesRevertCleanly() public {
        SwapParams memory p = _params(0, 1);
        p.amountSpecified = type(int256).min;
        vm.prank(address(manager));
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        hook.beforeSwap(ALICE, key, p, "");
        p.amountSpecified = -int256(uint256(uint128(type(int128).max)) + 1);
        vm.prank(address(manager));
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        hook.beforeSwap(ALICE, key, p, "");
        p = _params(3, uint256(uint128(type(int128).max)) + 1);
        vm.prank(address(manager));
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        hook.beforeSwap(ALICE, key, p, "");
    }

    function test_OracleWarmupAndSameBlockManipulationHasZeroWeight() public {
        vm.expectRevert(WorkHook.OracleNotReady.selector);
        hook.minimumBuybackOutput(100e6);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        eq(hook.minimumBuybackOutput(100e6), 93100000);
        manager.setTick(10000);
        _trade(2, 1, 1);
        require(hook.averageTick() == 0);
        eq(hook.minimumBuybackOutput(100e6), 93100000);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        require(hook.averageTick() == 10000);
        uint256 quote = hook.minimumBuybackOutput(100e6);
        require(hook.imdIs0() ? quote > 93100000 : quote < 93100000);
    }

    function test_NegativeAverageTickFloorsInsteadOfTruncates() public {
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        manager.setTick(-1);
        _trade(2, 1, 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        require(hook.averageTick() == -1, "negative fractional tick must round down");
    }

    function test_PermissionlessSweepSendsOnlyToBuilders() public {
        imd.mint(address(hook), 42);
        vm.deal(address(hook), 1 ether);
        uint256 before = B.balance;
        vm.prank(ALICE);
        hook.sweep(address(0));
        eq(B.balance - before, 1 ether);
        vm.prank(ALICE);
        hook.sweep(address(imd));
        eq(imd.balanceOf(B), 42);
        eq(imd.balanceOf(address(hook)), 0);
    }
}

contract WorkHookIMDFirstTest is HookBehaviorTests {
    function setUp() public {
        _setupHook(true);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_FeesAllDirectionsAndSplit(
        uint256 amount,
        uint16 fee,
        uint16 share,
        uint8 mode,
        bool ended,
        bool staked
    ) public override {
        super.testFuzz_FeesAllDirectionsAndSplit(amount, fee, share, mode, ended, staked);
    }
}

contract WorkHookIMDSecondTest is HookBehaviorTests {
    function setUp() public {
        _setupHook(false);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_FeesAllDirectionsAndSplit(
        uint256 amount,
        uint16 fee,
        uint16 share,
        uint8 mode,
        bool ended,
        bool staked
    ) public override {
        super.testFuzz_FeesAllDirectionsAndSplit(amount, fee, share, mode, ended, staked);
    }
}

contract WorkHookInitializationTest is HookFixture {
    function setUp() public {
        _setupHook(true);
    }

    function test_NewHookRejectsWrongPoolAndInitializerBeforeBinding() public {
        WorkHook fresh = _deployHook(manager, IWorkers(address(workers)));
        PoolKey memory candidate = key;
        candidate.hooks = address(fresh);
        SwapParams memory p = _params(0, 10);
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeSwap(ALICE, candidate, p, "");
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.afterInitialize(address(this), candidate, 1, 0);
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), candidate, 1);
        workers.bind(address(fresh));
        vm.prank(address(manager), ALICE);
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeInitialize(ALICE, candidate, 1);
        candidate.fee = 10000;
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), candidate, 1);
        candidate.fee = 12500;
        candidate.currency0 = Currency.wrap(address(123));
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), candidate, 1);
        candidate = key;
        candidate.hooks = address(fresh);
        candidate.tickSpacing = 1;
        vm.prank(address(manager));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), candidate, 1);
        candidate.tickSpacing = 60;
        vm.prank(address(manager));
        fresh.beforeInitialize(address(this), candidate, 1);
        vm.prank(address(manager));
        fresh.afterInitialize(address(this), candidate, 1, 0);
        require(fresh.initialized());
    }
}

contract HookSequenceHandler is WorkTestBase {
    WorkHook public hook;
    HookWorkersStandIn public workers;
    TestPoolManager public manager;
    TestIMD public imd;
    PoolKey private key;
    uint256 public totalFees;
    uint256 public stakerFees;
    uint256 public donations;

    constructor(WorkHook h, HookWorkersStandIn w, TestPoolManager m, TestIMD i, PoolKey memory k) {
        hook = h;
        workers = w;
        manager = m;
        imd = i;
        key = k;
    }

    function accept() external {
        hook.acceptOwnership();
    }

    function settings(uint16 fee, uint16 share) external {
        hook.setFeeBps(uint16(bounded(fee, 0, 875)));
        hook.setStakerShareBps(uint16(bounded(share, 9000, 10000)));
    }

    function phase(bool end, bool stake) external {
        workers.phase(workers.mintEnded() || end, stake ? 4 : 0);
    }

    function trade(uint256 amount, uint256 mode) external {
        amount = bounded(amount, 1, 1e20);
        mode %= 4;
        uint256 fee = mode == 3
            ? (amount * hook.feeBps() + 9999 - hook.feeBps()) / (10000 - hook.feeBps())
            : amount * hook.feeBps() / 10000;
        uint256 stakers = workers.mintEnded() && workers.totalWeight() > 0 ? fee * hook.stakerShareBps() / 10000 : 0;
        bool buy = mode < 2;
        bool first = hook.imdIs0();
        SwapParams memory p = SwapParams(buy == first, mode == 0 || mode == 2 ? -int256(amount) : int256(amount), 1);
        int128 i = buy ? -int128(int256(amount)) : int128(int256(amount));
        int128 w = -i;
        manager.callbacks(key, p, first ? manager.pack(i, w) : manager.pack(w, i));
        totalFees += fee;
        stakerFees += stakers;
    }

    function advance(uint256 seconds_, int24 nextTick) external {
        vm.warp(vm.getBlockTimestamp() + bounded(seconds_, 0, 2 hours));
        manager.setTick(int24(int256(uint256(uint24(nextTick)) % 200001) - 100000));
    }

    function donateAndSweep(uint256 amount) external {
        amount = bounded(amount, 0, 1e20);
        imd.mint(address(hook), amount);
        donations += amount;
        hook.sweep(address(imd));
    }
}

contract WorkHookInvariantTest is HookFixture {
    HookSequenceHandler private handler;

    function setUp() public {
        _setupHook(true);
        handler = new HookSequenceHandler(hook, workers, manager, imd, key);
        hook.transferOwnership(address(handler));
        handler.accept();
    }

    function targetContracts() public view returns (address[] memory result) {
        result = new address[](1);
        result[0] = address(handler);
    }

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory list) {
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.settings.selector;
        selectors[1] = handler.phase.selector;
        selectors[2] = handler.trade.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.donateAndSweep.selector;
        list = new FuzzSelector[](1);
        list[0] = FuzzSelector(address(handler), selectors);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_FeeConservationAndNoRetainedDebt() public view {
        eq(imd.balanceOf(address(hook)), 0);
        eq(imd.balanceOf(address(manager)) + handler.totalFees(), MANAGER_FUNDS);
        eq(imd.balanceOf(address(workers)), handler.stakerFees());
        eq(workers.notified(), handler.stakerFees());
        eq(imd.balanceOf(B) + handler.stakerFees(), handler.totalFees() + handler.donations());
        eq(manager.taken(), handler.totalFees());
        require(hook.feeBps() <= 875 && hook.stakerShareBps() >= 9000 && hook.stakerShareBps() <= 10000);
    }
}

// Full WorkersNFT <-> WorkHook path, including reward credit during a guarded
// buyback. Only the manager/IMD are stand-ins; neither production contract is mocked.
contract WorkHookWorkersIntegrationTest is WorkerFixture, HookDeployment {
    WorkHook private realHook;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1000000);
        vm.roll(1000);
        work = new Work();
        imd = new TestIMD(6);
        manager = new TestPoolManager();
        nft = new WorkersNFT(address(this), address(work), address(imd), manager, 60);
        realHook = _deployHook(manager, IWorkers(address(nft)));
        nft.setHook(address(realHook));
        work.distributeLaunch(ALICE, address(manager));
        vm.startPrank(B);
        work.approve(address(nft), 150_000_000 ether);
        nft.fundPools();
        vm.stopPrank();
        imd.mint(ALICE, 1e12);
        imd.mint(BOB, 1e12);
        imd.mint(address(manager), 1e12);
        vm.prank(ALICE);
        imd.approve(address(nft), type(uint256).max);
        vm.prank(BOB);
        imd.approve(address(nft), type(uint256).max);
        nft.setFloorAdjustment(-2);
        vm.warp(vm.getBlockTimestamp() + 600);
        PoolKey memory k = nft.poolKey();
        vm.prank(address(manager));
        realHook.beforeInitialize(address(this), k, uint160(1 << 96));
        vm.prank(address(manager));
        realHook.afterInitialize(address(this), k, uint160(1 << 96), 0);
        manager.useHook(true);
    }

    function test_HookRewardsCanBeClaimedAndBuybackSettlesDuringReentrancyGuard() public {
        uint256 a = _mint(ALICE);
        vm.prank(ALICE);
        nft.stake(a, 7);
        _mint(BOB);
        nft.endMint();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        uint256 reserveBefore = nft.stakerReserve();
        uint256 buybackBefore = nft.buybackBalance();
        uint256 supply = work.totalSupply();
        vm.prank(BOB);
        eq(nft.buyback(), 1 ether);
        uint256 hookFee = buybackBefore * 75 / 10000;
        eq(nft.stakerReserve(), reserveBefore + hookFee);
        eq(nft.buybackBalance(), 0);
        eq(imd.balanceOf(address(nft)), nft.stakerReserve());
        eq(work.totalSupply(), supply - 1 ether);
        vm.prank(ALICE);
        eq(nft.claimIMD(), reserveBefore + hookFee);
        eq(imd.balanceOf(address(nft)), 0);
        eq(work.balanceOf(address(nft)), 150_000_000 ether);
    }
}

contract WorkHookAutoBindTest is WorkerFixture, HookDeployment {
    function test_PoolInitializationBindsTheHookWithoutAnOwnerCall() public {
        vm.chainId(31337);
        vm.warp(1000000);
        vm.roll(1000);
        work = new Work();
        imd = new TestIMD(6);
        manager = new TestPoolManager();
        nft = new WorkersNFT(address(this), address(work), address(imd), manager, 60);
        WorkHook h = _deployHook(manager, IWorkers(address(nft)));
        require(nft.hook() == address(0), "not bound before pool init");
        PoolKey memory k = nft.poolKey();
        k.hooks = address(h);
        // a stranger's transaction cannot initialize the pool or bind the hook
        vm.prank(address(manager), address(0xBAD));
        vm.expectRevert(WorkHook.InvalidPool.selector);
        h.beforeInitialize(address(0xBAD), k, uint160(1 << 96));
        require(nft.hook() == address(0), "stranger did not bind");
        // the deploying account's pool initialization binds it in the same call
        vm.prank(address(manager));
        h.beforeInitialize(address(this), k, uint160(1 << 96));
        require(nft.hook() == address(h), "bound by pool init");
        vm.prank(address(manager));
        h.afterInitialize(address(this), k, uint160(1 << 96), 0);
        require(h.initialized());
    }
}
