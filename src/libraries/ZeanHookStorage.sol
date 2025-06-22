// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

contract ZeanHookStorage {
    // ========================= Constants =========================
    uint256 public constant MIN_SLIPPAGE = 10;
    uint256 public constant MAX_SLIPPAGE = 500;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant BATCH_INTERVAL = 180;
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant PRICE_DEVIATION_THRESHOLD = 50;
    uint256 public constant VOLATILITY_WINDOW = 24 hours;
    uint256 public constant MIN_SAMPLES = 5;
    uint256 public constant VOLATILITY_MULTIPLIER = 100;
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

    // ========================= Storage =========================
    mapping(PoolId => PriceData[]) public priceHistory;
    mapping(PoolId => VolatilityMetrics) public volatilityMetrics;
    mapping(PoolId => uint256) public lastSwapTimestamp;
    mapping(PoolId => BatchedSwap[]) public poolBatches;
    mapping(PoolId => BatchState) public batchStates;
    mapping(PoolId => mapping(address => uint256)) public userPendingSwaps;
    mapping(address => bool) public authorizedExecutors;
    mapping(PoolId => mapping(address => SwapCommit[])) public userCommits;
    mapping(PoolId => mapping(bytes32 => SwapReveal)) public commitReveals;
    mapping(PoolId => bytes32[]) public batchCommitHashes;
    mapping(PoolId => mapping(address => uint256)) public userCommitCounts;

    address public owner;
    bool internal _executing;
} 