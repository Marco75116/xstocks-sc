// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AccountFactory} from "../src/AccountFactory.sol";
import {UserAccount} from "../src/UserAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AccountFactoryTest is Test {
    AccountFactory factory;

    address operator;
    uint256 operatorKey;

    address userEOA;
    uint256 userKey;

    address usdc;
    address cowRelayer;
    address cowSettlement;

    address tokenA;
    address tokenB;

    function setUp() public {
        (operator, operatorKey) = makeAddrAndKey("operator");
        (userEOA, userKey) = makeAddrAndKey("user");

        // Deploy mock USDC
        usdc = address(new MockERC20());
        cowRelayer = makeAddr("cowRelayer");
        cowSettlement = makeAddr("cowSettlement");
        tokenA = address(new MockERC20());
        tokenB = address(new MockERC20());

        factory = new AccountFactory(operator, usdc, cowRelayer, cowSettlement);
    }

    function _defaultTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
    }

    function _createDefaultAccount() internal returns (UserAccount) {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());
        // Fund with USDC so isValidSignature balance check passes
        deal(usdc, account, 1000e6);
        return UserAccount(payable(account));
    }

    function _defaultOrder(address receiver) internal view returns (UserAccount.GPv2Order memory) {
        return UserAccount.GPv2Order({
            sellToken: usdc,
            buyToken: tokenA,
            receiver: receiver,
            sellAmount: 60e6,
            buyAmount: 1e18,
            validTo: uint32(block.timestamp + 1 hours),
            appData: bytes32(0),
            feeAmount: 0
        });
    }

    // ─── Factory tests ───────────────────────────────────────────────────────

    function test_createAccount() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());

        assertNotEq(account, address(0));
        assertEq(factory.accountOf(userEOA, 0), account);
        assertTrue(factory.hasAccount(userEOA, 0));
    }

    function test_createAccount_emitsAccountCreated() public {
        address predicted = factory.predictAddress(userEOA, 0, _defaultTokens());

        vm.expectEmit(true, true, true, true);
        emit AccountFactory.AccountCreated(predicted, userEOA, operator, 0);

        factory.createAccount(userEOA, 0, _defaultTokens());
    }

    function test_createAccount_revertsDuplicateSalt() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());

        vm.expectRevert(abi.encodeWithSelector(AccountFactory.AlreadyDeployed.selector, account));
        factory.createAccount(userEOA, 0, _defaultTokens());
    }

    function test_createAccount_multiplePerUser() public {
        address account0 = factory.createAccount(userEOA, 0, _defaultTokens());
        address account1 = factory.createAccount(userEOA, 1, _defaultTokens());
        address account2 = factory.createAccount(userEOA, 2, _defaultTokens());

        assertNotEq(account0, account1);
        assertNotEq(account1, account2);
        assertEq(factory.accountOf(userEOA, 0), account0);
        assertEq(factory.accountOf(userEOA, 1), account1);
        assertEq(factory.accountOf(userEOA, 2), account2);
    }

    function test_createAccount_revertsZeroAddress() public {
        vm.expectRevert(AccountFactory.ZeroAddress.selector);
        factory.createAccount(address(0), 0, _defaultTokens());
    }

    function test_predictAddress_matchesActual() public {
        address predicted = factory.predictAddress(userEOA, 0, _defaultTokens());
        address actual = factory.createAccount(userEOA, 0, _defaultTokens());

        assertEq(predicted, actual);
    }

    function test_predictAddress_matchesActualWithSalt() public {
        address predicted = factory.predictAddress(userEOA, 3, _defaultTokens());
        address actual = factory.createAccount(userEOA, 3, _defaultTokens());

        assertEq(predicted, actual);
    }

    function test_hasAccount_falseBeforeCreate() public view {
        assertFalse(factory.hasAccount(userEOA, 0));
    }

    // ─── UserAccount: createPendingOrder ──────────────────────────────────────

    function test_createPendingOrder_happyPath() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        bytes32 orderHash = ua.createPendingOrder(order);

        assertEq(ua.pendingOrderByToken(tokenA), orderHash);

        // Verify stored order params
        (address sellToken, address buyToken, address receiver, uint256 sellAmount,,,,) = ua.storedOrders(orderHash);
        assertEq(sellToken, usdc);
        assertEq(buyToken, tokenA);
        assertEq(receiver, address(ua));
        assertEq(sellAmount, 60e6);
    }

    function test_createPendingOrder_emitsEvent() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        vm.expectEmit(false, true, false, true);
        emit UserAccount.OrderCreated(bytes32(0), tokenA, 60e6);
        ua.createPendingOrder(order);
    }

    function test_createPendingOrder_revertsNonOperator() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(userEOA);
        vm.expectRevert(UserAccount.OnlyOperator.selector);
        ua.createPendingOrder(order);
    }

    function test_createPendingOrder_revertsDisallowedSellToken() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));
        order.sellToken = makeAddr("random"); // not USDC and not an xtoken

        vm.prank(operator);
        vm.expectRevert(UserAccount.InvalidSellToken.selector);
        ua.createPendingOrder(order);
    }

    function test_createPendingOrder_allowsXtokenAsSellToken() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));
        order.sellToken = tokenA; // liquidation: sell xtoken for USDC
        order.buyToken = usdc;
        order.sellAmount = 1e18;

        // Fund with tokenA
        deal(tokenA, address(ua), 10e18);

        vm.prank(operator);
        bytes32 orderHash = ua.createPendingOrder(order);
        assertEq(ua.pendingOrderByToken(usdc), orderHash);
    }

    function test_createPendingOrder_revertsWrongReceiver() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(userEOA);

        vm.prank(operator);
        vm.expectRevert(UserAccount.InvalidReceiver.selector);
        ua.createPendingOrder(order);
    }

    // ─── EIP-712 hash correctness ─────────────────────────────────────────────

    function test_createPendingOrder_eip712HashCorrectness() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        bytes32 gpv2TypeHash = keccak256(
            "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
        );
        bytes32 kindSell = keccak256("sell");
        bytes32 balanceErc20 = keccak256("erc20");

        bytes32 structHash = keccak256(
            abi.encode(
                gpv2TypeHash,
                order.sellToken,
                order.buyToken,
                order.receiver,
                order.sellAmount,
                order.buyAmount,
                order.validTo,
                order.appData,
                order.feeAmount,
                kindSell,
                false,
                balanceErc20,
                balanceErc20
            )
        );

        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Gnosis Protocol"),
                keccak256("v2"),
                block.chainid,
                cowSettlement
            )
        );

        bytes32 expectedHash = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        vm.prank(operator);
        bytes32 actualHash = ua.createPendingOrder(order);

        assertEq(actualHash, expectedHash);
    }

    // ─── Overwrite (one per token) ────────────────────────────────────────────

    function test_createPendingOrder_overwritesPreviousForSameToken() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        bytes32 hash1 = ua.createPendingOrder(order);

        // New order for same buyToken overwrites
        order.sellAmount = 50e6;
        vm.prank(operator);
        bytes32 hash2 = ua.createPendingOrder(order);

        // Old stored order is cleared
        (address sellToken,,,,,,,) = ua.storedOrders(hash1);
        assertEq(sellToken, address(0));

        // New stored order exists
        (sellToken,,,,,,,) = ua.storedOrders(hash2);
        assertEq(sellToken, usdc);
        assertEq(ua.pendingOrderByToken(tokenA), hash2);
    }

    function test_createPendingOrder_differentTokensIndependent() public {
        UserAccount ua = _createDefaultAccount();

        UserAccount.GPv2Order memory orderA = _defaultOrder(address(ua));
        vm.prank(operator);
        bytes32 hashA = ua.createPendingOrder(orderA);

        UserAccount.GPv2Order memory orderB = _defaultOrder(address(ua));
        orderB.buyToken = tokenB;
        vm.prank(operator);
        bytes32 hashB = ua.createPendingOrder(orderB);

        // Both stored
        (address sellTokenA,,,,,,,) = ua.storedOrders(hashA);
        (address sellTokenB,,,,,,,) = ua.storedOrders(hashB);
        assertEq(sellTokenA, usdc);
        assertEq(sellTokenB, usdc);
        assertEq(ua.pendingOrderByToken(tokenA), hashA);
        assertEq(ua.pendingOrderByToken(tokenB), hashB);
    }

    // ─── isValidSignature ─────────────────────────────────────────────────────

    function test_isValidSignature_operatorWithPendingOrder() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        bytes32 orderHash = ua.createPendingOrder(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, orderHash);
        assertEq(ua.isValidSignature(orderHash, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_ownerWithPendingOrder() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        bytes32 orderHash = ua.createPendingOrder(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, orderHash);
        assertEq(ua.isValidSignature(orderHash, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_invalidWithoutPendingOrder() public {
        UserAccount ua = _createDefaultAccount();

        bytes32 hash = keccak256("random order");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, hash);
        assertEq(ua.isValidSignature(hash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function test_isValidSignature_invalidSignerWithPendingOrder() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        bytes32 orderHash = ua.createPendingOrder(order);

        (, uint256 randomKey) = makeAddrAndKey("random");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomKey, orderHash);
        assertEq(ua.isValidSignature(orderHash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function test_isValidSignature_invalidBuyTokenNotAllowed() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));
        order.buyToken = makeAddr("disallowed"); // not in _xtokens

        vm.prank(operator);
        bytes32 orderHash = ua.createPendingOrder(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, orderHash);
        assertEq(ua.isValidSignature(orderHash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));
    }

    function test_isValidSignature_allowedTokensSetCorrectly() public {
        UserAccount ua = _createDefaultAccount();

        assertTrue(ua.allowedTokens(tokenA));
        assertTrue(ua.allowedTokens(tokenB));
        assertFalse(ua.allowedTokens(makeAddr("random")));
        assertFalse(ua.allowedTokens(usdc)); // USDC itself is not an xtoken
    }

    function test_isValidSignature_liquidationOrder() public {
        UserAccount ua = _createDefaultAccount();

        // Liquidation: sell tokenA for USDC
        UserAccount.GPv2Order memory order = UserAccount.GPv2Order({
            sellToken: tokenA,
            buyToken: usdc,
            receiver: address(ua),
            sellAmount: 1e18,
            buyAmount: 1,
            validTo: uint32(block.timestamp + 1 hours),
            appData: bytes32(0),
            feeAmount: 0
        });

        // Fund with tokenA
        deal(tokenA, address(ua), 10e18);

        vm.prank(operator);
        bytes32 orderHash = ua.createPendingOrder(order);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, orderHash);
        assertEq(ua.isValidSignature(orderHash, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_invalidAfterOverwrite() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        bytes32 oldHash = ua.createPendingOrder(order);

        // Overwrite with new order for same token
        order.sellAmount = 50e6;
        vm.prank(operator);
        bytes32 newHash = ua.createPendingOrder(order);

        // Old order is invalid (stored order cleared)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, oldHash);
        assertEq(ua.isValidSignature(oldHash, abi.encodePacked(r, s, v)), bytes4(0xffffffff));

        // New order is valid
        (v, r, s) = vm.sign(operatorKey, newHash);
        assertEq(ua.isValidSignature(newHash, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
    }

    // ─── Full integration ─────────────────────────────────────────────────────

    function test_fullIntegration_createSignOverwrite() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(operator);
        bytes32 hash1 = ua.createPendingOrder(order);

        // Verify isValidSignature works
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, hash1);
        assertEq(ua.isValidSignature(hash1, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));

        // Overwrite with new order
        order.sellAmount = 50e6;
        vm.prank(operator);
        bytes32 hash2 = ua.createPendingOrder(order);

        assertNotEq(hash1, hash2);

        // Old invalid, new valid
        (v, r, s) = vm.sign(operatorKey, hash1);
        assertEq(ua.isValidSignature(hash1, abi.encodePacked(r, s, v)), bytes4(0xffffffff));

        (v, r, s) = vm.sign(operatorKey, hash2);
        assertEq(ua.isValidSignature(hash2, abi.encodePacked(r, s, v)), bytes4(0x1626ba7e));
    }

    // ─── DCA interval ──────────────────────────────────────────────────────────

    function test_setDcaInterval() public {
        UserAccount ua = _createDefaultAccount();

        vm.prank(userEOA);
        ua.setDcaInterval(1 days);

        assertEq(ua.dcaInterval(), 1 days);
    }

    function test_setDcaInterval_revertsNonOwner() public {
        UserAccount ua = _createDefaultAccount();

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        ua.setDcaInterval(1 days);
    }

    function test_setDcaInterval_emitsEvent() public {
        UserAccount ua = _createDefaultAccount();

        vm.prank(userEOA);
        vm.expectEmit(false, false, false, true);
        emit UserAccount.DcaIntervalUpdated(0, 1 days);
        ua.setDcaInterval(1 days);
    }

    function test_createPendingOrder_revertsDcaTooSoon() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        // Owner sets DCA interval to 1 day
        vm.prank(userEOA);
        ua.setDcaInterval(1 days);

        // First order succeeds
        vm.prank(operator);
        ua.createPendingOrder(order);

        // Second order for same buyToken within interval reverts
        order.sellAmount = 50e6;
        vm.prank(operator);
        vm.expectRevert(UserAccount.DcaTooSoon.selector);
        ua.createPendingOrder(order);
    }

    function test_createPendingOrder_succeedsAfterDcaInterval() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        vm.prank(userEOA);
        ua.setDcaInterval(1 days);

        // First order
        vm.prank(operator);
        ua.createPendingOrder(order);

        // Warp past DCA interval
        vm.warp(block.timestamp + 1 days);

        // Second order succeeds
        order.sellAmount = 50e6;
        vm.prank(operator);
        ua.createPendingOrder(order);
    }

    function test_createPendingOrder_dcaPerToken() public {
        UserAccount ua = _createDefaultAccount();

        vm.prank(userEOA);
        ua.setDcaInterval(1 days);

        // Order for tokenA
        UserAccount.GPv2Order memory orderA = _defaultOrder(address(ua));
        vm.prank(operator);
        ua.createPendingOrder(orderA);

        // Order for tokenB should succeed (different buy token)
        UserAccount.GPv2Order memory orderB = _defaultOrder(address(ua));
        orderB.buyToken = tokenB;
        vm.prank(operator);
        ua.createPendingOrder(orderB);
    }

    function test_createPendingOrder_noDcaRestrictionWhenZero() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        // dcaInterval is 0 by default — no restriction
        assertEq(ua.dcaInterval(), 0);

        vm.prank(operator);
        ua.createPendingOrder(order);

        // Immediately create another — should work
        order.sellAmount = 50e6;
        vm.prank(operator);
        ua.createPendingOrder(order);
    }

    function test_lastPurchaseTimestamp_updatedOnOrder() public {
        UserAccount ua = _createDefaultAccount();
        UserAccount.GPv2Order memory order = _defaultOrder(address(ua));

        uint256 ts = block.timestamp;

        vm.prank(operator);
        ua.createPendingOrder(order);

        assertEq(ua.lastPurchaseTimestamp(tokenA), ts);
    }

    // ─── UserAccount: withdraw ───────────────────────────────────────────────

    function test_withdraw() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());
        deal(usdc, account, 1000e6);

        vm.prank(userEOA);
        UserAccount(payable(account)).withdraw(usdc, 500e6, userEOA);

        assertEq(IERC20(usdc).balanceOf(userEOA), 500e6);
        assertEq(IERC20(usdc).balanceOf(account), 500e6);
    }

    function test_withdraw_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());
        deal(usdc, account, 1000e6);

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).withdraw(usdc, 500e6, operator);
    }

    // ─── UserAccount: withdrawEth ────────────────────────────────────────────

    function test_withdrawEth() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());
        vm.deal(account, 1 ether);

        uint256 balBefore = userEOA.balance;

        vm.prank(userEOA);
        UserAccount(payable(account)).withdrawEth(1 ether, userEOA);

        assertEq(userEOA.balance, balBefore + 1 ether);
    }

    function test_withdrawEth_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());
        vm.deal(account, 1 ether);

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).withdrawEth(1 ether, operator);
    }

    // ─── UserAccount: setOperator ────────────────────────────────────────────

    function test_setOperator() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());
        address newOp = makeAddr("newOperator");

        vm.prank(userEOA);
        UserAccount(payable(account)).setOperator(newOp);

        assertEq(UserAccount(payable(account)).operator(), newOp);
    }

    function test_setOperator_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).setOperator(makeAddr("newOp"));
    }

    function test_setOperator_revertsZeroAddress() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());

        vm.prank(userEOA);
        vm.expectRevert(UserAccount.ZeroAddress.selector);
        UserAccount(payable(account)).setOperator(address(0));
    }

    // ─── UserAccount: approveSpender ─────────────────────────────────────────

    function test_approveSpender() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());
        address spender = makeAddr("spender");

        vm.prank(userEOA);
        UserAccount(payable(account)).approveSpender(usdc, spender, 1000e6);

        assertEq(IERC20(usdc).allowance(account, spender), 1000e6);
    }

    function test_approveSpender_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).approveSpender(usdc, makeAddr("spender"), 1000e6);
    }

    // ─── UserAccount: receive ETH ────────────────────────────────────────────

    function test_receiveEth() public {
        address account = factory.createAccount(userEOA, 0, _defaultTokens());

        vm.deal(address(this), 1 ether);
        (bool ok,) = account.call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(account.balance, 1 ether);
    }
}

/// @dev Minimal ERC20 mock for testing
contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
