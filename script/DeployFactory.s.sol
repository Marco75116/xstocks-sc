// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AccountFactory} from "../src/AccountFactory.sol";

contract DeployFactory is Script {
    function run() public {
        address operator = vm.envAddress("OPERATOR");
        address usdc = vm.envAddress("USDC");
        address cowRelayer = vm.envAddress("COW_RELAYER");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AccountFactory factory = new AccountFactory(operator, usdc, cowRelayer);

        vm.stopBroadcast();

        console.log("AccountFactory deployed at:", address(factory));
        console.log("  operator:   ", operator);
        console.log("  usdc:       ", usdc);
        console.log("  cowRelayer: ", cowRelayer);
    }
}
