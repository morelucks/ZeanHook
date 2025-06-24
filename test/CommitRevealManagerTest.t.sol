// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/libraries/CommitRevealManager.sol";

// Dummy implementation to deploy the abstract contract
contract CommitRevealManagerImpl is CommitRevealManager {
    constructor() {
        owner = msg.sender;
    }
}

contract CommitRevealManagerTest is Test {
    CommitRevealManagerImpl manager;
    PoolId constant POOL_ID = PoolId.wrap(bytes32("POOL1"));

    address owner = address(0xABCD);
    address executor = address(0xBEEF);
    address notAuthorized = address(0xDEAD);

    function setUp() public {
        vm.startPrank(owner);
        manager = new CommitRevealManagerImpl();
        vm.stopPrank();

        // Set the executor manually using storage slot manipulation
        bytes32 slot = keccak256(abi.encode(executor, uint256(keccak256("authorizedExecutors"))));
        vm.store(address(manager), slot, bytes32(uint256(1))); 
    }

    function testStartCommitPhase_AsOwner_Works() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CommitRevealManager.CommitPhaseStarted(
            POOL_ID,
            block.timestamp,
            block.timestamp + manager.COMMIT_PHASE_DURATION()
        );

        manager.startCommitPhase(POOL_ID);

        (bool active, uint256 startTime,,) = manager.getCommitPhaseInfo(POOL_ID);
        assertTrue(active);
        assertEq(startTime, block.timestamp);
    }

    function testStartCommitPhase_AsExecutor_Works() public {
        vm.prank(executor);
        manager.startCommitPhase(POOL_ID);

        (bool active,,,) = manager.getCommitPhaseInfo(POOL_ID);
        assertTrue(active);
    }

    function testStartCommitPhase_RevertsIfAlreadyActive() public {
        vm.prank(owner);
        manager.startCommitPhase(POOL_ID);

        vm.expectRevert("Commit phase already active");
        vm.prank(owner);
        manager.startCommitPhase(POOL_ID);
    }

    function testStartCommitPhase_RevertsIfRevealPhaseActive() public {
        // Write directly into batchStates[POOL_ID].revealPhaseActive = true;
        // batchStates is mapping(PoolId => BatchState) with known layout

        // Compute storage slot manually:
        // keccak256(abi.encode(POOL_ID, batchStates.slot)) + offset

        bytes32 base = keccak256(abi.encode(POOL_ID, uint256(0))); 
        uint256 revealPhaseActiveOffset = 8; 

        bytes32 slot = bytes32(uint256(base) + revealPhaseActiveOffset);
        vm.store(address(manager), slot, bytes32(uint256(1))); // true

        vm.expectRevert("Reveal phase active");
        vm.prank(owner);
        manager.startCommitPhase(POOL_ID);
    }

    function testStartCommitPhase_RevertsIfNotAuthorized() public {
        vm.expectRevert("Not authorized executor");
        vm.prank(notAuthorized);
        manager.startCommitPhase(POOL_ID);
    }
}
