// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    WorkOwned,
    WorkTransfer,
    WorkMath,
    IERC20Work,
    IPoolManager,
    IWorkHook,
    PoolKey,
    Currency,
    SwapParams,
    BalanceDelta
} from "./WorkHook.sol";

interface IWorkerReceiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

interface IWorkerPermit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 sigS)
        external;
}

interface IArbWorkBlocks {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 number) external view returns (bytes32);
}

/// @dev Shared storage for the two statically linked libraries. Only the NFT facade
/// exposes operations; it applies ownership and reentrancy guards before delegation.
library WorkerState {
    struct Stake {
        address staker;
        uint64 unlockAt;
        uint8 weight;
    }

    struct Data {
        address work;
        address imd;
        uint256 imdUnit;
        IPoolManager poolManager;
        int24 tickSpacing;
        address hook;
        bool poolsFunded;
        uint256 cap;
        uint256 minted;
        uint256 burned;
        uint256 remaining;
        mapping(uint256 => uint256) idPool;
        mapping(uint256 => address) owners;
        mapping(address => uint256) balances;
        mapping(uint256 => address) approvals;
        mapping(address => mapping(address => bool)) isApprovedForAll;
        mapping(uint256 => bool) overclocked;
        string baseURI;
        uint16 royaltyBps;
        uint16 priceScaleBps;
        int8 floorAdjustment;
        uint256 target;
        bytes32 prevWork;
        uint256 lastMintBlock;
        uint256 lastMintTime;
        uint256 retargetTime;
        bool mintEnded;
        uint256 mintEndTime;
        uint256 mintedAtEnd;
        uint256 pauseStarted;
        uint256 pauseUntil;
        uint256 activationFee;
        uint256 buybackBalance;
        uint256 lastBuybackTime;
        bool buying;
        uint256 stakerReserve;
        uint256 totalWeight;
        uint256 accIMDPerWeight;
        mapping(address => uint256) userWeight;
        mapping(address => uint256) userIMDCheckpoint;
        mapping(address => uint256) imdCredit;
        mapping(uint256 => Stake) stakes;
        uint256 miningPool;
        uint256 burnPool;
        uint256 burnReward;
        uint256 workReserve;
        uint256 activeWorkers;
        uint256 accWorkPerWorker;
        uint256 lastMiningUpdate;
        mapping(uint256 => bool) activated;
        mapping(uint256 => uint256) workCheckpoint;
        mapping(uint256 => uint256) workCredit;
    }
}

library WorkerConstants {
    string internal constant name = "Workers";
    string internal constant symbol = "WORKER";
    address internal constant BUILDERS = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    address internal constant ROBINHOOD_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 internal constant MAX_SUPPLY = 3333;
    uint256 internal constant MINING_ALLOCATION = 100_000_000 ether;
    uint256 internal constant BURN_ALLOCATION = 50_000_000 ether;
    uint256 internal constant ERA_EMISSION = 12_500_000 ether;
    uint256 internal constant PAUSE_DURATION = 72 hours;
    uint256 internal constant INITIAL_DIFFICULTY_BITS = 12;
    uint256 internal constant SCALE = 1e27;
    bytes32 internal constant DOMAIN = keccak256("WorkersNFT.Work.v1");
}

/// @notice Proof-of-work workers with real NFT escrow, IMD dividends and passive WORK mining.
/// Setup: deploy with requester as owner, deploy WorkHook, bind it once, then B funds pools.
/// WORK allocation is 100M swarm / 700M liquidity / 200M B. B retains 50M and deposits
/// 100M mining + 50M burn here before minting. No owner withdrawal or upgrade mechanism.
/// WorkerFinance and WorkerSale are statically linked libraries in this file; deploy
/// WorkerFinance, then WorkerSale, then WorkersNFT. Their addresses cannot be changed.
/// IMD must be a non-rebasing, non-taxed ERC20. Its decimals are read at construction.
contract WorkersNFT is WorkOwned {
    string public constant name = "Workers";
    string public constant symbol = "WORKER";
    address public constant BUILDERS = 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0;
    address public constant ROBINHOOD_IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    uint256 public constant MAX_SUPPLY = 3333;
    uint256 public constant MINING_ALLOCATION = 100_000_000 ether;
    uint256 public constant BURN_ALLOCATION = 50_000_000 ether;
    uint256 public constant ERA_EMISSION = 12_500_000 ether;
    uint256 public constant PAUSE_DURATION = 72 hours;
    uint256 public constant INITIAL_DIFFICULTY_BITS = 12;
    uint256 private constant SCALE = 1e27;
    bytes32 public constant DOMAIN = keccak256("WorkersNFT.Work.v1");
    WorkerState.Data private s;
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event MetadataUpdate(uint256 tokenId);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event HookBound(address indexed hook);
    event PoolsFunded(uint256 mining, uint256 burn);
    event CapChanged(uint256 oldCap, uint256 newCap);
    event MintEnded(uint256 minted, uint256 timestamp, uint256 burnReward);
    event Paused(uint256 until);
    event Unpaused();
    event FloorChanged(int8 oldValue, int8 newValue);
    event PriceScaleChanged(uint16 oldValue, uint16 newValue);
    event ActivationFeeChanged(uint256 oldValue, uint256 newValue);
    event RoyaltyChanged(uint16 oldValue, uint16 newValue);
    event BaseURIChanged(string value);
    event TargetChanged(uint256 target);
    event WorkerMinted(
        address indexed minter, uint256 indexed tokenId, bytes32 workHash, bool overclocked, uint256 price
    );
    event MintPayment(uint256 stakers, uint256 buyback, uint256 builders);
    event Staked(address indexed staker, uint256 indexed tokenId, uint256 unlockAt, uint256 weight);
    event Unstaked(address indexed staker, uint256 indexed tokenId);
    event IMDReward(uint256 amount);
    event IMDClaimed(address indexed staker, uint256 amount);
    event Activated(uint256 indexed tokenId);
    event WorkClaimed(address indexed holder, uint256 amount);
    event WorkerBurned(address indexed holder, uint256 indexed tokenId, uint256 reward);
    event Buyback(uint256 imdSpent, uint256 workBurned);
    event Swept(address indexed token, uint256 amount);
    error MintUnavailable();
    error InvalidWork();
    error InvalidToken();
    error Locked();
    error Insolvent();
    error UnsafeRecipient();
    error SwapFailed();

    function work() external view returns (address) {
        return s.work;
    }

    function imd() external view returns (address) {
        return s.imd;
    }

    function imdUnit() external view returns (uint256) {
        return s.imdUnit;
    }

    function poolManager() external view returns (IPoolManager) {
        return s.poolManager;
    }

    function tickSpacing() external view returns (int24) {
        return s.tickSpacing;
    }

    function hook() external view returns (address) {
        return s.hook;
    }

    function poolsFunded() external view returns (bool) {
        return s.poolsFunded;
    }

    function cap() external view returns (uint256) {
        return s.cap;
    }

    function minted() external view returns (uint256) {
        return s.minted;
    }

    function burned() external view returns (uint256) {
        return s.burned;
    }

    function remaining() external view returns (uint256) {
        return s.remaining;
    }

    function isApprovedForAll(address a, address b) external view returns (bool) {
        return s.isApprovedForAll[a][b];
    }

    function overclocked(uint256 a) external view returns (bool) {
        return s.overclocked[a];
    }

    function baseURI() external view returns (string memory) {
        return s.baseURI;
    }

    function royaltyBps() external view returns (uint16) {
        return s.royaltyBps;
    }

    function priceScaleBps() external view returns (uint16) {
        return s.priceScaleBps;
    }

    function floorAdjustment() external view returns (int8) {
        return s.floorAdjustment;
    }

    function target() external view returns (uint256) {
        return s.target;
    }

    function prevWork() external view returns (bytes32) {
        return s.prevWork;
    }

    function lastMintBlock() external view returns (uint256) {
        return s.lastMintBlock;
    }

    function lastMintTime() external view returns (uint256) {
        return s.lastMintTime;
    }

    function retargetTime() external view returns (uint256) {
        return s.retargetTime;
    }

    function mintEnded() external view returns (bool) {
        return s.mintEnded;
    }

    function mintEndTime() external view returns (uint256) {
        return s.mintEndTime;
    }

    function mintedAtEnd() external view returns (uint256) {
        return s.mintedAtEnd;
    }

    function pauseStarted() external view returns (uint256) {
        return s.pauseStarted;
    }

    function pauseUntil() external view returns (uint256) {
        return s.pauseUntil;
    }

    function activationFee() external view returns (uint256) {
        return s.activationFee;
    }

    function buybackBalance() external view returns (uint256) {
        return s.buybackBalance;
    }

    function lastBuybackTime() external view returns (uint256) {
        return s.lastBuybackTime;
    }

    function stakerReserve() external view returns (uint256) {
        return s.stakerReserve;
    }

    function totalWeight() external view returns (uint256) {
        return s.totalWeight;
    }

    function accIMDPerWeight() external view returns (uint256) {
        return s.accIMDPerWeight;
    }

    function userWeight(address a) external view returns (uint256) {
        return s.userWeight[a];
    }

    function userIMDCheckpoint(address a) external view returns (uint256) {
        return s.userIMDCheckpoint[a];
    }

    function stakes(uint256 a) external view returns (address staker, uint64 unlockAt, uint8 weight) {
        WorkerState.Stake memory v = s.stakes[a];
        return (v.staker, v.unlockAt, v.weight);
    }

    function miningPool() external view returns (uint256) {
        return s.miningPool;
    }

    function burnPool() external view returns (uint256) {
        return s.burnPool;
    }

    function burnReward() external view returns (uint256) {
        return s.burnReward;
    }

    function workReserve() external view returns (uint256) {
        return s.workReserve;
    }

    function activeWorkers() external view returns (uint256) {
        return s.activeWorkers;
    }

    function accWorkPerWorker() external view returns (uint256) {
        return s.accWorkPerWorker;
    }

    function lastMiningUpdate() external view returns (uint256) {
        return s.lastMiningUpdate;
    }

    function activated(uint256 a) external view returns (bool) {
        return s.activated[a];
    }

    function workCheckpoint(uint256 a) external view returns (uint256) {
        return s.workCheckpoint[a];
    }

    constructor(address initialOwner, address workToken, address imdToken, IPoolManager manager, int24 spacing)
        WorkOwned(initialOwner)
    {
        s.cap = MAX_SUPPLY;
        s.remaining = MAX_SUPPLY;
        s.baseURI = "ipfs://bafybeibmkvtnptsqztdvsm5sh3avormdnfyarbxpgdlcj6bmg37qchhqve/";
        s.royaltyBps = 500;
        s.priceScaleBps = 10000;
        s.target = type(uint256).max >> INITIAL_DIFFICULTY_BITS;
        if (
            workToken == imdToken || workToken.code.length == 0 || imdToken.code.length == 0
                || address(manager).code.length == 0 || spacing <= 0 || spacing > 32767
                || (block.chainid == 4663 && imdToken != ROBINHOOD_IMD) || IERC20Work(workToken).decimals() != 18
        ) revert InvalidParameter();
        uint8 decimals = IERC20Work(imdToken).decimals();
        if (decimals < 2 || decimals > 18) revert InvalidParameter();
        s.work = workToken;
        s.imd = imdToken;
        s.imdUnit = 10 ** decimals;
        s.poolManager = manager;
        s.tickSpacing = spacing;
        s.activationFee = 15 * s.imdUnit / 100;
        s.lastMintTime = block.timestamp;
        s.retargetTime = block.timestamp;
    }

    /// @notice One-time binding, before deposits or minting.
    function setHook(address value) external onlyOwner {
        WorkerSale.setHook(s, value);
    }

    function fundPools() external nonReentrant {
        WorkerFinance.fundPools(s);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd || id == 0x5b5e139f || id == 0x2a55205a || id == 0x49064906;
    }

    function balanceOf(address holder) external view returns (uint256) {
        return WorkerSale.balanceOf(s, holder);
    }

    function ownerOf(uint256 id) public view returns (address holder) {
        return WorkerSale.ownerOf(s, id);
    }

    function totalSupply() external view returns (uint256) {
        return WorkerSale.totalSupply(s);
    }

    function getApproved(uint256 id) external view returns (address) {
        return WorkerSale.getApproved(s, id);
    }

    function approve(address operator, uint256 id) external {
        WorkerSale.approve(s, operator, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        WorkerSale.setApprovalForAll(s, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        WorkerSale.transferFrom(s, from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        WorkerSale.safeTransferFrom(s, from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        WorkerSale.safeTransferFrom(s, from, to, id, data);
    }

    function _transfer(address from, address to, uint256 id) private {
        if (to == address(0)) revert InvalidParameter();
        delete s.approvals[id];
        --s.balances[from];
        ++s.balances[to];
        s.owners[id] = to;
        // Activation, checkpoints and unclaimed WORK are keyed by id and travel with it.
        emit Transfer(from, to, id);
    }

    function _checkReceiver(address from, address to, uint256 id, bytes memory data) private {
        if (
            to.code.length != 0
                && IWorkerReceiver(to).onERC721Received(msg.sender, from, id, data)
                    != IWorkerReceiver.onERC721Received.selector
        ) revert UnsafeRecipient();
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        return WorkerSale.tokenURI(s, id);
    }

    function setBaseURI(string calldata value) external onlyOwner {
        WorkerSale.setBaseURI(s, value);
    }

    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256) {
        return WorkerSale.royaltyInfo(s, tokenId, salePrice);
    }

    function setRoyaltyBps(uint16 value) external onlyOwner {
        if (value > 1000) revert InvalidParameter();
        emit RoyaltyChanged(s.royaltyBps, value);
        s.royaltyBps = value;
    }

    function setCap(uint256 value) external onlyOwner {
        WorkerSale.setCap(s, value);
    }

    function endMint() external onlyOwner {
        WorkerSale.endMint(s);
    }

    function paused() public view returns (bool) {
        return block.timestamp < s.pauseUntil;
    }

    /// @notice Pauses minting and accrual for at most 72 hours; transfers and claims remain available.
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
    }

    function epoch() public view returns (uint256) {
        return WorkerSale.epoch(s);
    }

    function floorBits() public view returns (uint256) {
        return WorkerSale.floorBits(s);
    }

    function setFloorAdjustment(int8 value) external onlyOwner {
        WorkerSale.setFloorAdjustment(s, value);
    }

    function setPriceScaleBps(uint16 value) external onlyOwner {
        if (value < 5000 || value > 10000) revert InvalidParameter();
        emit PriceScaleChanged(s.priceScaleBps, value);
        s.priceScaleBps = value;
    }

    function epochPrice(uint256 e) public view returns (uint256) {
        return WorkerSale.epochPrice(s, e);
    }

    function mintPrice() public view returns (uint256) {
        return WorkerSale.mintPrice(s);
    }

    function currentTarget() public view returns (uint256) {
        return WorkerSale.currentTarget(s);
    }

    function workBlockNumber() public view returns (uint256) {
        return WorkerSale.workBlockNumber(s);
    }

    function anchorHash(uint256 number) public view returns (bytes32 value) {
        return WorkerSale.anchorHash(s, number);
    }

    function workHash(uint256 anchor, address miner, uint256 nonce) public view returns (bytes32) {
        return WorkerSale.workHash(s, anchor, miner, nonce);
    }

    function poolAt(uint256 index) public view returns (uint256) {
        return WorkerSale.poolAt(s, index);
    }

    function mint(uint256 anchor, uint256 nonce) external nonReentrant returns (uint256) {
        return WorkerSale.mint(s, anchor, nonce);
    }

    function mintWithPermit(uint256 anchor, uint256 nonce, uint256 deadline, uint8 v, bytes32 r, bytes32 sigS)
        external
        nonReentrant
        returns (uint256)
    {
        return WorkerSale.mintWithPermit(s, anchor, nonce, deadline, v, r, sigS);
    }

    /// @dev The authenticated hook may credit transferred fees during a guarded buyback.
    /// This operation has no state-changing external call and cannot withdraw funds.
    function notifyHookReward(uint256 amount) external {
        WorkerFinance.notifyHookReward(s, amount);
    }

    function pendingIMD(address account) external view returns (uint256) {
        return WorkerFinance.pendingIMD(s, account);
    }

    function stake(uint256 id, uint256 lockDays) external nonReentrant {
        WorkerFinance.stake(s, id, lockDays);
    }

    function unstake(uint256 id) external nonReentrant {
        WorkerFinance.unstake(s, id);
    }

    function claimIMD() external nonReentrant returns (uint256 amount) {
        return WorkerFinance.claimIMD(s);
    }

    function setActivationFee(uint256 value) external onlyOwner {
        if (value > s.imdUnit / 2) revert InvalidParameter();
        emit ActivationFeeChanged(s.activationFee, value);
        s.activationFee = value;
    }

    function beneficiaryOf(uint256 id) public view returns (address) {
        address holder = WorkerSale.ownerOf(s, id);
        return holder == address(this) ? s.stakes[id].staker : holder;
    }

    function activate(uint256 id) external nonReentrant {
        WorkerFinance.activate(s, id);
    }

    function scheduledEmission(uint256 timestamp) public view returns (uint256 sum) {
        return WorkerFinance.scheduledEmission(s, timestamp);
    }

    function pendingWork(uint256 id) external view returns (uint256) {
        return WorkerFinance.pendingWork(s, id);
    }

    function claimWork(uint256[] calldata ids) external nonReentrant returns (uint256 amount) {
        return WorkerFinance.claimWork(s, ids);
    }

    function burn(uint256 id) external nonReentrant {
        WorkerFinance.burn(s, id);
    }

    function poolKey() public view returns (PoolKey memory) {
        return WorkerFinance.poolKey(s);
    }

    function buyback() external nonReentrant returns (uint256) {
        return WorkerFinance.buyback(s);
    }

    function buyback(uint256 amount, uint256 minWork, uint256 deadline) external nonReentrant returns (uint256) {
        return WorkerFinance.buyback(s, amount, minWork, deadline);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        return WorkerFinance.unlockCallback(s, data);
    }

    function protectedBalance(address token) public view returns (uint256) {
        return WorkerFinance.protectedBalance(s, token);
    }
    receive() external payable {}

    function sweep(address token) external nonReentrant {
        WorkerFinance.sweep(s, token);
    }
}

/// @dev Statically linked implementation library; has no owner or configurable target.
library WorkerSale {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);
    event HookBound(address indexed hook);

    event CapChanged(uint256 oldCap, uint256 newCap);
    event MintEnded(uint256 minted, uint256 timestamp, uint256 burnReward);

    event FloorChanged(int8 oldValue, int8 newValue);

    event BaseURIChanged(string value);
    event TargetChanged(uint256 target);
    event WorkerMinted(
        address indexed minter, uint256 indexed tokenId, bytes32 workHash, bool overclocked, uint256 price
    );

    error MintUnavailable();
    error InvalidWork();
    error InvalidToken();

    error UnsafeRecipient();

    error Unauthorized();
    error InvalidParameter();

    function setHook(WorkerState.Data storage s, address value) internal {
        if (
            s.hook != address(0) || s.minted != 0 || s.poolsFunded || value.code.length == 0
                || address(IWorkHook(value).workers()) != address(this)
                || address(IWorkHook(value).poolManager()) != address(s.poolManager)
        ) revert InvalidParameter();
        s.hook = value;
        emit HookBound(value);
    }

    function balanceOf(WorkerState.Data storage s, address holder) internal view returns (uint256) {
        if (holder == address(0)) revert InvalidParameter();
        return s.balances[holder];
    }

    function ownerOf(WorkerState.Data storage s, uint256 id) internal view returns (address holder) {
        holder = s.owners[id];
        if (holder == address(0)) revert InvalidToken();
    }

    function totalSupply(WorkerState.Data storage s) internal view returns (uint256) {
        return s.minted - s.burned;
    }

    function getApproved(WorkerState.Data storage s, uint256 id) internal view returns (address) {
        ownerOf(s, id);
        return s.approvals[id];
    }

    function approve(WorkerState.Data storage s, address operator, uint256 id) internal {
        address holder = ownerOf(s, id);
        if (msg.sender != holder && !s.isApprovedForAll[holder][msg.sender]) revert Unauthorized();
        s.approvals[id] = operator;
        emit Approval(holder, operator, id);
    }

    function setApprovalForAll(WorkerState.Data storage s, address operator, bool approved) internal {
        if (operator == msg.sender) revert InvalidParameter();
        s.isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(WorkerState.Data storage s, address from, address to, uint256 id) internal {
        if (
            ownerOf(s, id) != from
                || (msg.sender != from && msg.sender != s.approvals[id] && !s.isApprovedForAll[from][msg.sender])
        ) revert Unauthorized();
        // Direct deposits are rejected: WorkerFinance.stake(s) is the sole entry into escrow.
        if (to == address(this)) revert InvalidParameter();
        _transfer(s, from, to, id);
    }

    function safeTransferFrom(WorkerState.Data storage s, address from, address to, uint256 id) internal {
        safeTransferFrom(s, from, to, id, "");
    }

    function safeTransferFrom(WorkerState.Data storage s, address from, address to, uint256 id, bytes memory data)
        internal
    {
        transferFrom(s, from, to, id);
        _checkReceiver(from, to, id, data);
    }

    function _transfer(WorkerState.Data storage s, address from, address to, uint256 id) private {
        if (to == address(0)) revert InvalidParameter();
        delete s.approvals[id];
        --s.balances[from];
        ++s.balances[to];
        s.owners[id] = to;
        // Activation, checkpoints and unclaimed WORK are keyed by id and travel with it.
        emit Transfer(from, to, id);
    }

    function _checkReceiver(address from, address to, uint256 id, bytes memory data) private {
        if (
            to.code.length != 0
                && IWorkerReceiver(to).onERC721Received(msg.sender, from, id, data)
                    != IWorkerReceiver.onERC721Received.selector
        ) revert UnsafeRecipient();
    }

    function tokenURI(WorkerState.Data storage s, uint256 id) internal view returns (string memory) {
        ownerOf(s, id);
        return string.concat(s.baseURI, s.overclocked[id] ? "oc/" : "", _decimal(id), ".json");
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        uint256 digits;
        uint256 tmp = value;
        do {
            ++digits;
            tmp /= 10;
        } while (tmp != 0);
        bytes memory text = new bytes(digits);
        do {
            text[--digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        } while (value != 0);
        return string(text);
    }

    function setBaseURI(WorkerState.Data storage s, string calldata value) internal {
        if (bytes(value).length > 512) revert InvalidParameter();
        s.baseURI = value;
        emit BaseURIChanged(value);
        emit BatchMetadataUpdate(1, WorkerConstants.MAX_SUPPLY);
    }

    function royaltyInfo(WorkerState.Data storage s, uint256, uint256 salePrice)
        internal
        view
        returns (address, uint256)
    {
        return (WorkerConstants.BUILDERS, WorkMath.mulDiv(salePrice, s.royaltyBps, 10000));
    }

    function setCap(WorkerState.Data storage s, uint256 value) internal {
        if (value < s.minted || value > s.cap) revert InvalidParameter();
        emit CapChanged(s.cap, value);
        s.cap = value;
        if (value == s.minted && !s.mintEnded) _endMint(s);
    }

    function endMint(WorkerState.Data storage s) internal {
        if (s.mintEnded) revert MintUnavailable();
        emit CapChanged(s.cap, s.minted);
        s.cap = s.minted;
        _endMint(s);
    }

    function _endMint(WorkerState.Data storage s) private {
        s.mintEnded = true;
        s.mintedAtEnd = s.minted;
        s.mintEndTime = block.timestamp;
        s.lastMiningUpdate = block.timestamp;
        s.burnReward = s.minted == 0 ? 0 : s.burnPool / s.minted;
        emit MintEnded(s.minted, block.timestamp, s.burnReward);
        emit BatchMetadataUpdate(1, WorkerConstants.MAX_SUPPLY);
    }

    function epoch(WorkerState.Data storage s) internal view returns (uint256) {
        uint256 e = s.minted / 370;
        return e > 8 ? 8 : e;
    }

    function floorBits(WorkerState.Data storage s) internal view returns (uint256) {
        return uint256(int256(WorkerConstants.INITIAL_DIFFICULTY_BITS + epoch(s)) + s.floorAdjustment);
    }

    function setFloorAdjustment(WorkerState.Data storage s, int8 value) internal {
        // Absolute +/-2 from the epoch schedule; repeated calls cannot ratchet beyond the bound.
        if (value < -2 || value > 2) revert InvalidParameter();
        emit FloorChanged(s.floorAdjustment, value);
        s.floorAdjustment = value;
        uint256 maximum = type(uint256).max >> floorBits(s);
        if (s.target > maximum) {
            s.target = maximum;
            emit TargetChanged(s.target);
        }
    }

    function epochPrice(WorkerState.Data storage s, uint256 e) internal view returns (uint256) {
        if (e > 8) revert InvalidParameter();
        uint16[9] memory cents = [uint16(25), 50, 75, 125, 175, 250, 325, 400, 500];
        return uint256(cents[e]) * s.imdUnit * s.priceScaleBps / 1_000_000;
    }

    function mintPrice(WorkerState.Data storage s) internal view returns (uint256) {
        return epochPrice(s, epoch(s));
    }

    /// @notice Each full 300 seconds idle doubles target, saturating at the epoch floor.
    function currentTarget(WorkerState.Data storage s) internal view returns (uint256) {
        uint256 maximum = type(uint256).max >> floorBits(s);
        uint256 steps = (block.timestamp - s.lastMintTime) / 300;
        if (steps >= 256 || s.target > (maximum >> steps)) return maximum;
        return s.target << steps;
    }

    /// @notice Nitro local L2 blocks, rather than its parent-chain block.number.
    function workBlockNumber(WorkerState.Data storage) internal view returns (uint256) {
        return block.chainid == 4663 ? IArbWorkBlocks(address(100)).arbBlockNumber() : block.number;
    }

    function anchorHash(WorkerState.Data storage s, uint256 number) internal view returns (bytes32 value) {
        uint256 current = workBlockNumber(s);
        if (number >= current || current - number > 250) revert InvalidWork();
        value = block.chainid == 4663 ? IArbWorkBlocks(address(100)).arbBlockHash(number) : blockhash(number);
        if (value == bytes32(0)) revert InvalidWork();
    }

    function workHash(WorkerState.Data storage s, uint256 anchor, address miner, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                WorkerConstants.DOMAIN,
                block.chainid,
                address(this),
                keccak256(abi.encode(anchorHash(s, anchor), s.prevWork)),
                miner,
                nonce
            )
        );
    }

    function poolAt(WorkerState.Data storage s, uint256 index) internal view returns (uint256) {
        if (index >= s.remaining) revert InvalidParameter();
        uint256 id = s.idPool[index];
        return id == 0 ? index + 1 : id;
    }

    function mint(WorkerState.Data storage s, uint256 anchor, uint256 nonce) internal returns (uint256) {
        return _mintWork(s, anchor, nonce);
    }

    function mintWithPermit(
        WorkerState.Data storage s,
        uint256 anchor,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 sigS
    ) internal returns (uint256) {
        // A previously submitted permit may have consumed its nonce. Existing allowance still works.
        try IWorkerPermit(s.imd).permit(msg.sender, address(this), mintPrice(s), deadline, v, r, sigS) {} catch {}
        return _mintWork(s, anchor, nonce);
    }

    function _mintWork(WorkerState.Data storage s, uint256 anchor, uint256 nonce) private returns (uint256 id) {
        uint256 currentBlock = workBlockNumber(s);
        if (
            s.mintEnded || (block.timestamp < s.pauseUntil) || s.minted >= s.cap || !s.poolsFunded
                || currentBlock == s.lastMintBlock
        ) revert MintUnavailable();
        bytes32 hash = workHash(s, anchor, msg.sender, nonce);
        uint256 threshold = currentTarget(s);
        if (uint256(hash) >= threshold) revert InvalidWork();
        uint256 price = mintPrice(s);
        uint256 index = uint256(hash) % s.remaining;
        id = poolAt(s, index);
        s.idPool[index] = poolAt(s, s.remaining - 1);
        delete s.idPool[s.remaining - 1];
        --s.remaining;
        ++s.minted;
        s.owners[id] = msg.sender;
        ++s.balances[msg.sender];
        s.overclocked[id] = uint256(hash) < (threshold >> 4);
        s.prevWork = hash;
        s.lastMintBlock = currentBlock;
        s.lastMintTime = block.timestamp;
        s.target = threshold;
        if (s.minted % 8 == 0) {
            uint256 elapsed = block.timestamp - s.retargetTime;
            if (elapsed < 20) elapsed = 20;
            if (elapsed > 320) elapsed = 320;
            s.target = threshold * elapsed / 80;
            if (s.target == 0) s.target = 1;
            s.retargetTime = block.timestamp;
        }
        uint256 maximum = type(uint256).max >> floorBits(s);
        if (s.target > maximum) s.target = maximum;
        emit TargetChanged(s.target);
        if (s.minted == s.cap) _endMint(s);
        emit Transfer(address(0), msg.sender, id);
        emit WorkerMinted(msg.sender, id, hash, s.overclocked[id], price);
        WorkTransfer.pull(s.imd, msg.sender, price);
        WorkerFinance._splitMint(s, price);
        _checkReceiver(address(0), msg.sender, id, "");
    }
}

/// @dev Statically linked implementation library; has no owner or configurable target.
library WorkerFinance {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    event MetadataUpdate(uint256 tokenId);

    event PoolsFunded(uint256 mining, uint256 burn);

    event MintPayment(uint256 stakers, uint256 buyback, uint256 builders);
    event Staked(address indexed staker, uint256 indexed tokenId, uint256 unlockAt, uint256 weight);
    event Unstaked(address indexed staker, uint256 indexed tokenId);
    event IMDReward(uint256 amount);
    event IMDClaimed(address indexed staker, uint256 amount);
    event Activated(uint256 indexed tokenId);
    event WorkClaimed(address indexed holder, uint256 amount);
    event WorkerBurned(address indexed holder, uint256 indexed tokenId, uint256 reward);
    event Buyback(uint256 imdSpent, uint256 workBurned);
    event Swept(address indexed token, uint256 amount);
    error MintUnavailable();

    error InvalidToken();
    error Locked();
    error Insolvent();
    error UnsafeRecipient();
    error SwapFailed();
    error Unauthorized();
    error InvalidParameter();

    function fundPools(WorkerState.Data storage s) internal {
        if (msg.sender != WorkerConstants.BUILDERS) revert Unauthorized();
        if (s.poolsFunded || s.mintEnded || s.hook == address(0)) revert InvalidParameter();
        s.poolsFunded = true;
        s.miningPool = WorkerConstants.MINING_ALLOCATION;
        s.burnPool = WorkerConstants.BURN_ALLOCATION;
        WorkTransfer.pull(s.work, msg.sender, WorkerConstants.MINING_ALLOCATION + WorkerConstants.BURN_ALLOCATION);
        emit PoolsFunded(WorkerConstants.MINING_ALLOCATION, WorkerConstants.BURN_ALLOCATION);
    }

    function _transfer(WorkerState.Data storage s, address from, address to, uint256 id) private {
        if (to == address(0)) revert InvalidParameter();
        delete s.approvals[id];
        --s.balances[from];
        ++s.balances[to];
        s.owners[id] = to;
        // Activation, checkpoints and unclaimed WORK are keyed by id and travel with it.
        emit Transfer(from, to, id);
    }

    function _checkReceiver(address from, address to, uint256 id, bytes memory data) private {
        if (
            to.code.length != 0
                && IWorkerReceiver(to).onERC721Received(msg.sender, from, id, data)
                    != IWorkerReceiver.onERC721Received.selector
        ) revert UnsafeRecipient();
    }

    function _splitMint(WorkerState.Data storage s, uint256 price) internal {
        uint256 stakers = price * 65 / 100;
        uint256 buybackShare = price * 25 / 100;
        uint256 builders = price - stakers - buybackShare;
        if (s.totalWeight == 0) {
            buybackShare += stakers;
            stakers = 0;
        } else {
            _creditIMD(s, stakers);
        }
        s.buybackBalance += buybackShare;
        WorkTransfer.send(s.imd, WorkerConstants.BUILDERS, builders);
        emit MintPayment(stakers, buybackShare, builders);
    }

    function _creditIMD(WorkerState.Data storage s, uint256 amount) private {
        s.stakerReserve += amount;
        s.accIMDPerWeight += WorkMath.mulDiv(amount, WorkerConstants.SCALE, s.totalWeight);
        emit IMDReward(amount);
    }

    function notifyHookReward(WorkerState.Data storage s, uint256 amount) internal {
        if (msg.sender != s.hook || !s.mintEnded || s.totalWeight == 0) revert Unauthorized();
        if (IERC20Work(s.imd).balanceOf(address(this)) < s.stakerReserve + s.buybackBalance + amount) {
            revert Insolvent();
        }
        _creditIMD(s, amount);
    }

    function _settleIMD(WorkerState.Data storage s, address account) private {
        s.imdCredit[account] += s.userWeight[account] * (s.accIMDPerWeight - s.userIMDCheckpoint[account]);
        s.userIMDCheckpoint[account] = s.accIMDPerWeight;
    }

    function pendingIMD(WorkerState.Data storage s, address account) internal view returns (uint256) {
        return (s.imdCredit[account] + s.userWeight[account] * (s.accIMDPerWeight - s.userIMDCheckpoint[account]))
            / WorkerConstants.SCALE;
    }

    function stake(WorkerState.Data storage s, uint256 id, uint256 lockDays) internal {
        if (_ownerOf(s, id) != msg.sender) revert Unauthorized();
        uint8 weight = lockDays == 7 ? 1 : lockDays == 14 ? 2 : lockDays == 30 ? 4 : 0;
        if (weight == 0) revert InvalidParameter();
        _settleIMD(s, msg.sender);
        s.stakes[id] = WorkerState.Stake(msg.sender, uint64(block.timestamp + lockDays * 1 days), weight);
        s.totalWeight += weight;
        s.userWeight[msg.sender] += weight;
        _transfer(s, msg.sender, address(this), id);
        emit Staked(msg.sender, id, s.stakes[id].unlockAt, weight);
        emit MetadataUpdate(id);
    }

    function unstake(WorkerState.Data storage s, uint256 id) internal {
        WorkerState.Stake memory position = s.stakes[id];
        if (position.staker != msg.sender) revert Unauthorized();
        if (block.timestamp < position.unlockAt) revert Locked();
        _settleIMD(s, msg.sender);
        s.totalWeight -= position.weight;
        s.userWeight[msg.sender] -= position.weight;
        delete s.stakes[id];
        _transfer(s, address(this), msg.sender, id);
        emit Unstaked(msg.sender, id);
        emit MetadataUpdate(id);
        _checkReceiver(address(this), msg.sender, id, "");
    }

    function claimIMD(WorkerState.Data storage s) internal returns (uint256 amount) {
        _settleIMD(s, msg.sender);
        amount = s.imdCredit[msg.sender] / WorkerConstants.SCALE;
        s.imdCredit[msg.sender] %= WorkerConstants.SCALE;
        s.stakerReserve -= amount;
        WorkTransfer.send(s.imd, msg.sender, amount);
        emit IMDClaimed(msg.sender, amount);
    }

    function activate(WorkerState.Data storage s, uint256 id) internal {
        if (!s.mintEnded || s.activated[id]) revert InvalidParameter();
        if (_beneficiaryOf(s, id) != msg.sender) revert Unauthorized();
        _updateMining(s);
        s.activated[id] = true;
        ++s.activeWorkers;
        s.workCheckpoint[id] = s.accWorkPerWorker;
        uint256 fee = s.activationFee;
        if (fee != 0) {
            WorkTransfer.pull(s.imd, msg.sender, fee);
            WorkTransfer.send(s.imd, WorkerConstants.BUILDERS, fee);
        }
        emit Activated(id);
        emit MetadataUpdate(id);
    }

    function scheduledEmission(WorkerState.Data storage s, uint256 timestamp) internal view returns (uint256 sum) {
        if (!s.mintEnded || timestamp <= s.mintEndTime) return 0;
        uint256 elapsed = timestamp - s.mintEndTime;
        for (uint256 k; k < 8; ++k) {
            uint256 duration = (7 days) << k;
            if (elapsed < duration) {
                sum += WorkerConstants.ERA_EMISSION * elapsed / duration;
                break;
            }
            sum += WorkerConstants.ERA_EMISSION;
            elapsed -= duration;
        }
    }

    /// @dev Eras are measured from mint end. Paused time and time without active workers
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
        if (amount != 0) {
            s.miningPool -= amount;
            s.workReserve += amount;
            s.accWorkPerWorker += amount * WorkerConstants.SCALE / s.activeWorkers;
        }
        if (s.mintEnded) s.lastMiningUpdate = block.timestamp;
    }

    function pendingWork(WorkerState.Data storage s, uint256 id) internal view returns (uint256) {
        _ownerOf(s, id);
        if (!s.activated[id]) return 0;
        uint256 accumulator = s.accWorkPerWorker + _newEmission(s) * WorkerConstants.SCALE / s.activeWorkers;
        return (s.workCredit[id] + accumulator - s.workCheckpoint[id]) / WorkerConstants.SCALE;
    }

    function _claimWorker(WorkerState.Data storage s, uint256 id) private returns (uint256 amount) {
        if (!s.activated[id]) return 0;
        uint256 credit = s.workCredit[id] + s.accWorkPerWorker - s.workCheckpoint[id];
        amount = credit / WorkerConstants.SCALE;
        s.workCredit[id] = credit % WorkerConstants.SCALE;
        s.workCheckpoint[id] = s.accWorkPerWorker;
    }

    function claimWork(WorkerState.Data storage s, uint256[] calldata ids) internal returns (uint256 amount) {
        _updateMining(s);
        for (uint256 i; i < ids.length; ++i) {
            if (_beneficiaryOf(s, ids[i]) != msg.sender) revert Unauthorized();
            amount += _claimWorker(s, ids[i]);
            emit MetadataUpdate(ids[i]);
        }
        s.workReserve -= amount;
        WorkTransfer.send(s.work, msg.sender, amount);
        emit WorkClaimed(msg.sender, amount);
    }

    function burn(WorkerState.Data storage s, uint256 id) internal {
        if (!s.mintEnded) revert MintUnavailable();
        if (_ownerOf(s, id) != msg.sender) revert Unauthorized();
        _updateMining(s);
        uint256 accrued = _claimWorker(s, id);
        if (s.activated[id]) {
            --s.activeWorkers;
            s.activated[id] = false;
        }
        delete s.owners[id];
        delete s.approvals[id];
        delete s.workCredit[id];
        --s.balances[msg.sender];
        ++s.burned;
        s.burnPool -= s.burnReward;
        s.workReserve -= accrued;
        emit Transfer(msg.sender, address(0), id);
        emit MetadataUpdate(id);
        emit WorkerBurned(msg.sender, id, s.burnReward);
        WorkTransfer.send(s.work, msg.sender, s.burnReward + accrued);
    }

    function poolKey(WorkerState.Data storage s) internal view returns (PoolKey memory) {
        bool imdIs0 = s.imd < s.work;
        return PoolKey(
            Currency.wrap(imdIs0 ? s.imd : s.work), Currency.wrap(imdIs0 ? s.work : s.imd), 12500, s.tickSpacing, s.hook
        );
    }

    function buyback(WorkerState.Data storage s) internal returns (uint256) {
        uint256 amount = s.buybackBalance;
        if (amount > 100 * s.imdUnit) amount = 100 * s.imdUnit;
        return _buyback(s, amount, 0);
    }

    function buyback(WorkerState.Data storage s, uint256 amount, uint256 minWork, uint256 deadline)
        internal
        returns (uint256)
    {
        if (block.timestamp > deadline) revert InvalidParameter();
        return _buyback(s, amount, minWork);
    }

    function _buyback(WorkerState.Data storage s, uint256 amount, uint256 minWork) private returns (uint256 output) {
        if (
            amount == 0 || amount > 100 * s.imdUnit || amount > s.buybackBalance
                || (s.lastBuybackTime != 0 && block.timestamp < s.lastBuybackTime + 60)
        ) revert InvalidParameter();
        uint256 minimum = IWorkHook(s.hook).minimumBuybackOutput(amount);
        if (minimum == 0) revert SwapFailed();
        if (minWork < minimum) minWork = minimum;
        s.buybackBalance -= amount;
        s.lastBuybackTime = block.timestamp;
        s.buying = true;
        output = abi.decode(s.poolManager.unlock(abi.encode(amount, minWork)), (uint256));
        s.buying = false;
        emit Buyback(amount, output);
    }

    function unlockCallback(WorkerState.Data storage s, bytes calldata data) internal returns (bytes memory) {
        if (msg.sender != address(s.poolManager) || !s.buying) revert Unauthorized();
        s.buying = false;
        (uint256 amount, uint256 minWork) = abi.decode(data, (uint256, uint256));
        bool zeroForOne = s.imd < s.work;
        BalanceDelta delta = s.poolManager
            .swap(
                poolKey(s),
                SwapParams(
                    zeroForOne,
                    -int256(amount),
                    zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341)
                ),
                ""
            );
        int128 input = zeroForOne ? int128(BalanceDelta.unwrap(delta) >> 128) : int128(BalanceDelta.unwrap(delta));
        int128 output = zeroForOne ? int128(BalanceDelta.unwrap(delta)) : int128(BalanceDelta.unwrap(delta) >> 128);
        if (int256(input) != -int256(amount) || output <= 0 || uint128(output) < minWork) revert SwapFailed();
        s.poolManager.sync(Currency.wrap(s.imd));
        WorkTransfer.send(s.imd, address(s.poolManager), amount);
        if (s.poolManager.settle() != amount) revert SwapFailed();
        uint256 beforeBalance = IERC20Work(s.work).balanceOf(address(this));
        s.poolManager.take(Currency.wrap(s.work), address(this), uint128(output));
        if (IERC20Work(s.work).balanceOf(address(this)) != beforeBalance + uint128(output)) revert SwapFailed();
        IERC20Work(s.work).burn(uint128(output));
        if (IERC20Work(s.work).balanceOf(address(this)) != beforeBalance) revert SwapFailed();
        return abi.encode(uint256(uint128(output)));
    }

    function protectedBalance(WorkerState.Data storage s, address token) internal view returns (uint256) {
        if (token == s.imd) return s.stakerReserve + s.buybackBalance;
        if (token == s.work) return s.miningPool + s.burnPool + s.workReserve;
        return 0;
    }

    function sweep(WorkerState.Data storage s, address token) internal {
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            (bool ok,) = WorkerConstants.BUILDERS.call{value: amount}("");
            if (!ok) revert InvalidParameter();
        } else {
            uint256 balance = IERC20Work(token).balanceOf(address(this));
            uint256 reserved = protectedBalance(s, token);
            if (balance < reserved) revert Insolvent();
            amount = balance - reserved;
            WorkTransfer.send(token, WorkerConstants.BUILDERS, amount);
        }
        emit Swept(token, amount);
    }

    function _ownerOf(WorkerState.Data storage s, uint256 id) private view returns (address h) {
        h = s.owners[id];
        if (h == address(0)) revert InvalidToken();
    }

    function _beneficiaryOf(WorkerState.Data storage s, uint256 id) private view returns (address) {
        address h = _ownerOf(s, id);
        return h == address(this) ? s.stakes[id].staker : h;
    }
}
