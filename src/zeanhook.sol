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

 commit-reveal
    /**
     * Parameters for commit-reveal
     */
    uint256 public constant COMMIT_DURATION = 30 seconds;  
    uint256 public constant REVEAL_DURATION = 60 seconds;   
    uint256 public constant MAX_COMMITS_PER_ROUND = 100;    
    uint256 public constant COMMITMENT_BOND = 0.01 ether; 
    uint256 public constant EXECUTION_GRACE_PERIOD = 10 minutes; 

    // Trading round phases
    enum Phase {
        Commit,   
        Reveal,    
        Execute,  
        Cooldown   
    }

    struct SwapCommitment {
        bytes32 commitHash;
        address committer;     
        uint256 bond;         
        uint256 timestamp;    
        bool revealed;       
        bool executed;        
    }

    struct RevealedSwap {
        PoolKey poolKey;      
        SwapParams swapParams; 
        address swapper;     
        uint256 maxSlippage;  
        uint256 nonce;        
        uint256 deadline;     
        bool executed;        
    }

    struct CommitRound {
        uint256 roundId;           
        Phase currentPhase;
        uint256 phaseStartTime;   
        uint256 commitCount;
        mapping(uint256 => SwapCommitment) commitments;      // Commitment storage
        mapping(bytes32 => uint256) commitHashToIndex;    
    }


    struct BatchState {
        uint256 batchStartTime;
        uint160 referenceSqrtPriceX96;
        bool batchActive;
        uint256 batchCount;
        uint256 totalQueuedSwaps;
    }
 main
    struct PriceData {
        uint160 sqrtPriceX96;
        uint256 timestamp;
    }

    struct VolatilityMetrics {
        uint256 volatility;
        uint256 lastUpdate;
        uint256 sampleCount;
    }

    uint256 public currentRoundId;
    mapping(uint256 => CommitRound) public commitRounds;
    mapping(uint256 => RevealedSwap[]) public revealedSwaps;
    mapping(PoolId => PriceData[]) public priceHistory;
    mapping(PoolId => VolatilityMetrics) public volatilityMetrics;
    mapping(PoolId => uint256) public lastSwapTimestamp;
    mapping(PoolId => BatchedSwap[]) public poolBatches;
    mapping(PoolId => BatchState) public batchStates;
    mapping(PoolId => mapping(address => uint256)) public userPendingSwaps;
    mapping(address => bool) public authorizedExecutors;

    // Protocol treasury for slashed bonds (immutable) 
    //  instead of using an admin to control the slashed bonds
    address public immutable PROTOCOL_TREASURY;
    mapping(address => bool) public authorizedExecutors;

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

 commit-reveal
    // Events for commit-reveal
    event CommitPhaseStarted(uint256 indexed roundId, uint256 startTime);
    event RevealPhaseStarted(uint256 indexed roundId, uint256 startTime);
    event ExecutePhaseStarted(uint256 indexed roundId, uint256 startTime);
    event SwapCommitted(
        uint256 indexed roundId, 
        uint256 commitIndex, 
        address indexed committer, 
        bytes32 commitHash
    );
    event SwapRevealed(
        uint256 indexed roundId, 
        uint256 commitIndex, 
        address indexed swapper
    );
    event SwapExecuted(
        uint256 indexed roundId, 
        address indexed swapper, 
        PoolId indexed poolId,
        bool success
    );
    event BondSlashed(
        uint256 indexed roundId, 
        uint256 commitIndex, 
        address indexed committer, 
        uint256 amount
    );
    event BondReturned(
        uint256 indexed roundId, 
        address indexed committer, 
        uint256 amount
    );


    modifier onlyAuthorizedExecutor() {
        require(authorizedExecutors[msg.sender], "Not authorized");
        _;


   
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
 main
    }

     /**
     * @notice Constructor initializes the hook with a PoolManager
     * @param _manager The address of the Uniswap V4 PoolManager contract
     * @dev Inherits from BaseHook which provides core functionality
     */
    constructor(
 commit-reveal
        IPoolManager _manager,
        address _protocolTreasury
    ) BaseHook(_manager) {
        require(_protocolTreasury != address(0), "Invalid treasury");
        PROTOCOL_TREASURY = _protocolTreasury;
        _startNewRound();
    }

        IPoolManager _manager
    ) BaseHook(_manager) {
        owner = msg.sender;
        authorizedExecutors[msg.sender] = true;
    }
    
 main
 
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

     //== COMMIT PHASE ==//

    /**
     * @notice Submit a commitment to swap without revealing parameters
     * @param commitHash Keccak256 hash of abi.encode(poolKey, swapParams, maxSlippage, nonce, deadline)
     * @dev Users must include the commitment bond to prevent spam attacks
     */

    function commitSwap(bytes32 commitHash) external payable {
        require(msg.value >= COMMITMENT_BOND, "Insufficient bond");
        
        CommitRound storage round = commitRounds[currentRoundId];
        require(round.currentPhase == Phase.Commit, "Not in commit phase");
        require(round.commitCount < MAX_COMMITS_PER_ROUND, "Max commits reached");
        require(round.commitHashToIndex[commitHash] == 0, "Duplicate commit");

        uint256 commitIndex = round.commitCount;
        round.commitments[commitIndex] = SwapCommitment({
            commitHash: commitHash,
            committer: msg.sender,
            bond: msg.value,
            timestamp: block.timestamp,
            revealed: false,
            executed: false
        });

        round.commitHashToIndex[commitHash] = commitIndex + 1;
        round.commitCount++;

        emit SwapCommitted(currentRoundId, commitIndex, msg.sender, commitHash);
    }

    function createCommitmentHash(
        PoolKey calldata poolKey,
        SwapParams calldata swapParams,
        uint256 maxSlippage,
        uint256 nonce,
        uint256 deadline
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(poolKey, swapParams, maxSlippage, nonce, deadline));
    }

    function revealSwap(
        uint256 commitIndex,
        PoolKey calldata poolKey,
        SwapParams calldata swapParams,
        uint256 maxSlippage,
        uint256 nonce,
        uint256 deadline
    ) external {
        CommitRound storage round = commitRounds[currentRoundId];
        require(round.currentPhase == Phase.Reveal, "Not in reveal phase");
        require(commitIndex < round.commitCount, "Invalid commit index");
        
        SwapCommitment storage commitment = round.commitments[commitIndex];
        require(commitment.committer == msg.sender, "Not your commitment");
        require(!commitment.revealed, "Already revealed");
        require(block.timestamp <= deadline, "Deadline passed");
        require(maxSlippage <= MAX_SLIPPAGE, "Slippage too high");

        bytes32 expectedHash = keccak256(abi.encode(poolKey, swapParams, maxSlippage, nonce, deadline));
        require(expectedHash == commitment.commitHash, "Invalid reveal");

        commitment.revealed = true;
        
        revealedSwaps[currentRoundId].push(RevealedSwap({
            poolKey: poolKey,
            swapParams: swapParams,
            swapper: msg.sender,
            maxSlippage: maxSlippage,
            nonce: nonce,
            deadline: deadline,
            executed: false
        }));

        emit SwapRevealed(currentRoundId, commitIndex, msg.sender);
    }

    //== EXECUTE PHASE ==//

    
    /**
     * @notice Execute all revealed swaps - ANYONE can call this function
     * @dev No authorization required - fully decentralized execution
     */

    function executeRevealedSwaps() external {
        CommitRound storage round = commitRounds[currentRoundId];
        require(round.currentPhase == Phase.Execute, "Not in execute phase");

        // Optional: Add grace period for fair execution
        uint256 timeInExecutePhase = block.timestamp - round.phaseStartTime;
        require(timeInExecutePhase >= EXECUTION_GRACE_PERIOD, "Grace period not over");

        RevealedSwap[] storage swaps = revealedSwaps[currentRoundId];
        
        for (uint256 i = 0; i < swaps.length; i++) {
            if (!swaps[i].executed && block.timestamp <= swaps[i].deadline) {
                bool success = _executeSwap(swaps[i]);
                swaps[i].executed = true;
                
                emit SwapExecuted(currentRoundId, swaps[i].swapper, swaps[i].poolKey.toId(), success);
            }
        }

        _finalizeRound();
    }

    /**
     * @notice Advance to the next phase - ANYONE can call this
     * @dev Fully automated phase transitions based on time
     */

    function advancePhase() external {
        CommitRound storage round = commitRounds[currentRoundId];
        uint256 timeInPhase = block.timestamp - round.phaseStartTime;

        if (round.currentPhase == Phase.Commit && timeInPhase >= COMMIT_DURATION) {
            round.currentPhase = Phase.Reveal;
            round.phaseStartTime = block.timestamp;
            emit RevealPhaseStarted(currentRoundId, block.timestamp);
            
        } else if (round.currentPhase == Phase.Reveal && timeInPhase >= REVEAL_DURATION) {
            round.currentPhase = Phase.Execute;
            round.phaseStartTime = block.timestamp;
            emit ExecutePhaseStarted(currentRoundId, block.timestamp);
            
        } else if (round.currentPhase == Phase.Execute) {
            revert("Call executeRevealedSwaps to complete this phase");
        }
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
    /**
     * @dev Execute a single swap through the pool manager using unlock/lock pattern
     */
    function _executeSwap(RevealedSwap memory swap) internal returns (bool success) {
        try poolManager.unlock(abi.encode(swap)) {
            return true;
        } catch {
            return false;
        }
    }

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

     /**
     * @dev Callback function called by poolManager.unlock()
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        
        RevealedSwap memory swap = abi.decode(data, (RevealedSwap));
        
        poolManager.swap(swap.poolKey, swap.swapParams, "");
        
        return "";
    }

      /**
     * @dev Decentralized bond handling - no admin discretion
     */
    function _finalizeRound() internal {
        CommitRound storage round = commitRounds[currentRoundId];
        
        for (uint256 i = 0; i < round.commitCount; i++) {
            SwapCommitment storage commitment = round.commitments[i];
            
            if (!commitment.revealed) {
                // Automatically send slashed bonds to protocol treasury
                payable(PROTOCOL_TREASURY).transfer(commitment.bond);
                emit BondSlashed(currentRoundId, i, commitment.committer, commitment.bond);
            } else {
                // Return bond to users who revealed their commitments
                payable(commitment.committer).transfer(commitment.bond);
                emit BondReturned(currentRoundId, commitment.committer, commitment.bond);
            }
        }

        _startNewRound();
    }


    /**
     * @dev Initialize a new trading round
     */
    function _startNewRound() internal {
        currentRoundId++;
        CommitRound storage newRound = commitRounds[currentRoundId];
        newRound.roundId = currentRoundId;
        newRound.currentPhase = Phase.Commit;
        newRound.phaseStartTime = block.timestamp;
        newRound.commitCount = 0;

        emit CommitPhaseStarted(currentRoundId, block.timestamp);
    }	

    //== VIEW FUNCTIONS ==//

    /**
     * @notice Get the current phase and time remaining
     */
    function getCurrentPhase() external view returns (Phase phase, uint256 timeRemaining) {
        CommitRound storage round = commitRounds[currentRoundId];
        phase = round.currentPhase;
        
        uint256 timeInPhase = block.timestamp - round.phaseStartTime;
        
        if (phase == Phase.Commit) {
            timeRemaining = timeInPhase >= COMMIT_DURATION ? 0 : COMMIT_DURATION - timeInPhase;
        } else if (phase == Phase.Reveal) {
            timeRemaining = timeInPhase >= REVEAL_DURATION ? 0 : REVEAL_DURATION - timeInPhase;
        } else {
            timeRemaining = 0;
        }
    }

    function getCommitment(uint256 roundId, uint256 commitIndex) 
        external view returns (SwapCommitment memory) {
        return commitRounds[roundId].commitments[commitIndex];
    }

    function getRevealedSwaps(uint256 roundId) 
        external view returns (RevealedSwap[] memory) {
        return revealedSwaps[roundId];
    }

    function getCurrentCommitCount() external view returns (uint256) {
        return commitRounds[currentRoundId].commitCount;
    }

    function isCommitmentHashUsed(bytes32 commitHash) external view returns (bool) {
        return commitRounds[currentRoundId].commitHashToIndex[commitHash] != 0;
    }

        //== UTILITY FUNCTIONS ==//

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }


    receive() external payable {}

}