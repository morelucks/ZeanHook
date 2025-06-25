# ZeanHook

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Foundry-✓-green.svg)](https://getfoundry.sh/)

A sophisticated Uniswap V4 hook that implements MEV protection, volatility-adjusted slippage, and commit-reveal batch execution mechanisms.

## 📖 Overview

ZeanHook is a comprehensive Uniswap V4 hook that provides advanced trading protection and optimization features. It combines multiple sophisticated mechanisms to protect users from MEV attacks while providing efficient batch execution capabilities.

### Key Features

- **🛡️ MEV Protection**: Commit-reveal mechanism to prevent front-running and sandwich attacks
- **📊 Volatility-Adjusted Slippage**: Dynamic slippage calculation based on market volatility
- **⚡ Batch Execution**: Efficient processing of multiple swaps in a single transaction
- **🔐 AVS Integration**: External validation through Active Validation Service
- **📈 Price Tracking**: Real-time price history and volatility metrics
- **🎯 Smart Slippage**: Minimum and maximum slippage bounds with volatility adjustment

## 🏗️ Architecture

ZeanHook is built using a modular architecture with three main components:

### Core Components

1. **ZeanHook.sol** - Main hook contract that orchestrates all functionality
2. **VolatilityManager.sol** - Handles price tracking and volatility calculations
3. **BatchManager.sol** - Manages swap queuing and batch execution
4. **CommitRevealManager.sol** - Implements commit-reveal mechanism for MEV protection

### Hook Permissions

The hook implements the following Uniswap V4 hook points:

- ✅ `afterInitialize` - Records initial pool price and sets up volatility tracking
- ✅ `beforeSwap` - Validates swaps, calculates slippage, and queues for batch processing
- ✅ `afterSwap` - Records price changes and updates volatility metrics
- ❌ `beforeInitialize` - Not implemented
- ❌ Liquidity operations - Not implemented
- ❌ Donate operations - Not implemented

## 🚀 Installation

### Prerequisites

- [Foundry](https://getfoundry.sh/) (latest version)
- Node.js 18+ (for optional tooling)

### Setup

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd ZeanHook
   ```

2. **Install dependencies**
   ```bash
   forge install
   ```

3. **Build the project**
   ```bash
   forge build
   ```

## 🔧 Configuration

### Environment Variables

Create a `.env` file with the following variables:

```env
# Network Configuration
RPC_URL=your_rpc_url
PRIVATE_KEY=your_private_key

# Contract Addresses
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
AVS_ADDRESS=0xa789c91ECDdae96865913130B786140Ee17aF545
```

### Constants

The hook uses several configurable constants:

```solidity
MIN_SLIPPAGE = 10        // 0.1% minimum slippage
MAX_SLIPPAGE = 500       // 5% maximum slippage
BATCH_INTERVAL = 180     // 3 minutes batch interval
MAX_BATCH_SIZE = 100     // Maximum swaps per batch
VOLATILITY_WINDOW = 24 hours  // Price history window
COMMIT_PHASE_DURATION = 60    // 1 minute commit phase
REVEAL_PHASE_DURATION = 120   // 2 minutes reveal phase
```

## 📋 Usage

### Deployment

1. **Deploy using Foundry script**
   ```bash
   forge script script/DeployZeanHook.s.sol --rpc-url $RPC_URL --broadcast
   ```

2. **Verify deployment**
   ```bash
   forge verify-contract <deployed_address> src/ZeanHook.sol:ZeanHook \
     --constructor-args $(cast abi-encode "constructor(address,address)" $POOL_MANAGER $AVS_ADDRESS)
   ```

### Basic Usage

#### 1. Queue a Swap

```solidity
// Prepare swap parameters
SwapParams memory params = SwapParams({
    zeroForOne: true,
    amountSpecified: -1e18,  // Negative for exact input
    sqrtPriceLimitX96: 0
});

// Queue the swap
hook.queueSwap(
    poolKey,
    params,
    0,              // minAmountOut
    0,              // maxSqrtPriceX96
    0,              // minSqrtPriceX96
    ""              // hookData
);
```

#### 2. Commit-Reveal Process

```solidity
// Start commit phase
hook.startCommitPhase(poolId);

// Generate and commit swap
bytes32 commitHash = hook.generateCommitHash(
    user,
    params,
    minAmountOut,
    maxSqrtPriceX96,
    minSqrtPriceX96,
    hookData,
    nonce,
    salt
);
hook.commitSwap(poolId, commitHash);

// Start reveal phase
hook.startRevealPhase(poolId);

// Reveal the swap
hook.revealSwap(
    poolId,
    commitIndex,
    params,
    minAmountOut,
    maxSqrtPriceX96,
    minSqrtPriceX96,
    hookData,
    nonce,
    salt
);

// Execute batch after reveal phase ends
hook.executeBatchAfterReveal(poolKey, avsProof);
```

#### 3. Emergency Batch Execution

```solidity
// Execute all queued swaps immediately
hook.emergencyExecuteBatch(poolKey, avsProof);
```

### View Functions

#### Get Volatility Metrics
```solidity
VolatilityMetrics memory metrics = hook.getVolatilityMetrics(poolId);
uint256 recommendedSlippage = hook.getRecommendedSlippage(poolId);
```

#### Get Price History
```solidity
PriceData[] memory history = hook.getPriceHistory(poolId, 10); // Last 10 entries
```

#### Get Batch State
```solidity
BatchState memory state = hook.getBatchState(poolId);
```

## 🧪 Testing

### Run All Tests
```bash
forge test
```

### Run Specific Test File
```bash
forge test --match-contract ZeanHookTest
```

### Run with Verbose Output
```bash
forge test -vvv
```

### Gas Testing
```bash
forge test --gas-report
```

### Test Coverage
```bash
forge coverage
```

### Key Test Categories

1. **Hook Permissions** - Verifies correct hook point implementation
2. **Volatility Management** - Tests price tracking and slippage calculation
3. **Batch Management** - Tests swap queuing and execution
4. **Commit-Reveal** - Tests MEV protection mechanisms
5. **Access Control** - Tests ownership and authorization
6. **Edge Cases** - Tests boundary conditions and error handling

## 🔒 Security Features

### MEV Protection
- **Commit-Reveal Mechanism**: Users commit to swaps without revealing details
- **Batch Execution**: Multiple swaps executed atomically to prevent front-running
- **Time Delays**: Minimum commit delays prevent rapid manipulation

### Slippage Protection
- **Volatility-Adjusted Slippage**: Dynamic slippage based on market conditions
- **Bounds Checking**: Minimum and maximum slippage limits
- **Price Deviation Monitoring**: Tracks price movements to detect manipulation

### Access Control
- **Owner-Only Functions**: Critical operations restricted to owner
- **Executor Authorization**: Delegated execution with proper permissions
- **AVS Integration**: External validation for sensitive operations

## 📊 Events

The hook emits several events for monitoring and integration:

```solidity
event SwapQueued(PoolId indexed poolId, address indexed user, uint256 batchIndex, uint256 queueTime);
event BatchExecuted(PoolId indexed poolId, uint256 swapsExecuted, uint160 executionPrice, uint256 timestamp);
event SwapCommitted(PoolId indexed poolId, address indexed user, bytes32 indexed commitHash, uint256 commitTime);
event SwapRevealed(PoolId indexed poolId, address indexed user, bytes32 indexed commitHash, uint256 revealTime);
event PriceRecorded(PoolId indexed poolId, uint160 sqrtPriceX96, uint256 timestamp);
event SlippageCalculated(PoolId indexed poolId, uint256 volatility, uint256 adjustedSlippage, uint256 timestamp);
event ExecutorAuthorized(address indexed executor, bool authorized);
```

## 🔧 Development

### Project Structure
```
ZeanHook/
├── src/
│   ├── ZeanHook.sol              # Main hook contract
│   ├── interfaces/
│   │   └── IZeanHook.sol         # Hook interface
│   └── libraries/
│       ├── VolatilityManager.sol # Price tracking & volatility
│       ├── BatchManager.sol      # Swap batching
│       ├── CommitRevealManager.sol # MEV protection
│       └── ZeanHookStorage.sol   # Storage layout
├── test/
│   ├── ZeanHook.t.sol            # Unit tests
│   ├── ZeanHookTest.t.sol        # Integration tests
│   └── mocks/                    # Mock contracts
├── script/
│   └── DeployZeanHook.s.sol      # Deployment script
└── foundry.toml                  # Foundry configuration
```

### Adding New Features

1. **Extend Storage**: Add new state variables to `ZeanHookStorage.sol`
2. **Implement Logic**: Add functions to appropriate manager contracts
3. **Update Interface**: Add function signatures to `IZeanHook.sol`
4. **Add Tests**: Create comprehensive test coverage
5. **Update Documentation**: Document new functionality

### Code Style

- Follow Solidity style guide
- Use NatSpec documentation
- Implement comprehensive error handling
- Add events for important state changes
- Include gas optimization considerations

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines

- Write comprehensive tests for all new functionality
- Follow existing code patterns and conventions
- Update documentation for any API changes
- Ensure all tests pass before submitting PR
- Include gas optimization analysis for new features

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This software is provided "as is" without warranty of any kind. Use at your own risk. The authors are not responsible for any financial losses incurred through the use of this software.

## 🔗 Links

- [Uniswap V4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [Foundry Documentation](https://book.getfoundry.sh/)
- [Solidity Documentation](https://docs.soliditylang.org/)

## 📞 Support

For questions, issues, or contributions:

- Open an issue on GitHub
- Join our community discussions
- Review the test files for usage examples

---

**Built with ❤️ for the Uniswap V4 ecosystem**