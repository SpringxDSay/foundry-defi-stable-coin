// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from './DecentralizedStableCoin.sol';
import {ReentrancyGuard} from '@openzepplin/contracts/security/ReentrancyGuard.sol';
import {IERC20} from '@openzepplin/contracts/token/ERC20/IERC20.sol';
import {AggregatorV3Interface} from '@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol';
import {OracleLib} from './libraries/OracleLib.sol';

/**
 * @title DSCEngine 
 * @author 0xshuayb
 * 
 * The system is designed to be as minimal as possible, and have tokens maintain a 1 token == $1 peg.
 * This stable coin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged 
 * - Algorithmic Minting
 * 
 * Its is similar to DAI if DAI had no governace, zero fees and was only backed by wETH and wBTC.
 * 
 * Our DSC system should always be overcollateralized. At no point should the value of all collateral <= the $ backed value of all DSC
 * 
 * @notice This contract is the core of the Decentralized Stable Coin system. It handles all the logic for minting and redeeming DSC, as well as the deposit and withdrawal of collateral.
 * @notice This contract is VERY loosely ased on the MakerDAO DSS (DAI) system. 
 */

contract DSCEngine is ReentrancyGuard  {

    ///////////////// 
    /// ERRORS    /// 
    ///////////////// 
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressLengthMustBeTheSame(); 
    error DSCEngine__NotAllowedToken(); 
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor); 
    error DSCEngine__MintFailed(); 
    error DSCEngine__HealthFactorIsOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////// 
    /// TYPES    ////
    /////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////
    /// STATE VARIABLES ///  
    ///////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    mapping (address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscAmountMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc; 

    ///////////////////////
    /// EVENTS          /// 
    ///////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount); 

    ///////////////// 
    /// MODIFIERS /// 
    ///////////////// 

    modifier moreThanZero(uint256 amount) {
        if(amount == 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowed(address token) {
        if(s_priceFeeds[token] == address(0)) revert DSCEngine__NotAllowedToken();
        _;
    }

    ///////////////// 
    /// FUNCTIONS /// 
    ///////////////// 

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD PRICE FEED 
        if(tokenAddresses.length != priceFeedAddresses.length) revert DSCEngine__TokenAddressAndPriceFeedAddressLengthMustBeTheSame();

        for(uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; 
            s_collateralTokens.push(tokenAddresses[i]); 
        }
        i_dsc = DecentralizedStableCoin(dscAddress);

    }

    //////////////////////////
    /// EXTERNAL FUNCTIONS /// 
    //////////////////////////
    /**
     * 
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of token to deposit as collateral
     * @param dscAmountToMint The amout of DSC to mint
     * @notice This function deposits collateral and mint DSC in a transaction 
     */
    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 dscAmountToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(dscAmountToMint);
    }

    /**
     * @notice The function follows CEI, Checks, Effects and Interactions
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) isAllowed(tokenCollateralAddress) nonReentrant {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress
        , amountCollateral );
        (bool success) = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success) revert DSCEngine__TransferFailed();
    }
    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * 
     * This function burns DSC and redeems the underlying collateral in one transaction 
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks healh factor
    }

    // In order to redeem collateral:
    // 1. health factor > 1after collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) moreThanZero(amountCollateral) public {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param dscAmountToMint Amount of decentralized stable coin to mint
     * @notice they must have more collateral than the minimum threshold
     */
    function mintDSC(uint256 dscAmountToMint) public moreThanZero(dscAmountToMint) nonReentrant {
        s_DSCMinted[msg.sender] += dscAmountToMint;
        //If they minted too much for example trying to mint $150 DSC w $100 ETH
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender,dscAmountToMint);
        if(!minted) revert DSCEngine__MintFailed();
     }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); 
    }

    
    /**
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who has broken health factor. Their healthFactor should be < MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the user's _healthFactor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the user's funds
     * @notice This function working assumes the protocol will be 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol is < 100% collateralized, the we wouldn't be able to incentivice the liquidators
     * For example if the price of the collateral plummeted before anyone could be liquidated 
     */
    function liquidate(address collateral, address user, uint256 debtToCover) moreThanZero(debtToCover) nonReentrant external {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) revert DSCEngine__HealthFactorIsOk();

        // We need to pay the DSC they are owing(burning) and take their collateral
        uint256 ethValueOfDebtToCover = getTokenEthValue(collateral, debtToCover);
        // The liquidator gets 10% bonus
        // i.e. they get $110 for paying 100 DSC debt (Burning 100DSC)
        uint256 bonusCollateral = (ethValueOfDebtToCover * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = ethValueOfDebtToCover + bonusCollateral; 
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user); 
        if(endingUserHealthFactor <= startingUserHealthFactor) revert DSCEngine__HealthFactorNotImproved();

        _revertIfHealthFactorIsBroken(msg.sender); 
    }


    ////////////////////////////////////
    /// PRIVATE & INTERNAL FUNCTIONS /// 
    ////////////////////////////////////
    /**
     * @dev Low-level internal function. Do not call unless the function calling it is checking if health factor is broken 
     */
    function _burnDsc(uint256 amountDscToBurn, address debtor, address payer) public {
        s_DSCMinted[debtor] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(payer, address(this), amountDscToBurn);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        (bool success) = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user) private view returns(uint256 totalDSCMinted, uint256 collateralValueInUsd) {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * Returns how close to liquidation a player is
     * If a user goes below 1, they can get liquidated
     */

    function _healthFactor(address user) public view returns(uint256) {
        // total DSC minted $50
        // total collateral value $100
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
    }

    function getHealthFactor(address user) external view returns(uint256) { 
        return _healthFactor(user);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) internal pure returns(uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////
    /// GETTER FUNCTIONS    ////////////
    ////////////////////////////////////

    function getTokenEthValue(address token, uint256 usdAmountInWei) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , ,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getLiquidationBonus() public pure returns(uint256) {
        return LIQUIDATION_BONUS;
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they deposited and map it to the price to get the USD value
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getDscMinted(address user) external view returns(uint256) {
        return s_DSCMinted[user];
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns(uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user) external view returns(uint256 totalDSCMinted, uint256 collateralValueInUsd) {
        (totalDSCMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralDeposited(address user, address token) external view returns(uint256 totalCollateralValue) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns(address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getAdditionalFeedPrecision() external pure returns(uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns(uint256) {
        return PRECISION;
    }

}