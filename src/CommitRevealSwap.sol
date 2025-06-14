// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";


contract CommitRevealSwap is BaseHook {
    using PoolIdLibrary for PoolKey;

    uint256 public constant COMMIT_DURATION = 30 seconds;  
    uint256 public constant REVEAL_DURATION = 60 seconds;   
    uint256 public constant MAX_COMMITS_PER_ROUND = 100;    // DoS protection
    uint256 public constant COMMITMENT_BOND = 0.01 ether;   // Anti-spam bond
    uint256 public constant MAX_SLIPPAGE = 500; // 5% max slippage in basis points

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
        uint256 bond;         // ETH bond amount
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
        mapping(bytes32 => uint256) commitHashToIndex;       // Hash to index mapping
    }

    uint256 public currentRoundId;
    mapping(uint256 => CommitRound) public commitRounds;
    mapping(uint256 => RevealedSwap[]) public revealedSwaps;

    address public owner;
    mapping(address => bool) public authorizedExecutors;

    // Events
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

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAuthorizedExecutor() {
        require(authorizedExecutors[msg.sender] || msg.sender == owner, "Not authorized");
        _;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        owner = msg.sender;
        authorizedExecutors[msg.sender] = true;
        _startNewRound();
    }

   
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,         
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
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

        // Store mapping (add 1 to distinguish from default 0)
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

        bytes32 expectedHash = keccak256(abi.encode(
            poolKey,
            swapParams,
            maxSlippage,  
            nonce,
            deadline
        ));
        require(expectedHash == commitment.commitHash, "Invalid reveal - hash mismatch");

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
     * @notice Execute all revealed swaps in batch
     * @dev Only authorized executors can call this to ensure fair execution
     */
    function executeRevealedSwaps() external onlyAuthorizedExecutor {
        CommitRound storage round = commitRounds[currentRoundId];
        require(round.currentPhase == Phase.Execute, "Not in execute phase");

        RevealedSwap[] storage swaps = revealedSwaps[currentRoundId];
        
        // Execute all valid swaps in batch
        for (uint256 i = 0; i < swaps.length; i++) {
            if (!swaps[i].executed && block.timestamp <= swaps[i].deadline) {
                bool success = _executeSwap(swaps[i]);
                swaps[i].executed = true;
                
                emit SwapExecuted(
                    currentRoundId, 
                    swaps[i].swapper, 
                    swaps[i].poolKey.toId(),
                    success
                );
            }
        }

        // Finalize the round and start the next one
        _finalizeRound();
    }

    
    function advancePhase() external {
        CommitRound storage round = commitRounds[currentRoundId];
        uint256 timeInPhase = block.timestamp - round.phaseStartTime;

        if (round.currentPhase == Phase.Commit && timeInPhase >= COMMIT_DURATION) {
            // Move from commit to reveal phase
            round.currentPhase = Phase.Reveal;
            round.phaseStartTime = block.timestamp;
            emit RevealPhaseStarted(currentRoundId, block.timestamp);
            
        } else if (round.currentPhase == Phase.Reveal && timeInPhase >= REVEAL_DURATION) {
            // Move from reveal to execute phase
            round.currentPhase = Phase.Execute;
            round.phaseStartTime = block.timestamp;
            emit ExecutePhaseStarted(currentRoundId, block.timestamp);
            
        } else if (round.currentPhase == Phase.Execute) {
            revert("Call executeRevealedSwaps to complete this phase");
        }
    }

    //== INTERNAL FUNCTIONS ==//

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

    /**
     * @dev Callback function called by poolManager.unlock()
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        
        RevealedSwap memory swap = abi.decode(data, (RevealedSwap));
        
        // Execute the actual swap
        poolManager.swap(swap.poolKey, swap.swapParams, "");
        
        return "";
    }

    /**
     * @dev Finalize the current round and start a new one
     */
    function _finalizeRound() internal {
        CommitRound storage round = commitRounds[currentRoundId];
        
        for (uint256 i = 0; i < round.commitCount; i++) {
            SwapCommitment storage commitment = round.commitments[i];
            
            if (!commitment.revealed) {
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
            timeRemaining = 0; // Execute phase has no time limit
        }
    }

   
    function getCommitment(uint256 roundId, uint256 commitIndex) 
        external 
        view 
        returns (SwapCommitment memory) 
    {
        return commitRounds[roundId].commitments[commitIndex];
    }

   
    function getRevealedSwaps(uint256 roundId) 
        external 
        view 
        returns (RevealedSwap[] memory) 
    {
        return revealedSwaps[roundId];
    }

    function getCurrentCommitCount() external view returns (uint256) {
        return commitRounds[currentRoundId].commitCount;
    }

    
    function isCommitmentHashUsed(bytes32 commitHash) external view returns (bool) {
        return commitRounds[currentRoundId].commitHashToIndex[commitHash] != 0;
    }

    //== ADMIN FUNCTIONS ==//

    /**
     * @notice Add or remove authorized executors
     */
    function setAuthorizedExecutor(address executor, bool authorized) external onlyOwner {
        authorizedExecutors[executor] = authorized;
    }

    
    function emergencyWithdraw() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }


    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    //== UTILITY FUNCTIONS ==//

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }


    receive() external payable {}
}