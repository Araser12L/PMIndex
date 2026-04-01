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
