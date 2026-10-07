// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Self-contained ABI subset of Uniswap v4. These types have the canonical wire layout.
type Currency is address;
type BalanceDelta is int256;
type BeforeSwapDelta is int256;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata data) external returns (BalanceDelta);
    function take(Currency currency, address to, uint256 amount) external;
    function sync(Currency currency) external;
    function settle() external payable returns (uint256);
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IERC20Work {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function burn(uint256) external;
}

interface IWorkers {
    function work() external view returns (address);
    function imd() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function tickSpacing() external view returns (int24);
    function hook() external view returns (address);
    function bindHook() external;
    function mintEnded() external view returns (bool);
    function totalWeight() external view returns (uint256);
    function notifyHookReward(uint256 amount) external;
}

interface IWorkHook {
    function workers() external view returns (IWorkers);
    function poolManager() external view returns (IPoolManager);
    function minimumBuybackOutput(uint256 amount) external view returns (uint256);
}

library WorkTransfer {
    error TokenTransferFailed();

    function send(address token, address to, uint256 amount) internal {
        if (amount != 0) callToken(token, abi.encodeWithSelector(IERC20Work.transfer.selector, to, amount));
    }

    function pull(address token, address from, uint256 amount) internal {
        uint256 beforeBalance = IERC20Work(token).balanceOf(address(this));
        callToken(token, abi.encodeWithSelector(IERC20Work.transferFrom.selector, from, address(this), amount));
        if (IERC20Work(token).balanceOf(address(this)) != beforeBalance + amount) revert TokenTransferFailed();
    }

    function callToken(address token, bytes memory data) internal {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || token.code.length == 0 || (result.length != 0 && !abi.decode(result, (bool)))) {
            revert TokenTransferFailed();
        }
    }
}

abstract contract WorkOwned {
    error Unauthorized();
    error InvalidParameter();
    error ReentrantCall();
    address public owner;
    address public pendingOwner;
    uint256 private entered;
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert InvalidParameter();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    modifier nonReentrant() {
        if (entered != 0) revert ReentrantCall();
        entered = 1;
        _;
        entered = 0;
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert InvalidParameter();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }
}

/// @notice Fixed supply launch token. The factory receives 1 billion WORK and can
/// distribute 100M to its swarm, 700M to its pool and 200M to B using distributeLaunch.
/// No authority can mint more tokens. Burns only spend the caller's own balance.
contract Work {
    string public constant name = "Work";
    string public constant symbol = "WORK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply = 1_000_000_000 ether;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    error InvalidTransfer();

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidTransfer();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @notice Atomic initial allocation by the supply holder; never spends another account's funds.
    function distributeLaunch(address swarm, address pool) external {
        if (swarm == address(0) || pool == address(0)) revert InvalidTransfer();
        _transfer(msg.sender, swarm, 100_000_000 ether);
        _transfer(msg.sender, pool, 700_000_000 ether);
        _transfer(msg.sender, 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0, 200_000_000 ether);
    }
}

/// @notice IMD-denominated fees on one WORK/IMD v4 pool.
/// Deploy using CREATE2 to an address with low 14 bits REQUIRED_HOOK_FLAGS.
/// The requester supplies initialOwner; the deployment factory is not implicitly owner.
contract WorkHook is WorkOwned {
    address public constant BUILDERS = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    uint160 public constant REQUIRED_HOOK_FLAGS = 0x30cc;
    uint24 public constant LP_FEE = 12500;
    uint256 public constant ORACLE_WINDOW = 30 minutes;
    IPoolManager public immutable poolManager;
    IWorkers public immutable workers;
    address public immutable imd;
    address public immutable work;
    address public immutable initializer;
    address public immutable deployerOrigin;
    bool public immutable imdIs0;
    uint16 public feeBps = 75;
    uint16 public stakerShareBps = 10000;
    bytes32 public poolId;
    bool public initialized;
    int24 public lastTick;
    uint256 public lastObservationTime;
    int256 public tickCumulative;

    struct Observation {
        uint256 timestamp;
        int256 cumulative;
    }
    Observation public olderObservation;
    Observation public newerObservation;

    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }
    event FeeChanged(uint16 oldValue, uint16 newValue);
    event StakerShareChanged(uint16 oldValue, uint16 newValue);
    event FeesDistributed(uint256 builders, uint256 stakers);
    event PoolInitialized(bytes32 indexed poolId);
    event Swept(address indexed token, uint256 amount);
    error InvalidPool();
    error OracleNotReady();
    error PartialSpecifiedSwap();

    constructor(IPoolManager manager, IWorkers nft, address initialOwner) WorkOwned(initialOwner) {
        if (
            address(manager).code.length == 0 || address(nft).code.length == 0
                || address(nft.poolManager()) != address(manager)
                || (uint160(address(this)) & 0x3fff) != REQUIRED_HOOK_FLAGS
        ) revert InvalidParameter();
        initializer = msg.sender;
        deployerOrigin = tx.origin;
        poolManager = manager;
        workers = nft;
        imd = nft.imd();
        work = nft.work();
        imdIs0 = imd < work;
    }
    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() external pure returns (Permissions memory p) {
        p.beforeInitialize = true;
        p.afterInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function setFeeBps(uint16 value) external onlyOwner {
        if (value > 875) revert InvalidParameter();
        emit FeeChanged(feeBps, value);
        feeBps = value;
    }

    function setStakerShareBps(uint16 value) external onlyOwner {
        if (value < 9000 || value > 10000) revert InvalidParameter();
        emit StakerShareChanged(stakerShareBps, value);
        stakerShareBps = value;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        bool trusted = sender == initializer || sender == owner || tx.origin == deployerOrigin;
        if (trusted && workers.hook() == address(0)) workers.bindHook();
        if (
            !trusted || initialized || poolId != bytes32(0)
                || key.hooks != address(this) || key.fee != LP_FEE || key.tickSpacing != workers.tickSpacing()
                || workers.hook() != address(this) || Currency.unwrap(key.currency0) != (imdIs0 ? imd : work)
                || Currency.unwrap(key.currency1) != (imdIs0 ? work : imd)
        ) revert InvalidPool();
        poolId = keccak256(abi.encode(key));
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick) external onlyManager returns (bytes4) {
        if (initialized || poolId == bytes32(0) || poolId != keccak256(abi.encode(key))) revert InvalidPool();
        initialized = true;
        lastTick = tick;
        lastObservationTime = block.timestamp;
        newerObservation = Observation(block.timestamp, 0);
        olderObservation = newerObservation;
        emit PoolInitialized(poolId);
        return this.afterInitialize.selector;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || keccak256(abi.encode(key)) != poolId) revert InvalidPool();
    }

    function _imdSpecified(SwapParams calldata p) private view returns (bool) {
        return ((p.amountSpecified < 0) == p.zeroForOne) == imdIs0;
    }

    function _specifiedFee(int256 amount) private view returns (uint256) {
        if (amount == type(int256).min) revert InvalidParameter();
        uint256 magnitude = uint256(amount < 0 ? -amount : amount);
        if (magnitude > uint256(uint128(type(int128).max))) revert InvalidParameter();
        // Exact output specifies NET IMD. Gross up to collect feeBps of gross output.
        return amount < 0 ? magnitude * feeBps / 10000 : (magnitude * feeBps + (9999 - feeBps)) / (10000 - feeBps);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata p, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        uint256 fee;
        if (_imdSpecified(p)) {
            fee = _specifiedFee(p.amountSpecified);
            _distribute(fee);
        }
        // Positive specified delta takes IMD, reduces exact input or increases gross exact output.
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(int256(fee << 128)), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata p, BalanceDelta delta, bytes calldata)
        external
        onlyManager
        nonReentrant
        returns (bytes4, int128)
    {
        _checkPool(key);
        _observe();
        // v4 Pool.State.slot0: sqrtPriceX96 occupies 160 bits, then signed int24 tick.
        bytes32 slot0 = poolManager.extsload(keccak256(abi.encode(poolId, uint256(6))));
        lastTick = int24(uint24(uint256(slot0) >> 160));
        int128 imdDelta = imdIs0 ? int128(BalanceDelta.unwrap(delta) >> 128) : int128(BalanceDelta.unwrap(delta));
        uint256 fee;
        if (_imdSpecified(p)) {
            fee = _specifiedFee(p.amountSpecified);
            // A specified-currency fee cannot be corrected by afterSwap's unspecified delta.
            // Reject partial fills in this case instead of charging for input never swapped.
            if (fee != 0 && int256(imdDelta) != p.amountSpecified + int256(fee)) revert PartialSpecifiedSwap();
            fee = 0;
        } else {
            uint256 magnitude = uint256(imdDelta < 0 ? -int256(imdDelta) : int256(imdDelta));
            fee = magnitude * feeBps / 10000;
            _distribute(fee);
        }
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    function _distribute(uint256 fee) private {
        if (fee == 0) return;
        uint256 stakers;
        if (workers.mintEnded() && workers.totalWeight() != 0) stakers = fee * stakerShareBps / 10000;
        if (stakers != 0) {
            poolManager.take(Currency.wrap(imd), address(workers), stakers);
            workers.notifyHookReward(stakers);
        }
        if (fee != stakers) poolManager.take(Currency.wrap(imd), BUILDERS, fee - stakers);
        emit FeesDistributed(fee - stakers, stakers);
    }

    function _observe() private {
        tickCumulative += int256(lastTick) * int256(block.timestamp - lastObservationTime);
        lastObservationTime = block.timestamp;
        if (block.timestamp - newerObservation.timestamp >= ORACLE_WINDOW) {
            olderObservation = newerObservation;
            newerObservation = Observation(block.timestamp, tickCumulative);
        }
    }

    /// @notice Average tick over at least 30 minutes. Current-block price changes have zero weight.
    function averageTick() public view returns (int24) {
        Observation memory start =
            block.timestamp - newerObservation.timestamp >= ORACLE_WINDOW ? newerObservation : olderObservation;
        if (!initialized || block.timestamp - start.timestamp < ORACLE_WINDOW) revert OracleNotReady();
        int256 elapsed = int256(block.timestamp - start.timestamp);
        int256 difference =
            tickCumulative + int256(lastTick) * int256(block.timestamp - lastObservationTime) - start.cumulative;
        int256 mean = difference / elapsed;
        if (difference < 0 && difference % elapsed != 0) --mean;
        return int24(mean);
    }

    function minimumBuybackOutput(uint256 amount) external view returns (uint256) {
        uint160 sqrtRatio = WorkMath.sqrtAtTick(averageTick());
        uint256 quote;
        if (sqrtRatio <= type(uint128).max) {
            uint256 ratio = uint256(sqrtRatio) * sqrtRatio;
            quote = imdIs0 ? WorkMath.mulDiv(ratio, amount, 1 << 192) : WorkMath.mulDiv(1 << 192, amount, ratio);
        } else {
            uint256 ratio = WorkMath.mulDiv(sqrtRatio, sqrtRatio, 1 << 64);
            quote = imdIs0 ? WorkMath.mulDiv(ratio, amount, 1 << 128) : WorkMath.mulDiv(1 << 128, amount, ratio);
        }
        // Account for both fees, then allow at most 5% price impact against the average.
        return WorkMath.mulDiv(quote, uint256(10000 - 125 - feeBps) * 9500, 100_000_000);
    }
    receive() external payable {}

    function sweep(address token) external nonReentrant {
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            (bool ok,) = BUILDERS.call{value: amount}("");
            if (!ok) revert InvalidParameter();
        } else {
            amount = IERC20Work(token).balanceOf(address(this));
            WorkTransfer.send(token, BUILDERS, amount);
        }
        emit Swept(token, amount);
    }
}

/* WorkMath adapts Uniswap v4-core FullMath and TickMath (MIT).
 * Copyright (c) Uniswap Labs; mulDiv credit Remco Bloemen.
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is furnished to do
 * so, subject to the following conditions: The above copyright notice and this
 * permission notice shall be included in all copies or substantial portions of
 * the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
 * EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
 * OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
library WorkMath {
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0 = a * b; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly ("memory-safe") {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Make sure the result is less than 2**256.
            // Also prevents denominator == 0
            require(denominator > prod1);

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly ("memory-safe") {
                    result := div(prod0, denominator)
                }
                return result;
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly ("memory-safe") {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            // Compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = (0 - denominator) & denominator;
            // Divide denominator by power of two
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly ("memory-safe") {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            assembly ("memory-safe") {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4
            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the preconditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
            return result;
        }
    }

    function sqrtAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick;
            assembly ("memory-safe") {
                tick := signextend(2, tick)
                // mask = 0 if tick >= 0 else -1 (all 1s)
                let mask := sar(255, tick)
                // if tick >= 0, |tick| = tick = 0 ^ tick
                // if tick < 0, |tick| = ~~|tick| = ~(-|tick| - 1) = ~(tick - 1) = (-1) ^ (tick - 1)
                // either way, |tick| = mask ^ (tick + mask)
                absTick := xor(mask, add(mask, tick))
            }

            require(absTick <= 887272);

            // The tick is decomposed into bits, and for each bit with index i that is set, the product of 1/sqrt(1.0001^(2^i))
            // is calculated (using Q128.128). The constants used for this calculation are rounded to the nearest integer

            // Equivalent to:
            //     price = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            //     or price = int(2**128 / sqrt(1.0001)) if (absTick & 0x1) else 1 << 128
            uint256 price;
            assembly ("memory-safe") {
                price := xor(shl(128, 1), mul(xor(shl(128, 1), 0xfffcb933bd6fad37aa2d162d1a594001), and(absTick, 0x1)))
            }
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;

            assembly ("memory-safe") {
                // if (tick > 0) price = type(uint256).max / price;
                if sgt(tick, 0) { price := div(not(0), price) }

                // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
                // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
                // we round up in the division so getTickAtSqrtPrice of the output price is always consistent
                // `sub(shl(32, 1), 1)` is `type(uint32).max`
                // `price + type(uint32).max` will not overflow because `price` fits in 192 bits
                sqrtPriceX96 := shr(32, add(price, sub(shl(32, 1), 1)))
            }
        }
    }
}
