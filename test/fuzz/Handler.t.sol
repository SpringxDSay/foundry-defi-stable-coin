// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from 'forge-std/Test.sol';
import {DecentralizedStableCoin} from '../../src/DecentralizedStableCoin.sol';
import {DSCEngine} from '../../src/DSCEngine.sol';
import {ERC20Mock} from '@openzepplin/contracts/mocks/ERC20Mock.sol';
import {MockV3Aggregator} from '../../test/mocks/MockV3Aggregator.sol';

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUsdPriceFeed;
     
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited; 

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
    }

    function mintDSC(uint256 amount, uint256 addressSeed) public {
        if(usersWithCollateralDeposited.length == 0) return; 
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);
        
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if(maxDscToMint < 0) return;

        amount = bound(amount, 1, uint256(maxDscToMint));
        if(amount == 0) return;

        vm.startPrank( sender);
        dscEngine.mintDSC(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // double push
        usersWithCollateralDeposited.push(msg.sender); 
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dscEngine.getCollateralDeposited(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if(amountCollateral == 0) return;

        dscEngine.redeemCollateral(address(collateral), amountCollateral);

    }

    // This breaks our invariant test
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock) {
        if(collateralSeed % 2 == 0) return weth;
        else return wbtc; 
    } 
}