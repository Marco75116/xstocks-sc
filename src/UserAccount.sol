// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title UserAccount
 * @notice ERC-1271 smart account deployed per user.
 *         Holds USDC, allows the operator (backend) to sign
 *         swap orders on behalf of the owner (user EOA).
 *         Works with CoW Protocol (Ink) and 1inch Fusion (Ethereum).
 *
 *         Orders must be pre-registered via createPendingOrder before
 *         isValidSignature will accept them.
 */
contract UserAccount {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // ─── Types ────────────────────────────────────────────────────────────────

    struct GPv2Order {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
    }

    // ─── Constants ───────────────────────────────────────────────────────────

    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    bytes32 private constant GPV2_ORDER_TYPEHASH = keccak256(
        "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
    );
    bytes32 private constant KIND_SELL = keccak256("sell");
    bytes32 private constant BALANCE_ERC20 = keccak256("erc20");

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice The user's EOA. Only address that can withdraw or change operator.
    address public immutable owner;

    /// @notice Your backend key. Authorized to sign swap orders for this account.
    address public operator;

    /// @notice USDC token address (set at deploy time per chain)
    IERC20 public immutable usdc;

    /// @notice Swap relayer address (CoW VaultRelayer on Ink, 1inch Router on Ethereum)
    address public immutable cowRelayer;

    /// @notice CoW Protocol settlement contract address
    address public immutable cowSettlement;

    /// @notice EIP-712 domain separator for CoW Protocol
    bytes32 public immutable domainSeparator;

    /// @notice Allowed xtocks tokens set at deploy time
    mapping(address => bool) public allowedTokens;

    /// @notice Current pending order hash per buy token (one per token, overwritten on new order)
    mapping(address => bytes32) public pendingOrderByToken;

    /// @notice Stored order params for validation at settlement time
    mapping(bytes32 => GPv2Order) public storedOrders;

    // ─── Events ──────────────────────────────────────────────────────────────

    event OwnerSet(address indexed owner);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);
    event TokenApproved(address indexed token, address indexed spender, uint256 amount);
    event OrderCreated(bytes32 indexed orderHash, address indexed buyToken, uint256 sellAmount);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error OnlyOwner();
    error OnlyOperator();
    error ZeroAddress();
    error TransferFailed();
    error InvalidSellToken();
    error InvalidReceiver();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _owner          User's EOA address
     * @param _operator       Backend key authorized to sign swap orders
     * @param _usdc           USDC token address on this chain
     * @param _cowRelayer     Swap relayer address (CoW VaultRelayer or 1inch Router)
     * @param _cowSettlement  CoW Protocol settlement contract address
     * @param _xtokens        Xtocks token addresses to approve for selling via swap relayer
     */
    constructor(
        address _owner,
        address _operator,
        address _usdc,
        address _cowRelayer,
        address _cowSettlement,
        address[] memory _xtokens
    ) {
        if (
            _owner == address(0) || _operator == address(0) || _usdc == address(0) || _cowRelayer == address(0)
                || _cowSettlement == address(0)
        ) {
            revert ZeroAddress();
        }

        owner = _owner;
        operator = _operator;
        usdc = IERC20(_usdc);
        cowRelayer = _cowRelayer;
        cowSettlement = _cowSettlement;

        // Compute EIP-712 domain separator matching CoW Protocol
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                _cowSettlement
            )
        );

        emit OwnerSet(_owner);
        emit OperatorUpdated(address(0), _operator);

        // Approve swap relayer for USDC (buying) — valid forever, no future gas needed
        IERC20(_usdc).safeIncreaseAllowance(_cowRelayer, type(uint256).max);
        emit TokenApproved(_usdc, _cowRelayer, type(uint256).max);

        // Register and approve swap relayer for each xtocks token
        for (uint256 i = 0; i < _xtokens.length; i++) {
            allowedTokens[_xtokens[i]] = true;
            IERC20(_xtokens[i]).safeIncreaseAllowance(_cowRelayer, type(uint256).max);
            emit TokenApproved(_xtokens[i], _cowRelayer, type(uint256).max);
        }
    }

    // ─── Receive ETH ─────────────────────────────────────────────────────────

    receive() external payable {}

    // ─── Order management ─────────────────────────────────────────────────────

    /**
     * @notice Pre-register a CoW swap order. Only the operator can call this.
     *         One pending order per buy token — new order overwrites the previous.
     * @param order  The GPv2 order parameters
     * @return orderHash The EIP-712 hash of the order
     */
    function createPendingOrder(GPv2Order calldata order) external returns (bytes32 orderHash) {
        if (msg.sender != operator) revert OnlyOperator();
        if (order.sellToken != address(usdc) && !allowedTokens[order.sellToken]) revert InvalidSellToken();
        if (order.receiver != address(this)) revert InvalidReceiver();

        orderHash = _hashOrder(order);

        // Invalidate previous pending order for this token (one per token)
        bytes32 oldHash = pendingOrderByToken[order.buyToken];
        if (oldHash != bytes32(0)) {
            delete storedOrders[oldHash];
        }

        pendingOrderByToken[order.buyToken] = orderHash;
        storedOrders[orderHash] = order;

        emit OrderCreated(orderHash, order.buyToken, order.sellAmount);
    }

    // ─── ERC-1271 ────────────────────────────────────────────────────────────

    /**
     * @notice Called by swap protocol settlement to verify order signatures.
     *         Retrieves stored order params and enforces rules:
     *         - Order must have been pre-registered via createPendingOrder
     *         - sellToken and buyToken must be USDC or an allowed xtocks token
     *         - Signature must be from operator or owner
     * @param hash  The order hash (CoW or 1inch)
     * @param sig   Signature produced by the operator or owner key
     */
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        GPv2Order storage order = storedOrders[hash];

        // sellToken and buyToken must be USDC or an allowed xtocks token
        if (order.sellToken != address(usdc) && !allowedTokens[order.sellToken]) return ERC1271_INVALID;
        if (order.buyToken != address(usdc) && !allowedTokens[order.buyToken]) return ERC1271_INVALID;

        // Signature must be from operator or owner
        address signer = hash.recover(sig);
        if (signer == operator || signer == owner) return ERC1271_MAGIC;
        return ERC1271_INVALID;
    }

    // ─── Owner actions ───────────────────────────────────────────────────────

    /**
     * @notice Withdraw any ERC-20 token to a chosen wallet.
     *         User always retains full custody — they can exit anytime.
     * @param token   Token to withdraw (USDC, xtocks RWA tokens, etc.)
     * @param amount  Amount to withdraw
     * @param to      Destination wallet
     */
    function withdraw(address token, uint256 amount, address to) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    /**
     * @notice Withdraw ETH that was accidentally sent to this contract.
     * @param amount  Amount of ETH to withdraw
     * @param to      Destination wallet
     */
    function withdrawEth(uint256 amount, address to) external {
        if (msg.sender != owner) revert OnlyOwner();
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EthWithdrawn(to, amount);
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

    // ─── Internal ────────────────────────────────────────────────────────────

    /**
     * @notice Compute the EIP-712 hash for a GPv2 order matching CoW Protocol.
     */
    function _hashOrder(GPv2Order calldata order) internal view returns (bytes32) {
        // Split abi.encode to avoid stack-too-deep
        bytes32 structHash;
        {
            bytes memory encodedLeft = abi.encode(
                GPV2_ORDER_TYPEHASH,
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo
            );
            bytes memory encodedRight = abi.encode(
                order.appData,
                order.feeAmount,
                KIND_SELL,
                false, // partiallyFillable
                BALANCE_ERC20, // sellTokenBalance
                BALANCE_ERC20 // buyTokenBalance
            );
            structHash = keccak256(bytes.concat(encodedLeft, encodedRight));
        }

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
