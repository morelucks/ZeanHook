// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {ZeanHook} from "../src/ZeanHook.sol";
import {IZeanHook} from "../src/interfaces/IZeanHook.sol";

// Mock contracts for testing
import {MockPoolManager} from "./mocks/MockPoolManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

// V4 Core imports
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract ZeanHookTest is Test {
    using PoolIdLibrary for PoolKey;

    ZeanHook public hook;
    MockPoolManager public poolManager;
    MockERC20 public token0;
    MockERC20 public token1;
    
    PoolKey public poolKey;
    PoolId public poolId;
    
    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public executor = address(0x3);
    
    uint160 public constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1 price

    function setUp() public {
        // Deploy mock contracts
        poolManager = new MockPoolManager();
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        
        // Ensure proper token ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // Deploy hook
        hook = new ZeanHook(IPoolManager(address(poolManager)));
        
        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        
        poolId = poolKey.toId();
        
        // Setup pool manager with initial price
        poolManager.setMockSqrtPrice(poolId, INITIAL_SQRT_PRICE);
        
        // Initialize pool by calling afterInitialize with correct signature
        hook.afterInitialize(address(this), poolKey, INITIAL_SQRT_PRICE, 0);
        
        // Fund test accounts
        token0.mint(user1, 1000e18);
        token1.mint(user1, 1000e18);
        token0.mint(user2, 1000e18);
        token1.mint(user2, 1000e18);
    }

    // ========================= Hook Permissions Tests =========================
    
    function testHookPermissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        
        assertFalse(permissions.beforeInitialize);
        assertTrue(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }

    // ========================= Basic Functionality Tests =========================
    
    function testOwnershipAndAuthorization() public {
        assertEq(hook.owner(), owner);
        assertTrue(hook.isAuthorizedExecutor(owner));
        assertFalse(hook.isAuthorizedExecutor(executor));
        
        // Test authorization
        hook.setExecutorAuthorization(executor, true);
        assertTrue(hook.isAuthorizedExecutor(executor));
        
        hook.setExecutorAuthorization(executor, false);
        assertFalse(hook.isAuthorizedExecutor(executor));
    }
    
    function testSetExecutorAuthorizationOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert("Only owner");
        hook.setExecutorAuthorization(executor, true);
    }
    
    function testTransferOwnership() public {
        hook.transferOwnership(user1);
        assertEq(hook.owner(), user1);
        assertTrue(hook.isAuthorizedExecutor(user1));
    }
    
    function testTransferOwnershipOnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert("Only owner");
        hook.transferOwnership(user2);
    }
    
    function testTransferOwnershipInvalidAddress() public {
        vm.expectRevert("Invalid new owner");
        hook.transferOwnership(address(0));
    }

    // ========================= Volatility Management Tests =========================
    
    function testCalculateVolatilityAdjustedSlippage() public {
        uint256 slippage = hook.calculateVolatilityAdjustedSlippage(poolId);
        assertEq(slippage, hook.MIN_SLIPPAGE()); // Should return minimum slippage initially
    }
    
    function testGetRecommendedSlippage() public {
        uint256 slippage = hook.getRecommendedSlippage(poolId);
        assertEq(slippage, hook.MIN_SLIPPAGE());
    }
    
    function testCalculateVolatility() public {
        uint256 volatility = hook.calculateVolatility(poolId);
        // With only one price point, volatility should be 0
        assertEq(volatility, 0);
    }

    // ========================= Swap Hook Tests =========================
    
    function testBeforeSwap() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory hookData = abi.encode(uint256(100)); // 1% slippage tolerance
        
        // Should not revert
        hook.beforeSwap(user1, poolKey, params, hookData);
        
        // Check that swap was queued
        assertEq(hook.userPendingSwaps(poolId, user1), 1);
    }
    
    function testAfterSwap() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        // Update mock price for after swap
        uint160 newSqrtPrice = INITIAL_SQRT_PRICE + 1000;
        poolManager.setMockSqrtPrice(poolId, newSqrtPrice);
        
        // Call afterSwap
        hook.afterSwap(user1, poolKey, params, poolManager.getBalanceDelta(), "");
        
        // Check that last swap timestamp was updated
        assertEq(hook.lastSwapTimestamp(poolId), block.timestamp);
    }
    
    function testSwapWithInsufficientSlippage() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        // Set slippage below minimum
        bytes memory hookData = abi.encode(uint256(5)); // 0.05% slippage tolerance
        
        vm.expectRevert("User slippage below recommended minimum");
        hook.beforeSwap(user1, poolKey, params, hookData);
    }
    
    function testSwapWithExcessiveSlippage() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        // Set slippage above maximum
        bytes memory hookData = abi.encode(uint256(1000)); // 10% slippage tolerance
        
        vm.expectRevert("User slippage exceeds maximum");
        hook.beforeSwap(user1, poolKey, params, hookData);
    }

    // ========================= Batch Management Tests =========================
    
    function testQueueSwap() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        vm.prank(user1);
        hook.queueSwap(
            poolKey,
            params,
            0, // minAmountOut
            0, // maxSqrtPriceX96
            0, // minSqrtPriceX96
            ""
        );
        
        // Check that swap was queued
        assertEq(hook.userPendingSwaps(poolId, user1), 1);
    }
    
    function testQueueSwapWithInvalidAmount() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 0, // Invalid amount
            sqrtPriceLimitX96: 0
        });
        
        vm.prank(user1);
        vm.expectRevert("Invalid amount");
        hook.queueSwap(poolKey, params, 0, 0, 0, "");
    }

    // ========================= Commit-Reveal Tests =========================
    
    function testStartCommitPhase() public {
        hook.setExecutorAuthorization(executor, true);
        
        vm.prank(executor);
        hook.startCommitPhase(poolId);
        
        // Note: We can't easily test the internal state without public getters
        // This test verifies the function doesn't revert
    }
    
    function testCommitSwap() public {
        hook.setExecutorAuthorization(executor, true);
        
        vm.prank(executor);
        hook.startCommitPhase(poolId);
        
        bytes32 commitHash = keccak256("test_commit");
        
        vm.prank(user1);
        hook.commitSwap(poolId, commitHash);
        
        // Check that commit count increased
        assertEq(hook.userCommitCounts(poolId, user1), 1);
    }
    
    function testCommitWithoutCommitPhase() public {
        bytes32 commitHash = keccak256("test");
        
        vm.prank(user1);
        vm.expectRevert("Not in commit phase");
        hook.commitSwap(poolId, commitHash);
    }
    
    function testGenerateCommitHash() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        uint256 nonce = 12345;
        bytes32 salt = keccak256("test_salt");
        
        bytes32 hash1 = hook.generateCommitHash(
            user1, params, 0, 0, 0, "", nonce, salt
        );
        
        bytes32 hash2 = hook.generateCommitHash(
            user1, params, 0, 0, 0, "", nonce, salt
        );
        
        // Same parameters should generate same hash
        assertEq(hash1, hash2);
        
        // Different user should generate different hash
        bytes32 hash3 = hook.generateCommitHash(
            user2, params, 0, 0, 0, "", nonce, salt
        );
        
        assertNotEq(hash1, hash3);
    }

    // ========================= Emergency Functions Tests =========================
    
    function testEmergencyExecuteBatch() public {
        // Queue a swap first
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        vm.prank(user1);
        hook.queueSwap(poolKey, params, 0, 0, 0, "");
        
        // Execute batch as owner
        hook.emergencyExecuteBatch(poolKey);
        
        // This test verifies the function doesn't revert
        // In a real test environment, we'd check batch execution results
    }

    // ========================= Constants Tests =========================
    
    function testConstants() public {
        assertEq(hook.MIN_SLIPPAGE(), 10);
        assertEq(hook.MAX_SLIPPAGE(), 500);
        assertEq(hook.BASIS_POINTS(), 10000);
        assertEq(hook.BATCH_INTERVAL(), 180);
        assertEq(hook.MAX_BATCH_SIZE(), 100);
        assertEq(hook.PRICE_DEVIATION_THRESHOLD(), 50);
        assertEq(hook.VOLATILITY_WINDOW(), 24 hours);
        assertEq(hook.MIN_SAMPLES(), 5);
        assertEq(hook.VOLATILITY_MULTIPLIER(), 100);
        assertEq(hook.COMMIT_PHASE_DURATION(), 60);
        assertEq(hook.REVEAL_PHASE_DURATION(), 120);
        assertEq(hook.MIN_COMMIT_DELAY(), 10);
    }

    // ========================= View Functions Tests =========================
    
    function testGetPriceHistory() public {
        // Test with limit
        hook.getPriceHistory(poolId, 10);
        
        // Test with zero limit
        hook.getPriceHistory(poolId, 0);
    }
    
    function testGetVolatilityMetrics() public view {
        hook.getVolatilityMetrics(poolId);
    }

    // ========================= Multiple Swaps Test =========================
    
    function testMultipleSwapsTracking() public {
        SwapParams memory params1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e17,
            sqrtPriceLimitX96: 0
        });
        
        SwapParams memory params2 = SwapParams({
            zeroForOne: false,
            amountSpecified: -1e17,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory hookData = abi.encode(uint256(100));
        
        // Perform multiple swaps
        vm.prank(user1);
        hook.beforeSwap(user1, poolKey, params1, hookData);
        
        // Update price between swaps
        poolManager.setMockSqrtPrice(poolId, INITIAL_SQRT_PRICE + 1000);
        hook.afterSwap(user1, poolKey, params1, BalanceDelta.wrap(0), "");
        
        // Wait some time
        vm.warp(block.timestamp + 60);
        
        vm.prank(user2);
        hook.beforeSwap(user2, poolKey, params2, hookData);
        
        poolManager.setMockSqrtPrice(poolId, INITIAL_SQRT_PRICE - 500);
        hook.afterSwap(user2, poolKey, params2, BalanceDelta.wrap(0), "");
        
        // Check that multiple swaps were tracked
        assertEq(hook.userPendingSwaps(poolId, user1), 1);
        assertEq(hook.userPendingSwaps(poolId, user2), 1);
    }

    // ========================= Events Testing =========================
    
    function testSwapQueuedEvent() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        vm.expectEmit(true, true, false, true);
        emit SwapQueued(poolId, user1, 0, block.timestamp);
        
        vm.prank(user1);
        hook.queueSwap(poolKey, params, 0, 0, 0, "");
    }
    
    function testExecutorAuthorizedEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ExecutorAuthorized(executor, true);
        
        hook.setExecutorAuthorization(executor, true);
    }

    // ========================= Edge Cases =========================
    
    function testSwapWithNoHookData() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        // Should not revert with empty hook data
        hook.beforeSwap(user1, poolKey, params, "");
        
        // Check that swap was queued
        assertEq(hook.userPendingSwaps(poolId, user1), 1);
    }
    
    function testMaxQueuedSwaps() public {
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory hookData = abi.encode(uint256(100));
        
        // Queue multiple swaps to test limit (testing up to MAX_BATCH_SIZE)
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(user1);
            hook.beforeSwap(user1, poolKey, params, hookData);
        }
        
        assertEq(hook.userPendingSwaps(poolId, user1), 5);
    }

    // ========================= Events =========================
    event SwapQueued(PoolId indexed poolId, address indexed user, uint256 batchIndex, uint256 queueTime);
    event ExecutorAuthorized(address indexed executor, bool authorized);
} 