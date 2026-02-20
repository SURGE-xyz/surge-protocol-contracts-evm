// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./FFactory.sol";
import "./IFPair.sol";
import "../tax/IBondingTax.sol";

contract FRouter is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    FFactory public factory;
    address public assetToken;
    address public taxManager;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address assetToken_
    ) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(factory_ != address(0), "Zero addresses are not allowed.");
        require(assetToken_ != address(0), "Zero addresses are not allowed.");

        factory = FFactory(factory_);
        assetToken = assetToken_;
    }

    function getAmountsOut(
        address token,
        address assetToken_,
        uint256 amountIn
    ) public view returns (uint256 _amountOut) {
        require(token != address(0), "Zero addresses are not allowed.");

        address pairAddress = factory.getPair(token, assetToken);
        IFPair pair = IFPair(pairAddress);

        (uint256 reserveA, uint256 reserveB) = pair.getReserves();
        uint256 k = pair.kLast();

        uint256 amountOut;

        if (assetToken_ == assetToken) {
            uint256 newReserveB = reserveB + amountIn;
            uint256 newReserveA = k / newReserveB;
            amountOut = reserveA - newReserveA;
        } else {
            uint256 newReserveA = reserveA + amountIn;
            uint256 newReserveB = k / newReserveA;
            amountOut = reserveB - newReserveB;
        }

        return amountOut;
    }

    function addInitialLiquidity(
        address token_,
        uint256 amountToken_,
        uint256 amountAsset_
    ) public onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(token_ != address(0), "Zero addresses are not allowed.");

        address pairAddress = factory.getPair(token_, assetToken);
        IFPair pair = IFPair(pairAddress);

        IERC20 token = IERC20(token_);
        token.safeTransferFrom(msg.sender, pairAddress, amountToken_);

        pair.mint(amountToken_, amountAsset_);
        return (amountToken_, amountAsset_);
    }

    event Swap(
        uint256 amount0In,
        uint256 amount0Out,
        uint256 amount1In,
        uint256 amount1Out,
        address tokenAddress0,
        address tokenAddress1
    );

    function sell(
        uint256 amountIn,
        address tokenAddress,
        address to,
        address creator
    ) public nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(tokenAddress != address(0), "Zero addresses are not allowed.");
        require(to != address(0), "Zero addresses are not allowed.");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        IFPair pair = IFPair(pairAddress);

        IERC20 token = IERC20(tokenAddress);
        uint256 amountOut = getAmountsOut(tokenAddress, address(0), amountIn);
        token.safeTransferFrom(to, pairAddress, amountIn);

        uint Allfee = factory.sellTax();
        require(Allfee < 100, "sellTax must be < 100");

        uint256 txFee = (Allfee * amountOut) / 100;
        uint256 creatorFee = (1 * txFee) / 100;

        uint256 amount = amountOut - txFee;
        address feeTo = factory.taxVault();

        pair.transferAsset(to, amount);
        pair.transferAsset(feeTo, (txFee - creatorFee));
        pair.transferAsset(creator, creatorFee);
        pair.swap(amountIn, 0, 0, amountOut);

        if (feeTo == taxManager) {
            IBondingTax(taxManager).swapForAsset();
        }

        emit Swap(
            amountIn, // amount0In: tokens sent
            0, // amount0Out
            0, // amount1In
            amountOut, // amount1Out: assets received
            tokenAddress,
            assetToken
        );

        return (amountIn, amountOut);
    }

    function buy(
        uint256 amountIn,
        address tokenAddress,
        address to,
        address creator
    ) public onlyRole(EXECUTOR_ROLE) nonReentrant returns (uint256, uint256) {
        require(tokenAddress != address(0), "Zero addresses are not allowed.");
        require(to != address(0), "Zero addresses are not allowed.");
        require(amountIn > 0, "amountIn must be greater than 0");

        address pair = factory.getPair(tokenAddress, assetToken);

        uint Allfee = factory.buyTax();
        require(Allfee < 100, "buyTax must be < 100");

        uint256 txFee = (Allfee * amountIn) / 100;
        uint256 creatorFee = (1 * txFee) / 100;

        address feeTo = factory.taxVault();

        uint256 amount = amountIn - txFee;

        IERC20(assetToken).safeTransferFrom(to, pair, amount);
        // platform fee
        IERC20(assetToken).safeTransferFrom(to, feeTo, (txFee - creatorFee));
        // creator fee
        IERC20(assetToken).safeTransferFrom(to, creator, creatorFee);

        uint256 amountOut = getAmountsOut(tokenAddress, assetToken, amount);

        IFPair(pair).transferTo(to, amountOut);
        IFPair(pair).swap(0, amountOut, amount, 0);

        if (feeTo == taxManager) {
            IBondingTax(taxManager).swapForAsset();
        }

        emit Swap(0, amountOut, amount, 0, tokenAddress, assetToken);
        return (amount, amountOut);
    }

    function graduate(
        address tokenAddress
    ) public onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(tokenAddress != address(0), "Zero addresses are not allowed.");

        address pair = factory.getPair(tokenAddress, assetToken);
        uint256 assetBalance = IFPair(pair).assetBalance();

        IFPair(pair).transferAsset(msg.sender, assetBalance);
    }

    function approval(
        address pair,
        address asset,
        address spender,
        uint256 amount
    ) public onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(spender != address(0), "Zero addresses are not allowed.");
        IFPair(pair).approval(spender, asset, amount);
    }

    function setTaxManager(address newManager) public onlyRole(ADMIN_ROLE) {
        taxManager = newManager;
    }
}
