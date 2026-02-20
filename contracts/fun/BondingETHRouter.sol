// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IBonding {
    function fee() external view returns (uint256);
    function router() external view returns (address);
    function launch(
        string memory _name,
        string memory _ticker,
        uint8[] memory cores,
        string memory desc,
        string memory img,
        string[4] memory urls,
        uint256 purchaseAmount,
        string memory launchedHash,
        bytes32 salt,
        bytes32 mainSalt
    ) external returns (address, address, uint);
    function launchFor(
        address onBehalfOf,
        string memory _name,
        string memory _ticker,
        uint8[] memory cores,
        string memory desc,
        string memory img,
        string[4] memory urls,
        uint256 purchaseAmount,
        string memory launchedHash,
        bytes32 salt,
        bytes32 mainSalt
    ) external returns (address, address, uint);
    function buy(
        uint256 amountIn,
        address tokenAddress,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (bool);
    function sell(
        uint256 amountIn,
        address tokenAddress,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (bool);
}

interface IFRouter {
    function assetToken() external view returns (address);
}

/// @title BondingETHRouter - Wrapper for native ETH deposits
/// @notice Allows launching and buying tokens with native ETH instead of WETH
contract BondingETHRouter {
    using SafeERC20 for IERC20;

    IBonding public immutable bonding;
    address public immutable weth;

    constructor(address bonding_, address weth_) {
        bonding = IBonding(bonding_);
        weth = weth_;
    }

    /// @notice Launch token with native ETH (auto-wraps to WETH)
    /// @dev Uses launchFor to set msg.sender as the token creator
    function launchWithETH(
        string memory _name,
        string memory _ticker,
        uint8[] memory cores,
        string memory desc,
        string memory img,
        string[4] memory urls,
        string memory launchedHash,
        bytes32 salt,
        bytes32 mainSalt
    ) external payable returns (address, address, uint) {
        require(msg.value > 0, "No ETH sent");

        // Wrap ETH to WETH
        IWETH(weth).deposit{value: msg.value}();

        // Approve bonding to spend WETH
        IERC20(weth).forceApprove(address(bonding), msg.value);

        // Call launchFor on bonding - msg.sender becomes the creator
        (address token, address pair, uint id) = bonding.launchFor(
            msg.sender,  // onBehalfOf - the real user
            _name,
            _ticker,
            cores,
            desc,
            img,
            urls,
            msg.value,
            launchedHash,
            salt,
            mainSalt
        );

        // Tokens are already transferred to msg.sender by launchFor
        // But just in case, transfer any remaining balance
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(token).safeTransfer(msg.sender, tokenBalance);
        }

        return (token, pair, id);
    }

    /// @notice Buy tokens with native ETH (auto-wraps to WETH)
    function buyWithETH(
        address tokenAddress,
        uint256 amountOutMin,
        uint256 deadline
    ) external payable returns (bool) {
        require(msg.value > 0, "No ETH sent");

        // Wrap ETH to WETH
        IWETH(weth).deposit{value: msg.value}();

        // Approve router (not bonding!) to spend WETH
        address routerAddr = bonding.router();
        IERC20(weth).forceApprove(routerAddr, msg.value);

        // Call buy on bonding
        bonding.buy(msg.value, tokenAddress, amountOutMin, deadline);

        // Transfer received tokens to user
        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(tokenAddress).safeTransfer(msg.sender, tokenBalance);
        }

        return true;
    }

    /// @notice Sell tokens for native ETH (auto-unwraps WETH)
    /// @dev User must approve this contract to spend their tokens first
    function sellForETH(
        address tokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external returns (bool) {
        require(amountIn > 0, "Amount must be > 0");

        // Transfer tokens from user to this contract
        IERC20(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            amountIn
        );

        // Approve router to spend tokens
        address routerAddr = bonding.router();
        IERC20(tokenAddress).forceApprove(routerAddr, amountIn);

        // Call sell on bonding - WETH will be sent to this contract
        bonding.sell(amountIn, tokenAddress, amountOutMin, deadline);

        // Get WETH balance received
        uint256 wethBalance = IERC20(weth).balanceOf(address(this));

        if (wethBalance > 0) {
            // Unwrap WETH to ETH
            IWETH(weth).withdraw(wethBalance);

            // Send ETH to user
            (bool success, ) = payable(msg.sender).call{value: wethBalance}("");
            require(success, "ETH transfer failed");
        }

        return true;
    }

    /// @notice Receive ETH from WETH.withdraw()
    receive() external payable {}
}
