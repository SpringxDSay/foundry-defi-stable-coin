// This holds our invariants i.e. properties of the system that should always hold 

// 1. The total supply of DSC, totaDscMinted should be less than the total value of collateral
// 2. Getter view functions should never rever -> An evergreen invariant

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from 'forge-std/Test.sol';
import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {DeployDSC} from '../../script/DeployDSC.s.sol';
import {DecentralizedStableCoin} from '../../src/DecentralizedStableCoin.sol';
import {DSCEngine} from '../../src/DSCEngine.sol';
import {HelperConfig} from '../../script/HelperConfig.s.sol';
import {IERC20} from '@openzepplin/contracts/token/ERC20/IERC20.sol';
import {Handler} from './Handler.t.sol';

contract Invariants is StdInvariant, Test {  
    DecentralizedStableCoin dsc;
    DeployDSC deployer;
    DSCEngine dscEngine;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC(); 
        (dsc, dscEngine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveValueThanTotalSupply() public view {
        // Get all collateral values and compare it to the debt(Dsc minted)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

        uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log(totalWethDeposited, totalWbtcDeposited, totalSupply);

        assert(wethValue + wbtcValue >= totalSupply);
    }
 }