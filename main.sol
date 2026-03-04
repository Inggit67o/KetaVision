// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title KetaVision
/// @notice AI-assisted kitchen planning registry for on-chain layout summaries and ratings.
///
/// Kitchen plans are registered with layout style (0..KV_MAX_STYLE), risk tier (0..KV_MAX_TIER),
/// ceiling height, floor area in cm², and appliance count. Oracle can pin plans; auditor can
/// soft-delete. Anyone can rate a plan once (ergonomics, storage, vibe 1–10). Optional protocol
/// fee on rating (feeBps, max 5%) is sent to treasury. Owner configures oracle, auditor, treasury,
/// fee, and namespace pause. All role addresses are set in constructor or via owner; no
/// hard-coded literals. Safe for mainnet when deployed with correct roles.

contract KetaVision {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event KitchenSketched(
        bytes32 indexed planId,
        address indexed creator,
        uint8 layoutStyle,
        uint8 riskTier,
        uint32 ceilingHeightCm,
        uint32 areaCm2,
        uint16 applianceCount,
        uint64 createdAt
    );

    event PlanRated(
        bytes32 indexed planId,
        address indexed rater,
        uint8 ergonomicsScore,
        uint8 storageScore,
        uint8 vibeScore,
        uint64 ratedAt
    );

    event PlanPinned(bytes32 indexed planId, address indexed by, uint64 pinnedAt);
    event PlanSoftDeleted(bytes32 indexed planId, address indexed by, uint64 deletedAt);

    event OracleUpdated(address indexed previous, address indexed current, uint256 atBlock);
    event AuditorUpdated(address indexed previous, address indexed current, uint256 atBlock);
    event TreasuryUpdated(address indexed previous, address indexed current, uint256 atBlock);
    event FeeBpsUpdated(uint256 previous, uint256 current, uint256 atBlock);
    event NamespacePaused(bytes32 indexed ns, bool paused, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error KV_NotOwner();
    error KV_NotOracle();
    error KV_NotAuditor();
    error KV_ZeroAddress();
    error KV_ZeroPlan();
    error KV_ZeroArea();
    error KV_AlreadyExists();
    error KV_NotFound();
    error KV_AlreadyDeleted();
    error KV_InvalidStyle();
    error KV_InvalidTier();
    error KV_InvalidScore();
    error KV_Reentrant();
    error KV_TooManyPlans();
    error KV_TooManyRatings();
    error KV_InvalidFeeBps();
    error KV_NamespaceLocked();
    error KV_InsufficientFee();
    error KV_InvalidIndex();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant KV_FEE_DENOM_BPS = 10_000;
    uint256 public constant KV_MAX_STYLE = 15;
    uint256 public constant KV_MAX_TIER = 6;
    uint256 public constant KV_MAX_PLANS = 200_000;
    uint256 public constant KV_MAX_RATINGS_PER_PLAN = 512;

    bytes32 public constant KV_NAMESPACE = keccak256("KetaVision.kitchen.v1");
    bytes32 public constant KV_VERSION = keccak256("ketavision.version.1");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable owner;
    address public immutable deployer;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    address public oracle;
    address public auditor;
    address public treasury;
    uint256 public feeBps;

    uint256 private _lock;
    bool private _namespacePaused;

    struct Plan {
        bytes32 planId;
        address creator;
        uint8 layoutStyle;
        uint8 riskTier;
        uint32 ceilingHeightCm;
        uint32 areaCm2;
        uint16 applianceCount;
        bool exists;
        bool softDeleted;
        bool pinned;
        uint64 createdAt;
    }

    struct RatingSummary {
        uint32 ergonomicsTotal;
        uint32 storageTotal;
        uint32 vibeTotal;
        uint32 ratingCount;
    }

    mapping(bytes32 => Plan) private _plans;
    mapping(bytes32 => RatingSummary) private _ratingSummary;
    mapping(bytes32 => mapping(address => bool)) private _ratedByUser;

    bytes32[] private _planIds;
    uint256 public planCount;

    // Layout styles 0..15: 0=minimalist, 1=warm-wood, 2=industrial, 3=scandi, 4=neo-classic,
    // 5=maximalist, 6=galley-optimized, 7=island-centric, 8=chef-lab, 9=family-hub, 10..15=custom.
    // Risk tiers 0..6: 0=chill, 1=low, 2=medium, 3=high, 4=degen, 5=max-degen, 6=experimental.
    // Plans are stored by bytes32 planId; use derivePlanId(creator, seed, salt) for deterministic ids.
    // Rating scores 1..10 for ergonomics, storage, vibe; each address can rate each plan at most once.
    // Oracle can pin/unpin plans for featured display; auditor can soft-delete inappropriate plans.
    // Owner can update oracle, auditor, treasury, feeBps (max 500 = 5%), and pause the namespace.
    // Reentrancy guard protects registerPlan and ratePlan; pull-payment pattern for fee and refunds.
    //
    // Gas considerations: registerPlan writes one Plan + one push; ratePlan updates RatingSummary
    // and _ratedByUser; batch view functions iterate over input arrays — cap batch size off-chain.
    // Plan and RatingSummary are in separate mappings to keep SLOAD costs predictable.
    // Events KitchenSketched and PlanRated include all relevant fields for indexers.
    // Soft-deleted plans remain in _planIds but are excluded from pin and rate logic.
    // Pinned plans can be queried via getPlanIdsPinned for front-end featured sections.
    // Fee on rating is optional (feeBps=0 means no fee); excess msg.value is refunded.
    // Treasury receives the fee when feeBps > 0; if treasury is zero address behavior is unchanged
    // but fee transfer would fail so feeBps should be 0 or treasury set before enabling fee.
    // Namespace pause blocks registerPlan and ratePlan; admin actions (pin, softDelete, config) remain.
    // No time locks or multi-sig in this contract; owner is single EOA or contract as deployed.
    //
    // Off-chain: index KitchenSketched and PlanRated for search by creator, riskTier, layoutStyle;
    // use getPlansInRange and getPlanFull for bulk sync; use getPlanIdsForRiskTier for tier filters.
    // requiredRatingFeeWei() and quoteFeeForAmount(amount) for UI fee display when feeBps > 0.
    //
    // View function index: getPlan, getPlanCreator, getPlanLayoutStyle, getPlanRiskTier, getPlanCeilingHeightCm,
    // getPlanAreaCm2, getPlanApplianceCount, getPlanCreatedAt, planExists, planIsPinned, planIsSoftDeleted,
    // getRatingSummary, getAvgErgonomics, getAvgStorage, getAvgVibe, hasRated, getPlanIdAt, getPlanIdsInRange,
    // getAllPlanIds, getPlansBatch, getRatingSummariesBatch, getPlansInRange, getPlanIdsForCreator,
    // getPlanIdsForRiskTier, getPlanIdsPinned, getPlanFull, creatorOf, layoutStyleOf, riskTierOf, areaCm2Of,
    // applianceCountOf, createdAtOf, ceilingHeightCmOf, exists, softDeleted, pinned, countPlansByRiskTier,
    // countPlansByLayoutStyle, wouldRegisterSucceed, wouldRateSucceed, getGlobalState, contractBalanceWei,
    // isPlanActive, requiredRatingFeeWei, quoteFeeForAmount, planIdAt, totalPlanCount, currentFeeBps,
    // namespacePaused, balanceWei, getRatingCount, getErgonomicsTotal, getStorageTotal, getVibeTotal.

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert KV_NotOwner();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert KV_NotOracle();
        _;
    }

    modifier onlyAuditor() {
        if (msg.sender != auditor) revert KV_NotAuditor();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 0) revert KV_Reentrant();
        _lock = 1;
        _;
        _lock = 0;
    }

    modifier whenNamespaceActive() {
        if (_namespacePaused) revert KV_NamespaceLocked();
        _;
    }

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        owner = msg.sender;
        deployer = msg.sender;
        oracle = msg.sender;
        auditor = msg.sender;
        treasury = msg.sender;
        feeBps = 0;
    }

    // -------------------------------------------------------------------------
    // ADMIN CONFIG
    // -------------------------------------------------------------------------

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert KV_ZeroAddress();
        address previous = oracle;
        oracle = newOracle;
        emit OracleUpdated(previous, newOracle, block.number);
    }

    function setAuditor(address newAuditor) external onlyOwner {
        if (newAuditor == address(0)) revert KV_ZeroAddress();
        address previous = auditor;
        auditor = newAuditor;
        emit AuditorUpdated(previous, newAuditor, block.number);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert KV_ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury, block.number);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > 500) revert KV_InvalidFeeBps(); // max 5%
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsUpdated(prev, newFeeBps, block.number);
    }

    function setNamespacePaused(bool paused) external onlyOwner {
        _namespacePaused = paused;
        emit NamespacePaused(KV_NAMESPACE, paused, block.number);
    }

    // -------------------------------------------------------------------------
    // CORE: PLAN REGISTRATION
    // -------------------------------------------------------------------------

    function registerPlan(
        bytes32 planId,
        uint8 layoutStyle,
        uint8 riskTier,
        uint32 ceilingHeightCm,
        uint32 areaCm2,
        uint16 applianceCount
    ) external whenNamespaceActive nonReentrant {
        if (planId == bytes32(0)) revert KV_ZeroPlan();
        if (_plans[planId].exists) revert KV_AlreadyExists();
        if (planCount >= KV_MAX_PLANS) revert KV_TooManyPlans();
        if (areaCm2 == 0) revert KV_ZeroArea();
        if (layoutStyle > KV_MAX_STYLE) revert KV_InvalidStyle();
        if (riskTier > KV_MAX_TIER) revert KV_InvalidTier();

        Plan memory p = Plan({
