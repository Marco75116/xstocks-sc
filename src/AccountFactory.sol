// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UserAccount} from "./UserAccount.sol";

/**
 * @title AccountFactory
 * @notice Deploys UserAccounts per user using CREATE2.
 *         Supports multiple accounts per user via a salt index.
 *         Emits AccountCreated so your indexer can track all accounts
 *         from a single contract address.
 *
 *         CREATE2 means you can predict a user's account address
 *         before deploying — users can deposit USDC immediately
 *         after connecting their wallet, before paying any gas.
 */
contract AccountFactory {
    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Your backend key — shared operator across all user accounts
    address public immutable operator;

    /// @notice USDC address on this chain
    address public immutable usdc;

    /// @notice Swap relayer address (CoW VaultRelayer on Ink, 1inch Router on Ethereum)
    address public immutable cowRelayer;

    /// @notice CoW Protocol settlement contract address
    address public immutable cowSettlement;

    /// @notice owner EOA => salt index => deployed UserAccount address
    mapping(address => mapping(uint256 => address)) public accountOf;

    // ─── Events ──────────────────────────────────────────────────────────────

    /**
     * @dev Index all three fields so your indexer can filter by:
     *      - account address  (to watch for Trade events on CoW)
     *      - owner address    (to look up a user's account)
     *      - operator address (sanity check / operator rotation tracking)
     */
    event AccountCreated(address indexed account, address indexed owner, address indexed operator, uint256 salt);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error AlreadyDeployed(address existing);
    error ZeroAddress();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _operator       Your backend key — set once, used for all accounts
     * @param _usdc           USDC token address on this chain
     * @param _cowRelayer     Swap relayer address (CoW VaultRelayer or 1inch Router)
     * @param _cowSettlement  CoW Protocol settlement contract address
     */
    constructor(address _operator, address _usdc, address _cowRelayer, address _cowSettlement) {
        if (_operator == address(0) || _usdc == address(0) || _cowRelayer == address(0) || _cowSettlement == address(0))
        {
            revert ZeroAddress();
        }
        operator = _operator;
        usdc = _usdc;
        cowRelayer = _cowRelayer;
        cowSettlement = _cowSettlement;
    }

    // ─── Core ────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy a UserAccount for a user.
     *         Call this from your backend when a user first connects.
     *         You pay the gas — user needs nothing.
     * @param owner      The user's EOA address
     * @param saltIndex  Index to allow multiple accounts per user (0, 1, 2, ...)
     * @param tokens     Xtocks token addresses to approve for the swap relayer
     * @return account   The deployed UserAccount address
     */
    function createAccount(address owner, uint256 saltIndex, address[] calldata tokens)
        external
        returns (address account)
    {
        if (owner == address(0)) revert ZeroAddress();

        address existing = accountOf[owner][saltIndex];
        if (existing != address(0)) revert AlreadyDeployed(existing);

        bytes32 salt = keccak256(abi.encodePacked(owner, saltIndex));

        account =
            address(new UserAccount{salt: salt}(owner, operator, address(usdc), cowRelayer, cowSettlement, tokens));

        accountOf[owner][saltIndex] = account;

        emit AccountCreated(account, owner, operator, saltIndex);
    }

    // ─── View ────────────────────────────────────────────────────────────────

    /**
     * @notice Predict a user's account address before deploying.
     *         Use this in your frontend — show the deposit address
     *         as soon as the user connects, before createAccount is called.
     * @param owner      The user's EOA address
     * @param saltIndex  Index matching the one passed to createAccount
     * @param tokens     The xtocks token addresses (must match createAccount call)
     * @return  The address the UserAccount will be deployed to
     */
    function predictAddress(address owner, uint256 saltIndex, address[] calldata tokens)
        public
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(owner, saltIndex));

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(UserAccount).creationCode, abi.encode(owner, operator, usdc, cowRelayer, cowSettlement, tokens)
            )
        );

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /**
     * @notice Check if a user has an account deployed at a given salt index.
     * @param owner      The user's EOA address
     * @param saltIndex  The salt index to check
     */
    function hasAccount(address owner, uint256 saltIndex) external view returns (bool) {
        return accountOf[owner][saltIndex] != address(0);
    }
}
