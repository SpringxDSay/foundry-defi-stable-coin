// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from 'forge-std/Test.sol';
import {DSCEngine} from '../../src/DSCEngine.sol';
import {DeployDSC} from '../../script/DeployDSC.s.sol';
import {DecentralizedStableCoin} from '../../src/DecentralizedStableCoin.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {ERC20Mock} from '@openzepplin/contracts/mocks/ERC20Mock.sol'; 
import {MockV3Aggregator} from '../../test/mocks/MockV3Aggregator.sol';
import {MockFailedMintDSC} from '../mocks/MockFailedMntDSC.sol';

contract DscEngine  is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address public weth;
    address public wethUsdPrice;
    address public wbtcUsdPrice;
    address public USER = makeAddr('user');
    address public LIQUIDATOR = makeAddr('liquidator');
    uint256 public  collateralAmount = 10 ether;
    uint256 public  dscAmount = 5 ether;
    uint256 public  amountToMint = 100 ether;
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
 

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run(); 
        (wethUsdPrice, wbtcUsdPrice, weth, ,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }
    ////////////////////////////////
    //// CONSTRUCTOR TEST   ////////
    ////////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenAddressesLengthDoesntMatchPricefeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPrice);
        priceFeedAddresses.push(wbtcUsdPrice);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressLengthMustBeTheSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    


    ////////////////////////
    //// PRICE FEED ////////
    ////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenEthValue() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenEthValue(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ////////////////////////////////
    //// DEPOSIT COLLATERAL ////////
    ////////////////////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(weth, collateralAmount);
        _;
    }

     modifier depositedCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateralAndMintDSC(weth, collateralAmount, dscAmount);
        _;
    }

    function testReversalIfCollateralIsZero() public {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock('RAN', 'RAN', USER, collateralAmount);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(randomToken), collateralAmount);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenEthValue(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collateralAmount, expectedDepositAmount);
    }

    function testCanDepositCollateralAndMintDsc() public depositedCollateralAndMintDsc {
        (uint256 totalDscMinted, ) = dscEngine.getAccountInformation(USER);
        uint256 collateralDeposited = dscEngine.getCollateralDeposited(USER, weth);

        assertEq(totalDscMinted, dscAmount);
        assertEq(collateralAmount, collateralDeposited);
    }

     function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(wethUsdPrice).latestRoundData();
        amountToMint = (collateralAmount * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);

        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, collateralAmount));
        console.log(expectedHealthFactor);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDSC(weth, collateralAmount, amountToMint);
        vm.stopPrank();
    }

     function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();

        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPrice];

        address owner = msg.sender;
        
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), collateralAmount);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDSC(weth, collateralAmount, amountToMint);
        vm.stopPrank();
    }


    ////////////////////////////////
    //// MINT DSC /////////////////
    ////////////////////////////////

    function testAmountDscMinted() public depositedCollateralAndMintDsc {
        assertEq(dscEngine.getDscMinted(USER), dscAmount);
    }

    function testMintRevertsWhenHealthFactorBroken() public depositedCollateral {
        vm.stopPrank();
        amountToMint = 1000e18 ;// 1000 DSC


        // Simulate collateral price drop, causing health factor to break
        int256 ethUsdUpdatedPrice  = 18e8;

        MockV3Aggregator(wethUsdPrice).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, collateralAmount));

        // Expect revert due to health factor being broken
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, userHealthFactor));
        dscEngine.mintDSC(amountToMint);
        vm.stopPrank();
    }

    ////////////////////////////////
    //// BURN DSC //////////////////
    ////////////////////////////////

    function testSuccessfulBurn() public depositedCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), dscAmount);
        dscEngine.burnDSC(dscAmount);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscEngine.burnDSC(1);
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateralAndMintDSC(weth, collateralAmount, dscAmount);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDSC(0);
        vm.stopPrank();
    }
    
    ////////////////////////////////
    //// REDEEM COLLATERAL /////////
    ////////////////////////////////


    function testRedeemCollateral() public depositedCollateralAndMintDsc {
        dscEngine.redeemCollateral(weth, dscAmount);
        // $150 ETH -- $50 DSC
        uint256 collateralBalanceAfterRedemption = dscEngine.getCollateralDeposited(USER, weth);
        uint256 expectedCollateralBalance = collateralAmount - dscAmount;
     
        assertEq(collateralBalanceAfterRedemption, expectedCollateralBalance);
        assertEq(ERC20Mock(weth).balanceOf(USER), dscAmount);

    }

    function testHealthFactor() public depositedCollateralAndMintDsc {
        uint256 amountCollateral = dscEngine.getUsdValue(weth, collateralAmount); 

        uint256 expectedCollateral = (amountCollateral * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 expectedHealthFactor = (expectedCollateral * PRECISION) / dscAmount;

        assertEq(dscEngine._healthFactor(USER), expectedHealthFactor);
    }

    ////////////////////////////////
    //// LIQUIDATE /////////////////
    ////////////////////////////////

    function testLiquidateRevertsWhenHealthFactorIsOk() public depositedCollateralAndMintDsc {
        // Setup: Set a scenario where user's health factor is above the minimum
        // Ensure the _healthFactor function returns a value >= MIN_HEALTH_FACTOR for the user
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOk.selector); 
        dscEngine.liquidate(weth, USER, dscAmount);
    }

    modifier liquidated {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountToMint);
        dscEngine.depositCollateralAndMintDSC(weth, collateralAmount, amountToMint);
        vm.stopPrank();

        int256 ethUsdUpdatedPrice  = 18e8;

        MockV3Aggregator(wethUsdPrice).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        console.log(userHealthFactor);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDSC(weth, COLLATERAL_TO_COVER, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 bonusCollateral = (dscEngine.getTokenEthValue(weth, amountToMint) / dscEngine.getLiquidationBonus());
        uint256 expectedWeth = dscEngine.getTokenEthValue(weth, amountToMint)
            + bonusCollateral;

        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

}
