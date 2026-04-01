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
    // ─── Types ────────────────────────────────────────────────────────────────

    /// @notice Vault strategy configuration for a user account.
    ///         Manual mode: dcaAmount = 0, dcaFrequency = 0.
    /// @param tokens      Tokens to buy (xtock addresses)
    /// @param allocations Allocation per token in basis points (100 = 1%, sum = 10_000)
    /// @param dcaAmount   USDC amount per DCA execution (0 = manual)
    /// @param dcaFrequency Seconds between DCA executions (0 = manual)
    struct VaultConfig {
        address[] tokens;
        uint256[] allocations;
        uint256 dcaAmount;
        uint256 dcaFrequency;
    }

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Your backend key — shared operator across all user accounts
    address public immutable operator;

    /// @notice USDC address on this chain
    address public immutable usdc;

    /// @notice CoW Protocol VaultRelayer address on this chain
    address public immutable cowRelayer;

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
    event VaultConfigured(
        address indexed account,
        address indexed owner,
        address[] tokens,
        uint256[] allocations,
        uint256 dcaAmount,
        uint256 dcaFrequency
    );

    // ─── Errors ──────────────────────────────────────────────────────────────

    error AlreadyDeployed(address existing);
    error ZeroAddress();
    error ArrayLengthMismatch();

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
     * @param owner      The user's EOA address
     * @param saltIndex  Index to allow multiple accounts per user (0, 1, 2, ...)
     * @return account   The deployed UserAccount address
     */
    function createAccount(address owner, uint256 saltIndex, VaultConfig calldata config)
        external
        returns (address account)
    {
        if (owner == address(0)) revert ZeroAddress();
        if (config.tokens.length != config.allocations.length) revert ArrayLengthMismatch();

        address existing = accountOf[owner][saltIndex];
        if (existing != address(0)) revert AlreadyDeployed(existing);

        // Salt is deterministic from owner + index — same inputs always
        // get the same address across any chain with this factory
        bytes32 salt = keccak256(abi.encodePacked(owner, saltIndex));

        account = address(new UserAccount{salt: salt}(owner, operator, address(usdc), cowRelayer));

        accountOf[owner][saltIndex] = account;

        emit AccountCreated(account, owner, operator, saltIndex);
        emit VaultConfigured(account, owner, config.tokens, config.allocations, config.dcaAmount, config.dcaFrequency);
    }

    // ─── View ────────────────────────────────────────────────────────────────

    /**
     * @notice Predict a user's account address before deploying.
     *         Use this in your frontend — show the deposit address
     *         as soon as the user connects, before createAccount is called.
     * @param owner      The user's EOA address
     * @param saltIndex  Index matching the one passed to createAccount
     * @return  The address the UserAccount will be deployed to
     */
    function predictAddress(address owner, uint256 saltIndex) public view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(owner, saltIndex));

        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(UserAccount).creationCode, abi.encode(owner, operator, usdc, cowRelayer)));

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
