// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WorkersNFT, WorkerState, WorkerSale} from "src/WorkersNFT.sol";
import {
    Work,
    WorkHook,
    WorkOwned,
    WorkTransfer,
    IWorkers,
    IPoolManager,
    IERC20Work,
    Currency,
    PoolKey,
    SwapParams,
    BalanceDelta,
    BeforeSwapDelta
} from "src/WorkHook.sol";

// Review scope: authorization, payment rollback, reentrancy, escrow, reward
// conservation, irreversible mint end, and sweep protection. Live Robinhood IMD,
// ArbSys and v4 fork checks remain owed; all external integrations here are offline.
// No external test dependency: this repository deliberately has no lib/ or remappings.
interface WorkTestVm {
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function getBlockNumber() external view returns (uint256);
    function roll(uint256) external;
    function chainId(uint256) external;
    function setBlockhash(uint256, bytes32) external;
    function prank(address) external;
    function prank(address, address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectEmit(bool, bool, bool, bool, address) external;
    function deal(address, uint256) external;
    function etch(address, bytes calldata) external;
    function mockCall(address, bytes calldata, bytes calldata) external;
    function toString(uint256) external pure returns (string memory);
}

abstract contract WorkTestBase {
    WorkTestVm internal constant vm = WorkTestVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant B = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    address internal constant ALICE = address(0xa11ce);
    address internal constant BOB = address(0xb0b);
    address internal constant CAROL = address(0xca401);

    function eq(uint256 a, uint256 b) internal pure {
        require(a == b, "uint mismatch");
    }

    function eq(address a, address b) internal pure {
        require(a == b, "address mismatch");
    }

    function eq(bytes32 a, bytes32 b) internal pure {
        require(a == b, "bytes mismatch");
    }

    function bounded(uint256 x, uint256 low, uint256 high) internal pure returns (uint256) {
        return low + x % (high - low + 1);
    }

    function one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }
}

// Offline IMD stand-in: decimal scaling, failed/optional return data, tax, permit and
// callback behavior are exercised explicitly. It does not claim to model live IMD.
contract TestIMD {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public tax;
    bool public fail;
    bool public noReturn;
    bool public permitSupported;
    address public callback;
    bytes public callbackData;
    bool public callbackSucceeded;

    constructor(uint8 d) {
        decimals = d;
    }

    function mint(address to, uint256 n) external {
        balanceOf[to] += n;
    }

    function configure(uint256 t, bool f, bool nr) external {
        tax = t;
        fail = f;
        noReturn = nr;
    }

    function setCallback(address to, bytes calldata data) external {
        callback = to;
        callbackData = data;
    }

    function setPermit(bool enabled) external {
        permitSupported = enabled;
    }

    function approve(address to, uint256 n) external returns (bool) {
        allowance[msg.sender][to] = n;
        return true;
    }

    function permit(address from, address to, uint256 n, uint256 deadline, uint8, bytes32, bytes32) external {
        require(permitSupported && block.timestamp <= deadline, "permit unavailable");
        allowance[from][to] = n;
    }

    function transfer(address to, uint256 n) external returns (bool) {
        return _transfer(msg.sender, to, n);
    }

    function transferFrom(address from, address to, uint256 n) external returns (bool) {
        if (fail) return false;
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= n;
        if (callback != address(0)) (callbackSucceeded,) = callback.call(callbackData);
        return _transfer(from, to, n);
    }

    function _transfer(address from, address to, uint256 n) private returns (bool) {
        if (fail) return false;
        balanceOf[from] -= n;
        balanceOf[to] += n - n * tax / 10000;
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}

interface TestUnlock {
    function unlockCallback(bytes calldata) external returns (bytes memory);
}

// Canonical delta packing and callback fee accounting, with real token transfers.
// This is a deterministic settlement stand-in, not an AMM price/liquidity simulator.
contract TestPoolManager is IPoolManager {
    uint256 public output = 1 ether;
    uint256 public inputShortfall;
    uint256 public settlementShortfall;
    bool public shortTake;
    bool public locked = true;
    int24 public tick;
    address private synced;
    uint256 private beforeSync;
    uint256 public taken;
    bool public callHook;

    function configure(uint256 out, uint256 partialFill, uint256 settleShort, bool takeShort) external {
        output = out;
        inputShortfall = partialFill;
        settlementShortfall = settleShort;
        shortTake = takeShort;
    }

    function useHook(bool enabled) external {
        callHook = enabled;
    }

    function setTick(int24 value) external {
        tick = value;
    }

    function pack(int128 a, int128 b) public pure returns (BalanceDelta) {
        return BalanceDelta.wrap((int256(a) << 128) | int256(uint256(uint128(b))));
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locked, "already unlocked");
        locked = false;
        result = TestUnlock(msg.sender).unlockCallback(data);
        locked = true;
    }

    function swap(PoolKey calldata key, SwapParams calldata p, bytes calldata) external returns (BalanceDelta) {
        require(!locked && p.amountSpecified < 0, "invalid context");
        int128 input = int128(p.amountSpecified + int256(inputShortfall));
        BalanceDelta raw = p.zeroForOne ? pack(input, int128(int256(output))) : pack(int128(int256(output)), input);
        if (!callHook) return raw;
        return _callbacks(key, p, raw);
    }

    function callbacks(PoolKey calldata key, SwapParams calldata p, BalanceDelta raw) external returns (BalanceDelta) {
        return _callbacks(key, p, raw);
    }

    function _callbacks(PoolKey calldata key, SwapParams calldata p, BalanceDelta raw) private returns (BalanceDelta) {
        uint256 start = taken;
        (, BeforeSwapDelta beforeDelta,) = WorkHook(payable(key.hooks)).beforeSwap(msg.sender, key, p, "");
        int128 specified = int128(BeforeSwapDelta.unwrap(beforeDelta) >> 128);
        require(int128(BeforeSwapDelta.unwrap(beforeDelta)) == 0, "unexpected unspecified before delta");
        bool specified0 = (p.amountSpecified < 0) == p.zeroForOne;
        int128 a = int128(BalanceDelta.unwrap(raw) >> 128);
        int128 b = int128(BalanceDelta.unwrap(raw));
        // With an exact-input IMD fee the AMM receives input minus beforeSwap's fee.
        if (specified0) a += specified;
        else b += specified;
        (, int128 afterDelta) = WorkHook(payable(key.hooks)).afterSwap(msg.sender, key, p, pack(a, b), "");
        require(taken - start == uint256(int256(specified) + int256(afterDelta)), "unsettled hook debt");
        if (specified0) {
            a -= specified;
            b -= afterDelta;
        } else {
            b -= specified;
            a -= afterDelta;
        }
        return pack(a, b);
    }

    function take(Currency c, address to, uint256 amount) external {
        taken += amount;
        require(IERC20Work(Currency.unwrap(c)).transfer(to, shortTake && amount != 0 ? amount - 1 : amount));
    }

    function sync(Currency c) external {
        synced = Currency.unwrap(c);
        beforeSync = IERC20Work(synced).balanceOf(address(this));
    }

    function settle() external payable returns (uint256) {
        return IERC20Work(synced).balanceOf(address(this)) - beforeSync - settlementShortfall;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(uint24(tick)) << 160);
    }
}

contract TestHookBinding {
    IWorkers public workers;
    IPoolManager public poolManager;
    uint256 public minimum = 1;

    constructor(WorkersNFT nft, IPoolManager manager) {
        workers = IWorkers(address(nft));
        poolManager = manager;
    }

    function setMinimum(uint256 n) external {
        minimum = n;
    }

    function minimumBuybackOutput(uint256) external view returns (uint256) {
        return minimum;
    }

    function reward(uint256 n) external {
        workers.notifyHookReward(n);
    }
}

abstract contract WorkerFixture is WorkTestBase {
    Work internal work;
    TestIMD internal imd;
    WorkersNFT internal nft;
    TestPoolManager internal manager;
    TestHookBinding internal binding;
    event Transfer(address indexed from, address indexed to, uint256 indexed id);
    event MetadataUpdate(uint256 id);
    event BatchMetadataUpdate(uint256 from, uint256 to);
    event CapChanged(uint256 oldCap, uint256 newCap);
    event MintPayment(uint256 stakers, uint256 buyback, uint256 builders);
    event FloorChanged(int8 oldValue, int8 newValue);
    event PriceScaleChanged(uint16 oldValue, uint16 newValue);
    event ActivationFeeChanged(uint256 oldValue, uint256 newValue);
    event RoyaltyChanged(uint16 oldValue, uint16 newValue);
    event Paused(uint256 until);
    event Unpaused();

    function _setup() internal {
        vm.chainId(31337);
        vm.warp(1000000);
        vm.roll(1000);
        work = new Work();
        imd = new TestIMD(6);
        manager = new TestPoolManager();
        nft = new WorkersNFT(address(this), address(work), address(imd), manager, 60);
        binding = new TestHookBinding(nft, manager);
        nft.setHook(address(binding));
        work.distributeLaunch(ALICE, address(manager));
        vm.startPrank(B);
        work.approve(address(nft), 150_000_000 ether);
        nft.fundPools();
        vm.stopPrank();
        imd.mint(ALICE, 1e12);
        imd.mint(BOB, 1e12);
        imd.mint(CAROL, 1e12);
        vm.prank(ALICE);
        imd.approve(address(nft), type(uint256).max);
        vm.prank(BOB);
        imd.approve(address(nft), type(uint256).max);
        vm.prank(CAROL);
        imd.approve(address(nft), type(uint256).max);
        nft.setFloorAdjustment(-2);
        vm.warp(vm.getBlockTimestamp() + 600);
    }

    function _anchor() internal returns (uint256 anchor) {
        vm.roll(vm.getBlockNumber() + 1);
        anchor = vm.getBlockNumber() - 1;
        vm.setBlockhash(anchor, keccak256(abi.encode("offline block", anchor)));
    }

    function _solve(address who, uint256 anchor, uint256 salt, bool oc)
        internal
        view
        returns (uint256 nonce, bytes32 hash)
    {
        bytes32 challenge = keccak256(abi.encode(nft.anchorHash(anchor), nft.prevWork()));
        uint256 target = nft.currentTarget();
        bytes memory payload =
            abi.encode(keccak256("WorkersNFT.Work.v1"), block.chainid, address(nft), challenge, who, uint256(0));
        nonce = salt;
        while (true) {
            assembly ("memory-safe") {
                mstore(add(payload, 192), nonce)
                hash := keccak256(add(payload, 32), 192)
            }
            if (uint256(hash) < target && (!oc || uint256(hash) < target >> 4)) return (nonce, hash);
            unchecked {
                ++nonce;
            }
        }
    }

    function _mint(address who) internal returns (uint256 id) {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(who, anchor, 0, false);
        vm.prank(who);
        id = nft.mint(anchor, nonce);
    }

    function _endWithTwo() internal returns (uint256 a, uint256 b) {
        a = _mint(ALICE);
        b = _mint(BOB);
        nft.endMint();
    }

    function _activate(address who, uint256 id) internal {
        vm.prank(who);
        nft.activate(id);
    }
}

contract WorkersNFTTest is WorkerFixture {
    function setUp() public {
        _setup();
    }

    function test_LaunchFundingAndNoSecondDeposit() public {
        eq(work.balanceOf(B), 50_000_000 ether);
        eq(work.balanceOf(address(nft)), 150_000_000 ether);
        eq(work.totalSupply(), 1_000_000_000 ether);
        require(keccak256(bytes(work.name())) == keccak256("Work"));
        require(keccak256(bytes(work.symbol())) == keccak256("WORK"));
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.fundPools();
        vm.prank(B);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.fundPools();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setHook(address(binding));
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_WorkHashAndInvalidProof(uint256 nonce, uint256 age, address miner) public {
        age = bounded(age, 1, 250);
        uint256 anchor = vm.getBlockNumber() - age;
        bytes32 bh = keccak256(abi.encode(anchor, nonce));
        if (bh == bytes32(0)) bh = bytes32(uint256(1));
        vm.setBlockhash(anchor, bh);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("WorkersNFT.Work.v1"),
                block.chainid,
                address(nft),
                keccak256(abi.encode(bh, bytes32(0))),
                miner,
                nonce
            )
        );
        eq(nft.workHash(anchor, miner, nonce), expected);
        // Arbitrary proofs fail without charging IMD; valid proofs are tested below.
        if (uint256(expected) >= nft.currentTarget()) {
            vm.prank(miner);
            vm.expectRevert(WorkersNFT.InvalidWork.selector);
            nft.mint(anchor, nonce);
            eq(nft.minted(), 0);
            eq(nft.buybackBalance(), 0);
        }
    }

    function test_AnchorAgeAndChainDomain() public {
        vm.setBlockhash(vm.getBlockNumber() - 250, bytes32(uint256(7)));
        eq(nft.anchorHash(vm.getBlockNumber() - 250), bytes32(uint256(7)));
        vm.expectRevert(WorkersNFT.InvalidWork.selector);
        nft.anchorHash(vm.getBlockNumber() - 251);
        vm.expectRevert(WorkersNFT.InvalidWork.selector);
        nft.anchorHash(vm.getBlockNumber());
        vm.expectRevert(WorkersNFT.InvalidWork.selector);
        nft.anchorHash(vm.getBlockNumber() + 1);
        vm.setBlockhash(vm.getBlockNumber() - 1, bytes32(0));
        vm.expectRevert(WorkersNFT.InvalidWork.selector);
        nft.anchorHash(vm.getBlockNumber() - 1);
        bytes32 beforeHash = nft.workHash(vm.getBlockNumber() - 250, ALICE, 17);
        vm.chainId(1);
        require(beforeHash != nft.workHash(vm.getBlockNumber() - 250, ALICE, 17));
    }

    function test_RobinhoodUsesLocalArbBlocksAndPinnedIMD() public {
        vm.chainId(4663);
        address fixedIMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
        vm.etch(fixedIMD, address(imd).code);
        WorkersNFT rh = new WorkersNFT(address(this), address(work), fixedIMD, manager, 60);
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(90000)));
        vm.mockCall(
            address(100),
            abi.encodeWithSignature("arbBlockHash(uint256)", uint256(89999)),
            abi.encode(bytes32(uint256(88)))
        );
        eq(rh.workBlockNumber(), 90000);
        eq(rh.anchorHash(89999), bytes32(uint256(88)));
        vm.expectRevert(WorkersNFT.InvalidWork.selector);
        rh.anchorHash(89749);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        new WorkersNFT(address(this), address(work), address(imd), manager, 60);
        TestHookBinding rhBinding = new TestHookBinding(rh, manager);
        rh.setHook(address(rhBinding));
        vm.prank(ALICE);
        work.transfer(B, 100_000_000 ether);
        vm.startPrank(B);
        work.approve(address(rh), 150_000_000 ether);
        rh.fundPools();
        vm.stopPrank();
        TestIMD(fixedIMD).mint(ALICE, 1e9);
        vm.prank(ALICE);
        TestIMD(fixedIMD).approve(address(rh), type(uint256).max);
        rh.setFloorAdjustment(-2);
        vm.warp(vm.getBlockTimestamp() + 600);
        nft = rh;
        (uint256 nonce,) = _solve(ALICE, 89999, 0, false);
        vm.prank(ALICE);
        rh.mint(89999, nonce);
        vm.roll(vm.getBlockNumber() + 1); // Parent/L1 progress must not bypass the L2 block limit.
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.MintUnavailable.selector);
        rh.mint(89999, nonce);
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(90001)));
        // Another L2 mint is allowed while the parent block remains unchanged.
        (nonce,) = _solve(ALICE, 89999, 0, false);
        vm.prank(ALICE);
        rh.mint(89999, nonce);
        eq(rh.minted(), 2);
    }

    function test_MintSelectsIdChargesAndPreventsReplay() public {
        uint256 anchor = _anchor();
        (uint256 nonce, bytes32 hash) = _solve(ALICE, anchor, 0, false);
        uint256 expectedId = uint256(hash) % 3333 + 1;
        uint256 balance = imd.balanceOf(ALICE);
        vm.expectEmit(false, false, false, true, address(nft));
        emit MintPayment(0, 225000, 25000);
        vm.prank(ALICE);
        uint256 id = nft.mint(anchor, nonce);
        eq(id, expectedId);
        eq(nft.ownerOf(id), ALICE);
        eq(nft.prevWork(), hash);
        eq(balance - imd.balanceOf(ALICE), 250000);
        eq(imd.balanceOf(B), 25000);
        eq(nft.buybackBalance(), 225000);
        eq(nft.remaining(), 3332);
        eq(nft.poolAt(uint256(hash) % 3333), 3333);
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.MintUnavailable.selector);
        nft.mint(anchor, nonce);
        _anchor();
        require(nft.workHash(anchor, ALICE, nonce) != hash, "previous work did not chain");
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.poolAt(3332);
    }

    function test_PoWCannotBeCopiedByAnotherWallet() public {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(ALICE, anchor, 0, false);
        while (uint256(nft.workHash(anchor, BOB, nonce)) < nft.currentTarget()) {
            (nonce,) = _solve(ALICE, anchor, nonce + 1, false);
        }
        vm.prank(BOB);
        vm.expectRevert(WorkersNFT.InvalidWork.selector);
        nft.mint(anchor, nonce);
        vm.prank(ALICE);
        nft.mint(anchor, nonce);
    }

    function test_OverclockedURIAndMetadataEvents() public {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(ALICE, anchor, 0, true);
        vm.prank(ALICE);
        uint256 id = nft.mint(anchor, nonce);
        require(nft.overclocked(id));
        require(
            keccak256(bytes(nft.tokenURI(id)))
                == keccak256(bytes(string.concat(nft.baseURI(), "oc/", vm.toString(id), ".json")))
        );
        require(nft.supportsInterface(0x49064906) && nft.supportsInterface(0x2a55205a));
        require(!nft.supportsInterface(0xffffffff));
        vm.expectEmit(false, false, false, true, address(nft));
        emit BatchMetadataUpdate(1, 3333);
        nft.setBaseURI("ipfs://replacement/");
        require(
            keccak256(bytes(nft.tokenURI(id)))
                == keccak256(bytes(string.concat("ipfs://replacement/oc/", vm.toString(id), ".json")))
        );
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setBaseURI(string(new bytes(513)));
        vm.expectRevert(WorkersNFT.InvalidToken.selector);
        nft.tokenURI(0);
    }

    function test_MintFailuresRollBackIdAndPayment() public {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(ALICE, anchor, 0, false);
        imd.configure(100, false, false);
        vm.prank(ALICE);
        vm.expectRevert(WorkTransfer.TokenTransferFailed.selector);
        nft.mint(anchor, nonce);
        eq(nft.minted(), 0);
        eq(nft.remaining(), 3333);
        eq(nft.prevWork(), bytes32(0));
        eq(imd.balanceOf(B), 0);
        imd.configure(0, true, false);
        vm.prank(ALICE);
        vm.expectRevert(WorkTransfer.TokenTransferFailed.selector);
        nft.mint(anchor, nonce);
        imd.configure(0, false, false);
        vm.prank(ALICE);
        imd.approve(address(nft), 0);
        vm.prank(ALICE);
        vm.expectRevert(WorkTransfer.TokenTransferFailed.selector);
        nft.mint(anchor, nonce);
        eq(nft.minted(), 0);
    }

    function test_OptionalReturnsPermitFallbackAndReentrantPayment() public {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(ALICE, anchor, 0, false);
        imd.configure(0, false, true);
        imd.setCallback(address(nft), abi.encodeCall(nft.mint, (anchor, nonce)));
        vm.prank(ALICE);
        nft.mintWithPermit(anchor, nonce, vm.getBlockTimestamp(), 0, bytes32(0), bytes32(0));
        require(!imd.callbackSucceeded());
        eq(nft.minted(), 1);
        imd.configure(0, false, false);
        imd.setCallback(address(0), "");
        imd.setPermit(true);
        vm.prank(BOB);
        imd.approve(address(nft), 0);
        anchor = _anchor();
        (nonce,) = _solve(BOB, anchor, 0, false);
        vm.prank(BOB);
        nft.mintWithPermit(anchor, nonce, vm.getBlockTimestamp(), 0, bytes32(0), bytes32(0));
        eq(nft.minted(), 2);
        eq(imd.allowance(BOB, address(nft)), 0);
    }

    function test_CapOnlyLowersAndMintEndIsPermanent() public {
        _mint(ALICE);
        vm.expectEmit(false, false, false, true, address(nft));
        emit CapChanged(3333, 2);
        nft.setCap(2);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setCap(3);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setCap(0);
        _mint(BOB);
        require(nft.mintEnded());
        eq(nft.mintedAtEnd(), 2);
        eq(nft.burnReward(), 25_000_000 ether);
        eq(nft.cap(), 2);
        vm.expectRevert(WorkersNFT.MintUnavailable.selector);
        nft.endMint();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setCap(3333);
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.MintUnavailable.selector);
        nft.mint(vm.getBlockNumber() - 1, 0);
    }

    function test_EndMintAndZeroMintBoundary() public {
        nft.endMint();
        require(nft.mintEnded());
        eq(nft.cap(), 0);
        eq(nft.burnReward(), 0);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setCap(1);
    }

    function test_AllAdministrativePathsRejectStrangers() public {
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeCall(nft.setCap, (1));
        calls[1] = abi.encodeCall(nft.endMint, ());
        calls[2] = abi.encodeCall(nft.pause, ());
        calls[3] = abi.encodeCall(nft.unpause, ());
        calls[4] = abi.encodeCall(nft.setFloorAdjustment, (0));
        calls[5] = abi.encodeCall(nft.setPriceScaleBps, (5000));
        calls[6] = abi.encodeCall(nft.setActivationFee, (0));
        calls[7] = abi.encodeCall(nft.setRoyaltyBps, (0));
        calls[8] = abi.encodeCall(nft.setBaseURI, ("other"));
        calls[9] = abi.encodeCall(nft.setHook, (address(binding)));
        calls[10] = abi.encodeCall(nft.transferOwnership, (BOB));
        calls[11] = abi.encodeCall(nft.acceptOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(ALICE);
            (bool ok, bytes memory result) = address(nft).call(calls[i]);
            require(!ok && bytes4(result) == WorkOwned.Unauthorized.selector, "unprotected administration");
        }
    }

    function test_OwnerBoundsAndEvents() public {
        vm.expectEmit(false, false, false, true, address(nft));
        emit FloorChanged(-2, 2);
        nft.setFloorAdjustment(2);
        eq(nft.floorBits(), 14);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setFloorAdjustment(3);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setFloorAdjustment(-3);
        vm.expectEmit(false, false, false, true, address(nft));
        emit PriceScaleChanged(10000, 5000);
        nft.setPriceScaleBps(5000);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setPriceScaleBps(4999);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setPriceScaleBps(10001);
        vm.expectEmit(false, false, false, true, address(nft));
        emit ActivationFeeChanged(150000, 500000);
        nft.setActivationFee(500000);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setActivationFee(500001);
        vm.expectEmit(false, false, false, true, address(nft));
        emit RoyaltyChanged(500, 1000);
        nft.setRoyaltyBps(1000);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.setRoyaltyBps(1001);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.transferOwnership(address(0));
        nft.transferOwnership(BOB);
        eq(nft.owner(), address(this));
        vm.prank(BOB);
        nft.acceptOwnership();
        eq(nft.owner(), BOB);
        eq(nft.pendingOwner(), address(0));
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.pause();
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_PricesAndRoyalty(uint16 scale, uint256 salePrice) public {
        scale = uint16(bounded(scale, 5000, 10000));
        nft.setPriceScaleBps(scale);
        uint256[9] memory cents = [uint256(25), 50, 75, 125, 175, 250, 325, 400, 500];
        for (uint256 e; e < 9; ++e) {
            eq(nft.epochPrice(e), cents[e] * scale);
            require(nft.epochPrice(e) <= 5e6);
        }
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.epochPrice(9);
        (address receiver, uint256 royalty) = nft.royaltyInfo(0, salePrice);
        eq(receiver, B);
        eq(royalty, salePrice / 20);
    }

    function test_PauseExpiresExactlyAt24HoursWithCooldown() public {
        uint256 anchor = _anchor();
        (uint256 nonce,) = _solve(ALICE, anchor, 0, false);
        uint256 resume = vm.getBlockTimestamp() + 24 hours;
        vm.expectEmit(false, false, false, true, address(nft));
        emit Paused(resume);
        nft.pause();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.pause();
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.MintUnavailable.selector);
        nft.mint(anchor, nonce);
        vm.warp(resume - 1);
        require(nft.paused());
        vm.warp(resume);
        require(!nft.paused());
        vm.prank(ALICE);
        nft.mint(anchor, nonce);
        // a new pause needs 24h unpaused after the last one ended
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.pause();
        vm.warp(resume + 24 hours);
        nft.pause();
        vm.expectEmit(false, false, false, true, address(nft));
        emit Unpaused();
        nft.unpause();
        require(!nft.paused());
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.unpause();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.pause();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        nft.pause();
        require(nft.paused());
    }

    function test_StakingEscrowLocksTransfersAndEmitsOwnership() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        nft.approve(BOB, id);
        vm.expectEmit(true, true, true, true, address(nft));
        emit Transfer(ALICE, address(nft), id);
        vm.prank(ALICE);
        nft.stake(id, 7);
        eq(nft.ownerOf(id), address(nft));
        eq(nft.beneficiaryOf(id), ALICE);
        eq(nft.getApproved(id), address(0));
        eq(nft.totalWeight(), 1);
        eq(nft.balanceOf(address(nft)), 1);
        vm.prank(BOB);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.transferFrom(address(nft), BOB, id);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.transferFrom(address(nft), BOB, id);
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.Locked.selector);
        nft.unstake(id);
        vm.prank(BOB);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.unstake(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectEmit(true, true, true, true, address(nft));
        emit Transfer(address(nft), ALICE, id);
        vm.prank(ALICE);
        nft.unstake(id);
        eq(nft.totalWeight(), 0);
        eq(nft.ownerOf(id), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.unstake(id);
    }

    function test_StakeFailurePathsAndNormalMarketplaceTransfer() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.stake(id, 8);
        vm.prank(BOB);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.stake(id, 7);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.transferFrom(ALICE, address(nft), id);
        vm.prank(ALICE);
        nft.setApprovalForAll(BOB, true);
        vm.prank(BOB);
        nft.transferFrom(ALICE, CAROL, id);
        eq(nft.ownerOf(id), CAROL);
        vm.prank(CAROL);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.transferFrom(CAROL, address(0), id);
        vm.prank(CAROL);
        vm.expectRevert();
        nft.safeTransferFrom(CAROL, address(manager), id);
        eq(nft.ownerOf(id), CAROL);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_MintSplitsAndWeightedHookRewards(uint256 reward) public {
        reward = bounded(reward, 1, 1e18);
        uint256 a = _mint(ALICE);
        vm.prank(ALICE);
        nft.stake(a, 7);
        uint256 b = _mint(BOB);
        vm.prank(BOB);
        nft.stake(b, 30);
        eq(nft.pendingIMD(ALICE), 162500);
        eq(nft.pendingIMD(BOB), 0);
        _mint(CAROL);
        eq(nft.pendingIMD(ALICE), 195000);
        eq(nft.pendingIMD(BOB), 130000);
        eq(nft.buybackBalance(), 350000);
        eq(imd.balanceOf(B), 75000);
        nft.endMint();
        imd.mint(address(nft), reward);
        binding.reward(reward);
        uint256 beforeA = imd.balanceOf(ALICE);
        uint256 beforeB = imd.balanceOf(BOB);
        vm.prank(ALICE);
        uint256 paidA = nft.claimIMD();
        vm.prank(BOB);
        uint256 paidB = nft.claimIMD();
        eq(paidA, 195000 + reward / 5);
        eq(paidB, 130000 + reward * 4 / 5);
        eq(imd.balanceOf(ALICE) - beforeA, paidA);
        eq(imd.balanceOf(BOB) - beforeB, paidB);
        require(nft.stakerReserve() <= 2);
        eq(imd.balanceOf(address(nft)), nft.stakerReserve() + nft.buybackBalance());
        vm.prank(ALICE);
        eq(nft.claimIMD(), 0);
    }

    function test_HookRewardCannotBeForgedOrDoubleCredited() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        nft.stake(id, 14);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        binding.reward(10);
        nft.endMint();
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.notifyHookReward(10);
        vm.expectRevert(WorkersNFT.Insolvent.selector);
        binding.reward(10);
        imd.mint(address(nft), 10);
        binding.reward(10);
        vm.expectRevert(WorkersNFT.Insolvent.selector);
        binding.reward(10);
    }

    function test_ActivationFeesAndRewardsTravelWithToken() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.activate(id);
        nft.endMint();
        vm.prank(BOB);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.activate(id);
        uint256 builders = imd.balanceOf(B);
        vm.expectEmit(false, false, false, true, address(nft));
        emit MetadataUpdate(id);
        _activate(ALICE, id);
        eq(imd.balanceOf(B) - builders, 150000);
        eq(nft.ownerOf(id), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.activate(id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 pending = nft.pendingWork(id);
        eq(pending, 12_500_000 ether);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        require(nft.activated(id));
        eq(nft.pendingWork(id), pending);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.claimWork(one(id));
        vm.prank(BOB);
        eq(nft.claimWork(one(id)), pending);
        eq(work.balanceOf(BOB), pending);
        vm.prank(BOB);
        eq(nft.claimWork(one(id)), 0);
    }

    function test_StakerCanActivateAndClaimButNotBurn() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        nft.stake(id, 30);
        nft.endMint();
        _activate(ALICE, id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 expected = uint256(12_500_000 ether) / 7;
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), expected);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.burn(id);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_EraScheduleAndAccrual(uint256 era, uint256 within) public {
        era = bounded(era, 0, 7);
        within = bounded(within, 0, (7 days) << era);
        uint256 id = _mint(ALICE);
        nft.endMint();
        _activate(ALICE, id);
        uint256 elapsed = 7 days * ((1 << era) - 1) + within;
        uint256 expected = era * 12_500_000 ether + 12_500_000 ether * within / ((7 days) << era);
        vm.warp(nft.mintEndTime() + elapsed);
        eq(nft.scheduledEmission(vm.getBlockTimestamp()), expected);
        eq(nft.pendingWork(id), expected);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), expected);
        eq(nft.miningPool() + nft.workReserve() + expected, 100_000_000 ether);
    }

    function test_AccrualLateActivationAndBurnChangeDenominator() public {
        (uint256 a, uint256 b) = _endWithTwo();
        _activate(ALICE, a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _activate(BOB, b);
        eq(nft.pendingWork(a), 12_500_000 ether);
        eq(nft.pendingWork(b), 0);
        vm.warp(vm.getBlockTimestamp() + 14 days);
        eq(nft.pendingWork(a), 18_750_000 ether);
        eq(nft.pendingWork(b), 6_250_000 ether);
        vm.prank(BOB);
        nft.burn(b);
        eq(nft.activeWorkers(), 1);
        vm.warp(vm.getBlockTimestamp() + 28 days);
        eq(nft.pendingWork(a), 31_250_000 ether);
    }

    function test_EmissionWithNoActiveWorkersIsCarriedNotLost() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        // the first era passed with nobody activated: it is held, not burned
        _activate(ALICE, id);
        eq(nft.emissionCarry(), 12_500_000 ether);
        vm.warp(nft.mintEndTime() + 1785 days);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 100_000_000 ether);
        eq(nft.miningPool(), 0);
        eq(nft.emissionCarry(), 0);
        vm.warp(vm.getBlockTimestamp() + 10000 days);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 0);
    }

    function test_RemainderAfterFinalEraGoesOnlyToBuilders() public {
        _mint(ALICE);
        nft.endMint();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.releaseMiningRemainder();
        vm.warp(nft.mintEndTime() + 1785 days);
        vm.prank(ALICE);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.releaseMiningRemainder();
        uint256 before = work.balanceOf(nft.BUILDERS());
        nft.releaseMiningRemainder();
        eq(work.balanceOf(nft.BUILDERS()) - before, 100_000_000 ether);
        eq(nft.miningPool(), 0);
        eq(nft.burnPool(), 50_000_000 ether);
    }

    function test_AllEightErasEmptyTheFundedPool() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        _activate(ALICE, id);
        vm.warp(vm.getBlockTimestamp() + 1785 days);
        vm.prank(ALICE);
        eq(nft.claimWork(one(id)), 100_000_000 ether);
        eq(nft.miningPool(), 0);
        eq(nft.workReserve(), 0);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        eq(nft.pendingWork(id), 0);
    }

    function test_PauseHoldsAccrualAndReleasesItAfterwards() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        _activate(ALICE, id);
        uint256 end = nft.mintEndTime();
        vm.warp(end + 1 days);
        nft.pause();
        uint256 earned = nft.pendingWork(id);
        eq(earned, nft.scheduledEmission(end + 1 days));
        vm.warp(end + 1 days + 12 hours);
        // nothing new is paid while paused...
        eq(nft.pendingWork(id), earned);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        vm.prank(BOB);
        eq(nft.claimWork(one(id)), earned);
        // ...and the paused share is released once the pause is over, so nothing is lost
        vm.warp(end + 5 days);
        eq(nft.pendingWork(id), nft.scheduledEmission(end + 5 days) - earned);
        vm.prank(BOB);
        nft.claimWork(one(id));
        eq(nft.emissionCarry(), 0);
    }

    function test_BindHookOnlyFromDeployingAccount() public {
        vm.prank(address(0xBEEF), address(0xBAD));
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.bindHook();
    }

    function test_ClaimDuplicateAndEmptyArraysDoNotDuplicateRewards() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        _activate(ALICE, id);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        vm.prank(ALICE);
        eq(nft.claimWork(ids), 12_500_000 ether);
        vm.prank(ALICE);
        eq(nft.claimWork(new uint256[](0)), 0);
        eq(nft.workReserve(), 0);
    }

    function test_BurnFixedDenominatorAndAccruedWork() public {
        (uint256 a, uint256 b) = _endWithTwo();
        _activate(ALICE, a);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 before = work.balanceOf(ALICE);
        vm.prank(ALICE);
        nft.burn(a);
        eq(work.balanceOf(ALICE) - before, 37_500_000 ether);
        eq(nft.burnReward(), 25_000_000 ether);
        eq(nft.burnPool(), 25_000_000 ether);
        eq(nft.activeWorkers(), 0);
        vm.expectRevert(WorkersNFT.InvalidToken.selector);
        nft.ownerOf(a);
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.InvalidToken.selector);
        nft.burn(a);
        vm.prank(BOB);
        nft.burn(b);
        eq(work.balanceOf(BOB), 25_000_000 ether);
        eq(nft.burnPool(), 0);
        eq(nft.totalSupply(), 0);
        eq(nft.mintedAtEnd(), 2);
    }

    function test_BurnRequiresMintEndAndOwner() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.MintUnavailable.selector);
        nft.burn(id);
        nft.endMint();
        vm.prank(BOB);
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.burn(id);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_SweepOnlySurplus(uint256 extraIMD, uint256 extraWork) public {
        extraIMD = bounded(extraIMD, 0, 1e24);
        extraWork = bounded(extraWork, 0, 1e20);
        uint256 a = _mint(ALICE);
        vm.prank(ALICE);
        nft.stake(a, 7);
        _mint(BOB);
        nft.endMint();
        _activate(ALICE, a);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        nft.claimWork(new uint256[](0));
        uint256 reserveIMD = nft.stakerReserve() + nft.buybackBalance();
        uint256 reserveWork = nft.miningPool() + nft.burnPool() + nft.workReserve();
        imd.mint(address(nft), extraIMD);
        vm.prank(ALICE);
        work.transfer(address(nft), extraWork);
        uint256 imdB = imd.balanceOf(B);
        uint256 workB = work.balanceOf(B);
        vm.prank(CAROL);
        nft.sweep(address(imd));
        vm.prank(CAROL);
        nft.sweep(address(work));
        eq(imd.balanceOf(B) - imdB, extraIMD);
        eq(work.balanceOf(B) - workB, extraWork);
        eq(imd.balanceOf(address(nft)), reserveIMD);
        eq(work.balanceOf(address(nft)), reserveWork);
        nft.sweep(address(imd));
        nft.sweep(address(work));
        eq(imd.balanceOf(address(nft)), reserveIMD);
        eq(work.balanceOf(address(nft)), reserveWork);
    }

    function test_SweepETHAndUnrelatedTokensToBuilders() public {
        vm.deal(address(nft), 3 ether);
        uint256 before = B.balance;
        vm.prank(CAROL);
        nft.sweep(address(0));
        eq(B.balance - before, 3 ether);
        TestIMD other = new TestIMD(18);
        other.mint(address(nft), 50 ether);
        nft.sweep(address(other));
        eq(other.balanceOf(B), 50 ether);
    }

    function test_BuybackBurnsAndPreservesMiningAndBurnPools() public {
        _mint(ALICE);
        uint256 amount = nft.buybackBalance();
        uint256 supply = work.totalSupply();
        vm.prank(CAROL);
        eq(nft.buyback(), 1 ether);
        eq(work.totalSupply(), supply - 1 ether);
        eq(nft.buybackBalance(), 0);
        eq(work.balanceOf(address(nft)), 150_000_000 ether);
        eq(imd.balanceOf(address(manager)), amount);
        _mint(BOB);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.buyback();
        vm.warp(vm.getBlockTimestamp() + 60);
        nft.buyback();
    }

    function test_BuybackFailurePathsAreAtomic() public {
        _mint(ALICE);
        uint256 reserve = nft.buybackBalance();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.buyback(0, 0, vm.getBlockTimestamp());
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.buyback(reserve + 1, 0, vm.getBlockTimestamp());
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.buyback(100e6 + 1, 0, vm.getBlockTimestamp());
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        nft.buyback(1, 0, vm.getBlockTimestamp() - 1);
        vm.expectRevert(WorkersNFT.SwapFailed.selector);
        nft.buyback(reserve, 2 ether, vm.getBlockTimestamp());
        binding.setMinimum(2 ether);
        vm.expectRevert(WorkersNFT.SwapFailed.selector);
        nft.buyback();
        binding.setMinimum(1);
        manager.configure(1 ether, 1, 0, false);
        vm.expectRevert(WorkersNFT.SwapFailed.selector);
        nft.buyback();
        manager.configure(1 ether, 0, 1, false);
        vm.expectRevert(WorkersNFT.SwapFailed.selector);
        nft.buyback();
        manager.configure(1 ether, 0, 0, true);
        vm.expectRevert(WorkersNFT.SwapFailed.selector);
        nft.buyback();
        eq(nft.buybackBalance(), reserve);
        eq(nft.lastBuybackTime(), 0);
        eq(work.balanceOf(address(nft)), 150_000_000 ether);
        vm.prank(address(manager));
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.unlockCallback(abi.encode(1, 1));
        vm.expectRevert(WorkOwned.Unauthorized.selector);
        nft.unlockCallback(abi.encode(1, 1));
    }

    function test_ExactUnstakeBoundaryKeepsEarnedIMD() public {
        uint256 a = _mint(ALICE);
        vm.prank(ALICE);
        nft.stake(a, 14);
        _mint(BOB);
        uint256 pending = nft.pendingIMD(ALICE);
        (, uint64 unlockAt,) = nft.stakes(a);
        vm.warp(unlockAt - 1);
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.Locked.selector);
        nft.unstake(a);
        vm.warp(unlockAt);
        vm.prank(ALICE);
        nft.unstake(a);
        eq(nft.pendingIMD(ALICE), pending);
        eq(nft.totalWeight(), 0);
        vm.prank(ALICE);
        eq(nft.claimIMD(), pending);
        uint256 before = nft.buybackBalance();
        _mint(CAROL);
        eq(nft.buybackBalance() - before, 225000);
        eq(nft.pendingIMD(ALICE), 0);
    }

    function test_ActivationPaymentFailureRollsBackWorkerCount() public {
        uint256 id = _mint(ALICE);
        nft.endMint();
        vm.prank(ALICE);
        imd.approve(address(nft), 0);
        vm.prank(ALICE);
        vm.expectRevert(WorkTransfer.TokenTransferFailed.selector);
        nft.activate(id);
        require(!nft.activated(id));
        eq(nft.activeWorkers(), 0);
        nft.setActivationFee(0);
        _activate(ALICE, id);
        require(nft.activated(id));
        eq(nft.activeWorkers(), 1);
    }

    function test_UnfundedAndUnboundDeploymentCannotMint() public {
        WorkersNFT fresh = new WorkersNFT(address(this), address(work), address(imd), manager, 60);
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.MintUnavailable.selector);
        fresh.mint(vm.getBlockNumber() - 1, 0);
        vm.prank(B);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        fresh.fundPools();
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        fresh.setHook(address(binding));
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        fresh.setHook(ALICE);
    }

    function test_ConstructorRejectsInvalidAssetsOwnerAndSpacing() public {
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        new WorkersNFT(address(0), address(work), address(imd), manager, 60);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        new WorkersNFT(address(this), address(work), address(work), manager, 60);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        new WorkersNFT(address(this), address(work), address(imd), manager, 0);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        new WorkersNFT(address(this), address(work), address(imd), IPoolManager(ALICE), 60);
        TestIMD bad = new TestIMD(1);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        new WorkersNFT(address(this), address(work), address(bad), manager, 60);
        bad = new TestIMD(19);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        new WorkersNFT(address(this), address(work), address(bad), manager, 60);
    }
}

// Unit boundary harness: only the harness seeds sale state. End-to-end NFT tests
// above mint real proofs without changing the implementation's storage.
contract SaleBoundaryHarness {
    WorkerState.Data private s;

    constructor(address token) {
        s.imd = token;
        s.imdUnit = 1e6;
        s.priceScaleBps = 10000;
        s.cap = 3333;
        s.remaining = 3333;
        s.poolsFunded = true;
        s.floorAdjustment = -2;
    }

    function seed(uint256 minted, uint256 threshold, uint256 last, uint256 retarget) external {
        s.minted = minted;
        s.target = threshold;
        s.lastMintTime = last;
        s.retargetTime = retarget;
    }

    function seedPool(uint256 poolSize, uint256 index, uint256 replacement) external {
        s.remaining = poolSize;
        s.idPool[index] = replacement;
    }

    function mint(uint256 anchor, uint256 nonce) external returns (uint256) {
        return WorkerSale.mint(s, anchor, nonce);
    }

    function floorBits() external view returns (uint256) {
        return WorkerSale.floorBits(s);
    }

    function epoch() external view returns (uint256) {
        return WorkerSale.epoch(s);
    }

    function target() external view returns (uint256) {
        return s.target;
    }

    function currentTarget() external view returns (uint256) {
        return WorkerSale.currentTarget(s);
    }

    function poolAt(uint256 n) external view returns (uint256) {
        return WorkerSale.poolAt(s, n);
    }

    function remaining() external view returns (uint256) {
        return s.remaining;
    }
}

contract WorkerSaleBoundaryTest is WorkTestBase {
    TestIMD internal token;
    SaleBoundaryHarness internal sale;

    function setUp() public {
        vm.chainId(31337);
        vm.warp(1000000);
        vm.roll(1000);
        vm.setBlockhash(999, bytes32(uint256(123)));
        token = new TestIMD(6);
        sale = new SaleBoundaryHarness(address(token));
        token.mint(ALICE, 1e12);
        vm.prank(ALICE);
        token.approve(address(sale), type(uint256).max);
    }

    function _proof(uint256 threshold, uint256 salt) internal view returns (uint256 nonce, bytes32 hash) {
        bytes memory payload = abi.encode(
            keccak256("WorkersNFT.Work.v1"),
            block.chainid,
            address(sale),
            keccak256(abi.encode(bytes32(uint256(123)), bytes32(0))),
            ALICE,
            uint256(0)
        );
        nonce = salt;
        while (true) {
            assembly ("memory-safe") {
                mstore(add(payload, 192), nonce)
                hash := keccak256(add(payload, 32), 192)
            }
            if (uint256(hash) < threshold) return (nonce, hash);
            unchecked {
                ++nonce;
            }
        }
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_ProofStrictThreshold(uint256 salt) public {
        (uint256 nonce, bytes32 hash) = _proof(type(uint256).max >> 10, salt);
        // Equality must fail. One greater must accept the exact same nonce.
        sale.seed(0, uint256(hash), vm.getBlockTimestamp(), vm.getBlockTimestamp());
        vm.prank(ALICE);
        vm.expectRevert(WorkersNFT.InvalidWork.selector);
        sale.mint(999, nonce);
        sale.seed(0, uint256(hash) + 1, vm.getBlockTimestamp(), vm.getBlockTimestamp());
        vm.prank(ALICE);
        uint256 id = sale.mint(999, nonce);
        eq(id, uint256(hash) % 3333 + 1);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_EpochFloors(uint256 count) public {
        count = bounded(count, 0, 3333);
        sale.seed(count, 1, vm.getBlockTimestamp(), vm.getBlockTimestamp());
        uint256 expected = count >= 2960 ? 8 : count / 370;
        eq(sale.epoch(), expected);
        eq(sale.floorBits(), 10 + expected);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_IdleTargetDoublingSaturates(uint256 elapsed, uint256 bits) public {
        elapsed = bounded(elapsed, 0, 100000);
        bits = bounded(bits, 10, 200);
        uint256 start = type(uint256).max >> bits;
        sale.seed(0, start, vm.getBlockTimestamp(), vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + elapsed);
        uint256 steps = elapsed / 300;
        uint256 expected = start;
        uint256 ceiling = type(uint256).max >> 10;
        for (uint256 i; i < steps && expected < ceiling; ++i) {
            expected = expected > ceiling / 2 ? ceiling : expected * 2;
        }
        eq(sale.currentTarget(), expected);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_EighthMintRetargetsClampedTime(uint256 elapsed) public {
        elapsed = bounded(elapsed, 0, 1000);
        uint256 start = type(uint256).max >> 12;
        sale.seed(7, start, vm.getBlockTimestamp(), vm.getBlockTimestamp() - elapsed);
        (uint256 nonce,) = _proof(start, 0);
        vm.prank(ALICE);
        sale.mint(999, nonce);
        uint256 time = elapsed < 20 ? 20 : elapsed > 320 ? 320 : elapsed;
        eq(sale.target(), start * time / 80);
    }

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_SwapAndPopPicking(uint256 remaining, uint256 salt) public {
        remaining = bounded(remaining, 2, 3333);
        uint256 threshold = type(uint256).max >> 10;
        sale.seed(0, threshold, vm.getBlockTimestamp(), vm.getBlockTimestamp());
        // Put an already-swapped id in the last slot to check sparse-pool handling.
        sale.seedPool(remaining, remaining - 1, 3333);
        (uint256 nonce, bytes32 hash) = _proof(threshold, salt);
        uint256 index = uint256(hash) % remaining;
        uint256 selected = index == remaining - 1 ? 3333 : index + 1;
        vm.prank(ALICE);
        eq(sale.mint(999, nonce), selected);
        eq(sale.remaining(), remaining - 1);
        if (index < remaining - 1) eq(sale.poolAt(index), 3333);
        vm.expectRevert(WorkOwned.InvalidParameter.selector);
        sale.poolAt(remaining - 1);
    }
}

contract WorkerSequenceHandler is WorkTestBase {
    WorkersNFT public nft;
    TestIMD public imd;
    Work public work;
    TestHookBinding public binding;
    uint256[] public ids;
    uint256 public hookRewards;
    uint256 public imdClaims;
    uint256 public workClaims;
    uint256 public burnsPaid;
    uint256 public sweptIMD;
    uint256 public sweptWORK;
    uint256 public buybackSpent;
    uint256 public destroyedWORK;
    uint256 public initialCap;
    uint256 public smallestCap;
    bool public ended;
    uint256 public successfulActions;

    constructor(WorkersNFT n, TestIMD i, Work w, TestHookBinding h, uint256[] memory initialIds) {
        nft = n;
        imd = i;
        work = w;
        binding = h;
        ids = initialIds;
        initialCap = n.cap();
        smallestCap = n.cap();
    }

    function accept() external {
        nft.acceptOwnership();
    }

    function actor(uint256 seed) public pure returns (address) {
        return seed % 3 == 0 ? ALICE : seed % 3 == 1 ? BOB : CAROL;
    }

    function _holder(uint256 id) internal view returns (address holder) {
        try nft.ownerOf(id) returns (address h) {
            holder = h;
        } catch {}
    }

    function advance(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bounded(seconds_, 1, 15 days));
        ++successfulActions;
    }

    function stake(uint256 seed, uint256 duration) external {
        uint256 id = ids[seed % ids.length];
        address holder = _holder(id);
        if (holder == address(0) || holder == address(nft)) return;
        vm.prank(holder);
        nft.stake(id, duration % 3 == 0 ? 7 : duration % 3 == 1 ? 14 : 30);
        ++successfulActions;
    }

    function unstake(uint256 seed) external {
        uint256 id = ids[seed % ids.length];
        (address staker, uint64 unlockAt,) = nft.stakes(id);
        if (staker == address(0) || vm.getBlockTimestamp() < unlockAt) return;
        vm.prank(staker);
        nft.unstake(id);
        ++successfulActions;
    }

    function transfer(uint256 seed, uint256 to) external {
        uint256 id = ids[seed % ids.length];
        address holder = _holder(id);
        if (holder == address(0) || holder == address(nft)) return;
        vm.prank(holder);
        nft.transferFrom(holder, actor(to), id);
        ++successfulActions;
    }

    function finishMint() external {
        if (nft.mintEnded()) return;
        nft.endMint();
        ended = true;
        smallestCap = nft.cap();
        ++successfulActions;
    }

    function lowerCap(uint256 seed) external {
        uint256 cap = bounded(seed, nft.minted(), nft.cap());
        nft.setCap(cap);
        smallestCap = cap;
        ended = nft.mintEnded();
        ++successfulActions;
    }

    function activate(uint256 seed) external {
        uint256 id = ids[seed % ids.length];
        if (!nft.mintEnded() || _holder(id) == address(0) || nft.activated(id)) return;
        vm.prank(nft.beneficiaryOf(id));
        nft.activate(id);
        ++successfulActions;
    }

    function claimIMD(uint256 who) external {
        vm.prank(actor(who));
        imdClaims += nft.claimIMD();
        ++successfulActions;
    }

    function claimWORK(uint256 seed) external {
        uint256 id = ids[seed % ids.length];
        if (_holder(id) == address(0)) return;
        vm.prank(nft.beneficiaryOf(id));
        workClaims += nft.claimWork(one(id));
        ++successfulActions;
    }

    function burn(uint256 seed) external {
        uint256 id = ids[seed % ids.length];
        address holder = _holder(id);
        if (!nft.mintEnded() || holder == address(0) || holder == address(nft)) return;
        uint256 before = work.balanceOf(holder);
        vm.prank(holder);
        nft.burn(id);
        burnsPaid += nft.burnReward();
        workClaims += work.balanceOf(holder) - before - nft.burnReward();
        ++successfulActions;
    }

    function reward(uint256 amount) external {
        if (!nft.mintEnded() || nft.totalWeight() == 0) return;
        amount = bounded(amount, 0, 1e12);
        imd.mint(address(nft), amount);
        binding.reward(amount);
        hookRewards += amount;
        ++successfulActions;
    }

    function donationAndSweep(uint256 amount) external {
        amount = bounded(amount, 0, 1e12);
        imd.mint(address(nft), amount);
        uint256 before = imd.balanceOf(B);
        nft.sweep(address(imd));
        eq(imd.balanceOf(B) - before, amount);
        sweptIMD += amount;
        uint256 w = work.balanceOf(ALICE) < amount ? work.balanceOf(ALICE) : amount;
        vm.prank(ALICE);
        work.transfer(address(nft), w);
        before = work.balanceOf(B);
        nft.sweep(address(work));
        eq(work.balanceOf(B) - before, w);
        sweptWORK += w;
        ++successfulActions;
    }

    function buyback(uint256 amount) external {
        uint256 available = nft.buybackBalance();
        if (available == 0 || (nft.lastBuybackTime() != 0 && vm.getBlockTimestamp() < nft.lastBuybackTime() + 60)) return;
        uint256 maximum = available > 100e6 ? 100e6 : available;
        amount = bounded(amount, 1, maximum);
        destroyedWORK += nft.buyback(amount, 0, vm.getBlockTimestamp());
        buybackSpent += amount;
        ++successfulActions;
    }

    function pauseOrResume(bool pause_) external {
        if (pause_ && !nft.paused() && block.timestamp >= nft.pauseCooldownUntil()) nft.pause();
        else if (!pause_ && nft.paused()) nft.unpause();
        ++successfulActions;
    }
}

contract WorkersNFTInvariantTest is WorkerFixture {
    WorkerSequenceHandler internal handler;
    uint256[] internal initialIds;

    function setUp() public {
        _setup();
        initialIds.push(_mint(ALICE));
        initialIds.push(_mint(BOB));
        initialIds.push(_mint(CAROL));
        initialIds.push(_mint(ALICE));
        handler = new WorkerSequenceHandler(nft, imd, work, binding, initialIds);
        nft.transferOwnership(address(handler));
        handler.accept();
    }

    function targetContracts() public view returns (address[] memory list) {
        list = new address[](1);
        list[0] = address(handler);
    }

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory list) {
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.stake.selector;
        selectors[2] = handler.unstake.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.finishMint.selector;
        selectors[5] = handler.lowerCap.selector;
        selectors[6] = handler.activate.selector;
        selectors[7] = handler.claimIMD.selector;
        selectors[8] = handler.claimWORK.selector;
        selectors[9] = handler.burn.selector;
        selectors[10] = handler.reward.selector;
        selectors[11] = handler.donationAndSweep.selector;
        selectors[12] = handler.pauseOrResume.selector;
        selectors[13] = handler.buyback.selector;
        list = new FuzzSelector[](1);
        list[0] = FuzzSelector(address(handler), selectors);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ReservesAndConservation() public view {
        eq(imd.balanceOf(address(nft)), nft.stakerReserve() + nft.buybackBalance());
        eq(work.balanceOf(address(nft)), nft.miningPool() + nft.burnPool() + nft.workReserve());
        // Four pre-sequence mints had no stakers. All subsequent staker IMD is known hook inflow.
        eq(nft.stakerReserve() + handler.imdClaims(), handler.hookRewards());
        eq(nft.miningPool() + nft.workReserve() + handler.workClaims(), 100_000_000 ether);
        eq(nft.burnPool() + handler.burnsPaid(), 50_000_000 ether);
        eq(work.totalSupply() + handler.destroyedWORK(), 1_000_000_000 ether);
        eq(nft.buybackBalance() + handler.buybackSpent(), 900000);
        eq(
            work.balanceOf(ALICE) + work.balanceOf(BOB) + work.balanceOf(CAROL) + work.balanceOf(B)
                + work.balanceOf(address(manager)) + work.balanceOf(address(nft)),
            work.totalSupply()
        );
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_EscrowSupplyAndTerminalMint() public view {
        uint256 escrow;
        uint256 live;
        uint256 active;
        uint256 weights;
        uint256 pendingIMD;
        uint256 pendingWORK;
        for (uint256 i; i < initialIds.length; ++i) {
            uint256 id = initialIds[i];
            try nft.ownerOf(id) returns (address holder) {
                ++live;
                (address staker,, uint8 weight) = nft.stakes(id);
                if (holder == address(nft)) {
                    ++escrow;
                    weights += weight;
                    require(staker != address(0));
                } else {
                    eq(staker, address(0));
                    eq(uint256(weight), 0);
                }
                if (nft.activated(id)) ++active;
                pendingWORK += nft.pendingWork(id);
            } catch {}
        }
        for (uint256 i; i < 3; ++i) {
            pendingIMD += nft.pendingIMD(handler.actor(i));
        }
        require(pendingIMD <= nft.stakerReserve());
        require(pendingWORK <= nft.miningPool() + nft.workReserve());
        eq(live, nft.totalSupply());
        eq(live + nft.burned(), 4);
        eq(nft.activeWorkers(), active);
        eq(nft.balanceOf(address(nft)), escrow);
        eq(nft.totalWeight(), weights);
        eq(weights, nft.userWeight(ALICE) + nft.userWeight(BOB) + nft.userWeight(CAROL));
        require(nft.cap() <= handler.initialCap());
        eq(nft.cap(), handler.smallestCap());
        if (handler.ended()) {
            require(nft.mintEnded());
            eq(nft.cap(), nft.minted());
            eq(nft.mintedAtEnd(), 4);
        }
    }
}
