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

    address tokenA;
    address tokenB;

    function setUp() public {
        (operator, operatorKey) = makeAddrAndKey("operator");
        (userEOA, userKey) = makeAddrAndKey("user");

        // Deploy mock USDC
        usdc = address(new MockERC20());
        cowRelayer = makeAddr("cowRelayer");
        tokenA = makeAddr("tokenA");
        tokenB = makeAddr("tokenB");

        factory = new AccountFactory(operator, usdc, cowRelayer);
    }

    function _defaultConfig() internal view returns (AccountFactory.VaultConfig memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 6000;
        allocations[1] = 4000;
        return AccountFactory.VaultConfig(tokens, allocations, 100e6, 1 days);
    }

    function _manualConfig() internal view returns (AccountFactory.VaultConfig memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = tokenA;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 10_000;
        return AccountFactory.VaultConfig(tokens, allocations, 0, 0);
    }

    // ─── Factory tests ───────────────────────────────────────────────────────

    function test_createAccount() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());

        assertNotEq(account, address(0));
        assertEq(factory.accountOf(userEOA, 0), account);
        assertTrue(factory.hasAccount(userEOA, 0));
    }

    function test_createAccount_emitsAccountCreated() public {
        vm.expectEmit(true, true, true, true);
        address predicted = factory.predictAddress(userEOA, 0);
        emit AccountFactory.AccountCreated(predicted, userEOA, operator, 0);

        factory.createAccount(userEOA, 0, _defaultConfig());
    }

    function test_createAccount_emitsVaultConfigured() public {
        AccountFactory.VaultConfig memory config = _defaultConfig();
        address predicted = factory.predictAddress(userEOA, 0);

        vm.expectEmit(true, true, false, true);
        emit AccountFactory.VaultConfigured(
            predicted, userEOA, config.tokens, config.allocations, config.dcaAmount, config.dcaFrequency
        );

        factory.createAccount(userEOA, 0, config);
    }

    function test_createAccount_manualConfig() public {
        AccountFactory.VaultConfig memory config = _manualConfig();
        address predicted = factory.predictAddress(userEOA, 0);

        vm.expectEmit(true, true, false, true);
        emit AccountFactory.VaultConfigured(predicted, userEOA, config.tokens, config.allocations, 0, 0);

        factory.createAccount(userEOA, 0, config);
    }

    function test_createAccount_revertsDuplicateSalt() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());

        vm.expectRevert(abi.encodeWithSelector(AccountFactory.AlreadyDeployed.selector, account));
        factory.createAccount(userEOA, 0, _defaultConfig());
    }

    function test_createAccount_revertsArrayLengthMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = tokenA;
        tokens[1] = tokenB;
        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 10_000;

        vm.expectRevert(AccountFactory.ArrayLengthMismatch.selector);
        factory.createAccount(userEOA, 0, AccountFactory.VaultConfig(tokens, allocations, 100e6, 1 days));
    }

    function test_createAccount_multiplePerUser() public {
        address account0 = factory.createAccount(userEOA, 0, _defaultConfig());
        address account1 = factory.createAccount(userEOA, 1, _defaultConfig());
        address account2 = factory.createAccount(userEOA, 2, _defaultConfig());

        assertNotEq(account0, account1);
        assertNotEq(account1, account2);
        assertEq(factory.accountOf(userEOA, 0), account0);
        assertEq(factory.accountOf(userEOA, 1), account1);
        assertEq(factory.accountOf(userEOA, 2), account2);
    }

    function test_createAccount_revertsZeroAddress() public {
        vm.expectRevert(AccountFactory.ZeroAddress.selector);
        factory.createAccount(address(0), 0, _defaultConfig());
    }

    function test_predictAddress_matchesActual() public {
        address predicted = factory.predictAddress(userEOA, 0);
        address actual = factory.createAccount(userEOA, 0, _defaultConfig());

        assertEq(predicted, actual);
    }

    function test_predictAddress_matchesActualWithSalt() public {
        address predicted = factory.predictAddress(userEOA, 3);
        address actual = factory.createAccount(userEOA, 3, _defaultConfig());

        assertEq(predicted, actual);
    }

    function test_hasAccount_falseBeforeCreate() public view {
        assertFalse(factory.hasAccount(userEOA, 0));
    }

    // ─── UserAccount: ERC-1271 ───────────────────────────────────────────────

    function test_isValidSignature_operator() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        UserAccount ua = UserAccount(payable(account));

        bytes32 hash = keccak256("test order");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(ua.isValidSignature(hash, sig), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_owner() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        UserAccount ua = UserAccount(payable(account));

        bytes32 hash = keccak256("test order");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(ua.isValidSignature(hash, sig), bytes4(0x1626ba7e));
    }

    function test_isValidSignature_invalidSigner() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        UserAccount ua = UserAccount(payable(account));

        (, uint256 randomKey) = makeAddrAndKey("random");
        bytes32 hash = keccak256("test order");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(randomKey, hash);
        bytes memory sig = abi.encodePacked(r, s, v);

        assertEq(ua.isValidSignature(hash, sig), bytes4(0xffffffff));
    }

    // ─── UserAccount: withdraw ───────────────────────────────────────────────

    function test_withdraw() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());

        // Fund the account with mock USDC
        deal(usdc, account, 1000e6);

        vm.prank(userEOA);
        UserAccount(payable(account)).withdraw(usdc, 500e6, userEOA);

        assertEq(IERC20(usdc).balanceOf(userEOA), 500e6);
        assertEq(IERC20(usdc).balanceOf(account), 500e6);
    }

    function test_withdraw_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        deal(usdc, account, 1000e6);

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).withdraw(usdc, 500e6, operator);
    }

    // ─── UserAccount: withdrawEth ────────────────────────────────────────────

    function test_withdrawEth() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        vm.deal(account, 1 ether);

        uint256 balBefore = userEOA.balance;

        vm.prank(userEOA);
        UserAccount(payable(account)).withdrawEth(1 ether, userEOA);

        assertEq(userEOA.balance, balBefore + 1 ether);
    }

    function test_withdrawEth_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        vm.deal(account, 1 ether);

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).withdrawEth(1 ether, operator);
    }

    // ─── UserAccount: setOperator ────────────────────────────────────────────

    function test_setOperator() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        address newOp = makeAddr("newOperator");

        vm.prank(userEOA);
        UserAccount(payable(account)).setOperator(newOp);

        assertEq(UserAccount(payable(account)).operator(), newOp);
    }

    function test_setOperator_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).setOperator(makeAddr("newOp"));
    }

    function test_setOperator_revertsZeroAddress() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());

        vm.prank(userEOA);
        vm.expectRevert(UserAccount.ZeroAddress.selector);
        UserAccount(payable(account)).setOperator(address(0));
    }

    // ─── UserAccount: approveSpender ─────────────────────────────────────────

    function test_approveSpender() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());
        address spender = makeAddr("spender");

        vm.prank(userEOA);
        UserAccount(payable(account)).approveSpender(usdc, spender, 1000e6);

        assertEq(IERC20(usdc).allowance(account, spender), 1000e6);
    }

    function test_approveSpender_revertsNonOwner() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());

        vm.prank(operator);
        vm.expectRevert(UserAccount.OnlyOwner.selector);
        UserAccount(payable(account)).approveSpender(usdc, makeAddr("spender"), 1000e6);
    }

    // ─── UserAccount: receive ETH ────────────────────────────────────────────

    function test_receiveEth() public {
        address account = factory.createAccount(userEOA, 0, _defaultConfig());

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
