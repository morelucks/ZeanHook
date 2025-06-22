// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {ZeanHookStorage} from "./ZeanHookStorage.sol";

abstract contract CommitRevealManager is ZeanHookStorage {

    // ========================= Events =========================
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

    modifier onlyAuthorizedExecutor() {
        require(
            authorizedExecutors[msg.sender] || msg.sender == owner,
            "Not authorized executor"
        );
        _;
    }

    // ========================= External Functions =========================
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

    // ========================= Internal Functions =========================
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

    function _clearCommitData(PoolId poolId) internal {
        delete batchCommitHashes[poolId];
        // Note: Individual user commits and reveals are kept for historical purposes
        // You might want to implement a cleanup mechanism based on your requirements
    }

    // ========================= View Functions =========================
    function getCommitPhaseInfo(PoolId poolId) external view returns (
        bool active,
        uint256 startTime,
        uint256 endTime,
        uint256 remainingTime
    ) {
        BatchState memory state = batchStates[poolId];
        active = state.commitPhaseActive;
        startTime = state.commitPhaseStart;
        endTime = startTime + COMMIT_PHASE_DURATION;
        
        if (active && block.timestamp < endTime) {
            remainingTime = endTime - block.timestamp;
        } else {
            remainingTime = 0;
        }
    }

    function getRevealPhaseInfo(PoolId poolId) external view returns (
        bool active,
        uint256 startTime,
        uint256 endTime,
        uint256 remainingTime
    ) {
        BatchState memory state = batchStates[poolId];
        active = state.revealPhaseActive;
        startTime = state.revealPhaseStart;
        endTime = startTime + REVEAL_PHASE_DURATION;
        
        if (active && block.timestamp < endTime) {
            remainingTime = endTime - block.timestamp;
        } else {
            remainingTime = 0;
        }
    }

    function getUserCommitCount(PoolId poolId, address user) external view returns (uint256) {
        return userCommitCounts[poolId][user];
    }

    function getUserCommits(PoolId poolId, address user) external view returns (SwapCommit[] memory) {
        return userCommits[poolId][user];
    }

    function getCommitReveal(PoolId poolId, bytes32 commitHash) external view returns (SwapReveal memory) {
        return commitReveals[poolId][commitHash];
    }

    function getBatchCommitHashes(PoolId poolId) external view returns (bytes32[] memory) {
        return batchCommitHashes[poolId];
    }
} 