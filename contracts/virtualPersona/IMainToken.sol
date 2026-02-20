// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IERC20Config.sol";
import "./IErrors.sol";

interface IMainToken is IERC20, IERC20Config, IERC20Metadata, IErrors {
    event AutoSwapThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    event ExternalCallError(uint256 identifier);

    event InitialLiquidityAdded(
        uint256 tokenA,
        uint256 tokenB,
        uint256 lpToken
    );

    event LimitsUpdated(
        uint256 oldMaxTokensPerTransaction,
        uint256 newMaxTokensPerTransaction,
        uint256 oldMaxTokensPerWallet,
        uint256 newMaxTokensPerWallet
    );

    event LiquidityPoolCreated(address addedPool);

    event LiquidityPoolAdded(address addedPool);

    event LiquidityPoolRemoved(address removedPool);

    event ProjectTaxBasisPointsChanged(
        uint256 oldBuyBasisPoints,
        uint256 newBuyBasisPoints,
        uint256 oldSellBasisPoints,
        uint256 newSellBasisPoints
    );

    event RevenueAutoSwap();

    event ProjectTaxRecipientUpdated(address treasury);

    event ValidCallerAdded(bytes32 addedValidCaller);

    event ValidCallerRemoved(bytes32 removedValidCaller);

    /**
     * @dev Add initial liquidity to the uniswap pair
     * @param _lockerFactory V2LockerFactory address (Aerodrome). If address(0) - LP tokens are burned (BSC mode)
     * @param _lockerOwner Owner of the locker (can unlock LP after lockUntil)
     * @param _beneficiary Address that receives trading fees
     * @param _beneficiaryShare Share of fees for beneficiary (basis points, 10000 = 100%)
     */
    function addInitialLiquidity(
        address _lockerFactory,
        address _lockerOwner,
        address _beneficiary,
        uint16 _beneficiaryShare
    ) external;

    /**
     * @dev Return if an address is a liquidity pool
     * @param queryAddress_ The address being queried
     */
    function isLiquidityPool(
        address queryAddress_
    ) external view returns (bool);

    /**
     * @dev Returns a list of all liquidity pools
     */
    function liquidityPools()
        external
        view
        returns (address[] memory liquidityPools_);

    /**
     * @dev Adds a liquidity pool (onlyOwnerOrFactory)
     * @param newLiquidityPool_ The address of the new liquidity pool
     */
    function addLiquidityPool(address newLiquidityPool_) external;

    /**
     * @dev Removes a liquidity pool (onlyOwnerOrFactory)
     * @param removedLiquidityPool_ The address of the removed liquidity pool
     */
    function removeLiquidityPool(address removedLiquidityPool_) external;

    /**
     * @dev Return if a code hash is a valid caller
     * @param queryHash_ The code hash being queried
     */
    function isValidCaller(bytes32 queryHash_) external view returns (bool);

    /**
     * @dev Returns a list of all valid caller code hashes
     */
    function validCallers()
        external
        view
        returns (bytes32[] memory validCallerHashes_);

    /**
     * @dev Add a valid caller code hash (onlyOwnerOrFactory)
     * @param newValidCallerHash_ The hash of the new valid caller
     */
    function addValidCaller(bytes32 newValidCallerHash_) external;

    /**
     * @dev Remove a valid caller code hash (onlyOwnerOrFactory)
     * @param removedValidCallerHash_ The hash of the removed valid caller
     */
    function removeValidCaller(bytes32 removedValidCallerHash_) external;

    /**
     * @dev Set the project tax recipient (onlyOwnerOrFactory)
     * @param projectTaxRecipient_ New recipient address
     */
    function setProjectTaxRecipient(address projectTaxRecipient_) external;

    /**
     * @dev Set the autoswap threshold (onlyOwnerOrFactory)
     * @param swapThresholdBasisPoints_ New swap threshold in basis points
     */
    function setSwapThresholdBasisPoints(
        uint16 swapThresholdBasisPoints_
    ) external;

    /**
     * @dev Change the tax rates (onlyOwnerOrFactory)
     * @param newProjectBuyTaxBasisPoints_ The new buy tax rate (bps)
     * @param newProjectSellTaxBasisPoints_ The new sell tax rate (bps)
     */
    function setProjectTaxRates(
        uint16 newProjectBuyTaxBasisPoints_,
        uint16 newProjectSellTaxBasisPoints_
    ) external;

    /// @dev Provide easy to view tax totals
    function totalBuyTaxBasisPoints() external view returns (uint256);

    function totalSellTaxBasisPoints() external view returns (uint256);

    /**
     * @dev Fallback distribution of accumulated tax tokens
     */
    function distributeTaxTokens() external;

    /**
     * @dev Withdraw ETH (onlyOwnerOrFactory)
     * @param amount_ The amount to withdraw
     */
    function withdrawETH(uint256 amount_) external;

    /**
     * @dev Withdraw ERC20s (except address(this)) (onlyOwnerOrFactory)
     * @param token_ The ERC20 contract
     * @param amount_ The amount to withdraw
     */
    function withdrawERC20(address token_, uint256 amount_) external;

    /// @dev Burn functions
    function burn(uint256 value) external;

    function burnFrom(address account, uint256 value) external;

    /**
     * @dev initializer
     * @param integrationAddresses_ [projectOwner, uniswapRouter, pairToken]
     * @param baseParams_ ERC20 base params (name, symbol)
     * @param supplyParams_ supply configuration (ERC20SupplyParameters encoded)
     * @param taxParams_ tax configuration (ERC20TaxParameters encoded)
     */
    function initialize(
        address[3] memory integrationAddresses_,
        bytes memory baseParams_,
        bytes memory supplyParams_,
        bytes memory taxParams_
    ) external;
}
