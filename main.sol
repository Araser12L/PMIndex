// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    PMIndex – Polyhedral Meta‑Prediction Index

    This contract maintains a registry and index of prediction markets
    across heterogeneous venues (on‑chain AMMs, orderbooks, off‑chain
    brokers, oracle‑only feeds). It aggregates odds, computes weighted
    index views, and records arbitrage opportunities at an accounting
    level for downstream bots.

    It is intentionally conservative: it does not custody user funds,
    only tracks synthetic exposure and venue snapshots with explicit
    risk bounds that can be tuned by governance.
*/

/// @notice Simple reentrancy guard
abstract contract ReentrancyGate {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status = _NOT_ENTERED;

    modifier nonReentrant() {
        require(_status != _ENTERED, "RG:reentrant");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

/// @notice Governance + pause control
abstract contract Governed is ReentrancyGate {
    address public immutable governor;
    address private _pendingGovernor;
    bool public paused;

    event GovernorTransferStarted(address indexed from, address indexed to);
    event GovernorAccepted(address indexed newGovernor);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error NotGovernor();
    error NotPendingGovernor();
    error SystemPaused();
    error ZeroAddress();

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert SystemPaused();
        _;
    }

    constructor(address _governor) {
        if (_governor == address(0)) revert ZeroAddress();
        governor = _governor;
    }

    function beginGovernorTransfer(address nextGovernor) external onlyGovernor {
        if (nextGovernor == address(0)) revert ZeroAddress();
        _pendingGovernor = nextGovernor;
        emit GovernorTransferStarted(msg.sender, nextGovernor);
    }

    function acceptGovernor() external {
        if (msg.sender != _pendingGovernor) revert NotPendingGovernor();
        _pendingGovernor = address(0);
        emit GovernorAccepted(msg.sender);
    }

    function pendingGovernor() external view returns (address) {
        return _pendingGovernor;
    }

    function pause() external onlyGovernor {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyGovernor {
        paused = false;
        emit Unpaused(msg.sender);
    }
}

/// @notice Prediction Market Meta‑Index
contract PMIndex is Governed {
    // ---------------------------
    // Types
    // ---------------------------

    enum VenueKind {
        Unknown,
        OnChainAMM,
        OnChainOrderbook,
        OffChainBroker,
        OracleOnly
    }

    enum OutcomeSide {
        Invalid,
        Yes,
        No
    }

    struct Venue {
        string name;
        string metadataURI;
        address adapter;
        uint96 baseFeePpm;      // 1e6 == 100%
        VenueKind kind;
        bool active;
    }

    struct MarketKey {
        bytes32 venueMarketId;  // opaque venue identifier
        address baseToken;
        uint8 decimals;
    }

    struct MarketSnapshot {
        uint64 lastUpdate;
        uint64 yesOddsMilli;    // milli‑odds: 1000 == 1.0
        uint64 noOddsMilli;
        uint64 confidenceBps;   // 0‑10_000
        uint64 spreadBps;
        uint128 totalLiability; // accounting units of baseToken
    }

    struct AggregatedView {
        uint64 compositeYesMilli;
        uint64 compositeNoMilli;
        uint64 compositeConfidenceBps;
        uint64 effectiveSpreadBps;
        uint128 weightedLiquidity;
        uint32 contributingFeeds;
    }

    struct ArbRoute {
        uint256 routeId;
        uint16 fromVenueId;
        uint16 toVenueId;
        bytes32 marketId;
        int64 edgeMilli;
        uint64 discoveredAt;
        uint64 expiresAt;
        bool live;
    }

    struct SyntheticPosition {
        uint128 notional;
        uint128 maxLoss;
        OutcomeSide side;
        uint16 venueId;
        bytes32 marketId;
        address owner;
        uint64 openedAt;
        bool closed;
    }

    // ---------------------------
    // Storage – static identifiers
    // ---------------------------

    string public indexName;
    string public indexSymbol;

    // entropy / risk domains (fresh, contract‑local constants)
    bytes32 public immutable entropySalt;
    uint96 public immutable baseFeeFloorPpm;

    // sentinel addresses (random‑looking, contract‑local only)
    address private constant SENTINEL_VALIDATOR = 0xF9bA7a60f2c9A99a7d3f8971A102bF3b7D4c0C91;
    address private constant SENTINEL_ROUTER    = 0x3E4bC12aA9577E0eA0732dB5cA343fA98C52A4EE;

    bytes32 private constant FEED_DOMAIN =
        0x8e55907e4b1f64d9db0c1e7d4dd3a76a4c905c3a2130e26e0c8a031221f798c2;
    bytes32 private constant RISK_DOMAIN =
        0x52f984d3f1ba0aa0da50a0b21e48d3f8f3ab6a2b60175a78b4b97e3a9cc8d4f7;

    // ---------------------------
    // Storage – registries
    // ---------------------------

    // venueId => Venue
    mapping(uint16 => Venue) public venues;
    uint16 public venueCount;

    // marketHash => MarketKey
    mapping(bytes32 => MarketKey) public markets;
    bytes32[] public allMarketIds;

    // marketHash => venueId => snapshot
    mapping(bytes32 => mapping(uint16 => MarketSnapshot)) private _snapshots;

    // marketHash => aggregate
    mapping(bytes32 => AggregatedView) private _aggregates;

    // synthetic positions
    uint256 public nextSyntheticPositionId;
    mapping(uint256 => SyntheticPosition) public syntheticPositions;

    // arb routes
    uint256 public nextArbRouteId;
    mapping(uint256 => ArbRoute) public arbRoutes;

    // roles
    mapping(address => bool) public isCurator;
    mapping(address => bool) public isOperator;

    // risk parameters
    uint128 public maxGlobalLiability;
    uint128 public maxPerPositionLoss;
    uint64 public staleAfterSeconds;
    uint64 public minConfidenceBps;
    uint64 public minSpreadBpsForArb;

    // lightweight accounting of total synthetic risk
    uint128 public totalSyntheticMaxLoss;

