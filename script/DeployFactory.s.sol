// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {OPERATOR, InkConstants, EthConstants} from "./Constants.sol";

contract DeployFactoryInk is Script {
    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AccountFactory factory =
            new AccountFactory(OPERATOR, InkConstants.USDC, InkConstants.SWAP_RELAYER, InkConstants.COW_SETTLEMENT);

        vm.stopBroadcast();

        console.log("AccountFactory (Ink) deployed at:", address(factory));
        console.log("  operator:       ", OPERATOR);
        console.log("  usdc:           ", InkConstants.USDC);
        console.log("  swapRelayer:    ", InkConstants.SWAP_RELAYER);
        console.log("  cowSettlement:  ", InkConstants.COW_SETTLEMENT);
    }
}

contract DeployFactoryEth is Script {
    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AccountFactory factory =
            new AccountFactory(OPERATOR, EthConstants.USDC, EthConstants.SWAP_RELAYER, EthConstants.COW_SETTLEMENT);

        vm.stopBroadcast();

        console.log("AccountFactory (Ethereum) deployed at:", address(factory));
        console.log("  operator:       ", OPERATOR);
        console.log("  usdc:           ", EthConstants.USDC);
        console.log("  swapRelayer:    ", EthConstants.SWAP_RELAYER);
        console.log("  cowSettlement:  ", EthConstants.COW_SETTLEMENT);
    }
}
