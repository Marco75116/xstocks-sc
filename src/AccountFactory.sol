// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UserAccount} from "./UserAccount.sol";

/**
 * @title AccountFactory
 * @notice Deploys one UserAccount per user using CREATE2.
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

    /// @notice CoW Protocol VaultRelayer address on this chain
    address public immutable cowRelayer;

    /// @notice owner EOA => deployed UserAccount address
    mapping(address => address) public accountOf;

    // ─── Events ──────────────────────────────────────────────────────────────

    /**
     * @dev Index all three fields so your indexer can filter by:
     *      - account address  (to watch for Trade events on CoW)
     *      - owner address    (to look up a user's account)
     *      - operator address (sanity check / operator rotation tracking)
     */
    event AccountCreated(address indexed account, address indexed owner, address indexed operator);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error AlreadyDeployed(address existing);
    error ZeroAddress();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _operator   Your backend key — set once, used for all accounts
     * @param _usdc       USDC token address on this chain
     * @param _cowRelayer CoW Protocol VaultRelayer address on this chain
     */
    constructor(address _operator, address _usdc, address _cowRelayer) {
        if (_operator == address(0) || _usdc == address(0) || _cowRelayer == address(0)) {
            revert ZeroAddress();
        }
        operator = _operator;
        usdc = _usdc;
        cowRelayer = _cowRelayer;
    }

    // ─── Core ────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy a UserAccount for a user.
     *         Call this from your backend when a user first connects.
     *         You pay the gas — user needs nothing.
     * @param owner  The user's EOA address
     * @return account  The deployed UserAccount address
     */
    function createAccount(address owner) external returns (address account) {
        if (owner == address(0)) revert ZeroAddress();

        address existing = accountOf[owner];
        if (existing != address(0)) revert AlreadyDeployed(existing);

        // Salt is deterministic from owner address — same owner always
        // gets the same address across any chain with this factory
        bytes32 salt = keccak256(abi.encodePacked(owner));

        account = address(new UserAccount{salt: salt}(owner, operator, address(usdc), cowRelayer));

        accountOf[owner] = account;

        emit AccountCreated(account, owner, operator);
    }

    // ─── View ────────────────────────────────────────────────────────────────

    /**
     * @notice Predict a user's account address before deploying.
     *         Use this in your frontend — show the deposit address
     *         as soon as the user connects, before createAccount is called.
     * @param owner  The user's EOA address
     * @return  The address the UserAccount will be deployed to
     */
    function predictAddress(address owner) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(owner));

        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(UserAccount).creationCode, abi.encode(owner, operator, usdc, cowRelayer)));

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    /**
     * @notice Check if a user already has an account deployed.
     * @param owner  The user's EOA address
     */
    function hasAccount(address owner) external view returns (bool) {
        return accountOf[owner] != address(0);
    }
}
