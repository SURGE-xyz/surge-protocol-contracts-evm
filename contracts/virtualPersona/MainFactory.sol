// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "./IMainFactory.sol";
import "./IMainToken.sol";

contract MainFactory is
    IMainFactory,
    Initializable,
    AccessControl,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // --- storage ---
    uint256 private _nextId;

    address public tokenImplementation; // MainToken template (clone)
    address public assetToken; // Base asset (e.g. WETH/USDC)

    // MainToken parameters (set by admin)
    address private _uniswapRouter;
    address private _tokenAdmin;
    bytes private _tokenSupplyParams;
    bytes private _tokenTaxParams;

    // Roles
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE");
    bytes32 public constant BONDING_ROLE = keccak256("BONDING_ROLE");

    // Threshold for proposeToken (kept for compatibility)
    uint256 public applicationThreshold;

    // Optional (not used currently, kept for backward compatibility)
    address private _vault;

    // ========== LP Locker Configuration (Aerodrome/Base) ==========
    /// @notice V2LockerFactory address (Aerodrome). If address(0) - LP tokens are burned (BSC mode)
    address private _lockerFactory;
    /// @notice Locker owner address (can unlock LP after lockUntil)
    address private _lockerOwner;
    /// @notice Fee beneficiary address (receives trading fees from LP)
    address private _feeBeneficiary;
    /// @notice Beneficiary share in basis points (10000 = 100%)
    uint16 private _beneficiaryShare;

    // Token clones tracking
    address[] public allTradingTokens;
    mapping(address => bool) private _existingTokens;

    // --- Application model (kept for compatibility with Bonding interface) ---
    enum ApplicationStatus {
        Active,
        Executed,
        Withdrawn
    }
    event NewApplication(uint256 indexed id);

    struct Application {
        string name;
        string symbol;
        string tokenURI; // unused
        ApplicationStatus status;
        uint256 withdrawableAmount;
        address proposer;
        uint8[] cores; // unused
        uint256 proposalEndBlock;
        uint256 virtualId; // unused
        bytes32 tbaSalt; // unused
        address tbaImplementation; // unused
        uint32 daoVotingPeriod; // unused
        uint256 daoThreshold; // unused
    }

    mapping(uint256 => Application) private _applications;

    error TokenAlreadyExists();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------- initialize (5 arguments) --------
    function initialize(
        address tokenImplementation_,
        address assetToken_,
        uint256 applicationThreshold_,
        address vault_,
        uint256 nextId_
    ) public initializer {
        __Pausable_init();

        require(tokenImplementation_ != address(0), "tokenImpl=0");
        require(assetToken_ != address(0), "asset=0");

        tokenImplementation = tokenImplementation_;
        assetToken = assetToken_;
        applicationThreshold = applicationThreshold_;
        _vault = vault_;
        _nextId = nextId_;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // -------- views --------
    function getApplication(
        uint256 id
    ) public view returns (Application memory) {
        return _applications[id];
    }

    function totalTokens() public view returns (uint256) {
        return allTradingTokens.length;
    }

    // -------- propose / withdraw (compatibility; optional) --------
    function proposeToken(
        string memory name,
        string memory symbol,
        string memory tokenURI,
        uint8[] memory cores,
        bytes32 tbaSalt,
        address tbaImplementation,
        uint32 daoVotingPeriod,
        uint256 daoThreshold
    ) public whenNotPaused returns (uint256) {
        address sender = _msgSender();

        require(
            IERC20(assetToken).balanceOf(sender) >= applicationThreshold,
            "Insufficient asset token"
        );
        require(
            IERC20(assetToken).allowance(sender, address(this)) >=
                applicationThreshold,
            "Insufficient allowance"
        );
        require(cores.length > 0, "Cores must be provided");

        IERC20(assetToken).safeTransferFrom(
            sender,
            address(this),
            applicationThreshold
        );

        uint256 id = _nextId++;
        uint256 proposalEndBlock = block.number;

        _applications[id] = Application({
            name: name,
            symbol: symbol,
            tokenURI: tokenURI,
            status: ApplicationStatus.Active,
            withdrawableAmount: applicationThreshold,
            proposer: sender,
            cores: cores,
            proposalEndBlock: proposalEndBlock,
            virtualId: 0,
            tbaSalt: tbaSalt,
            tbaImplementation: tbaImplementation,
            daoVotingPeriod: daoVotingPeriod,
            daoThreshold: daoThreshold
        });

        emit NewApplication(id);
        return id;
    }

    function withdraw(uint256 id) public {
        Application storage application = _applications[id];

        require(
            msg.sender == application.proposer ||
                hasRole(WITHDRAW_ROLE, msg.sender),
            "Not proposer"
        );
        require(
            application.status == ApplicationStatus.Active,
            "Application not active"
        );
        require(block.number > application.proposalEndBlock, "Not matured");

        uint256 amt = application.withdrawableAmount;
        application.withdrawableAmount = 0;
        application.status = ApplicationStatus.Withdrawn;

        IERC20(assetToken).safeTransfer(application.proposer, amt);
    }

    // -------- internal: create token + add initial LP --------
    function _executeApplication(
        uint256 id,
        bytes memory tokenSupplyParams_,
        bytes32 salt
    ) internal returns (address token) {
        require(
            _applications[id].status == ApplicationStatus.Active,
            "Application inactive"
        );
        require(_tokenAdmin != address(0), "Token admin not set");

        Application storage application = _applications[id];

        uint256 initialAmount = application.withdrawableAmount;
        application.withdrawableAmount = 0;
        application.status = ApplicationStatus.Executed;

        // 1) Clone MainToken - pass proposer as owner
        token = _createNewMainToken(
            application.name,
            application.symbol,
            tokenSupplyParams_,
            salt,
            application.proposer // creator becomes token owner
        );

        // 2) Transfer asset to token and add liquidity
        IERC20(assetToken).safeTransfer(token, initialAmount);
        
        // Add liquidity with locker config:
        // - If _lockerFactory is set (Aerodrome/Base): LP tokens are locked FOREVER via V2LockerFactory
        //   - Creator (proposer) = locker owner -> gets (100% - beneficiaryShare) of fees
        //   - Platform (feeBeneficiary) = beneficiary -> gets beneficiaryShare of fees
        // - If _lockerFactory is address(0) (BSC): LP tokens are burned
        IMainToken(token).addInitialLiquidity(
            _lockerFactory,         // V2LockerFactory address (or address(0) for BSC)
            application.proposer,   // Creator = locker owner (gets 100% - beneficiaryShare, e.g. 5%)
            _feeBeneficiary,        // Platform = beneficiary (gets beneficiaryShare, e.g. 95%)
            _beneficiaryShare       // Platform share in BPS (e.g. 9500 = 95%)
        );

        return token;
    }

    function _createNewMainToken(
        string memory name,
        string memory symbol,
        bytes memory tokenSupplyParams_,
        bytes32 salt,
        address tokenOwner // token owner parameter
    ) internal returns (address instance) {
        instance = Clones.cloneDeterministic(tokenImplementation, salt);
        if (_existingTokens[instance]) {
            revert TokenAlreadyExists();
        }
        _existingTokens[instance] = true;

        // tokenOwner (creator) becomes token owner instead of _tokenAdmin
        IMainToken(instance).initialize(
            [tokenOwner, _uniswapRouter, assetToken],
            abi.encode(name, symbol),
            tokenSupplyParams_,
            _tokenTaxParams
        );

        allTradingTokens.push(instance);
        return instance;
    }

    // -------- public factory actions --------
    function executeApplication(
        uint256 id,
        bool /*canStake*/, // unused in DEX-only
        bytes32 salt
    ) public {
        Application storage application = _applications[id];
        require(
            msg.sender == application.proposer ||
                hasRole(WITHDRAW_ROLE, msg.sender),
            "Not proposer"
        );
        _executeApplication(id, _tokenSupplyParams, salt);
    }

    // --- Bonding API (used from Bonding.sol) ---
    function initFromBondingCurve(
        string memory name,
        string memory symbol,
        uint8[] memory cores,
        bytes32 /*tbaSalt*/,
        address /*tbaImplementation*/,
        uint32 /*daoVotingPeriod*/,
        uint256 /*daoThreshold*/,
        uint256 applicationThreshold_,
        address creator
    ) public whenNotPaused onlyRole(BONDING_ROLE) returns (uint256) {
        address sender = _msgSender();

        require(
            IERC20(assetToken).balanceOf(sender) >= applicationThreshold_,
            "Insufficient asset token"
        );
        require(
            IERC20(assetToken).allowance(sender, address(this)) >=
                applicationThreshold_,
            "Insufficient allowance"
        );
        require(cores.length > 0, "Cores must be provided");

        IERC20(assetToken).safeTransferFrom(
            sender,
            address(this),
            applicationThreshold_
        );

        uint256 id = _nextId++;
        uint256 proposalEndBlock = block.number;

        _applications[id] = Application({
            name: name,
            symbol: symbol,
            tokenURI: "",
            status: ApplicationStatus.Active,
            withdrawableAmount: applicationThreshold_,
            proposer: creator, // important: application owner is the creator
            cores: cores,
            proposalEndBlock: proposalEndBlock,
            virtualId: 0,
            tbaSalt: 0,
            tbaImplementation: address(0),
            daoVotingPeriod: 0,
            daoThreshold: 0
        });

        emit NewApplication(id);
        return id;
    }

    function executeBondingCurveApplication(
        uint256 id,
        uint256 totalSupply,
        uint256 lpSupply,
        address vault
    ) public onlyRole(BONDING_ROLE) returns (address) {
        return
            executeBondingCurveApplicationSalt(
                id,
                totalSupply,
                lpSupply,
                vault,
                keccak256(abi.encodePacked(msg.sender, block.timestamp))
            );
    }

    function executeBondingCurveApplicationSalt(
        uint256 id,
        uint256 totalSupply,
        uint256 lpSupply,
        address vault,
        bytes32 salt
    ) public onlyRole(BONDING_ROLE) returns (address) {
        // Configure supply params for MainToken.initialize(...)
        bytes memory tokenSupplyParams = abi.encode(
            totalSupply, // maxSupply
            lpSupply, // lpSupply
            totalSupply - lpSupply, // vaultSupply
            totalSupply, // maxTokensPerWallet (no limit)
            totalSupply, // maxTokensPerTxn (no limit)
            0, // botProtectionDurationInSeconds
            vault // vault
        );

        address token = _executeApplication(id, tokenSupplyParams, salt);
        return token;
    }

    // -------- admin setters --------
    function setApplicationThreshold(
        uint256 newThreshold
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        applicationThreshold = newThreshold;
    }

    function setVault(address newVault) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _vault = newVault;
    }

    function setImplementations(
        address token
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenImplementation = token;
    }

    function setParams(
        uint256 /*newMaturityDuration*/, // unused
        address newRouter,
        address /*newDelegatee*/, // unused
        address newTokenAdmin
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _uniswapRouter = newRouter;
        _tokenAdmin = newTokenAdmin;
    }

    /// @notice Configure LP locker for Aerodrome (Base network)
    /// @dev If lockerFactory_ is address(0), LP tokens will be burned (BSC mode)
    /// @dev Fee distribution: Creator gets (100% - beneficiaryShare_), Platform gets beneficiaryShare_
    /// @param lockerFactory_ V2LockerFactory address (Aerodrome). Set to address(0) for BSC
    /// @param lockerOwner_ Fallback owner (not used - creator comes from application.proposer)
    /// @param beneficiary_ Platform address that receives beneficiaryShare_ of trading fees
    /// @param beneficiaryShare_ Platform share (basis points, e.g. 9500 = 95% platform, 5% creator)
    function setLockerConfig(
        address lockerFactory_,
        address lockerOwner_,
        address beneficiary_,
        uint16 beneficiaryShare_
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(beneficiaryShare_ <= 10000, "Share > 100%");
        _lockerFactory = lockerFactory_;
        _lockerOwner = lockerOwner_;
        _feeBeneficiary = beneficiary_;
        _beneficiaryShare = beneficiaryShare_;
    }

    /// @notice Get current locker factory address
    function lockerFactory() public view returns (address) {
        return _lockerFactory;
    }

    /// @notice Get current locker owner
    function lockerOwner() public view returns (address) {
        return _lockerOwner;
    }

    /// @notice Get current fee beneficiary
    function feeBeneficiary() public view returns (address) {
        return _feeBeneficiary;
    }

    /// @notice Get current beneficiary share (basis points)
    function beneficiaryShare() public view returns (uint16) {
        return _beneficiaryShare;
    }

    function setTokenParams(
        uint256 maxSupply,
        uint256 lpSupply,
        uint256 vaultSupply,
        uint256 maxTokensPerWallet,
        uint256 maxTokensPerTxn,
        uint256 botProtectionDurationInSeconds,
        address vault,
        uint256 projectBuyTaxBasisPoints,
        uint256 projectSellTaxBasisPoints,
        uint256 taxSwapThresholdBasisPoints,
        address projectTaxRecipient
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require((lpSupply + vaultSupply) <= maxSupply, "Invalid supply");

        _tokenSupplyParams = abi.encode(
            maxSupply,
            lpSupply,
            vaultSupply,
            maxTokensPerWallet,
            maxTokensPerTxn,
            botProtectionDurationInSeconds,
            vault
        );

        _tokenTaxParams = abi.encode(
            projectBuyTaxBasisPoints,
            projectSellTaxBasisPoints,
            taxSwapThresholdBasisPoints,
            projectTaxRecipient
        );
    }

    // -------- pause --------
    function pause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // -------- ctx glue (due to mixed inheritance) --------
    function _msgSender()
        internal
        view
        override(Context, ContextUpgradeable)
        returns (address sender)
    {
        sender = ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(Context, ContextUpgradeable)
        returns (bytes calldata)
    {
        return ContextUpgradeable._msgData();
    }
}
