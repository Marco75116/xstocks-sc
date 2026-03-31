# Xstocks Smart Contracts

## Project
ERC-1271 smart accounts for CoW Protocol integration. Users deposit USDC, the backend operator signs CoW swap orders on their behalf to batch-buy RWA stock tokens (xtocks).

## Architecture
- `AccountFactory` — deploys one `UserAccount` per user via CREATE2 (predictable addresses)
- `UserAccount` — ERC-1271 contract that validates operator/owner signatures for CoW Protocol settlement

## Stack
- Foundry (forge, cast, anvil)
- Solidity ^0.8.20
- OpenZeppelin Contracts (ECDSA, SafeERC20)

## Commands
```bash
forge build          # compile
forge test -vvv      # run tests verbose
forge fmt            # format code (CI enforces this)
forge script script/DeployFactory.s.sol --rpc-url <RPC> --broadcast  # deploy
```

## Deploy env vars
- `OPERATOR` — backend signer address
- `USDC` — USDC token address on target chain
- `COW_RELAYER` — CoW Protocol GPv2VaultRelayer address on target chain

## Key design decisions
- COW_RELAYER is a constructor param (not hardcoded) for multi-chain support
- Owner AND operator can both sign via ERC-1271
- SafeERC20 used for token interactions
- No pause/upgrade mechanism — minimal accounts by design
