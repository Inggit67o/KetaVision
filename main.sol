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
