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

    /**
     * Parameters for volatility calculation
     */
    uint256 public constant VOLATILITY_WINDOW = 24 hours;
    uint256 public constant MIN_SAMPLES = 5;
    uint256 public constant VOLATILITY_MULTIPLIER = 100;

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
    }

     /**
     * @notice Constructor initializes the hook with a PoolManager
     * @param _manager The address of the Uniswap V4 PoolManager contract
     * @dev Inherits from BaseHook which provides core functionality
     */
    constructor(
        IPoolManager _manager,
        address _protocolTreasury
    ) BaseHook(_manager) {
        require(_protocolTreasury != address(0), "Invalid treasury");
        PROTOCOL_TREASURY = _protocolTreasury;
        _startNewRound();
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
        address,
        PoolKey calldata key,
        bytes calldata hookData
    ) internal view returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        uint256 adjustedSlippage = calculateVolatilityAdjustedSlippage(poolId);
        
        _validateSwapSlippage(adjustedSlippage, hookData);
        
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