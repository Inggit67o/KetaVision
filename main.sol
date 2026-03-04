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
