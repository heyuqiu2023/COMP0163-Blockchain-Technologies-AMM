// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract AMMPair {
    using SafeERC20 for IERC20Metadata;

    address public immutable token0;
    address public immutable token1;

    // -------- sqrtPrice (S) in Q96 --------
    uint256 internal constant Q96 = 2**96;

    // current sqrtPrice S = sqrt(P) in Q96
    uint160 public sqrtPriceX96;

    // 固定手续费 0.3%
    uint24 public constant FEE_PPM = 3000; // 0.3% = 3000 / 1e6
    uint256 internal constant FEE_DENOM = 1_000_000;

    // ---- position: (owner, lower, upper) -> liquidity ----
    struct Position {
        uint128 liquidity;
    }
    mapping(bytes32 => Position) public positions;

    // （演示简化）当前价格所在区间的“活跃流动性”
    // 在真正 V3 中这是“跨 tick 累加出来的 active liquidity”
    uint128 public liquidity; // active L at current price

    event Mint(address indexed owner, uint160 sqrtA, uint160 sqrtB, uint128 liquidity, uint amount0, uint amount1);
    event Burn(address indexed owner, uint160 sqrtA, uint160 sqrtB, uint128 liquidity, uint amount0, uint amount1);
    event Swap(address indexed sender, address indexed tokenIn, uint amountIn, address indexed to, uint amountOut, uint160 newSqrtPriceX96);

    constructor(address _token0, address _token1, uint160 _sqrtPriceX96) {
        require(_token0 != _token1, "IDENTICAL");
        token0 = _token0;
        token1 = _token1;
        require(_sqrtPriceX96 > 0, "BAD_SQRT");
        sqrtPriceX96 = _sqrtPriceX96;
    }

    // ----------------- helpers (Q96 math) -----------------

    function _key(address owner, uint160 sqrtA, uint160 sqrtB) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, sqrtA, sqrtB));
    }

    function _sort(uint160 a, uint160 b) internal pure returns (uint160, uint160) {
        return a < b ? (a, b) : (b, a);
    }

    // amount0 = L * (sqrtB - sqrtA) / (sqrtA*sqrtB)
    function _amount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 L) internal pure returns (uint256) {
        (sqrtA, sqrtB) = _sort(sqrtA, sqrtB);
        uint256 numerator = uint256(L) * (uint256(sqrtB) - uint256(sqrtA)) * Q96;
        // denominator = sqrtA * sqrtB
        uint256 denom = (uint256(sqrtA) * uint256(sqrtB)) / Q96;
        return numerator / denom;
    }

    // amount1 = L * (sqrtB - sqrtA)
    function _amount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 L) internal pure returns (uint256) {
        (sqrtA, sqrtB) = _sort(sqrtA, sqrtB);
        return (uint256(L) * (uint256(sqrtB) - uint256(sqrtA))) / Q96;
    }

    // liquidity from amount0: L = amount0 * (sqrtA*sqrtB) / (sqrtB - sqrtA)
    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        (sqrtA, sqrtB) = _sort(sqrtA, sqrtB);
        uint256 num = amount0 * (uint256(sqrtA) * uint256(sqrtB) / Q96);
        uint256 den = (uint256(sqrtB) - uint256(sqrtA));
        uint256 L = (num / den);
        require(L <= type(uint128).max, "L_OOB");
        return uint128(L);
    }

    // liquidity from amount1: L = amount1 / (sqrtB - sqrtA)
    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        (sqrtA, sqrtB) = _sort(sqrtA, sqrtB);
        uint256 den = (uint256(sqrtB) - uint256(sqrtA));
        uint256 L = amount1 * Q96 / den;
        require(L <= type(uint128).max, "L_OOB");
        return uint128(L);
    }

    // Core: liquidity for amounts at current price sqrtP, range [sqrtA, sqrtB]
    function _liquidityForAmounts(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal pure returns (uint128 L)
    {
        (sqrtA, sqrtB) = _sort(sqrtA, sqrtB);
        if (sqrtP <= sqrtA) {
            // all token0
            return _liquidityForAmount0(sqrtA, sqrtB, amount0);
        } else if (sqrtP < sqrtB) {
            // both tokens
            uint128 L0 = _liquidityForAmount0(sqrtP, sqrtB, amount0);
            uint128 L1 = _liquidityForAmount1(sqrtA, sqrtP, amount1);
            return L0 < L1 ? L0 : L1;
        } else {
            // all token1
            return _liquidityForAmount1(sqrtA, sqrtB, amount1);
        }
    }

    // ----------------- Mint/Burn (positions) -----------------

    function mintPosition(
        uint160 sqrtA,
        uint160 sqrtB,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint128 L, uint256 amount0, uint256 amount1) {
        require(amount0Desired > 0 || amount1Desired > 0, "ZERO");
        (sqrtA, sqrtB) = _sort(sqrtA, sqrtB);
        require(sqrtA > 0 && sqrtB > sqrtA, "BAD_RANGE");

        uint160 sqrtP = sqrtPriceX96;

        L = _liquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0Desired, amount1Desired);
        require(L > 0, "L=0");

        // Determine actual token amounts required for this L at current price
        if (sqrtP <= sqrtA) {
            amount0 = _amount0ForLiquidity(sqrtA, sqrtB, L);
            amount1 = 0;
        } else if (sqrtP < sqrtB) {
            amount0 = _amount0ForLiquidity(sqrtP, sqrtB, L);
            amount1 = _amount1ForLiquidity(sqrtA, sqrtP, L);
        } else {
            amount0 = 0;
            amount1 = _amount1ForLiquidity(sqrtA, sqrtB, L);
        }

        // pull tokens
        if (amount0 > 0) IERC20Metadata(token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20Metadata(token1).safeTransferFrom(msg.sender, address(this), amount1);

        // record position
        bytes32 k = _key(msg.sender, sqrtA, sqrtB);
        positions[k].liquidity += L;

        // (simplified) update active liquidity if current price inside this range
        if (sqrtP >= sqrtA && sqrtP < sqrtB) {
            liquidity += L;
        }

        emit Mint(msg.sender, sqrtA, sqrtB, L, amount0, amount1);
    }

    function burnPosition(uint160 sqrtA, uint160 sqrtB, uint128 Lburn, address to)
        external returns (uint256 amount0, uint256 amount1)
    {
        (sqrtA, sqrtB) = _sort(sqrtA, sqrtB);
        bytes32 k = _key(msg.sender, sqrtA, sqrtB);
        Position storage p = positions[k];
        require(Lburn > 0 && p.liquidity >= Lburn, "BAD_BURN");
        p.liquidity -= Lburn;

        uint160 sqrtP = sqrtPriceX96;

        // amounts owed at current price for this burned liquidity
        if (sqrtP <= sqrtA) {
            amount0 = _amount0ForLiquidity(sqrtA, sqrtB, Lburn);
            amount1 = 0;
        } else if (sqrtP < sqrtB) {
            amount0 = _amount0ForLiquidity(sqrtP, sqrtB, Lburn);
            amount1 = _amount1ForLiquidity(sqrtA, sqrtP, Lburn);
            // active liquidity decreases
            liquidity -= Lburn;
        } else {
            amount0 = 0;
            amount1 = _amount1ForLiquidity(sqrtA, sqrtB, Lburn);
        }

        if (amount0 > 0) IERC20Metadata(token0).safeTransfer(to, amount0);
        if (amount1 > 0) IERC20Metadata(token1).safeTransfer(to, amount1);

        emit Burn(msg.sender, sqrtA, sqrtB, Lburn, amount0, amount1);
    }

    // ----------------- Swap (demo: within active range only) -----------------
    // tokenIn = token1 => price goes up (S increases): dy = L dS
    // tokenIn = token0 => price goes down (S decreases): dx = L(1/Snew - 1/Sold)
    function swapExactIn(address tokenIn, uint256 amountIn, address to) external returns (uint256 amountOut) {
        require(amountIn > 0, "ZERO_IN");
        require(liquidity > 0, "NO_ACTIVE_L");

        uint256 amountInAfterFee = amountIn * (FEE_DENOM - FEE_PPM) / FEE_DENOM;

        if (tokenIn == token1) {
            // user pays token1, receives token0, S increases
            IERC20Metadata(token1).safeTransferFrom(msg.sender, address(this), amountIn);

            uint160 S0 = sqrtPriceX96;
            // dS = dy / L  => S1 = S0 + dy/L
            uint256 dS = amountInAfterFee * Q96 / uint256(liquidity);
            uint160 S1 = uint160(uint256(S0) + dS);

            // amount0Out = L * (1/S0 - 1/S1)
            // 1/S in Q96 => invS = Q96^2 / S
            uint256 invS0 = (Q96 * Q96) / uint256(S0);
            uint256 invS1 = (Q96 * Q96) / uint256(S1);
            uint256 dx = uint256(liquidity) * (invS0 - invS1) / Q96;
            amountOut = dx;

            IERC20Metadata(token0).safeTransfer(to, amountOut);
            sqrtPriceX96 = S1;

            emit Swap(msg.sender, tokenIn, amountIn, to, amountOut, S1);
        } else if (tokenIn == token0) {
            // user pays token0, receives token1, S decreases
            IERC20Metadata(token0).safeTransferFrom(msg.sender, address(this), amountIn);

            uint160 S0 = sqrtPriceX96;

            // dx = L(1/S1 - 1/S0)  with dx = amountInAfterFee
            // => 1/S1 = 1/S0 + dx/L
            uint256 invS0 = (Q96 * Q96) / uint256(S0);
            uint256 add = amountInAfterFee * Q96 / uint256(liquidity);
            uint256 invS1 = invS0 + add;

            uint160 S1 = uint160((Q96 * Q96) / invS1);

            // amount1Out = L*(S0 - S1)
            uint256 dy = uint256(liquidity) * (uint256(S0) - uint256(S1)) / Q96;
            amountOut = dy;

            IERC20Metadata(token1).safeTransfer(to, amountOut);
            sqrtPriceX96 = S1;

            emit Swap(msg.sender, tokenIn, amountIn, to, amountOut, S1);
        } else {
            revert("BAD_TOKEN_IN");
        }
    }
}
