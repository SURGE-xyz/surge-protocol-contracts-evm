// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./FFactory.sol";
import "./IFPair.sol";
import "./FRouter.sol";
import "./FERC20.sol";
import "../virtualPersona/IMainFactory.sol";

contract Bonding is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;

    address private _feeTo;
    FFactory public factory;
    FRouter public router;
    uint256 public initialSupply;
    uint256 public fee;
    uint256 public constant K = 3_000_000_000_000;
    uint256 public assetRate;
    uint256 public gradThreshold;
    uint256 public maxTx;
    address public mainFactory;

    struct Profile {
        address user;
        address[] tokens;
    }
    struct Token {
        address creator;
        address token;
        address pair;
        address mainToken;
        Data data;
        string description;
        uint8[] cores;
        string image;
        string twitter;
        string telegram;
        string youtube;
        string website;
        bool trading;
        bool tradingOnUniswap;
    }
    struct Data {
        address token;
        string name;
        string ticker;
        uint256 supply;
        uint256 price;
        uint256 marketCap;
        uint256 liquidity;
        uint256 volume;
        uint256 volume24H;
        uint256 prevPrice;
        uint256 lastUpdated;
    }

    mapping(address => bytes32) private _mainTokenSalt;
    mapping(address => Profile) public profile;
    address[] public profiles;
    mapping(address => Token) public tokenInfo;
    address[] public tokenInfos;

    event Launched(
        address indexed token,
        address indexed pair,
        uint,
        string launchedHash
    );
    event Graduated(address indexed token, address mainToken);

    error InvalidTokenStatus();
    error InvalidInput();
    error SlippageTooHigh();
    error NotApprovedRouter();

    mapping(address => bool) public approvedRouters;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_,
        address router_,
        address feeTo_,
        uint256 fee_,
        uint256 initialSupply_,
        uint256 assetRate_,
        uint256 maxTx_,
        address mainFactory_,
        uint256 gradThreshold_
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        factory = FFactory(factory_);
        router = FRouter(router_);
        _feeTo = feeTo_;
        fee = (fee_ * 1 ether) / 1000;
        initialSupply = initialSupply_;
        assetRate = assetRate_;
        maxTx = maxTx_;
        mainFactory = mainFactory_;
        gradThreshold = gradThreshold_;
    }

    function setTokenParams(
        uint256 newSupply,
        uint256 newGradThreshold,
        uint256 newMaxTx,
        uint256 newAssetRate,
        uint256 newFee,
        address newFeeTo
    ) public onlyOwner {
        if (newAssetRate == 0) revert InvalidInput();
        initialSupply = newSupply;
        gradThreshold = newGradThreshold;
        maxTx = newMaxTx;
        assetRate = newAssetRate;
        fee = newFee;
        _feeTo = newFeeTo;
    }

    function setApprovedRouter(
        address router_,
        bool approved
    ) public onlyOwner {
        approvedRouters[router_] = approved;
    }

    /// @notice Launch a new token (caller is creator)
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
    ) public nonReentrant returns (address, address, uint) {
        return
            _launch(
                msg.sender,
                msg.sender,
                _name,
                _ticker,
                cores,
                desc,
                img,
                urls,
                purchaseAmount,
                launchedHash,
                salt,
                mainSalt
            );
    }

    /// @notice Launch token on behalf of another address (for approved routers only)
    /// @param onBehalfOf The address that will be set as the token creator
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
    ) public nonReentrant returns (address, address, uint) {
        if (!approvedRouters[msg.sender]) revert NotApprovedRouter();
        return
            _launch(
                onBehalfOf,
                msg.sender,
                _name,
                _ticker,
                cores,
                desc,
                img,
                urls,
                purchaseAmount,
                launchedHash,
                salt,
                mainSalt
            );
    }

    /// @dev Internal launch logic
    /// @param creator The address to be set as token creator
    /// @param payer The address paying for the launch (tokens transferred from)
    function _launch(
        address creator,
        address payer,
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
    ) internal returns (address, address, uint) {
        if (purchaseAmount <= fee || cores.length == 0) revert InvalidInput();

        address assetToken = router.assetToken();
        uint256 initialPurchase = purchaseAmount - fee;
        IERC20(assetToken).safeTransferFrom(payer, _feeTo, fee);
        IERC20(assetToken).safeTransferFrom(
            payer,
            address(this),
            initialPurchase
        );

        FERC20 token = new FERC20{salt: salt}(
            _name,
            _ticker,
            initialSupply,
            maxTx
        );
        uint256 supply = token.totalSupply();
        _mainTokenSalt[address(token)] = mainSalt;

        address _pair = factory.createPair(address(token), assetToken);
        IERC20(address(token)).forceApprove(address(router), supply);

        uint256 liquidity = (((((K * 10000) / assetRate) * 10000 ether) /
            supply) * 1 ether) / 10000;
        router.addInitialLiquidity(address(token), supply, liquidity);

        tokenInfo[address(token)] = Token({
            creator: creator,
            token: address(token),
            mainToken: address(0),
            pair: _pair,
            data: Data({
                token: address(token),
                name: _name,
                ticker: _ticker,
                supply: supply,
                price: supply / liquidity,
                marketCap: liquidity,
                liquidity: liquidity * 2,
                volume: 0,
                volume24H: 0,
                prevPrice: supply / liquidity,
                lastUpdated: block.timestamp
            }),
            description: desc,
            cores: cores,
            image: img,
            twitter: urls[0],
            telegram: urls[1],
            youtube: urls[2],
            website: urls[3],
            trading: true,
            tradingOnUniswap: false
        });
        tokenInfos.push(address(token));

        if (profile[creator].user == creator) {
            profile[creator].tokens.push(address(token));
        } else {
            profile[creator].user = creator;
            profile[creator].tokens.push(address(token));
        }

        emit Launched(address(token), _pair, tokenInfos.length, launchedHash);

        IERC20(assetToken).forceApprove(address(router), initialPurchase);
        _buy(
            address(this),
            initialPurchase,
            address(token),
            0,
            block.timestamp + 300
        );
        token.transfer(creator, token.balanceOf(address(this)));

        return (address(token), _pair, tokenInfos.length);
    }

    function sell(
        uint256 amountIn,
        address tokenAddress,
        uint256 amountOutMin,
        uint256 deadline
    ) public returns (bool) {
        if (!tokenInfo[tokenAddress].trading) revert InvalidTokenStatus();
        if (block.timestamp > deadline) revert InvalidInput();

        (, uint256 amount1Out) = router.sell(
            amountIn,
            tokenAddress,
            msg.sender,
            tokenInfo[tokenAddress].creator
        );
        if (amount1Out < amountOutMin) revert SlippageTooHigh();

        if (block.timestamp - tokenInfo[tokenAddress].data.lastUpdated > 86400)
            tokenInfo[tokenAddress].data.lastUpdated = block.timestamp;
        return true;
    }

    function buy(
        uint256 amountIn,
        address tokenAddress,
        uint256 amountOutMin,
        uint256 deadline
    ) public payable returns (bool) {
        if (!tokenInfo[tokenAddress].trading) revert InvalidTokenStatus();
        _buy(msg.sender, amountIn, tokenAddress, amountOutMin, deadline);
        return true;
    }

    function _buy(
        address buyer,
        uint256 amountIn,
        address tokenAddress,
        uint256 amountOutMin,
        uint256 deadline
    ) internal {
        if (block.timestamp > deadline) revert InvalidInput();

        address pairAddress = factory.getPair(
            tokenAddress,
            router.assetToken()
        );
        (uint256 reserveA, ) = IFPair(pairAddress).getReserves();

        (, uint256 amount0Out) = router.buy(
            amountIn,
            tokenAddress,
            buyer,
            tokenInfo[tokenAddress].creator
        );
        if (amount0Out < amountOutMin) revert SlippageTooHigh();

        if (block.timestamp - tokenInfo[tokenAddress].data.lastUpdated > 86400)
            tokenInfo[tokenAddress].data.lastUpdated = block.timestamp;

        if (
            reserveA - amount0Out <= gradThreshold &&
            tokenInfo[tokenAddress].trading
        ) _openTradingOnUniswap(tokenAddress);
    }

    function _openTradingOnUniswap(address tokenAddress) private {
        Token storage _token = tokenInfo[tokenAddress];
        if (_token.tradingOnUniswap || !_token.trading)
            revert InvalidTokenStatus();

        _token.trading = false;
        _token.tradingOnUniswap = true;

        address pairAddress = factory.getPair(
            tokenAddress,
            router.assetToken()
        );
        uint256 assetBalance = IFPair(pairAddress).assetBalance();
        uint256 tokenBalance = IFPair(pairAddress).balance();

        router.graduate(tokenAddress);
        IERC20(router.assetToken()).forceApprove(mainFactory, assetBalance);

        uint256 id = IMainFactory(mainFactory).initFromBondingCurve(
            _token.data.name,
            _token.data.ticker,
            _token.cores,
            bytes32(0),
            address(0),
            0,
            0,
            assetBalance,
            _token.creator
        );

        bytes32 saltToUse = _mainTokenSalt[tokenAddress];
        if (saltToUse == bytes32(0))
            saltToUse = keccak256(
                abi.encodePacked(msg.sender, block.timestamp, tokenAddress)
            );

        address mainToken = IMainFactory(mainFactory)
            .executeBondingCurveApplicationSalt(
                id,
                _token.data.supply / 1 ether,
                tokenBalance / 1 ether,
                pairAddress,
                saltToUse
            );
        _token.mainToken = mainToken;

        router.approval(
            pairAddress,
            mainToken,
            address(this),
            IERC20(mainToken).balanceOf(pairAddress)
        );
        FERC20(tokenAddress).burnFrom(pairAddress, tokenBalance);

        emit Graduated(tokenAddress, mainToken);
    }

    function unwrapToken(
        address srcTokenAddress,
        address[] memory accounts
    ) public {
        Token memory info = tokenInfo[srcTokenAddress];
        if (!info.tradingOnUniswap) revert InvalidTokenStatus();

        FERC20 token = FERC20(srcTokenAddress);
        address pairAddress = factory.getPair(
            srcTokenAddress,
            router.assetToken()
        );

        for (uint i = 0; i < accounts.length; i++) {
            uint256 balance = token.balanceOf(accounts[i]);
            if (balance > 0) {
                token.burnFrom(accounts[i], balance);
                IERC20(info.mainToken).transferFrom(
                    pairAddress,
                    accounts[i],
                    balance
                );
            }
        }
    }
}
