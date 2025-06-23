// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract ZeanHookStorageBase {
    address public owner;
    mapping(address => bool) public authorizedExecutors;
    
    uint256 public COMMIT_PHASE_DURATION;
    uint256 public REVEAL_PHASE_DURATION;
    uint256 public MIN_COMMIT_DELAY;
    
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
    
    struct BatchState {
        bool commitPhaseActive;
        bool revealPhaseActive;
        uint256 commitPhaseStart;
        uint256 revealPhaseStart;
        uint256 batchStartTime;
    }
    
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
    
    mapping(PoolId => BatchState) public batchStates;
    mapping(PoolId => mapping(address => SwapCommit[])) public userCommits;
    mapping(PoolId => mapping(address => uint256)) public userCommitCounts;
    mapping(PoolId => mapping(bytes32 => SwapReveal)) public commitReveals;
    mapping(PoolId => bytes32[]) public batchCommitHashes;
    mapping(PoolId => BatchedSwap[]) public poolBatches;
    mapping(PoolId => mapping(address => uint256)) public userPendingSwaps;
}

contract MockCommitRevealManager is ZeanHookStorageBase {
    // Events from original contract
    event SwapCommitted(
        PoolId indexed poolId,
        address indexed user,
        bytes32 indexed commitHash,
        uint256 commitTime
    );

    constructor() {
        owner = msg.sender;
        COMMIT_PHASE_DURATION = 300; // 5 minutes
        REVEAL_PHASE_DURATION = 300; // 5 minutes
        MIN_COMMIT_DELAY = 60; // 1 minute
    }

    // Modifiers from original contract
    modifier onlyDuringCommitPhase(PoolId poolId) {
        require(batchStates[poolId].commitPhaseActive, "Not in commit phase");
        require(
            block.timestamp < batchStates[poolId].commitPhaseStart + COMMIT_PHASE_DURATION,
            "Commit phase ended"
        );
        _;
    }

    // this is the function I test, just for the commitSwap
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

    // View functions from original contract
    function getUserCommitCount(PoolId poolId, address user) external view returns (uint256) {
        return userCommitCounts[poolId][user];
    }

    function getUserCommits(PoolId poolId, address user) external view returns (SwapCommit[] memory) {
        return userCommits[poolId][user];
    }

    function getBatchCommitHashes(PoolId poolId) external view returns (bytes32[] memory) {
        return batchCommitHashes[poolId];
    }

    // Test helper functions
    function setBatchState(PoolId poolId, bool commitActive, uint256 startTime) external {
        batchStates[poolId].commitPhaseActive = commitActive;
        batchStates[poolId].commitPhaseStart = startTime;
    }

    function getBatchCommitHashesLength(PoolId poolId) external view returns (uint256) {
        return batchCommitHashes[poolId].length;
    }

    function getUserCommitsLength(PoolId poolId, address user) external view returns (uint256) {
        return userCommits[poolId][user].length;
    }
}

contract CommitSwapTest is Test {
    MockCommitRevealManager public manager;
    PoolId public poolId;
    PoolKey public poolKey;
    
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    
    bytes32 public validCommitHash = keccak256("valid_commit");
    bytes32 public anotherValidCommitHash = keccak256("another_valid_commit");

    event SwapCommitted(
        PoolId indexed poolId,
        address indexed user,
        bytes32 indexed commitHash,
        uint256 commitTime
    );

    function setUp() public {
        manager = new MockCommitRevealManager();
        
        // Create a mock pool ID and key
        poolId = PoolId.wrap(keccak256("test_pool"));
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(manager))
        });
    }

    // ========================= Success Cases =========================

    function test_commitSwap_Success() public {
        // Setup: Start commit phase
        manager.setBatchState(poolId, true, block.timestamp);
        
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit SwapCommitted(poolId, user1, validCommitHash, block.timestamp);
        
        manager.commitSwap(poolId, validCommitHash);
        
        // Verify state changes
        assertEq(manager.getUserCommitCount(poolId, user1), 1);
        assertEq(manager.getUserCommitsLength(poolId, user1), 1);
        assertEq(manager.getBatchCommitHashesLength(poolId), 1);
        
        // Verify commit details
        MockCommitRevealManager.SwapCommit[] memory commits = manager.getUserCommits(poolId, user1);
        assertEq(commits[0].commitHash, validCommitHash);
        assertEq(commits[0].commitTime, block.timestamp);
        assertFalse(commits[0].revealed);
        assertFalse(commits[0].executed);
        
        // Verify batch commit hashes
        bytes32[] memory batchHashes = manager.getBatchCommitHashes(poolId);
        assertEq(batchHashes[0], validCommitHash);
    }

    function test_commitSwap_MultipleCommitsFromSameUser() public {
        // Setup: Start commit phase
        manager.setBatchState(poolId, true, block.timestamp);
        
        vm.startPrank(user1);
        
        // First commit
        vm.expectEmit(true, true, true, true);
        emit SwapCommitted(poolId, user1, validCommitHash, block.timestamp);
        manager.commitSwap(poolId, validCommitHash);
        
        // Second commit
        vm.expectEmit(true, true, true, true);
        emit SwapCommitted(poolId, user1, anotherValidCommitHash, block.timestamp);
        manager.commitSwap(poolId, anotherValidCommitHash);
        
        vm.stopPrank();
        
        // Verify state
        assertEq(manager.getUserCommitCount(poolId, user1), 2);
        assertEq(manager.getUserCommitsLength(poolId, user1), 2);
        assertEq(manager.getBatchCommitHashesLength(poolId), 2);
        
        // Verify both commits
        MockCommitRevealManager.SwapCommit[] memory commits = manager.getUserCommits(poolId, user1);
        assertEq(commits[0].commitHash, validCommitHash);
        assertEq(commits[1].commitHash, anotherValidCommitHash);
    }

    function test_commitSwap_MultipleUsersCommitting() public {
        // Setup: Start commit phase
        manager.setBatchState(poolId, true, block.timestamp);
        
        // User1 commits
        vm.prank(user1);
        manager.commitSwap(poolId, validCommitHash);
        
        // User2 commits
        vm.prank(user2);
        manager.commitSwap(poolId, anotherValidCommitHash);
        
        // Verify individual user states
        assertEq(manager.getUserCommitCount(poolId, user1), 1);
        assertEq(manager.getUserCommitCount(poolId, user2), 1);
        
        // Verify batch state
        assertEq(manager.getBatchCommitHashesLength(poolId), 2);
        
        bytes32[] memory batchHashes = manager.getBatchCommitHashes(poolId);
        assertEq(batchHashes[0], validCommitHash);
        assertEq(batchHashes[1], anotherValidCommitHash);
    }

    function test_commitSwap_AtCommitPhaseEnd() public {
        uint256 startTime = block.timestamp;
        manager.setBatchState(poolId, true, startTime);
        
        // Move to just before commit phase ends (COMMIT_PHASE_DURATION = 300)
        vm.warp(startTime + 299);
        
        vm.prank(user1);
        manager.commitSwap(poolId, validCommitHash);
        
        assertEq(manager.getUserCommitCount(poolId, user1), 1);
    }

    // ========================= Failure Cases =========================

    function test_commitSwap_RevertWhen_NotInCommitPhase() public {
        // Don't start commit phase
        vm.prank(user1);
        vm.expectRevert("Not in commit phase");
        manager.commitSwap(poolId, validCommitHash);
    }

    function test_commitSwap_RevertWhen_CommitPhaseEnded() public {
        uint256 startTime = block.timestamp;
        manager.setBatchState(poolId, true, startTime);
        
        // Move past commit phase end (COMMIT_PHASE_DURATION = 300)
        vm.warp(startTime + 301);
        
        vm.prank(user1);
        vm.expectRevert("Commit phase ended");
        manager.commitSwap(poolId, validCommitHash);
    }

    function test_commitSwap_RevertWhen_InvalidCommitHash() public {
        manager.setBatchState(poolId, true, block.timestamp);
        
        vm.prank(user1);
        vm.expectRevert("Invalid commit hash");
        manager.commitSwap(poolId, bytes32(0));
    }

    // ========================= Edge Cases =========================

    function test_commitSwap_SameHashFromDifferentUsers() public {
        manager.setBatchState(poolId, true, block.timestamp);
        
        // Both users commit the same hash (should be allowed)
        vm.prank(user1);
        manager.commitSwap(poolId, validCommitHash);
        
        vm.prank(user2);
        manager.commitSwap(poolId, validCommitHash);
        
        // Both should have the commit
        assertEq(manager.getUserCommitCount(poolId, user1), 1);
        assertEq(manager.getUserCommitCount(poolId, user2), 1);
        assertEq(manager.getBatchCommitHashesLength(poolId), 2);
    }

    function test_commitSwap_SameUserCommitsSameHashTwice() public {
        manager.setBatchState(poolId, true, block.timestamp);
        
        vm.startPrank(user1);
        
        // First commit
        manager.commitSwap(poolId, validCommitHash);
        
        // Second commit with same hash (should be allowed)
        manager.commitSwap(poolId, validCommitHash);
        
        vm.stopPrank();
        
        // Should have 2 commits
        assertEq(manager.getUserCommitCount(poolId, user1), 2);
        assertEq(manager.getBatchCommitHashesLength(poolId), 2);
        
        MockCommitRevealManager.SwapCommit[] memory commits = manager.getUserCommits(poolId, user1);
        assertEq(commits[0].commitHash, validCommitHash);
        assertEq(commits[1].commitHash, validCommitHash);
    }

    function test_commitSwap_DifferentPoolIds() public {
        PoolId poolId2 = PoolId.wrap(keccak256("test_pool_2"));
        
        // Start commit phase for both pools
        manager.setBatchState(poolId, true, block.timestamp);
        manager.setBatchState(poolId2, true, block.timestamp);
        
        vm.startPrank(user1);
        
        // Commit to first pool
        manager.commitSwap(poolId, validCommitHash);
        
        // Commit to second pool
        manager.commitSwap(poolId2, anotherValidCommitHash);
        
        vm.stopPrank();
        
        // Verify commits are separate per pool
        assertEq(manager.getUserCommitCount(poolId, user1), 1);
        assertEq(manager.getUserCommitCount(poolId2, user1), 1);
        assertEq(manager.getBatchCommitHashesLength(poolId), 1);
        assertEq(manager.getBatchCommitHashesLength(poolId2), 1);
    }

    // ========================= Gas Tests =========================

    function test_commitSwap_Gas() public {
        manager.setBatchState(poolId, true, block.timestamp);
        
        vm.prank(user1);
        uint256 gasBefore = gasleft();
        manager.commitSwap(poolId, validCommitHash);
        uint256 gasUsed = gasBefore - gasleft();
        
        // Gas usage should be reasonable (adjust based on expected usage)
        assertLt(gasUsed, 100000, "Gas usage too high");
    }

    // ========================= Fuzz Tests =========================

    function testFuzz_commitSwap_ValidHashes(bytes32 commitHash) public {
        vm.assume(commitHash != bytes32(0)); // Skip zero hash
        
        manager.setBatchState(poolId, true, block.timestamp);
        
        vm.prank(user1);
        manager.commitSwap(poolId, commitHash);
        
        assertEq(manager.getUserCommitCount(poolId, user1), 1);
        
        MockCommitRevealManager.SwapCommit[] memory commits = manager.getUserCommits(poolId, user1);
        assertEq(commits[0].commitHash, commitHash);
    }

    function testFuzz_commitSwap_MultipleUsers(address user, bytes32 commitHash) public {
        vm.assume(user != address(0));
        vm.assume(commitHash != bytes32(0));
        
        manager.setBatchState(poolId, true, block.timestamp);
        
        vm.prank(user);
        manager.commitSwap(poolId, commitHash);
        
        assertEq(manager.getUserCommitCount(poolId, user), 1);
    }

    function testFuzz_commitSwap_TimingEdgeCases(uint256 timeOffset) public {
        vm.assume(timeOffset < 300); // Within commit phase duration
        
        uint256 startTime = block.timestamp;
        manager.setBatchState(poolId, true, startTime);
        
        vm.warp(startTime + timeOffset);
        
        vm.prank(user1);
        manager.commitSwap(poolId, validCommitHash);
        
        assertEq(manager.getUserCommitCount(poolId, user1), 1);
    }
}