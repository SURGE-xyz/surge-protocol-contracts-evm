// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../pool/IUniswapV2Router02.sol";
import "../pool/IUniswapV2Factory.sol";
import "../pool/IUniswapV2Pair.sol";
import "../pool/IV2LockerFactory.sol";

import "./IMainToken.sol";

contract MainToken is ContextUpgradeable, IMainToken, Ownable2StepUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;

    uint256 internal constant BP_DENOM = 10000;
    uint256 internal constant ROUND_DEC = 100000000000;
    uint256 internal constant CALL_GAS_LIMIT = 50000;
    uint256 internal constant MAX_SWAP_THRESHOLD_MULTIPLE = 20;

    /// @notice Dead address for burning LP tokens
    address internal constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    /// @notice Maximum tax rate (0% = 0 basis points, tax disabled)
    uint16 public constant MAX_TAX_BASIS_POINTS = 0;

    address public uniswapV2Pair;
    uint256 public botProtectionDurationInSeconds;
    bool internal _tokenHasTax;
    IUniswapV2Router02 internal _uniswapRouter;

    uint32 public fundedDate;
    uint16 public projectBuyTaxBasisPoints;
    uint16 public projectSellTaxBasisPoints;
    uint16 public swapThresholdBasisPoints;
    address public pairToken; // The token used to trade for this token

    /** @dev {_autoSwapInProgress} see comments in initialize/_addInitialLiquidity */
    bool private _autoSwapInProgress;

    address public projectTaxRecipient;
    uint128 public projectTaxPendingSwap;
    address public vault; // Project supply vault

    string private _name;
    string private _symbol;
    uint256 private _totalSupply;

    /** @dev {_balances} */
    mapping(address => uint256) private _balances;

    /** @dev {_allowances} */
    mapping(address => mapping(address => uint256)) private _allowances;

    /** @dev {_validCallerCodeHashes} */
    EnumerableSet.Bytes32Set private _validCallerCodeHashes;

    /** @dev {_liquidityPools} */
    EnumerableSet.AddressSet private _liquidityPools;

    address private _factory; // Single source of truth (factory address)

    /// @notice LP Locker Factory address (Aerodrome V2). If address(0) - LP tokens are burned (BSC mode)
    address public lockerFactory;
    /// @notice Locker owner = token creator (gets 100% - beneficiaryShare of fees, e.g. 5%)
    address public lockerOwner;
    /// @notice Fee beneficiary = platform (gets beneficiaryShare of fees, e.g. 95%)
    address public feeBeneficiary;
    /// @notice Platform share in basis points (e.g. 9500 = 95% platform, 5% creator)
    uint16 public beneficiaryShare;
    /// @notice Created locker address (set after locking)
    address public lpLocker;

    /**
     * @dev {onlyOwnerOrFactory}
     * Allows calls only from owner or factory
     */
    modifier onlyOwnerOrFactory() {
        if (owner() != _msgSender() && _factory != _msgSender()) {
            revert CallerIsNotAdminNorFactory();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address[3] memory integrationAddresses_,
        bytes memory baseParams_,
        bytes memory supplyParams_,
        bytes memory taxParams_
    ) external initializer {
        _decodeBaseParams(integrationAddresses_[0], baseParams_);
        _uniswapRouter = IUniswapV2Router02(integrationAddresses_[1]);
        pairToken = integrationAddresses_[2];

        ERC20SupplyParameters memory supplyParams = abi.decode(
            supplyParams_,
            (ERC20SupplyParameters)
        );

        ERC20TaxParameters memory taxParams = abi.decode(
            taxParams_,
            (ERC20TaxParameters)
        );

        _processSupplyParams(supplyParams);

        uint256 lpSupply = supplyParams.lpSupply * (10 ** decimals());
        uint256 vaultSupply = supplyParams.vaultSupply * (10 ** decimals());

        botProtectionDurationInSeconds = supplyParams
            .botProtectionDurationInSeconds;

        _tokenHasTax = _processTaxParams(taxParams);
        swapThresholdBasisPoints = uint16(
            taxParams.taxSwapThresholdBasisPoints
        );
        projectTaxRecipient = taxParams.projectTaxRecipient;

        _mintBalances(lpSupply, vaultSupply);

        uniswapV2Pair = _createPair();

        // Factory is msg.sender when calling initialize (cloning)
        _factory = _msgSender();

        // Disable auto-swaps/taxes during initial liquidity
        _autoSwapInProgress = true;
    }

    /**
     * @dev Decode base params (owner/name/symbol)
     */
    function _decodeBaseParams(
        address projectOwner_,
        bytes memory encodedBaseParams_
    ) internal {
        _transferOwnership(projectOwner_);
        (_name, _symbol) = abi.decode(encodedBaseParams_, (string, string));
    }

    /**
     * @dev Process supply params
     */
    function _processSupplyParams(
        ERC20SupplyParameters memory erc20SupplyParameters_
    ) internal {
        if (
            erc20SupplyParameters_.maxSupply !=
            (erc20SupplyParameters_.vaultSupply +
                erc20SupplyParameters_.lpSupply)
        ) {
            revert SupplyTotalMismatch();
        }

        if (erc20SupplyParameters_.maxSupply > type(uint128).max) {
            revert MaxSupplyTooHigh();
        }

        vault = erc20SupplyParameters_.vault;
    }

    /**
     * @dev Process tax params
     */
    function _processTaxParams(
        ERC20TaxParameters memory erc20TaxParameters_
    ) internal returns (bool tokenHasTax_) {
        // Check max tax (0% - tax disabled)
        require(
            erc20TaxParameters_.projectBuyTaxBasisPoints <=
                MAX_TAX_BASIS_POINTS,
            "Initial buy tax exceeds maximum 0%"
        );
        require(
            erc20TaxParameters_.projectSellTaxBasisPoints <=
                MAX_TAX_BASIS_POINTS,
            "Initial sell tax exceeds maximum 0%"
        );

        if (
            erc20TaxParameters_.projectBuyTaxBasisPoints == 0 &&
            erc20TaxParameters_.projectSellTaxBasisPoints == 0
        ) {
            return false;
        } else {
            projectBuyTaxBasisPoints = uint16(
                erc20TaxParameters_.projectBuyTaxBasisPoints
            );
            projectSellTaxBasisPoints = uint16(
                erc20TaxParameters_.projectSellTaxBasisPoints
            );
            return true;
        }
    }

    /**
     * @dev Mint initial balances
     */
    function _mintBalances(uint256 lpMint_, uint256 vaultMint_) internal {
        if (lpMint_ > 0) {
            _mint(address(this), lpMint_);
        }
        if (vaultMint_ > 0) {
            _mint(vault, vaultMint_);
        }
    }

    /**
     * @dev Create the uniswap pair
     */
    function _createPair() internal returns (address uniswapV2Pair_) {
        address factoryAddr = _uniswapRouter.factory();
        require(factoryAddr != address(0), "Factory ADDRESS!");

        uniswapV2Pair_ = IUniswapV2Factory(_uniswapRouter.factory()).getPair(
            address(this),
            pairToken
        );

        if (uniswapV2Pair_ == address(0)) {
            uniswapV2Pair_ = IUniswapV2Factory(_uniswapRouter.factory())
                .createPair(address(this), pairToken);

            emit LiquidityPoolCreated(uniswapV2Pair_);
        }

        _liquidityPools.add(uniswapV2Pair_);

        return (uniswapV2Pair_);
    }

    /**
     * @dev Add initial liquidity (external)
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
    ) external onlyOwnerOrFactory {
        _addInitialLiquidity(_lockerFactory, _lockerOwner, _beneficiary, _beneficiaryShare);
    }

    /**
     * @dev Add initial liquidity (internal)
     * @notice Two modes:
     *   - Aerodrome (Base): LP tokens locked FOREVER via V2LockerFactory
     *   - BSC: LP tokens burned to DEAD_ADDRESS
     * @param _lockerFactory V2LockerFactory address. If address(0) - burn LP (BSC mode)
     * @param _lockerOwner Owner of the locker (can unlock LP after lockUntil)
     * @param _beneficiary Address that receives trading fees
     * @param _beneficiaryShare Share of fees for beneficiary (basis points, 10000 = 100%)
     */
    function _addInitialLiquidity(
        address _lockerFactory,
        address _lockerOwner,
        address _beneficiary,
        uint16 _beneficiaryShare
    ) internal {
        if (fundedDate != 0) {
            revert InitialLiquidityAlreadyAdded();
        }

        fundedDate = uint32(block.timestamp);

        if (balanceOf(address(this)) == 0) {
            revert NoTokenForLiquidityPair();
        }

        // Approve router (for auto-swaps/compatibility)
        _approve(address(this), address(_uniswapRouter), type(uint256).max);
        IERC20(pairToken).approve(address(_uniswapRouter), type(uint256).max);

        // Manual liquidity addition via pair
        address pairAddr = IUniswapV2Factory(_uniswapRouter.factory()).getPair(
            address(this),
            pairToken
        );

        uint256 amountA = balanceOf(address(this));
        uint256 amountB = IERC20(pairToken).balanceOf(address(this));

        _transfer(address(this), pairAddr, amountA, false);
        IERC20(pairToken).transfer(pairAddr, amountB);

        uint256 lpTokens = IUniswapV2Pair(pairAddr).mint(address(this));
        emit InitialLiquidityAdded(amountA, amountB, lpTokens);

        _autoSwapInProgress = false;

        // Handle LP tokens based on network mode
        if (_lockerFactory != address(0)) {
            // ========== AERODROME MODE (Base) ==========
            // Lock LP tokens FOREVER via V2LockerFactory
            lockerFactory = _lockerFactory;
            lockerOwner = _lockerOwner;
            feeBeneficiary = _beneficiary;
            beneficiaryShare = _beneficiaryShare;

            // Approve locker factory to spend LP tokens
            IERC20(uniswapV2Pair).approve(_lockerFactory, lpTokens);

            // Lock until max uint32 (year 2106) = FOREVER
            uint32 lockUntil = type(uint32).max;

            // Create locker and lock LP tokens
            // Params: pool, lp, lockUntil, beneficiary, beneficiaryShare, bribeableShare, owner
            lpLocker = IV2LockerFactory(_lockerFactory).lock(
                uniswapV2Pair,           // _pool: LP token address
                lpTokens,                // _lp: amount
                lockUntil,               // _lockUntil: max uint32 = FOREVER
                _beneficiary,            // _beneficiary: receives trading fees
                _beneficiaryShare,       // _beneficiaryShare: % of fees (10000 = 100%)
                0,                       // _bribeableShare: 0 (no bribes)
                _lockerOwner             // _owner: can unlock (after lockUntil = never)
            );

            emit LPLocked(lpLocker, lpTokens, lockUntil, _lockerOwner, _beneficiary, _beneficiaryShare);
        } else {
            // ========== BSC MODE ==========
            // Burn LP tokens to DEAD_ADDRESS (rug pull impossible)
            IERC20(uniswapV2Pair).transfer(DEAD_ADDRESS, lpTokens);

            emit LPBurned(lpTokens);
        }
    }

    /// @notice Emitted when LP tokens are locked (Aerodrome/Base)
    event LPLocked(
        address indexed locker,
        uint256 lpAmount,
        uint32 lockUntil,
        address lockerOwner,
        address beneficiary,
        uint16 beneficiaryShare
    );

    /// @notice Emitted when LP tokens are burned (BSC)
    event LPBurned(uint256 lpAmount);

    function isLiquidityPool(address queryAddress_) public view returns (bool) {
        return (queryAddress_ == uniswapV2Pair ||
            _liquidityPools.contains(queryAddress_));
    }

    function liquidityPools()
        external
        view
        returns (address[] memory liquidityPools_)
    {
        return (_liquidityPools.values());
    }

    function addLiquidityPool(
        address newLiquidityPool_
    ) public onlyOwnerOrFactory {
        if (newLiquidityPool_ == address(0)) {
            revert LiquidityPoolCannotBeAddressZero();
        }
        if (newLiquidityPool_.code.length == 0) {
            revert LiquidityPoolMustBeAContractAddress();
        }
        _liquidityPools.add(newLiquidityPool_);
        emit LiquidityPoolAdded(newLiquidityPool_);
    }

    function removeLiquidityPool(
        address removedLiquidityPool_
    ) external onlyOwnerOrFactory {
        _liquidityPools.remove(removedLiquidityPool_);
        emit LiquidityPoolRemoved(removedLiquidityPool_);
    }

    function isValidCaller(bytes32 queryHash_) public view returns (bool) {
        return (_validCallerCodeHashes.contains(queryHash_));
    }

    function validCallers()
        external
        view
        returns (bytes32[] memory validCallerHashes_)
    {
        return (_validCallerCodeHashes.values());
    }

    function addValidCaller(
        bytes32 newValidCallerHash_
    ) external onlyOwnerOrFactory {
        _validCallerCodeHashes.add(newValidCallerHash_);
        emit ValidCallerAdded(newValidCallerHash_);
    }

    function removeValidCaller(
        bytes32 removedValidCallerHash_
    ) external onlyOwnerOrFactory {
        _validCallerCodeHashes.remove(removedValidCallerHash_);
        emit ValidCallerRemoved(removedValidCallerHash_);
    }

    function setProjectTaxRecipient(
        address projectTaxRecipient_
    ) external onlyOwnerOrFactory {
        projectTaxRecipient = projectTaxRecipient_;
        emit ProjectTaxRecipientUpdated(projectTaxRecipient_);
    }

    function setSwapThresholdBasisPoints(
        uint16 swapThresholdBasisPoints_
    ) external onlyOwnerOrFactory {
        uint256 oldswapThresholdBasisPoints = swapThresholdBasisPoints;
        swapThresholdBasisPoints = swapThresholdBasisPoints_;
        emit AutoSwapThresholdUpdated(
            oldswapThresholdBasisPoints,
            swapThresholdBasisPoints_
        );
    }

    function setProjectTaxRates(
        uint16 newProjectBuyTaxBasisPoints_,
        uint16 newProjectSellTaxBasisPoints_
    ) external onlyOwnerOrFactory {
        // Check max tax (0% - tax disabled)
        require(
            newProjectBuyTaxBasisPoints_ <= MAX_TAX_BASIS_POINTS,
            "Buy tax exceeds maximum 0%"
        );
        require(
            newProjectSellTaxBasisPoints_ <= MAX_TAX_BASIS_POINTS,
            "Sell tax exceeds maximum 0%"
        );

        uint16 oldBuyTaxBasisPoints = projectBuyTaxBasisPoints;
        uint16 oldSellTaxBasisPoints = projectSellTaxBasisPoints;

        projectBuyTaxBasisPoints = newProjectBuyTaxBasisPoints_;
        projectSellTaxBasisPoints = newProjectSellTaxBasisPoints_;

        _tokenHasTax =
            (projectBuyTaxBasisPoints + projectSellTaxBasisPoints) > 0;

        emit ProjectTaxBasisPointsChanged(
            oldBuyTaxBasisPoints,
            newProjectBuyTaxBasisPoints_,
            oldSellTaxBasisPoints,
            newProjectSellTaxBasisPoints_
        );
    }

    // ===== ERC20 standard =====

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function totalBuyTaxBasisPoints() public view returns (uint256) {
        return projectBuyTaxBasisPoints;
    }

    function totalSellTaxBasisPoints() public view returns (uint256) {
        return projectSellTaxBasisPoints;
    }

    function balanceOf(
        address account
    ) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function transfer(
        address to,
        uint256 amount
    ) public virtual override(IERC20) returns (bool) {
        address owner = _msgSender();
        _transfer(
            owner,
            to,
            amount,
            (isLiquidityPool(owner) || isLiquidityPool(to))
        );
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(
            from,
            to,
            amount,
            (isLiquidityPool(from) || isLiquidityPool(to))
        );
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < subtractedValue) {
            revert AllowanceDecreasedBelowZero();
        }
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount,
        bool applyTax
    ) internal virtual {
        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _pretaxValidationAndLimits(from, to, amount);

        _autoSwap(from, to);

        uint256 amountMinusTax = _taxProcessing(applyTax, to, from, amount);

        _balances[from] = fromBalance - amount;
        _balances[to] += amountMinusTax;

        emit Transfer(from, to, amountMinusTax);

        _afterTokenTransfer(from, to, amount);
    }

    function _pretaxValidationAndLimits(
        address from_,
        address to_,
        uint256 amount_
    ) internal view returns (uint256 fromBalance_) {
        if (to_ == uniswapV2Pair && from_ != address(this) && fundedDate == 0) {
            revert InitialLiquidityNotYetAdded();
        }
        if (from_ == address(0)) {
            revert TransferFromZeroAddress();
        }
        if (to_ == address(0)) {
            revert TransferToZeroAddress();
        }
        fromBalance_ = _balances[from_];
        if (fromBalance_ < amount_) {
            revert TransferAmountExceedsBalance();
        }
        return (fromBalance_);
    }

    function _taxProcessing(
        bool applyTax_,
        address to_,
        address from_,
        uint256 sentAmount_
    ) internal returns (uint256 amountLessTax_) {
        amountLessTax_ = sentAmount_;
        unchecked {
            if (_tokenHasTax && applyTax_ && !_autoSwapInProgress) {
                uint256 tax;

                // sell
                if (isLiquidityPool(to_) && totalSellTaxBasisPoints() > 0) {
                    if (projectSellTaxBasisPoints > 0) {
                        uint256 projectTax = ((sentAmount_ *
                            projectSellTaxBasisPoints) / BP_DENOM);
                        projectTaxPendingSwap += uint128(projectTax);
                        tax += projectTax;
                    }
                }
                // buy
                else if (
                    isLiquidityPool(from_) && totalBuyTaxBasisPoints() > 0
                ) {
                    if (projectBuyTaxBasisPoints > 0) {
                        uint256 projectTax = ((sentAmount_ *
                            projectBuyTaxBasisPoints) / BP_DENOM);
                        projectTaxPendingSwap += uint128(projectTax);
                        tax += projectTax;
                    }
                }

                if (tax > 0) {
                    _balances[address(this)] += tax;
                    emit Transfer(from_, address(this), tax);
                    amountLessTax_ -= tax;
                }
            }
        }
        return (amountLessTax_);
    }

    function _autoSwap(address from_, address to_) internal {
        if (_tokenHasTax) {
            uint256 contractBalance = balanceOf(address(this));
            uint256 swapBalance = contractBalance;

            uint256 swapThresholdInTokens = (_totalSupply *
                swapThresholdBasisPoints) / BP_DENOM;

            if (
                _eligibleForSwap(from_, to_, swapBalance, swapThresholdInTokens)
            ) {
                _autoSwapInProgress = true;

                if (
                    swapBalance >
                    swapThresholdInTokens * MAX_SWAP_THRESHOLD_MULTIPLE
                ) {
                    swapBalance =
                        swapThresholdInTokens *
                        MAX_SWAP_THRESHOLD_MULTIPLE;
                }

                _swapTax(swapBalance, contractBalance);

                _autoSwapInProgress = false;
            }
        }
    }

    function _eligibleForSwap(
        address from_,
        address to_,
        uint256 taxBalance_,
        uint256 swapThresholdInTokens_
    ) internal view returns (bool) {
        return (taxBalance_ >= swapThresholdInTokens_ &&
            !_autoSwapInProgress &&
            !isLiquidityPool(from_) &&
            from_ != address(_uniswapRouter) &&
            to_ != address(_uniswapRouter) &&
            from_ != address(this));
    }

    function _swapTax(uint256 swapBalance_, uint256 contractBalance_) internal {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pairToken;

        try
            _uniswapRouter
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    swapBalance_,
                    0,
                    path,
                    projectTaxRecipient,
                    block.timestamp + 600
                )
        {
            if (swapBalance_ < contractBalance_) {
                projectTaxPendingSwap -= uint128(
                    (projectTaxPendingSwap * swapBalance_) / contractBalance_
                );
            } else {
                projectTaxPendingSwap = 0;
            }
        } catch {
            emit ExternalCallError(5);
        }
    }

    function distributeTaxTokens() external {
        if (projectTaxPendingSwap > 0) {
            uint256 projectDistribution = projectTaxPendingSwap;
            projectTaxPendingSwap = 0;
            _transfer(
                address(this),
                projectTaxRecipient,
                projectDistribution,
                false
            );
        }
    }

    function withdrawETH(uint256 amount_) external onlyOwnerOrFactory {
        (bool success, ) = _msgSender().call{value: amount_}("");
        if (!success) {
            revert TransferFailed();
        }
    }

    function withdrawERC20(
        address token_,
        uint256 amount_
    ) external onlyOwnerOrFactory {
        if (token_ == address(this)) {
            revert CannotWithdrawThisToken();
        }
        IERC20(token_).safeTransfer(_msgSender(), amount_);
    }

    function _mint(address account, uint256 amount) internal virtual {
        if (account == address(0)) {
            revert MintToZeroAddress();
        }

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += uint128(amount);
        unchecked {
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        if (account == address(0)) {
            revert BurnFromTheZeroAddress();
        }

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        if (accountBalance < amount) {
            revert BurnExceedsBalance();
        }

        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply -= uint128(amount);
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        if (owner == address(0)) {
            revert ApproveFromTheZeroAddress();
        }
        if (spender == address(0)) {
            revert ApproveToTheZeroAddress();
        }

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function burn(uint256 value) public virtual {
        _burn(_msgSender(), value);
    }

    function burnFrom(address account, uint256 value) public virtual {
        _spendAllowance(account, _msgSender(), value);
        _burn(account, value);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

    receive() external payable {}
}
