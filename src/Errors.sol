// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Shared custom errors for gas-efficient reverts (TranspaChain testnet)
library TranspaChainErrors {
    error ZeroAmount();
    error NotActive();
    error Expired();
    error WrongPaymentToken();
    error NotOrg();
    error InvalidState();
    error InsufficientEscrow();
    error TransferFailed();
    error NotRefundable();
    error NothingToRefund();
    error OnlyDAO();
    error ZeroAddress();
    error FeeTooHigh();
}
