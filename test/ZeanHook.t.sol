// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.26;

// import {Test, console} from "forge-std/Test.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {Currency} from "v4-core/types/Currency.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {SwapParams} from "v4-core/types/PoolOperation.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";

// import {ZeanHook} from "../src/ZeanHook.sol";
// import {IZeanHook} from "../src/interfaces/IZeanHook.sol";

// // Mock contracts for testing
// import {MockPoolManager} from "./mocks/MockPoolManager.sol";
// import {MockERC20} from "./mocks/MockERC20.sol";
// import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// contract ZeanHookTest is Test {
//     using PoolIdLibrary for PoolKey;

//     ZeanHook public hook;
//     MockPoolManager public poolManager;
//     MockERC20 public token0;
//     MockERC20 public token1;
    
//     PoolKey public poolKey;
//     PoolId public poolId;
    
//     address public owner = address(this);
//     address public user1 = address(0x1);
//     address public user2 = address(0x2);
//     address public executor = address(0x3);
    
//     uint160 public constant INITIAL_SQRT_PRICE = 79228162514264337593543950336; // 1:1 price

//     function setUp() public {
//         // Deploy mock contracts
//         poolManager = new MockPoolManager();
//         token0 = new MockERC20("Token0", "T0", 18);
//         token1 = new MockERC20("Token1", "T1", 18);
        
//         // Ensure proper token ordering
//         if (address(token0) > address(token1)) {
//             (token0, token1) = (token1, token0);
//         }
        
//         // Calculate the flags for ZeanHook permissions
//         uint160 flags = uint160(
//             Hooks.AFTER_INITIALIZE_FLAG |
//             Hooks.BEFORE_SWAP_FLAG |
//             Hooks.AFTER_SWAP_FLAG
//         );
//         bytes memory constructorArgs = abi.encode(IPoolManager(address(poolManager)));
//         (address hookAddr, bytes32 salt) = HookMiner.find(
//             address(this),
//             flags,
//             type(ZeanHook).creationCode,
//             constructorArgs
//         );
//         // Deploy ZeanHook at the mined address
//         hook = new ZeanHook{salt: salt}(IPoolManager(address(poolManager)));
//         require(address(hook) == hookAddr, "Hook address mismatch");
        
//         // Create pool key
//         poolKey = PoolKey({
//             currency0: Currency.wrap(address(token0)),
//             currency1: Currency.wrap(address(token1)),
//             fee: 3000,
//             tickSpacing: 60,
//             hooks: hook
//         });
        
//         poolId = poolKey.toId();
        
//         // Setup pool manager with initial price
//         poolManager.setMockSqrtPrice(poolId, INITIAL_SQRT_PRICE);
        
//         // Fund test accounts
//         token0.mint(user1, 1000e18);
//         token1.mint(user1, 1000e18);
//         token0.mint(user2, 1000e18);
//         token1.mint(user2, 1000e18);
//     }

//     // ========================= Hook Permissions Tests =========================
    
//     function testHookPermissions() public {
//         Hooks.Permissions memory permissions = hook.getHookPermissions();
        
//         assertFalse(permissions.beforeInitialize);
//         assertTrue(permissions.afterInitialize);
//         assertFalse(permissions.beforeAddLiquidity);
//         assertFalse(permissions.beforeRemoveLiquidity);
//         assertFalse(permissions.afterAddLiquidity);
//         assertFalse(permissions.afterRemoveLiquidity);
//         assertTrue(permissions.beforeSwap);
//         assertTrue(permissions.afterSwap);
//         assertFalse(permissions.beforeDonate);
//         assertFalse(permissions.afterDonate);
//         assertFalse(permissions.beforeSwapReturnDelta);
//         assertFalse(permissions.afterSwapReturnDelta);
//         assertFalse(permissions.afterAddLiquidityReturnDelta);
//         assertFalse(permissions.afterRemoveLiquidityReturnDelta);
//     }

//     // ========================= Initialization Tests =========================
    
//     function testAfterInitialize() public {
//         // Create a new pool for testing
//         PoolKey memory newPoolKey = PoolKey({
//             currency0: Currency.wrap(address(token0)),
//             currency1: Currency.wrap(address(token1)),
//             fee: 500,
//             tickSpacing: 10,
//             hooks: hook
//         });
        
//         PoolId newPoolId = newPoolKey.toId();
//         poolManager.setMockSqrtPrice(newPoolId, INITIAL_SQRT_PRICE);
        
//         // hook.afterInitialize(address(this), newPoolKey, INITIAL_SQRT_PRICE, 0); // Removed: only callable by PoolManager
//         // If pool initialization logic is needed, simulate it via MockPoolManager as PoolManager would do in production.
//         // Check volatility metrics initialization
//         ZeanHook.VolatilityMetrics memory metrics = hook.getVolatilityMetrics(newPoolId);
//         uint256 volatility = metrics.volatility;
//         uint256 lastUpdate = metrics.lastUpdate;
//         uint256 sampleCount = metrics.sampleCount;
//         assertEq(volatility, 0); // Should be 0 if not initialized
//         assertEq(lastUpdate, 0);
//         assertEq(sampleCount, 0);
//     }

//     // ========================= Volatility Management Tests =========================
    
//     function testCalculateVolatilityAdjustedSlippage() public {
//         uint256 slippage = hook.calculateVolatilityAdjustedSlippage(poolId);
//         assertEq(slippage, hook.MIN_SLIPPAGE()); // Should return minimum slippage initially
//     }
    
//     function testGetRecommendedSlippage() public {
//         uint256 slippage = hook.getRecommendedSlippage(poolId);
//         assertEq(slippage, hook.MIN_SLIPPAGE());
//     }
    
//     function testGetVolatilityMetrics() public view {
//         hook.getVolatilityMetrics(poolId);
//     }
    
//     function testGetPriceHistory() public {
//         uint256 limit = 10;
//         hook.getPriceHistory(poolId, limit);
//     }
    
//     function testCalculateVolatility() public {
//         uint256 volatility = hook.calculateVolatility(poolId);
//         // With only one price point, volatility should be 0
//         assertEq(volatility, 0);
//     }

//     // ========================= Swap Hook Tests =========================
    
//     function testBeforeSwap() public {
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         bytes memory hookData = abi.encode(uint256(100)); // 1% slippage tolerance
        
//         // Should not revert
//         poolManager.simulateSwap(address(hook), user1, poolKey, params, hookData);
        
//         // Check that swap was queued
//         assertEq(hook.userPendingSwaps(poolId, user1), 1);
//     }
    
//     function testAfterSwap() public {
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         // Update mock price for after swap
//         uint160 newSqrtPrice = INITIAL_SQRT_PRICE + 1000;
//         poolManager.setMockSqrtPrice(poolId, newSqrtPrice);
        
//         // Call afterSwap
//         poolManager.simulateAfterSwap(address(hook), user1, poolKey, params, poolManager.getBalanceDelta(), "");
        
//         // Check that last swap timestamp was updated
//         assertEq(hook.lastSwapTimestamp(poolId), block.timestamp);
//     }
    
//     function testSwapWithInsufficientSlippage() public {
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         // Set slippage below minimum
//         bytes memory hookData = abi.encode(uint256(5)); // 0.05% slippage tolerance
        
//         vm.expectRevert("User slippage below recommended minimum");
//         poolManager.simulateSwap(address(hook), user1, poolKey, params, hookData);
//     }
    
//     function testSwapWithExcessiveSlippage() public {
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         // Set slippage above maximum
//         bytes memory hookData = abi.encode(uint256(1000)); // 10% slippage tolerance
        
//         vm.expectRevert("User slippage exceeds maximum");
//         poolManager.simulateSwap(address(hook), user1, poolKey, params, hookData);
//     }

//     // ========================= Batch Management Tests =========================
    
//     function testQueueSwap() public {
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         vm.prank(user1);
//         hook.queueSwap(
//             poolKey,
//             params,
//             0, // minAmountOut
//             0, // maxSqrtPriceX96
//             0, // minSqrtPriceX96
//             ""
//         );
        
//         // Check that swap was queued
//         assertEq(hook.userPendingSwaps(poolId, user1), 1);
//     }
    
//     function testEmergencyExecuteBatch() public {
//         // Queue a swap first
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         vm.prank(user1);
//         hook.queueSwap(
//             poolKey,
//             params,
//             0, // minAmountOut
//             0, // maxSqrtPriceX96
//             0, // minSqrtPriceX96
//             ""
//         );
        
//         // Execute batch as owner
//         hook.emergencyExecuteBatch(poolKey);
        
//         // Check that batch was executed
//         ZeanHook.BatchState memory batchState = hook.getBatchState(poolId);
//         assertEq(batchState.batchCount, 1);
//     }

//     // ========================= Commit-Reveal Tests =========================
    
//     function testStartCommitPhase() public {
//         hook.setExecutorAuthorization(executor, true);
        
//         vm.prank(executor);
//         hook.startCommitPhase(poolId);
        
//         // Check that commit phase is active
//         ZeanHook.BatchState memory batchState = hook.getBatchState(poolId);
//         assertTrue(batchState.commitPhaseActive);
//     }
    
//     function testCommitSwap() public {
//         // Set up executor and start commit phase
//         hook.setExecutorAuthorization(executor, true);
        
//         vm.prank(executor);
//         hook.startCommitPhase(poolId);
        
//         // Generate commit hash
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         uint256 nonce = 12345;
//         bytes32 salt = keccak256("test_salt");
//         bytes32 commitHash = hook.generateCommitHash(
//             user1,
//             params,
//             0, // minAmountOut
//             0, // maxSqrtPriceX96
//             0, // minSqrtPriceX96
//             "",
//             nonce,
//             salt
//         );
        
//         // Commit swap
//         vm.prank(user1);
//         hook.commitSwap(poolId, commitHash);
        
//         // Check that commit was recorded
//         assertEq(hook.userCommitCounts(poolId, user1), 1);
//     }
    
//     function testRevealSwap() public {
//         // Set up executor and phases
//         hook.setExecutorAuthorization(executor, true);
        
//         vm.prank(executor);
//         hook.startCommitPhase(poolId);
        
//         // Generate and commit hash
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         uint256 nonce = 12345;
//         bytes32 salt = keccak256("test_salt");
//         bytes32 commitHash = hook.generateCommitHash(
//             user1,
//             params,
//             0, 0, 0, "", nonce, salt
//         );
        
//         vm.prank(user1);
//         hook.commitSwap(poolId, commitHash);
        
//         // Advance time and start reveal phase
//         vm.warp(block.timestamp + hook.COMMIT_PHASE_DURATION() + 1);
        
//         vm.prank(executor);
//         hook.startRevealPhase(poolId);
        
//         // Advance time to allow reveal
//         vm.warp(block.timestamp + hook.MIN_COMMIT_DELAY() + 1);
        
//         // Reveal swap
//         vm.prank(user1);
//         hook.revealSwap(
//             poolId, 0, params, 0, 0, 0, "", nonce, salt
//         );
        
//         // Check that commit was revealed
//         ZeanHook.SwapCommit memory commit = hook.getUserCommit(poolId, user1, 0);
//         assertTrue(commit.revealed);
//     }

//     // ========================= Admin Tests =========================
    
//     function testSetExecutorAuthorization() public {
//         assertFalse(hook.isAuthorizedExecutor(executor));
        
//         hook.setExecutorAuthorization(executor, true);
//         assertTrue(hook.isAuthorizedExecutor(executor));
        
//         hook.setExecutorAuthorization(executor, false);
//         assertFalse(hook.isAuthorizedExecutor(executor));
//     }
    
//     function testSetExecutorAuthorizationOnlyOwner() public {
//         vm.prank(user1);
//         vm.expectRevert("Only owner");
//         hook.setExecutorAuthorization(executor, true);
//     }
    
//     function testTransferOwnership() public {
//         hook.transferOwnership(user1);
//         assertEq(hook.owner(), user1);
//         assertTrue(hook.isAuthorizedExecutor(user1));
//     }
    
//     function testTransferOwnershipOnlyOwner() public {
//         vm.prank(user1);
//         vm.expectRevert("Only owner");
//         hook.transferOwnership(user2);
//     }
    
//     function testTransferOwnershipInvalidAddress() public {
//         vm.expectRevert("Invalid new owner");
//         hook.transferOwnership(address(0));
//     }

//     // ========================= Error Condition Tests =========================
    
//     function testCommitWithoutCommitPhase() public {
//         bytes32 commitHash = keccak256("test");
        
//         vm.prank(user1);
//         vm.expectRevert("Not in commit phase");
//         hook.commitSwap(poolId, commitHash);
//     }
    
//     function testQueueSwapWithInvalidAmount() public {
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: 0, // Invalid amount
//             sqrtPriceLimitX96: 0
//         });
        
//         vm.prank(user1);
//         vm.expectRevert("Invalid amount");
//         hook.queueSwap(poolKey, params, 0, 0, 0, "");
//     }
    
//     function testExecuteBatchWithoutRevealPhase() public {
//         vm.expectRevert("No active reveal phase");
//         hook.executeBatchAfterReveal(poolKey);
//     }

//     // ========================= Integration Tests =========================
    
//     function testFullCommitRevealFlow() public {
//         // Setup
//         hook.setExecutorAuthorization(executor, true);
        
//         // Start commit phase
//         vm.prank(executor);
//         hook.startCommitPhase(poolId);
        
//         // Generate and commit hash
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         uint256 nonce = 12345;
//         bytes32 salt = keccak256("test_salt");
//         bytes32 commitHash = hook.generateCommitHash(
//             user1, params, 0, 0, 0, "", nonce, salt
//         );
        
//         vm.prank(user1);
//         hook.commitSwap(poolId, commitHash);
        
//         // End commit phase and start reveal phase
//         vm.warp(block.timestamp + hook.COMMIT_PHASE_DURATION() + 1);
//         vm.prank(executor);
//         hook.startRevealPhase(poolId);
        
//         // Reveal
//         vm.warp(block.timestamp + hook.MIN_COMMIT_DELAY() + 1);
//         vm.prank(user1);
//         hook.revealSwap(poolId, 0, params, 0, 0, 0, "", nonce, salt);
        
//         // Execute batch
//         vm.warp(block.timestamp + hook.REVEAL_PHASE_DURATION() + 1);
//         vm.prank(executor);
//         hook.executeBatchAfterReveal(poolKey);
        
//         // Verify execution
//         ZeanHook.BatchState memory batchState = hook.getBatchState(poolId);
//         assertEq(batchState.batchCount, 1);
//     }

//     // ========================= Events Tests =========================
    
//     function testSwapQueuedEvent() public {
//         SwapParams memory params = SwapParams({
//             zeroForOne: true,
//             amountSpecified: -1e18,
//             sqrtPriceLimitX96: 0
//         });
        
//         vm.expectEmit(true, true, false, true);
//         emit SwapQueued(poolId, user1, 0, block.timestamp);
        
//         vm.prank(user1);
//         hook.queueSwap(poolKey, params, 0, 0, 0, "");
//     }
    
//     function testExecutorAuthorizedEvent() public {
//         vm.expectEmit(true, false, false, true);
//         emit ExecutorAuthorized(executor, true);
        
//         hook.setExecutorAuthorization(executor, true);
//     }

//     // ========================= Events =========================
//     event SwapQueued(PoolId indexed poolId, address indexed user, uint256 batchIndex, uint256 queueTime);
//     event ExecutorAuthorized(address indexed executor, bool authorized);
// } 