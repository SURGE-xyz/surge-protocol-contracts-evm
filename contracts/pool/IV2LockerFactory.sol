// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IV2LockerFactory
 * @notice Interface for Aerodrome V2 LP Locker Factory (Basic Volatile pools)
 * @dev Address: 0x067b028C66f61466F66864cc01F92Afc7D99e530 (Base)
 */
interface IV2LockerFactory {
    /**
     * @notice Lock LP tokens with owner and beneficiary
     * @param _pool LP token (pool) address
     * @param _lp Amount of LP tokens to lock
     * @param _lockUntil Unix timestamp when tokens can be unlocked
     * @param _beneficiary Address that receives trading fees
     * @param _beneficiaryShare Share of fees for beneficiary (basis points, max 10000 = 100%)
     * @param _bribeableShare Share that can be used for bribes (basis points)
     * @param _owner Owner of the locker (can unlock after _lockUntil)
     * @return locker Address of the created locker contract
     */
    function lock(
        address _pool,
        uint256 _lp,
        uint32 _lockUntil,
        address _beneficiary,
        uint16 _beneficiaryShare,
        uint16 _bribeableShare,
        address _owner
    ) external returns (address locker);

    /**
     * @notice Get locker implementation address
     */
    function lockerImplementation() external view returns (address);

    /**
     * @notice Max basis points (10000 = 100%)
     */
    function MAX_BPS() external view returns (uint256);
}
