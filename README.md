# Xstocks Smart Contracts

ERC-1271 smart accounts for CoW Protocol integration. Users deposit USDC, the backend operator signs CoW swap orders on their behalf to batch-buy RWA stock tokens (xtocks).

## Architecture

- **AccountFactory** — deploys one `UserAccount` per user via CREATE2 (predictable addresses)
- **UserAccount** — ERC-1271 contract that validates operator/owner signatures for CoW Protocol settlement

## Deployed Addresses

### Ink Mainnet (Chain ID: 57073)

| Contract | Address |
|----------|---------|
| AccountFactory | `0x52ce41F6B4e95b6891F93Ad85165b525412e1362` |
| Operator | `0xB351edfb846d7c26Aed130c2DE66151c1efF5236` |
| USDC | `0x2D270e6886d130D724215A266106e6832161EAEd` |
| CoW Relayer | `0xC92E8bdf79f0507f65a392b0ab4667716BFE0110` |

## Stack

- Foundry (forge, cast, anvil)
- Solidity ^0.8.20
- OpenZeppelin Contracts (ECDSA, SafeERC20)

## Commands

```bash
forge build          # compile
forge test -vvv      # run tests verbose
forge fmt            # format code
forge script script/DeployFactory.s.sol --rpc-url <RPC> --broadcast  # deploy
```

## Deploy env vars

- `PRIVATE_KEY` — deployer private key
- `OPERATOR` — backend signer address
- `USDC` — USDC token address on target chain
- `COW_RELAYER` — CoW Protocol GPv2VaultRelayer address on target chain

## Key design decisions

- COW_RELAYER is a constructor param (not hardcoded) for multi-chain support
- Owner AND operator can both sign via ERC-1271
- SafeERC20 used for token interactions
- No pause/upgrade mechanism — minimal accounts by design
