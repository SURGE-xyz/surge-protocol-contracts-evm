// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./IBondingTax.sol";
import "../pool/IRouter.sol";

contract BondingTax is Initializable, AccessControlUpgradeable, IBondingTax {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public assetToken; // target asset (e.g. USDC)
    address public taxToken; // token to swap (tax token)
    IRouter public router; // external router (Uniswap/aggregator)
    address public bondingRouter; // FRouter address - only it can call swapForAsset
    address public treasury; // asset recipient after swap

    uint256 public minSwapThreshold; // min tax amount for swap
    uint256 public maxSwapThreshold; // max amount per swap
    uint16 private _slippage; // in bps, 100 = 1%

    event SwapParamsUpdated(
        address oldRouter,
        address newRouter,
        address oldBondingRouter,
        address newBondingRouter,
        address oldAsset,
        address newAsset
    );
    event SwapThresholdUpdated(
        uint256 oldMinThreshold,
        uint256 newMinThreshold,
        uint256 oldMaxThreshold,
        uint256 newMaxThreshold
    );
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event SwapExecuted(uint256 taxTokenAmount, uint256 assetTokenAmount);
    event SwapFailed(uint256 taxTokenAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyBondingRouter() {
        require(_msgSender() == bondingRouter, "Only bonding router");
        _;
    }

    function initialize(
        address defaultAdmin_,
        address assetToken_,
        address taxToken_,
        address router_,
        address bondingRouter_,
        address treasury_,
        uint256 minSwapThreshold_,
        uint256 maxSwapThreshold_
    ) external initializer {
        __AccessControl_init();

        require(defaultAdmin_ != address(0), "admin=0");
        require(assetToken_ != address(0), "asset=0");
        require(taxToken_ != address(0), "tax=0");
        require(router_ != address(0), "router=0");
        require(bondingRouter_ != address(0), "bondingRouter=0");
        require(treasury_ != address(0), "treasury=0");
        require(minSwapThreshold_ <= maxSwapThreshold_, "min>max");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin_);
        _grantRole(ADMIN_ROLE, defaultAdmin_);

        assetToken = assetToken_;
        taxToken = taxToken_;
        router = IRouter(router_);
        bondingRouter = bondingRouter_;
        treasury = treasury_;
        minSwapThreshold = minSwapThreshold_;
        maxSwapThreshold = maxSwapThreshold_;

        // Approve router to spend tax token
        IERC20(taxToken).forceApprove(router_, type(uint256).max);

        _slippage = 100; // 1% default
    }

    function updateSwapParams(
        address router_,
        address bondingRouter_,
        address assetToken_,
        uint16 slippage_ // in bps, 100=1%, 10000=100%
    ) public onlyRole(ADMIN_ROLE) {
        require(router_ != address(0), "router=0");
        require(bondingRouter_ != address(0), "bondingRouter=0");
        require(assetToken_ != address(0), "asset=0");
        require(slippage_ <= 10_000, "slippage>100%");

        address oldRouter = address(router);
        address oldBondingRouter = bondingRouter;
        address oldAsset = assetToken;

        assetToken = assetToken_;
        router = IRouter(router_);
        bondingRouter = bondingRouter_;
        _slippage = slippage_;

        // Update allowance: approve new router, revoke old
        IERC20(taxToken).forceApprove(router_, type(uint256).max);
        if (oldRouter != address(0) && oldRouter != router_) {
            IERC20(taxToken).forceApprove(oldRouter, 0);
        }

        emit SwapParamsUpdated(
            oldRouter,
            router_,
            oldBondingRouter,
            bondingRouter_,
            oldAsset,
            assetToken_
        );
    }

    function updateSwapThresholds(
        uint256 minSwapThreshold_,
        uint256 maxSwapThreshold_
    ) public onlyRole(ADMIN_ROLE) {
        require(minSwapThreshold_ <= maxSwapThreshold_, "min>max");

        uint256 oldMin = minSwapThreshold;
        uint256 oldMax = maxSwapThreshold;

        minSwapThreshold = minSwapThreshold_;
        maxSwapThreshold = maxSwapThreshold_;

        emit SwapThresholdUpdated(
            oldMin,
            minSwapThreshold_,
            oldMax,
            maxSwapThreshold_
        );
    }

    function updateTreasury(address treasury_) public onlyRole(ADMIN_ROLE) {
        require(treasury_ != address(0), "treasury=0");
        address oldTreasury = treasury;
        treasury = treasury_;
        emit TreasuryUpdated(oldTreasury, treasury_);
    }

    function withdraw(address token) external onlyRole(ADMIN_ROLE) {
        IERC20(token).safeTransfer(
            treasury,
            IERC20(token).balanceOf(address(this))
        );
    }

    /// @dev Called ONLY by bonding router (FRouter), see onlyBondingRouter
    function swapForAsset() public onlyBondingRouter returns (bool, uint256) {
        uint256 amount = IERC20(taxToken).balanceOf(address(this));
        if (amount == 0 || amount < minSwapThreshold) {
            return (false, 0);
        }
        if (amount > maxSwapThreshold) {
            amount = maxSwapThreshold;
        }

        address[] memory path = new address[](2);
        path[0] = taxToken;
        path[1] = assetToken;

        uint256[] memory amountsOut = router.getAmountsOut(amount, path);
        require(amountsOut.length > 1, "price failed");

        uint256 expectedOutput = amountsOut[1];
        uint256 minOutput = (expectedOutput * (10_000 - _slippage)) / 10_000;

        try
            router.swapExactTokensForTokens(
                amount,
                minOutput,
                path,
                treasury,
                block.timestamp + 300
            )
        returns (uint256[] memory amounts) {
            emit SwapExecuted(amount, amounts[1]);
            return (true, amounts[1]);
        } catch {
            emit SwapFailed(amount);
            return (false, 0);
        }
    }
}
