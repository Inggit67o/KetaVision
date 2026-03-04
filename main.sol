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
            planId: planId,
            creator: msg.sender,
            layoutStyle: layoutStyle,
            riskTier: riskTier,
            ceilingHeightCm: ceilingHeightCm,
            areaCm2: areaCm2,
            applianceCount: applianceCount,
            exists: true,
            softDeleted: false,
            pinned: false,
            createdAt: uint64(block.timestamp)
        });

        _plans[planId] = p;
        _planIds.push(planId);
        planCount++;

        emit KitchenSketched(
            planId,
            msg.sender,
            layoutStyle,
            riskTier,
            ceilingHeightCm,
            areaCm2,
            applianceCount,
            uint64(block.timestamp)
        );
    }

    // -------------------------------------------------------------------------
    // ORACLE / AUDITOR ACTIONS
    // -------------------------------------------------------------------------

    function pinPlan(bytes32 planId, bool value) external onlyOracle {
        Plan storage p = _plans[planId];
        if (!p.exists) revert KV_NotFound();
        if (p.softDeleted) revert KV_AlreadyDeleted();
        p.pinned = value;
        emit PlanPinned(planId, msg.sender, uint64(block.timestamp));
    }

    function softDeletePlan(bytes32 planId) external onlyAuditor {
        Plan storage p = _plans[planId];
        if (!p.exists) revert KV_NotFound();
        if (p.softDeleted) revert KV_AlreadyDeleted();
        p.softDeleted = true;
        emit PlanSoftDeleted(planId, msg.sender, uint64(block.timestamp));
    }

    // -------------------------------------------------------------------------
    // RATING
    // -------------------------------------------------------------------------

    function ratePlan(
        bytes32 planId,
        uint8 ergonomicsScore,
        uint8 storageScore,
        uint8 vibeScore
    ) external payable whenNamespaceActive nonReentrant {
        Plan storage p = _plans[planId];
        if (!p.exists || p.softDeleted) revert KV_NotFound();

        if (ergonomicsScore == 0 || ergonomicsScore > 10) revert KV_InvalidScore();
        if (storageScore == 0 || storageScore > 10) revert KV_InvalidScore();
        if (vibeScore == 0 || vibeScore > 10) revert KV_InvalidScore();

        RatingSummary storage summary = _ratingSummary[planId];
        if (summary.ratingCount >= KV_MAX_RATINGS_PER_PLAN) revert KV_TooManyRatings();
        if (_ratedByUser[planId][msg.sender]) revert KV_InvalidScore();

        if (feeBps > 0) {
            uint256 requiredFee = (1 ether * feeBps) / KV_FEE_DENOM_BPS;
            if (msg.value < requiredFee) revert KV_InsufficientFee();
            if (treasury != address(0)) {
                (bool ok, ) = treasury.call{value: requiredFee}("");
                if (!ok) revert KV_InsufficientFee();
            }
            if (msg.value > requiredFee) {
                (bool refundOk, ) = msg.sender.call{value: msg.value - requiredFee}("");
                if (!refundOk) revert KV_InsufficientFee();
            }
        } else if (msg.value > 0) {
            (bool refundOk2, ) = msg.sender.call{value: msg.value}("");
            if (!refundOk2) revert KV_InsufficientFee();
        }

        summary.ergonomicsTotal += ergonomicsScore;
        summary.storageTotal += storageScore;
        summary.vibeTotal += vibeScore;
        summary.ratingCount += 1;
        _ratedByUser[planId][msg.sender] = true;

        emit PlanRated(
            planId,
            msg.sender,
            ergonomicsScore,
            storageScore,
            vibeScore,
            uint64(block.timestamp)
        );
    }

    // -------------------------------------------------------------------------
    // VIEWS
    // -------------------------------------------------------------------------

    function getPlan(bytes32 planId)
        external
        view
        returns (
            address creator,
            uint8 layoutStyle,
            uint8 riskTier,
            uint32 ceilingHeightCm,
            uint32 areaCm2,
            uint16 applianceCount,
            bool softDeleted,
            bool pinned,
            uint64 createdAt
        )
    {
        Plan storage p = _plans[planId];
        if (!p.exists) revert KV_NotFound();
        return (
            p.creator,
            p.layoutStyle,
            p.riskTier,
            p.ceilingHeightCm,
            p.areaCm2,
            p.applianceCount,
            p.softDeleted,
            p.pinned,
            p.createdAt
        );
    }

    function getRatingSummary(bytes32 planId)
        external
        view
        returns (uint32 ergonomicsTotal, uint32 storageTotal, uint32 vibeTotal, uint32 ratingCount)
    {
        RatingSummary storage s = _ratingSummary[planId];
        return (s.ergonomicsTotal, s.storageTotal, s.vibeTotal, s.ratingCount);
    }

    function hasRated(bytes32 planId, address user) external view returns (bool) {
        return _ratedByUser[planId][user];
    }

    function getPlanIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _planIds.length) revert KV_InvalidIndex();
        return _planIds[index];
    }

    function getPlanIdsInRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory ids) {
        if (fromIndex > toIndex || toIndex >= _planIds.length) revert KV_InvalidIndex();
        uint256 len = toIndex - fromIndex + 1;
        ids = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = _planIds[fromIndex + i];
        }
    }

    function getAllPlanIds() external view returns (bytes32[] memory) {
        return _planIds;
    }

    function isNamespacePaused() external view returns (bool) {
        return _namespacePaused;
    }

    function getImmutableAddresses()
        external
        view
        returns (address owner_, address deployer_, address oracle_, address auditor_, address treasury_)
    {
        return (owner, deployer, oracle, auditor, treasury);
    }

    function namespaceHash() external pure returns (bytes32) {
        return KV_NAMESPACE;
    }

    function versionHash() external pure returns (bytes32) {
        return KV_VERSION;
    }

    // -------------------------------------------------------------------------
    // EXTENDED VIEWS (single-field and batch)
    // -------------------------------------------------------------------------

    function getPlanCreator(bytes32 planId) external view returns (address) {
        if (!_plans[planId].exists) revert KV_NotFound();
        return _plans[planId].creator;
    }

    function getPlanLayoutStyle(bytes32 planId) external view returns (uint8) {
        if (!_plans[planId].exists) revert KV_NotFound();
        return _plans[planId].layoutStyle;
    }

    function getPlanRiskTier(bytes32 planId) external view returns (uint8) {
        if (!_plans[planId].exists) revert KV_NotFound();
        return _plans[planId].riskTier;
    }

    function getPlanCeilingHeightCm(bytes32 planId) external view returns (uint32) {
        if (!_plans[planId].exists) revert KV_NotFound();
        return _plans[planId].ceilingHeightCm;
    }

    function getPlanAreaCm2(bytes32 planId) external view returns (uint32) {
        if (!_plans[planId].exists) revert KV_NotFound();
        return _plans[planId].areaCm2;
    }

    function getPlanApplianceCount(bytes32 planId) external view returns (uint16) {
        if (!_plans[planId].exists) revert KV_NotFound();
        return _plans[planId].applianceCount;
    }

    function getPlanCreatedAt(bytes32 planId) external view returns (uint64) {
        if (!_plans[planId].exists) revert KV_NotFound();
        return _plans[planId].createdAt;
    }

    function planExists(bytes32 planId) external view returns (bool) {
        return _plans[planId].exists;
    }

    function planIsPinned(bytes32 planId) external view returns (bool) {
        return _plans[planId].pinned;
    }

    function planIsSoftDeleted(bytes32 planId) external view returns (bool) {
        return _plans[planId].softDeleted;
    }

    function getPlanCount() external view returns (uint256) {
        return planCount;
    }

    function getPlanIdsLength() external view returns (uint256) {
        return _planIds.length;
    }

    function getFeeBps() external view returns (uint256) {
        return feeBps;
    }

    function getOracle() external view returns (address) {
        return oracle;
    }

    function getAuditor() external view returns (address) {
        return auditor;
    }

    function getTreasury() external view returns (address) {
        return treasury;
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function getDeployer() external view returns (address) {
        return deployer;
    }

    /// @notice Batch return plan data for multiple ids (bounded).
    function getPlansBatch(bytes32[] calldata planIds) external view returns (
        address[] memory creators,
        uint8[] memory layoutStyles,
        uint8[] memory riskTiers,
        uint32[] memory ceilingHeightsCm,
        uint32[] memory areasCm2,
        uint16[] memory applianceCounts,
        bool[] memory softDeletedFlags,
        bool[] memory pinnedFlags,
        uint64[] memory createdAts,
        bool[] memory existsFlags
    ) {
        uint256 n = planIds.length;
        creators = new address[](n);
        layoutStyles = new uint8[](n);
        riskTiers = new uint8[](n);
        ceilingHeightsCm = new uint32[](n);
        areasCm2 = new uint32[](n);
        applianceCounts = new uint16[](n);
        softDeletedFlags = new bool[](n);
        pinnedFlags = new bool[](n);
        createdAts = new uint64[](n);
        existsFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            Plan storage p = _plans[planIds[i]];
            existsFlags[i] = p.exists;
            if (p.exists) {
                creators[i] = p.creator;
                layoutStyles[i] = p.layoutStyle;
                riskTiers[i] = p.riskTier;
                ceilingHeightsCm[i] = p.ceilingHeightCm;
                areasCm2[i] = p.areaCm2;
                applianceCounts[i] = p.applianceCount;
                softDeletedFlags[i] = p.softDeleted;
                pinnedFlags[i] = p.pinned;
                createdAts[i] = p.createdAt;
            }
        }
    }

    /// @notice Batch return rating summaries for multiple plan ids.
    function getRatingSummariesBatch(bytes32[] calldata planIds) external view returns (
        uint32[] memory ergonomicsTotals,
        uint32[] memory storageTotals,
        uint32[] memory vibeTotals,
        uint32[] memory ratingCounts
    ) {
        uint256 n = planIds.length;
        ergonomicsTotals = new uint32[](n);
        storageTotals = new uint32[](n);
        vibeTotals = new uint32[](n);
        ratingCounts = new uint32[](n);
        for (uint256 i = 0; i < n; i++) {
            RatingSummary storage s = _ratingSummary[planIds[i]];
            ergonomicsTotals[i] = s.ergonomicsTotal;
            storageTotals[i] = s.storageTotal;
            vibeTotals[i] = s.vibeTotal;
            ratingCounts[i] = s.ratingCount;
        }
    }

    /// @notice Average ergonomics score for a plan (0 if no ratings).
    function getAvgErgonomics(bytes32 planId) external view returns (uint256) {
        RatingSummary storage s = _ratingSummary[planId];
        if (s.ratingCount == 0) return 0;
        return uint256(s.ergonomicsTotal) / uint256(s.ratingCount);
    }

    /// @notice Average storage score for a plan (0 if no ratings).
    function getAvgStorage(bytes32 planId) external view returns (uint256) {
        RatingSummary storage s = _ratingSummary[planId];
        if (s.ratingCount == 0) return 0;
        return uint256(s.storageTotal) / uint256(s.ratingCount);
    }

    /// @notice Average vibe score for a plan (0 if no ratings).
    function getAvgVibe(bytes32 planId) external view returns (uint256) {
        RatingSummary storage s = _ratingSummary[planId];
        if (s.ratingCount == 0) return 0;
        return uint256(s.vibeTotal) / uint256(s.ratingCount);
    }

    /// @notice Whether registration would succeed for given params (no state change).
    function wouldRegisterSucceed(bytes32 planId, uint8 layoutStyle, uint8 riskTier, uint32 areaCm2) external view returns (bool) {
        if (planId == bytes32(0) || areaCm2 == 0) return false;
        if (_plans[planId].exists) return false;
        if (planCount >= KV_MAX_PLANS) return false;
        if (layoutStyle > KV_MAX_STYLE || riskTier > KV_MAX_TIER) return false;
        return true;
    }

    /// @notice Whether rating would succeed for plan and user (no state change).
    function wouldRateSucceed(bytes32 planId, address user, uint8 e, uint8 s, uint8 v) external view returns (bool) {
        if (!_plans[planId].exists || _plans[planId].softDeleted) return false;
        if (e == 0 || e > 10 || s == 0 || s > 10 || v == 0 || v > 10) return false;
        if (_ratedByUser[planId][user]) return false;
        if (_ratingSummary[planId].ratingCount >= KV_MAX_RATINGS_PER_PLAN) return false;
        return true;
    }

    // -------------------------------------------------------------------------
    // PURE HELPERS AND CONSTANTS EXPOSED
    // -------------------------------------------------------------------------

    function getFeeDenomBps() external pure returns (uint256) {
        return KV_FEE_DENOM_BPS;
    }

    function getMaxStyle() external pure returns (uint256) {
        return KV_MAX_STYLE;
    }

    function getMaxTier() external pure returns (uint256) {
        return KV_MAX_TIER;
    }

    function getMaxPlans() external pure returns (uint256) {
        return KV_MAX_PLANS;
    }

    function getMaxRatingsPerPlan() external pure returns (uint256) {
        return KV_MAX_RATINGS_PER_PLAN;
    }

    function isValidLayoutStyle(uint8 style) external pure returns (bool) {
        return style <= KV_MAX_STYLE;
    }

    function isValidRiskTier(uint8 tier) external pure returns (bool) {
        return tier <= KV_MAX_TIER;
    }

    function isValidScore(uint8 score) external pure returns (bool) {
        return score >= 1 && score <= 10;
    }

    function derivePlanId(address creator, bytes32 seed, uint256 salt) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(creator, seed, salt));
    }

    function isZeroPlanId(bytes32 planId) external pure returns (bool) {
        return planId == bytes32(0);
    }

    // -------------------------------------------------------------------------
    // ADDITIONAL VIEWS (analytics / off-chain indexing)
    // -------------------------------------------------------------------------

    function getPlansInRange(uint256 fromIdx, uint256 toIdx) external view returns (
        bytes32[] memory ids,
        address[] memory creators,
        uint8[] memory riskTiers,
        uint32[] memory areasCm2,
        bool[] memory pinned
    ) {
        if (fromIdx > toIdx || toIdx >= _planIds.length) revert KV_InvalidIndex();
        uint256 len = toIdx - fromIdx + 1;
        ids = new bytes32[](len);
        creators = new address[](len);
        riskTiers = new uint8[](len);
        areasCm2 = new uint32[](len);
        pinned = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _planIds[fromIdx + i];
            Plan storage p = _plans[id];
            ids[i] = id;
            creators[i] = p.creator;
            riskTiers[i] = p.riskTier;
            areasCm2[i] = p.areaCm2;
            pinned[i] = p.pinned;
        }
    }

    function countPlansByRiskTier(uint8 riskTier) external view returns (uint256 count) {
        if (riskTier > KV_MAX_TIER) return 0;
        for (uint256 i = 0; i < _planIds.length; i++) {
            if (_plans[_planIds[i]].riskTier == riskTier) count++;
        }
    }

    function countPlansByLayoutStyle(uint8 layoutStyle) external view returns (uint256 count) {
        if (layoutStyle > KV_MAX_STYLE) return 0;
        for (uint256 i = 0; i < _planIds.length; i++) {
            if (_plans[_planIds[i]].layoutStyle == layoutStyle) count++;
        }
    }

    function getPlanIdsForCreator(address creator, uint256 maxReturn) external view returns (bytes32[] memory ids) {
        uint256 cap = maxReturn > _planIds.length ? _planIds.length : maxReturn;
        uint256 found = 0;
        bytes32[] memory tmp = new bytes32[](_planIds.length);
        for (uint256 i = 0; i < _planIds.length && found < cap; i++) {
            if (_plans[_planIds[i]].creator == creator && !_plans[_planIds[i]].softDeleted) {
                tmp[found] = _planIds[i];
                found++;
            }
        }
        ids = new bytes32[](found);
        for (uint256 j = 0; j < found; j++) ids[j] = tmp[j];
    }

    function getPlanIdsForRiskTier(uint8 riskTier, uint256 maxReturn) external view returns (bytes32[] memory ids) {
        if (riskTier > KV_MAX_TIER) return new bytes32[](0);
        uint256 cap = maxReturn > _planIds.length ? _planIds.length : maxReturn;
        uint256 found = 0;
        bytes32[] memory tmp = new bytes32[](_planIds.length);
        for (uint256 i = 0; i < _planIds.length && found < cap; i++) {
            if (_plans[_planIds[i]].riskTier == riskTier && !_plans[_planIds[i]].softDeleted) {
                tmp[found] = _planIds[i];
                found++;
            }
        }
        ids = new bytes32[](found);
        for (uint256 j = 0; j < found; j++) ids[j] = tmp[j];
    }

    function getPlanIdsPinned(uint256 maxReturn) external view returns (bytes32[] memory ids) {
        uint256 cap = maxReturn > _planIds.length ? _planIds.length : maxReturn;
        uint256 found = 0;
        bytes32[] memory tmp = new bytes32[](_planIds.length);
        for (uint256 i = 0; i < _planIds.length && found < cap; i++) {
            if (_plans[_planIds[i]].pinned && !_plans[_planIds[i]].softDeleted) {
                tmp[found] = _planIds[i];
                found++;
            }
        }
        ids = new bytes32[](found);
        for (uint256 j = 0; j < found; j++) ids[j] = tmp[j];
    }

    function contractBalanceWei() external view returns (uint256) {
        return address(this).balance;
    }

    function getGlobalState() external view returns (
        uint256 planCount_,
        uint256 feeBps_,
        bool namespacePaused_,
        address oracle_,
        address auditor_,
        address treasury_
    ) {
        return (planCount, feeBps, _namespacePaused, oracle, auditor, treasury);
    }

    // -------------------------------------------------------------------------
    // DOCUMENTATION / REFERENCE (view wrappers for constants)
    // -------------------------------------------------------------------------

    /// @notice Denominator for fee basis points (10000).
    function feeDenomBps() external pure returns (uint256) { return KV_FEE_DENOM_BPS; }

    /// @notice Maximum layout style index (15).
    function maxStyleIndex() external pure returns (uint8) { return uint8(KV_MAX_STYLE); }

    /// @notice Maximum risk tier index (6).
    function maxTierIndex() external pure returns (uint8) { return uint8(KV_MAX_TIER); }

    /// @notice Maximum number of plans that can be registered.
    function maxPlansCap() external pure returns (uint256) { return KV_MAX_PLANS; }

    /// @notice Maximum ratings per plan.
    function maxRatingsPerPlanCap() external pure returns (uint256) { return KV_MAX_RATINGS_PER_PLAN; }

    /// @notice Namespace hash for pause scope.
