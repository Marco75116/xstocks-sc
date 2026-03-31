// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UserAccount
 * @notice ERC-1271 smart account deployed per user.
 *         Holds USDC, allows the operator (backend) to sign
 *         CoW Protocol orders on behalf of the owner (user EOA).
 */
contract UserAccount {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice The user's EOA. Only address that can withdraw or change operator.
    address public immutable owner;

    /// @notice Your backend key. Authorized to sign CoW orders for this account.
    address public operator;

    /// @notice USDC token address (set at deploy time per chain)
    IERC20 public immutable usdc;

    /// @notice CoW Protocol VaultRelayer address (chain-specific)
    address public immutable cowRelayer;

    // ─── Events ──────────────────────────────────────────────────────────────

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);
    event TokenApproved(address indexed token, address indexed spender, uint256 amount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error OnlyOwner();
    error ZeroAddress();
    error TransferFailed();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _owner      User's EOA address
     * @param _operator   Backend key authorized to sign CoW orders
     * @param _usdc       USDC token address on this chain
     * @param _cowRelayer CoW Protocol VaultRelayer address on this chain
     */
    constructor(address _owner, address _operator, address _usdc, address _cowRelayer) {
        if (_owner == address(0) || _operator == address(0) || _usdc == address(0) || _cowRelayer == address(0)) {
            revert ZeroAddress();
        }

        owner = _owner;
        operator = _operator;
        usdc = IERC20(_usdc);
        cowRelayer = _cowRelayer;

        // Approve CoW relayer once — valid forever, no future gas needed
        IERC20(_usdc).safeIncreaseAllowance(_cowRelayer, type(uint256).max);
        emit TokenApproved(_usdc, _cowRelayer, type(uint256).max);
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────────

    receive() external payable {}

    // ─── ERC-1271 ────────────────────────────────────────────────────────────

    /**
     * @notice Called by CoW Protocol settlement to verify order signatures.
     *         Returns magic value if the operator or owner signed the hash.
     * @param hash  The CoW order hash
     * @param sig   Signature produced by the operator or owner key
     */
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        address signer = hash.recover(sig);
        if (signer == operator || signer == owner) return ERC1271_MAGIC;
        return ERC1271_INVALID;
    }

    // ─── Owner actions ───────────────────────────────────────────────────────

    /**
     * @notice Withdraw any ERC-20 token back to the owner.
     *         User always retains full custody — they can exit anytime.
     * @param token   Token to withdraw (USDC, xtocks RWA tokens, etc.)
     * @param amount  Amount to withdraw
     */
    function withdraw(address token, uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        IERC20(token).safeTransfer(owner, amount);
        emit Withdrawn(token, owner, amount);
    }

    /**
     * @notice Withdraw ETH that was accidentally sent to this contract.
     * @param amount  Amount of ETH to withdraw
     */
    function withdrawEth(uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        (bool ok,) = owner.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EthWithdrawn(owner, amount);
    }

    /**
     * @notice Replace the operator key.
     *         Useful if your backend key is rotated or compromised.
     * @param newOperator  New backend key address
     */
    function setOperator(address newOperator) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    /**
     * @notice Approve an additional spender if needed in the future.
     *         Only callable by owner — prevents operator from draining funds.
     * @param token    Token to approve
     * @param spender  Address to approve
     * @param amount   Allowance amount
     */
    function approveSpender(address token, address spender, uint256 amount) external {
        if (msg.sender != owner) revert OnlyOwner();
        IERC20(token).forceApprove(spender, amount);
        emit TokenApproved(token, spender, amount);
    }
}
