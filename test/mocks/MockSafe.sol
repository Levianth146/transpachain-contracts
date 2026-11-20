// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockSafe
/// @notice Labeled mock of a Gnosis Safe 3-of-5 for DisbursementController tests.
/// @dev    Not production Safe code. `exec` requires ≥3 distinct valid owners,
///         then low-level calls `to` with `data` as this contract (the Safe).
contract MockSafe {
    uint256 public constant THRESHOLD = 3;
    uint256 public constant OWNER_COUNT = 5;

    address[OWNER_COUNT] public owners;

    constructor(address[OWNER_COUNT] memory _owners) {
        for (uint256 i = 0; i < OWNER_COUNT; i++) {
            require(_owners[i] != address(0), "MockSafe: zero owner");
            owners[i] = _owners[i];
        }
    }

    /// @notice Execute after verifying ≥ THRESHOLD distinct valid owners.
    function exec(
        address to,
        bytes calldata data,
        address[] calldata signers
    ) external returns (bool success, bytes memory returnData) {
        require(signers.length >= THRESHOLD, "MockSafe: below threshold");

        for (uint256 i = 0; i < signers.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < OWNER_COUNT; j++) {
                if (signers[i] == owners[j]) {
                    found = true;
                    break;
                }
            }
            require(found, "MockSafe: invalid signer");
            for (uint256 k = 0; k < i; k++) {
                require(signers[i] != signers[k], "MockSafe: duplicate signer");
            }
        }

        (success, returnData) = to.call(data);
        if (!success) {
            // Bubble the inner revert so expectRevert(selector) works in tests.
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    function getOwners() external view returns (address[OWNER_COUNT] memory) {
        return owners;
    }

    receive() external payable {}
}
