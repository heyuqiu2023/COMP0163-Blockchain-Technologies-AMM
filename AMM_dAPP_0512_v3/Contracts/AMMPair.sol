// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

// Import SafeERC20 and interface for ERC20
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// A minimal library for math operations (sqrt) if needed
library Math {
    // Babylonian method for sqrt calculation
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // if y == 0, z remains 0
    }
}

// The AMM Pair contract managing a liquidity pool for a pair of ERC20 tokens.
// It inherits an internal ERC20 implementation to represent liquidity provider (LP) tokens.
contract AMMPair {
    using SafeERC20 for IERC20Metadata;  // Use SafeERC20 for IERC20Metadata which extends IERC20.

    // Token addresses for the pair and the factory address
    address public token0;
    address public token1;
    address public factory;

    // Reserve balances of token0 and token1, stored as uint112 (to fit in 224 bits with block timestamp if needed)
    uint112 private reserve0;
    uint112 private reserve1;
    // We do not track blockTimestampLast or price accumulators for simplicity (not required for basic AMM functionality).

    // Constants for LP token metadata
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint public totalSupply;
    // Mapping of account balances and allowances for the LP token (liquidity token)
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    // Minimum liquidity constant (similar to Uniswap V2) to ensure some liquidity is permanently locked in the pool
    uint public constant MINIMUM_LIQUIDITY = 1000;

    // Events for adding/removing liquidity and swaps, following Uniswap V2 conventions
    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    // Standard ERC20 events
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    // The constructor initializes the pair with the two token addresses and sets the LP token metadata.
    constructor(address _token0, address _token1) {
        require(_token0 != _token1, "IDENTICAL_ADDRESSES");
        token0 = _token0;
        token1 = _token1;
        factory = msg.sender;
        // Set the LP token name and symbol dynamically based on the pair tokens
        string memory symbol0 = IERC20Metadata(_token0).symbol();
        string memory symbol1 = IERC20Metadata(_token1).symbol();
        name = string(abi.encodePacked("LP-", symbol0, "-", symbol1));
        symbol = string(abi.encodePacked("LP-", symbol0, "-", symbol1));
    }

    // Returns the current reserves of the pool (token0, token1).
    function getReserves() external view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    // Internal function to safely update the reserve values to match the actual contract balances.
    function _update(uint balance0, uint balance1) private {
        // Ensure balances fit in uint112
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "OVERFLOW");
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Sync(reserve0, reserve1);
    }

    // Add liquidity to the pool. Transfers in the specified amounts of token0 and token1 from caller.
    // If the pool is initialized (has reserves), it will adjust one of the amounts to maintain the current price ratio and refund any excess to the caller (by not transferring it in).
    // Returns the amount of liquidity (LP tokens) minted.
    function addLiquidity(uint amount0Desired, uint amount1Desired) external returns (uint liquidity) {
        // Use local variables for reserves to save gas
        uint _reserve0 = reserve0;
        uint _reserve1 = reserve1;

        // Determine optimal amounts to deposit to maintain the ratio, if pool is not empty
        uint amount0 = amount0Desired;
        uint amount1 = amount1Desired;
        if (_reserve0 > 0 || _reserve1 > 0) {
            // Calculate the amount1 required to keep the price ratio with amount0, and vice versa
            uint amount1Required = (amount0Desired * _reserve1) / _reserve0;
            uint amount0Required = (amount1Desired * _reserve0) / _reserve1;
            // Adjust amounts to the correct ratio
            if (amount1Required <= amount1Desired) {
                // Too much of token1 provided, use only the required amount1
                amount1 = amount1Required;
            } else {
                // Too much of token0 provided, use only the required amount0
                amount0 = amount0Required;
            }
        }
        // Transfer the calculated amount0 and amount1 from the sender to the pair contract
        IERC20Metadata(token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20Metadata(token1).safeTransferFrom(msg.sender, address(this), amount1);

        // After transfer, get updated balances
        uint balance0 = IERC20Metadata(token0).balanceOf(address(this));
        uint balance1 = IERC20Metadata(token1).balanceOf(address(this));

        // Calculate how many liquidity tokens to mint to the provider
        if (totalSupply == 0) {
            // If first liquidity, use geometric mean of amounts as baseline, and lock minimum liquidity
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
            // Mint the first MINIMUM_LIQUIDITY tokens to address(0) (burned) to lock them permanently in pool
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // For additional liquidity, mint proportional to existing supply
            uint liquidity0 = (amount0 * totalSupply) / _reserve0;
            uint liquidity1 = (amount1 * totalSupply) / _reserve1;
            // The actual liquidity minted is the lesser of liquidity0 and liquidity1
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
            require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        }
        // Mint liquidity tokens to the liquidity provider (msg.sender)
        _mint(msg.sender, liquidity);

        // Update reserves to match new balances
        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    // Remove liquidity from the pool. Burns the specified amount of LP tokens from caller and transfers proportional token0 and token1 amounts to the 'to' address.
    // Returns the amounts of token0 and token1 that were withdrawn.
    function removeLiquidity(uint liquidity, address to) external returns (uint amount0, uint amount1) {
        require(liquidity > 0, "ZERO_LIQUIDITY");
        // Get current balances of tokens in the contract
        uint balance0 = IERC20Metadata(token0).balanceOf(address(this));
        uint balance1 = IERC20Metadata(token1).balanceOf(address(this));
        // Calculate token amounts proportional to liquidity being removed: amount = liquidity / totalSupply * balance
        amount0 = (liquidity * balance0) / totalSupply;
        amount1 = (liquidity * balance1) / totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

        // Burn the LP tokens from the sender
        _burn(msg.sender, liquidity);
        // Transfer tokens to the recipient
        IERC20Metadata(token0).safeTransfer(to, amount0);
        IERC20Metadata(token1).safeTransfer(to, amount1);

        // Get new balances after transfer
        balance0 = IERC20Metadata(token0).balanceOf(address(this));
        balance1 = IERC20Metadata(token1).balanceOf(address(this));
        // Update reserves to new balances
        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // Swap function to swap tokens. The caller specifies the amount of token0 or token1 they want to withdraw (one of amount0Out or amount1Out must be zero).
    // The contract will send the specified output tokens to the 'to' address, and the caller must have sent the input tokens in before calling this function.
    // This function enforces the constant product invariant with a 0.3% fee.
    function swap(uint amount0Out, uint amount1Out, address to) external {
        require(amount0Out > 0 || amount1Out > 0, "OUTPUT_ZERO");
        require(amount0Out == 0 || amount1Out == 0, "OUTPUT_BOTH"); // can't withdraw both tokens simultaneously
        // Save current reserves to local variables
        uint _reserve0 = reserve0;
        uint _reserve1 = reserve1;
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "INSUFFICIENT_LIQUIDITY");

        // Determine which token is being sent out and which is being taken in
        if (amount0Out > 0) {
            // Send token0 out to the recipient
            IERC20Metadata(token0).safeTransfer(to, amount0Out);
        }
        if (amount1Out > 0) {
            // Send token1 out to the recipient
            IERC20Metadata(token1).safeTransfer(to, amount1Out);
        }

        // Compute new balance of token0 and token1 after sending out
        uint balance0 = IERC20Metadata(token0).balanceOf(address(this));
        uint balance1 = IERC20Metadata(token1).balanceOf(address(this));
        // Calculate how much input was actually sent in for each token (should be positive for one token only)
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "INSUFFICIENT_INPUT");

        // Apply a 0.3% fee to the input amounts. The invariant after swap should satisfy:
        // (reserve0 + amount0In)*(reserve1 + amount1In) >= reserve0*reserve1 (constant product)
        // With fee, the effective input considered for the invariant is 0.997 of actual input.
        // We enforce: (reserve0 + amount0In*0.997)*(reserve1 + amount1In*0.997) >= reserve0 * reserve1
        // To avoid fractional math, multiply both sides by 1000:
        uint balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(balance0Adjusted * balance1Adjusted >= uint(_reserve0) * uint(_reserve1) * (1000**2), "INVALID_K");

        // Update reserves after the swap
        _update(balance0, balance1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // Return a quote of how much of the other token is required given an input token and amount, to maintain the current price ratio.
    // This is useful for front-end to calculate the optimal deposit amounts for addLiquidity.
    function quoteAddLiquidity(address token, uint amount) external view returns (uint quoteAmount) {
        require(token == token0 || token == token1, "INVALID_TOKEN");
        if (reserve0 == 0 && reserve1 == 0) {
            // No reserves yet, cannot determine ratio; return the same amount for simplicity (1:1 assumption)
            quoteAmount = amount;
        } else if (token == token0) {
            quoteAmount = (amount * reserve1) / reserve0;
        } else {
            quoteAmount = (amount * reserve0) / reserve1;
        }
    }

    // Return a quote for output amount given an exact input swap of one token.
    // tokenIn is the address of the input token and amountIn is the amount of input token sent.
    // Calculates the amount of the other token that would be received (after the 0.3% fee).
    function quoteSwapExactIn(address tokenIn, uint amountIn) external view returns (uint amountOut) {
        require(tokenIn == token0 || tokenIn == token1, "INVALID_TOKEN");
        require(reserve0 > 0 && reserve1 > 0, "NO_LIQUIDITY");
        // Determine input/output direction
        if (tokenIn == token0) {
            // token0 is input, token1 is output
            uint amountInWithFee = amountIn * 997;
            uint numerator = amountInWithFee * reserve1;
            uint denominator = reserve0 * 1000 + amountInWithFee;
            amountOut = numerator / denominator;
        } else {
            // token1 is input, token0 is output
            uint amountInWithFee = amountIn * 997;
            uint numerator = amountInWithFee * reserve0;
            uint denominator = reserve1 * 1000 + amountInWithFee;
            amountOut = numerator / denominator;
        }
    }

    // --- ERC20 (LP token) functionality ---

    // Internal function to mint LP tokens to an address
    function _mint(address to, uint value) internal {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    // Internal function to burn LP tokens from an address
    function _burn(address from, uint value) internal {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    // Standard ERC20 approve function for LP tokens
    function approve(address spender, uint value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    // Standard ERC20 transfer function for LP tokens
    function transfer(address to, uint value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "BALANCE_TOO_LOW");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    // Standard ERC20 transferFrom function for LP tokens
    function transferFrom(address from, address to, uint value) external returns (bool) {
        require(balanceOf[from] >= value, "BALANCE_TOO_LOW");
        require(allowance[from][msg.sender] >= value, "ALLOWANCE_TOO_LOW");
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}
