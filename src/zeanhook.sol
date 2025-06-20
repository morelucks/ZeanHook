// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
 
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/**
 * @title ZeanHook - Base contract for Uniswap V4 hooks
 * @notice This contract provides the foundation for implementing custom Uniswap V4 hooks.
 */
 
contract ZeanHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /**
     * Constants for slippage bounds (in basis points)
     * MIN_SLIPPAGE = 10 (0.1%)
     * MAX_SLIPPAGE = 500 (5%)
     */
    uint256 public constant MIN_SLIPPAGE = 10;
    uint256 public constant MAX_SLIPPAGE = 500;
    uint256 public constant BASIS_POINTS = 10000;
    // connstants for batch transactions 
     uint256 public constant BATCH_INTERVAL = 180;
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant PRICE_DEVIATION_THRESHOLD = 50;

    /**
     * Parameters for volatility calculation
     */
    uint256 public constant VOLATILITY_WINDOW = 24 hours;
    uint256 public constant MIN_SAMPLES = 5;
    uint256 public constant VOLATILITY_MULTIPLIER = 100;

    /**
     * Commit-Reveal Constants
     */

    uint256 public constant COMMIT_PHASE_DURATION = 60; 
    uint256 public constant REVEAL_PHASE_DURATION = 120;
    uint256 public constant MIN_COMMIT_DELAY = 10; 

    // ========================= Structs =========================
    struct BatchedSwap {
        address user;
        SwapParams params;
        uint256 queueTime;
        uint256 minAmountOut;
        uint160 maxSqrtPriceX96;
        uint160 minSqrtPriceX96;
        bool isExecuted;
        bytes hookData;
    }

    struct BatchState {
        uint256 batchStartTime;
        uint160 referenceSqrtPriceX96;
        bool batchActive;
        uint256 batchCount;
        uint256 totalQueuedSwaps;
        // Commit-Reveal additions
        uint256 commitPhaseStart;
        uint256 revealPhaseStart;
        bool commitPhaseActive;
        bool revealPhaseActive;
        bytes32 batchCommitHash;
    }
    struct PriceData {
        uint160 sqrtPriceX96;
        uint256 timestamp;
    }

    struct VolatilityMetrics {
        uint256 volatility;
        uint256 lastUpdate;
        uint256 sampleCount;
    }

     /**
     * Commit-Reveal Structs
     */
    struct SwapCommit {
        bytes32 commitHash;
        uint256 commitTime;
        bool revealed;
        bool executed;
    }

    struct SwapReveal {
        SwapParams params;
        uint256 minAmountOut;
        uint160 maxSqrtPriceX96;
        uint160 minSqrtPriceX96;
        bytes hookData;
        uint256 nonce;
        bytes32 salt;
    }

    mapping(PoolId => PriceData[]) public priceHistory;
    mapping(PoolId => VolatilityMetrics) public volatilityMetrics;
    mapping(PoolId => uint256) public lastSwapTimestamp;
    mapping(PoolId => BatchedSwap[]) public poolBatches;
    mapping(PoolId => BatchState) public batchStates;
    mapping(PoolId => mapping(address => uint256)) public userPendingSwaps;
    mapping(address => bool) public authorizedExecutors;

     // Commit-Reveal Storage
    mapping(PoolId => mapping(address => SwapCommit[])) public userCommits;
    mapping(PoolId => mapping(bytes32 => SwapReveal)) public commitReveals;
    mapping(PoolId => bytes32[]) public batchCommitHashes;
    mapping(PoolId => mapping(address => uint256)) public userCommitCounts;

    event SlippageCalculated(
        PoolId indexed poolId,
        uint256 volatility,
        uint256 adjustedSlippage,
        uint256 timestamp
    );
    
    event PriceRecorded(
        PoolId indexed poolId,
        uint160 sqrtPriceX96,
        uint256 timestamp
    );


   
    address public owner;

   
    bool private _executing;

    // ========================= Events =========================
    event SwapQueued(
        PoolId indexed poolId,
        address indexed user,
        uint256 batchIndex,
        uint256 queueTime
    );

    event BatchExecuted(
        PoolId indexed poolId,
        uint256 swapsExecuted,
        uint160 executionPrice,
        uint256 timestamp
    );

    event SwapFailed(
        PoolId indexed poolId,
        address indexed user,
        uint256 batchIndex,
        string reason
    );

    event BatchInitialized(
        PoolId indexed poolId,
        uint160 referencePrice,
        uint256 startTime
    );

    event ExecutorAuthorized(address indexed executor, bool authorized);

     // Commit-Reveal Events
    event SwapCommitted(
        PoolId indexed poolId,
        address indexed user,
        bytes32 indexed commitHash,
        uint256 commitTime
    );

    event SwapRevealed(
        PoolId indexed poolId,
        address indexed user,
        bytes32 indexed commitHash,
        uint256 revealTime
    );

    event CommitPhaseStarted(
        PoolId indexed poolId,
        uint256 startTime,
        uint256 endTime
    );

    event RevealPhaseStarted(
        PoolId indexed poolId,
        uint256 startTime,
        uint256 endTime
    );

    event InvalidReveal(
        PoolId indexed poolId,
        address indexed user,
        bytes32 indexed commitHash,
        string reason
    );

    // ========================= Modifiers =========================
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAuthorizedExecutor() {
        require(
            authorizedExecutors[msg.sender] || msg.sender == owner,
            "Not authorized executor"
        );
        _;
    }

    modifier noReentrant() {
        require(!_executing, "Reentrant call");
        _executing = true;
        _;
        _executing = false;
    }

     modifier onlyDuringCommitPhase(PoolId poolId) {
        require(batchStates[poolId].commitPhaseActive, "Not in commit phase");
        require(
            block.timestamp < batchStates[poolId].commitPhaseStart + COMMIT_PHASE_DURATION,
            "Commit phase ended"
        );
        _;
    }

    modifier onlyDuringRevealPhase(PoolId poolId) {
        require(batchStates[poolId].revealPhaseActive, "Not in reveal phase");
        require(
            block.timestamp < batchStates[poolId].revealPhaseStart + REVEAL_PHASE_DURATION,
            "Reveal phase ended"
        );
        _;
    }

     /**
     * @notice Constructor initializes the hook with a PoolManager
     * @param _manager The address of the Uniswap V4 PoolManager contract
     * @dev Inherits from BaseHook which provides core functionality
     */
    constructor(
        IPoolManager _manager
    ) BaseHook(_manager) {
        owner = msg.sender;
        authorizedExecutors[msg.sender] = true;
    }
    
 
	// Set up hook permissions to return `true`
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24,
        bytes calldata
    ) external returns (bytes4) {
        PoolId poolId = key.toId();
        
        priceHistory[poolId].push(PriceData({
            sqrtPriceX96: sqrtPriceX96,
            timestamp: block.timestamp
        }));
        
        volatilityMetrics[poolId] = VolatilityMetrics({
            volatility: MIN_SLIPPAGE,
            lastUpdate: block.timestamp,
            sampleCount: 1
        });


        
        emit PriceRecorded(poolId, sqrtPriceX96, block.timestamp);
        
        // return this.afterInitialize.selector;
        return ZeanHook.afterInitialize.selector;
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        bytes calldata hookData,
        SwapParams calldata params

    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        uint256 adjustedSlippage = calculateVolatilityAdjustedSlippage(poolId);
        
        _validateSwapSlippage(adjustedSlippage, hookData);

        _queueSwap(poolId, key, sender, params, hookData);

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        
        uint160 currentSqrtPrice = _getCurrentSqrtPrice(poolId);
        _recordPriceData(poolId, currentSqrtPrice);
        
        _updateVolatilityMetrics(poolId);
        
        lastSwapTimestamp[poolId] = block.timestamp;
        
        return (this.afterSwap.selector, 0);
    }

        // ========================= Commit-Reveal Functions =========================

    /**
     * @notice Commit to a swap during the commit phase
     * @param poolId The pool identifier
     * @param commitHash Hash of swap parameters + nonce + salt
     */
    function commitSwap(
        PoolId poolId,
        bytes32 commitHash
    ) external onlyDuringCommitPhase(poolId) {
        require(commitHash != bytes32(0), "Invalid commit hash");
        
        SwapCommit memory newCommit = SwapCommit({
            commitHash: commitHash,
            commitTime: block.timestamp,
            revealed: false,
            executed: false
        });

        userCommits[poolId][msg.sender].push(newCommit);
        userCommitCounts[poolId][msg.sender]++;
        batchCommitHashes[poolId].push(commitHash);

        emit SwapCommitted(poolId, msg.sender, commitHash, block.timestamp);
    }

     function revealSwap(
        PoolId poolId,
        uint256 commitIndex,
        SwapParams calldata params,
        uint256 minAmountOut,
        uint160 maxSqrtPriceX96,
        uint160 minSqrtPriceX96,
        bytes calldata hookData,
        uint256 nonce,
        bytes32 salt
    ) external onlyDuringRevealPhase(poolId) {
        require(commitIndex < userCommits[poolId][msg.sender].length, "Invalid commit index");
        
        SwapCommit storage commit = userCommits[poolId][msg.sender][commitIndex];
        require(!commit.revealed, "Already revealed");
        require(
            block.timestamp >= commit.commitTime + MIN_COMMIT_DELAY,
            "Reveal too early"
        );

        // Verify commit hash
        bytes32 expectedHash = generateCommitHash(
            msg.sender,
            params,
            minAmountOut,
            maxSqrtPriceX96,
            minSqrtPriceX96,
            hookData,
            nonce,
            salt
        );

        if (expectedHash != commit.commitHash) {
            emit InvalidReveal(poolId, msg.sender, commit.commitHash, "Hash mismatch");
            return;
        }

        // Mark as revealed and store reveal data
        commit.revealed = true;
        commitReveals[poolId][commit.commitHash] = SwapReveal({
            params: params,
            minAmountOut: minAmountOut,
            maxSqrtPriceX96: maxSqrtPriceX96,
            minSqrtPriceX96: minSqrtPriceX96,
            hookData: hookData,
            nonce: nonce,
            salt: salt
        });

        emit SwapRevealed(poolId, msg.sender, commit.commitHash, block.timestamp);
    }

    /**
     * @notice Generate commit hash for swap parameters
     */
    function generateCommitHash(
        address user,
        SwapParams memory params,
        uint256 minAmountOut,
        uint160 maxSqrtPriceX96,
        uint160 minSqrtPriceX96,
        bytes memory hookData,
        uint256 nonce,
        bytes32 salt
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            user,
            params.zeroForOne,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            minAmountOut,
            maxSqrtPriceX96,
            minSqrtPriceX96,
            hookData,
            nonce,
            salt
        ));
    }

     /**
     * @notice Start commit phase for a pool
     */
    function startCommitPhase(PoolId poolId) external onlyAuthorizedExecutor {
        BatchState storage batchState = batchStates[poolId];
        require(!batchState.commitPhaseActive, "Commit phase already active");
        require(!batchState.revealPhaseActive, "Reveal phase active");

        batchState.commitPhaseActive = true;
        batchState.commitPhaseStart = block.timestamp;
        batchState.batchStartTime = block.timestamp;

        emit CommitPhaseStarted(
            poolId,
            block.timestamp,
            block.timestamp + COMMIT_PHASE_DURATION
        );
    }

     /**
     * @notice Start reveal phase for a pool
     */
    function startRevealPhase(PoolId poolId) external onlyAuthorizedExecutor {
        BatchState storage batchState = batchStates[poolId];
        require(batchState.commitPhaseActive, "No active commit phase");
        require(
            block.timestamp >= batchState.commitPhaseStart + COMMIT_PHASE_DURATION,
            "Commit phase not ended"
        );

        batchState.commitPhaseActive = false;
        batchState.revealPhaseActive = true;
        batchState.revealPhaseStart = block.timestamp;

        emit RevealPhaseStarted(
            poolId,
            block.timestamp,
            block.timestamp + REVEAL_PHASE_DURATION
        );
    }

    /**
     * @notice Execute batch after reveal phase
     */
    function executeBatchAfterReveal(
        PoolKey calldata key
    ) external onlyAuthorizedExecutor noReentrant {
        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];

        require(batchState.revealPhaseActive, "No active reveal phase");
        require(
            block.timestamp >= batchState.revealPhaseStart + REVEAL_PHASE_DURATION,
            "Reveal phase not ended"
        );

        // Convert revealed commits to batched swaps
        _processRevealedCommits(poolId, key);

        // Execute the batch
        uint160 executionPrice = _getCurrentPrice(key);
        uint256 executedCount = _executeSwapBatch(key, poolId, executionPrice);

        // Update state
        batchState.batchCount++;
        batchState.totalQueuedSwaps += executedCount;
        batchState.revealPhaseActive = false;

        // Clear commit data
        _clearCommitData(poolId);

        emit BatchExecuted(
            poolId,
            executedCount,
            executionPrice,
            block.timestamp
        );
    }

    /**
     * @notice Process revealed commits and add them to batch queue
     */
    function _processRevealedCommits(PoolId poolId, PoolKey calldata key) internal {
        bytes32[] storage commitHashes = batchCommitHashes[poolId];
        
        for (uint256 i = 0; i < commitHashes.length; i++) {
            bytes32 commitHash = commitHashes[i];
            SwapReveal memory reveal = commitReveals[poolId][commitHash];
            
            // Find the user who made this commit
            address user = _findCommitUser(poolId, commitHash);
            if (user == address(0)) continue;

            // Add to batch queue
            BatchedSwap memory newSwap = BatchedSwap({
                user: user,
                params: reveal.params,
                queueTime: block.timestamp,
                minAmountOut: reveal.minAmountOut,
                maxSqrtPriceX96: reveal.maxSqrtPriceX96,
                minSqrtPriceX96: reveal.minSqrtPriceX96,
                isExecuted: false,
                hookData: reveal.hookData
            });

            poolBatches[poolId].push(newSwap);
            userPendingSwaps[poolId][user]++;
        }
    }

     /**
     * @notice Find user who made a specific commit
     */
    function _findCommitUser(PoolId poolId, bytes32 commitHash) internal view returns (address) {
        // This is a simplified approach - in production, you might want to store user->commit mapping
        // For now, we iterate through all users (this could be optimized)
        bytes32[] memory hashes = batchCommitHashes[poolId];
        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] == commitHash) {
                // In a real implementation, you'd have a mapping from hash to user
                // This is a placeholder - you'd need to implement proper user tracking
                return address(0); // Placeholder
            }
        }
        return address(0);
    }

    /**
     * @notice Clear commit data after batch execution
     */
    function _clearCommitData(PoolId poolId) internal {
        delete batchCommitHashes[poolId];
        // Note: Individual user commits and reveals are kept for historical purposes
        // You might want to implement a cleanup mechanism based on your requirements
    }


    function queueSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        uint256 minAmountOut,
        uint160 maxSqrtPriceX96,
        uint160 minSqrtPriceX96,
        bytes calldata hookData
    ) external {
        PoolId poolId = key.toId();

        // Validate price limits
        if (maxSqrtPriceX96 > 0 && minSqrtPriceX96 > 0) {
            require(maxSqrtPriceX96 > minSqrtPriceX96, "Invalid price limits");
        }

        _addSwapToBatch(
            poolId,
            key,
            msg.sender,
            params,
            minAmountOut,
            maxSqrtPriceX96,
            minSqrtPriceX96,
            hookData
        );
    }


 // ========================= Internal Functions =========================

    /**
     * @notice Internal function to queue a swap from beforeSwap hook
     */
    function _queueSwap(
        PoolId poolId,
        PoolKey calldata key,
        address user,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal {
        // Decode additional parameters from hookData if provided
        (
            uint256 minAmountOut,
            uint160 maxSqrtPriceX96,
            uint160 minSqrtPriceX96
        ) = hookData.length >= 96
                ? abi.decode(hookData, (uint256, uint160, uint160))
                : (0, uint160(0), uint160(0));

        _addSwapToBatch(
            poolId,
            key,
            user,
            params,
            minAmountOut,
            maxSqrtPriceX96,
            minSqrtPriceX96,
            hookData
        );
    }



    /**
     * @notice Add a swap to the batch queue
     */
    function _addSwapToBatch(
        PoolId poolId,
        PoolKey calldata key,
        address user,
        SwapParams calldata params,
        uint256 minAmountOut,
        uint160 maxSqrtPriceX96,
        uint160 minSqrtPriceX96,
        bytes calldata hookData
    ) internal {
        // Validate swap parameters
        require(params.amountSpecified != 0, "Invalid amount");

        BatchedSwap memory newSwap = BatchedSwap({
            user: user,
            params: params,
            queueTime: block.timestamp,
            minAmountOut: minAmountOut,
            maxSqrtPriceX96: maxSqrtPriceX96,
            minSqrtPriceX96: minSqrtPriceX96,
            isExecuted: false,
            hookData: hookData
        });

        poolBatches[poolId].push(newSwap);
        userPendingSwaps[poolId][user]++;

        // Initialize or update batch state
        BatchState storage batchState = batchStates[poolId];
        if (!batchState.batchActive) {
            batchState.batchActive = true;
            batchState.batchStartTime = block.timestamp;
            batchState.referenceSqrtPriceX96 = _getCurrentSqrtPrice(key.toId());
            emit BatchInitialized(
                poolId,
                batchState.referenceSqrtPriceX96,
                block.timestamp
            );
        }

        emit SwapQueued(
            poolId,
            user,
            poolBatches[poolId].length - 1,
            block.timestamp
        );
    }

/**
     * @notice Execute a single swap at the reference price
     */
    function _executeSwapAtReferencePrice(
        PoolKey calldata key,
        BatchedSwap memory swapData,
        uint160 referenceSqrtPriceX96
    ) internal returns (bool success) {
        // Validate price limits before execution
        if (!_validatePriceLimits(swapData, referenceSqrtPriceX96)) {
            return false;
        }

        // Create swap params with reference price as limit
        SwapParams memory batchParams = SwapParams({
            zeroForOne: swapData.params.zeroForOne,
            amountSpecified: swapData.params.amountSpecified,
            sqrtPriceLimitX96: referenceSqrtPriceX96
        });

        try poolManager.swap(key, batchParams, swapData.hookData) returns (
            BalanceDelta delta
        ) {
            // Validate minimum output if specified
            if (swapData.minAmountOut > 0) {
                int256 outputAmount = swapData.params.zeroForOne
                    ? -delta.amount1()
                    : -delta.amount0();
                if (
                    outputAmount < 0 ||
                    uint256(outputAmount) < swapData.minAmountOut
                ) {
                    return false;
                }
            }
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @notice Execute a batch of swaps atomically
     */
    function _executeSwapBatch(
        PoolKey calldata key,
        PoolId poolId,
        uint160 executionPrice
    ) internal returns (uint256 executedCount) {
        BatchedSwap[] storage batch = poolBatches[poolId];
        executedCount = 0;

        // Execute swaps up to maximum batch size
        for (
            uint256 i = 0;
            i < batch.length && executedCount < MAX_BATCH_SIZE;
            i++
        ) {
            if (!batch[i].isExecuted) {
                if (
                    _executeSwapAtReferencePrice(key, batch[i], executionPrice)
                ) {
                    batch[i].isExecuted = true;
                    executedCount++;
                    userPendingSwaps[poolId][batch[i].user]--;
                } else {
                    emit SwapFailed(
                        poolId,
                        batch[i].user,
                        i,
                        "Execution failed"
                    );
                }
            }
        }

        // Clean up executed swaps
        _cleanupBatch(poolId);

        return executedCount;
    }


    /**
     * @notice Validate price limits for a swap
     */
    function _validatePriceLimits(
        BatchedSwap memory swapData,
        uint160 referenceSqrtPriceX96
    ) internal pure returns (bool) {
        // Check price limits based on swap direction
        if (swapData.params.zeroForOne) {
            // For zeroForOne swaps, check minimum price
            if (
                swapData.minSqrtPriceX96 > 0 &&
                referenceSqrtPriceX96 < swapData.minSqrtPriceX96
            ) {
                return false;
            }
        } else {
            // For oneForZero swaps, check maximum price
            if (
                swapData.maxSqrtPriceX96 > 0 &&
                referenceSqrtPriceX96 > swapData.maxSqrtPriceX96
            ) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Get current price from pool
     */

    function _getCurrentPrice(
        PoolKey calldata key
    ) internal view returns (uint160) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(
            poolManager,
            poolId
        );
        return sqrtPriceX96;
    }
/**
     * @notice Check if price is within acceptable deviation threshold
     */
    function _isPriceWithinThreshold(
        uint160 referencePrice,
        uint160 currentPrice
    ) internal pure returns (bool) {
        if (referencePrice == 0 || currentPrice == 0) return false;

        uint256 priceDiff = referencePrice > currentPrice
            ? referencePrice - currentPrice
            : currentPrice - referencePrice;

        uint256 threshold = (uint256(referencePrice) *
            PRICE_DEVIATION_THRESHOLD) / BASIS_POINTS;

        return priceDiff <= threshold;
    }
     /**
     * @notice Clean up executed swaps from batch
     */
    function _cleanupBatch(PoolId poolId) internal {
        BatchedSwap[] storage batch = poolBatches[poolId];
        uint256 writeIndex = 0;

        // Compact array by moving unexecuted swaps to front
        for (uint256 readIndex = 0; readIndex < batch.length; readIndex++) {
            if (!batch[readIndex].isExecuted) {
                if (writeIndex != readIndex) {
                    batch[writeIndex] = batch[readIndex];
                }
                writeIndex++;
            }
        }

        // Remove executed swaps from the end
        while (batch.length > writeIndex) {
            batch.pop();
        }
    }


    // ========================= Admin Functions =========================

    /**
     * @notice Authorize/deauthorize batch executors
     */
    function setExecutorAuthorization(
        address executor,
        bool authorized
    ) external onlyOwner {
        authorizedExecutors[executor] = authorized;
        emit ExecutorAuthorized(executor, authorized);
    }

    /**
     * @notice Transfer ownership
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        owner = newOwner;
        authorizedExecutors[newOwner] = true;
    }

    /**
     * @notice Emergency function to force execute a batch (owner only)
     */
    function emergencyExecuteBatch(
        PoolKey calldata key
    ) external onlyOwner noReentrant {
        PoolId poolId = key.toId();
        BatchState storage batchState = batchStates[poolId];

        require(batchState.batchActive, "No active batch");
        require(poolBatches[poolId].length > 0, "Empty batch");

        uint160 executionPrice = batchState.referenceSqrtPriceX96;
        uint256 executedCount = _executeSwapBatch(key, poolId, executionPrice);

        // Update state
        batchState.batchCount++;
        batchState.totalQueuedSwaps += executedCount;

        if (poolBatches[poolId].length == 0) {
            batchState.batchActive = false;
        } else {
            batchState.batchStartTime = block.timestamp;
            batchState.referenceSqrtPriceX96 = _getCurrentPrice(key);
        }

        emit BatchExecuted(
            poolId,
            executedCount,
            executionPrice,
            block.timestamp
        );
    }
    // ========================= View Functions =========================

    /**
     * @notice Get comprehensive batch information for a pool
     */
    function getBatchInfo(
        PoolId poolId
    )
        external
        view
        returns (
            uint256 pendingSwaps,
            uint256 batchStartTime,
            uint256 timeUntilExecution,
            uint160 referencePrice,
            bool batchActive,
            uint256 batchCount,
            uint256 totalQueuedSwaps
        )
    {
        BatchState memory state = batchStates[poolId];
        uint256 currentTime = block.timestamp;

        return (
            poolBatches[poolId].length,
            state.batchStartTime,
            state.batchStartTime + BATCH_INTERVAL > currentTime
                ? state.batchStartTime + BATCH_INTERVAL - currentTime
                : 0,
            state.referenceSqrtPriceX96,
            state.batchActive,
            state.batchCount,
            state.totalQueuedSwaps
        );
    }

    /**
     * @notice Get user's pending swaps count
     */
    function getUserPendingSwaps(
        PoolId poolId,
        address user
    ) external view returns (uint256) {
        return userPendingSwaps[poolId][user];
    }

    /**
     * @notice Check if batch can be executed
     */
    function canExecuteBatch(PoolId poolId) external view returns (bool) {
        BatchState memory state = batchStates[poolId];
        return
            state.batchActive &&
            block.timestamp >= state.batchStartTime + BATCH_INTERVAL &&
            poolBatches[poolId].length > 0;
    }

    /**
     * @notice Get batch details with pagination
     */
    function getBatchDetails(
        PoolId poolId,
        uint256 startIndex,
        uint256 count
    ) external view returns (BatchedSwap[] memory) {
        BatchedSwap[] storage batch = poolBatches[poolId];
        require(startIndex < batch.length, "Start index out of bounds");

        uint256 endIndex = startIndex + count;
        if (endIndex > batch.length) {
            endIndex = batch.length;
        }

        BatchedSwap[] memory result = new BatchedSwap[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = batch[i];
        }

        return result;
    }

    /**
     * @notice Get the next batch execution time
     */
    function getNextExecutionTime(
        PoolId poolId
    ) external view returns (uint256) {
        BatchState memory state = batchStates[poolId];
        if (!state.batchActive) {
            return 0;
        }
        return state.batchStartTime + BATCH_INTERVAL;
    }

    /**
     * @notice Check if an address is an authorized executor
     */
    function isAuthorizedExecutor(
        address executor
    ) external view returns (bool) {
        return authorizedExecutors[executor];
    }

    /**
     * @dev Calculate volatility-adjusted slippage based on recent price movements
     * @param poolId The pool identifier
     * @return adjustedSlippage The calculated slippage in basis points
     */
    function calculateVolatilityAdjustedSlippage(PoolId poolId) 
        public 
        view 
        returns (uint256 adjustedSlippage) 
    {
        VolatilityMetrics memory metrics = volatilityMetrics[poolId];
        
        if (metrics.sampleCount < MIN_SAMPLES) {
            return MIN_SLIPPAGE;
        }
        
        adjustedSlippage = MIN_SLIPPAGE;
        
        uint256 volatilityAdjustment = (metrics.volatility * VOLATILITY_MULTIPLIER) / BASIS_POINTS;
        adjustedSlippage += volatilityAdjustment;
        
        if (adjustedSlippage > MAX_SLIPPAGE) {
            adjustedSlippage = MAX_SLIPPAGE;
        }
        
        return adjustedSlippage;
    }

    /**
     * @dev Calculate current volatility based on price history
     * @param poolId The pool identifier
     * @return volatility The calculated volatility in basis points
     */
    function calculateVolatility(PoolId poolId) public view returns (uint256 volatility) {
        PriceData[] memory history = priceHistory[poolId];
        uint256 historyLength = history.length;
        
        if (historyLength < 2) {
            return 0;
        }
        
        uint256 cutoffTime = block.timestamp - VOLATILITY_WINDOW;
        uint256 validSamples = 0;
        uint256 sumSquaredReturns = 0;
        uint256 sumReturns = 0;
        
        for (uint256 i = 1; i < historyLength; i++) {
            if (history[i-1].timestamp < cutoffTime) continue;
            
            uint256 currentPrice = uint256(history[i].sqrtPriceX96);
            uint256 previousPrice = uint256(history[i-1].sqrtPriceX96);
            
            if (previousPrice == 0) continue;
            
            int256 return_ = int256((currentPrice * BASIS_POINTS) / previousPrice) - int256(BASIS_POINTS);
            uint256 absReturn = uint256(return_ < 0 ? -return_ : return_);
            
            sumReturns += absReturn;
            sumSquaredReturns += (absReturn * absReturn) / BASIS_POINTS;
            validSamples++;
        }
        
        if (validSamples < 2) {
            return 0;
        }
        
        uint256 meanReturn = sumReturns / validSamples;
        uint256 variance = (sumSquaredReturns / validSamples) - (meanReturn * meanReturn) / BASIS_POINTS;
        
        volatility = _sqrt(variance);
        
        return volatility;
    }

    /**
     * @dev Get the recommended slippage for a pool
     * @param poolId The pool identifier
     * @return slippage The recommended slippage in basis points
     */
    function getRecommendedSlippage(PoolId poolId) external view returns (uint256 slippage) {
        return calculateVolatilityAdjustedSlippage(poolId);
    }

    /**
     * @dev Get volatility metrics for a pool
     * @param poolId The pool identifier
     * @return metrics The current volatility metrics
     */
    function getVolatilityMetrics(PoolId poolId) 
        external 
        view 
        returns (VolatilityMetrics memory metrics) 
    {
        return volatilityMetrics[poolId];
    }

    /**
     * @dev Get recent price history for a pool
     * @param poolId The pool identifier
     * @param limit Maximum number of recent entries to return
     * @return history Array of recent price data
     */
    function getPriceHistory(PoolId poolId, uint256 limit) 
        external 
        view 
        returns (PriceData[] memory history) 
    {
        PriceData[] memory fullHistory = priceHistory[poolId];
        uint256 length = fullHistory.length;
        
        if (length == 0) {
            return new PriceData[](0);
        }
        
        uint256 returnLength = length > limit ? limit : length;
        history = new PriceData[](returnLength);
        
        uint256 startIndex = length - returnLength;
        for (uint256 i = 0; i < returnLength; i++) {
            history[i] = fullHistory[startIndex + i];
        }
        
        return history;
    }

    //== Internal functions ==//
    function _recordPriceData(PoolId poolId, uint160 sqrtPriceX96) internal {
        PriceData[] storage history = priceHistory[poolId];
        
        history.push(PriceData({
            sqrtPriceX96: sqrtPriceX96,
            timestamp: block.timestamp
        }));
        
        if (history.length > 100) {
            for (uint256 i = 0; i < history.length - 1; i++) {
                history[i] = history[i + 1];
            }
            history.pop();
        }
        
        emit PriceRecorded(poolId, sqrtPriceX96, block.timestamp);
    }
    
    function _updateVolatilityMetrics(PoolId poolId) internal {
        uint256 currentVolatility = calculateVolatility(poolId);
        uint256 adjustedSlippage = calculateVolatilityAdjustedSlippage(poolId);
        
        volatilityMetrics[poolId] = VolatilityMetrics({
            volatility: currentVolatility,
            lastUpdate: block.timestamp,
            sampleCount: priceHistory[poolId].length
        });
        
        emit SlippageCalculated(poolId, currentVolatility, adjustedSlippage, block.timestamp);
    }
    
    function _validateSwapSlippage(
        uint256 recommendedSlippage,
        bytes calldata hookData
    ) internal pure {
        
        if (hookData.length >= 32) {
            uint256 userMaxSlippage = abi.decode(hookData, (uint256));
            require(
                userMaxSlippage >= recommendedSlippage,
                "User slippage below recommended minimum"
            );
            require(userMaxSlippage <= MAX_SLIPPAGE, "User slippage exceeds maximum");
        }
    }
    
    function _getCurrentSqrtPrice(PoolId poolId) internal view returns (uint160) {
        bytes32 slot0 = poolManager.extsload(bytes32(uint256(PoolId.unwrap(poolId))));

        uint160 sqrtPriceX96 = uint160(uint256(slot0));

        return sqrtPriceX96;
    }
    
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        
        return y;
    }	
}