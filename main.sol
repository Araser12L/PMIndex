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
