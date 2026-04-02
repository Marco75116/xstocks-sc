// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

address constant OPERATOR = 0xB351edfb846d7c26Aed130c2DE66151c1efF5236;

library InkConstants {
    address constant USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
    address constant SWAP_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110; // CoW VaultRelayer
    address constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
}

library EthConstants {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SWAP_RELAYER = 0x111111125421cA6dc452d289314280a0f8842A65; // 1inch Router v6
    address constant COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
}
