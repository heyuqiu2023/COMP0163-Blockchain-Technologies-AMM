// AMMPair.sol
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract AMMPair is ERC20, ReentrancyGuard, Ownable {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint public feeBps = 30;       // 手续费默认0.30% (30/10000)
    address public feeTo;          // 手续费接收地址 (协议所有者)

    constructor(address _tokenA, address _tokenB) ERC20("AMM LP Token", "AMM-LP") {
        require(_tokenA != _tokenB, "Identical tokens");
        // 将 tokenA 和 tokenB 按地址大小排序，确保 token0 < token1
        if (_tokenA < _tokenB) {
            token0 = _tokenA;
            token1 = _tokenB;
        } else {
            token0 = _tokenB;
            token1 = _tokenA;
        }
    }

    // 读取当前储备量
    function getReserves() public view returns (uint112, uint112) {
        return (reserve0, reserve1);
    }

    // 设置手续费接收地址（治理）
    function setFeeTo(address _feeTo) external onlyOwner {
        feeTo = _feeTo;
    }

    // 设置手续费基点数（治理）, 最大不超过1000 (10%)
    function setFeeBps(uint _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "fee too high");
        feeBps = _feeBps;
    }

    // ... （以下为流动性增减和交换函数的实现）
}

function addLiquidity(
    uint amountA, 
    uint amountB, 
    uint minLiquidity, 
    uint deadline
) external nonReentrant returns (uint liquidity) {
    require(block.timestamp <= deadline, "Expired");
    // 获取当前储备
    uint112 _reserve0 = reserve0;
    uint112 _reserve1 = reserve1;
    // 记录添加前的余额，用于计算实际转入量
    uint balance0Before = IERC20(token0).balanceOf(address(this));
    uint balance1Before = IERC20(token1).balanceOf(address(this));
    // 从用户账户转入指定数量的代币到池子
    IERC20(token0).transferFrom(msg.sender, address(this), amountA);
    IERC20(token1).transferFrom(msg.sender, address(this), amountB);
    // 计算实际转入的数量（考虑代币可能有扣费特性）
    uint balance0After = IERC20(token0).balanceOf(address(this));
    uint balance1After = IERC20(token1).balanceOf(address(this));
    uint added0 = balance0After - balance0Before;
    uint added1 = balance1After - balance1Before;
    if (_reserve0 == 0 && _reserve1 == 0) {
        // 初始流动性，按代币乘积开方计算 LP 代币数量
        liquidity = sqrt(added0 * added1);
        require(liquidity > 0, "Insufficient liquidity");
        _mint(msg.sender, liquidity);
        // （可选）铸造最小单位的 LP 代币到地址0锁定，防止移除最后流动性时除零（此处为简化未实现）
    } else {
        // 非初始添加，要求加入的代币比例等于当前储备比例
        require(_reserve0 * added1 == _reserve1 * added0, "Unbalanced liquidity");
        // 按比例计算应增发的 LP 代币数量
        uint totalSupply = totalSupply();
        uint liquidity0 = (added0 * totalSupply) / _reserve0;
        uint liquidity1 = (added1 * totalSupply) / _reserve1;
        liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        require(liquidity > 0, "Insufficient liquidity");
        _mint(msg.sender, liquidity);
    }
    // 滑点保护：确保获得的 LP 不低于预期最小值
    require(liquidity >= minLiquidity, "Slippage: insufficient LP output");
    // 更新储备为最新余额
    reserve0 = uint112(balance0After);
    reserve1 = uint112(balance1After);
}

function sqrt(uint y) internal pure returns (uint z) {
    if (y > 3) {
        z = y;
        uint x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    } else if (y != 0) {
        z = 1;
    }
}

function removeLiquidity(
    uint liquidity, 
    uint minA, 
    uint minB, 
    address to, 
    uint deadline
) external nonReentrant returns (uint amountA, uint amountB) {
    require(block.timestamp <= deadline, "Expired");
    uint _totalSupply = totalSupply();
    require(liquidity > 0 && _totalSupply > 0, "No liquidity");
    // 按比例计算应返回的两种代币数量
    amountA = liquidity * reserve0 / _totalSupply;
    amountB = liquidity * reserve1 / _totalSupply;
    require(amountA >= minA && amountB >= minB, "Slippage: insufficient output");
    // 燃烧 LP 代币
    _burn(msg.sender, liquidity);
    // 更新储备
    reserve0 = uint112(reserve0 - amountA);
    reserve1 = uint112(reserve1 - amountB);
    // 将两种代币发送给指定接收地址
    IERC20(token0).transfer(to, amountA);
    IERC20(token1).transfer(to, amountB);
}

function swapExactIn(
    address tokenIn, 
    uint amountIn, 
    uint minOut, 
    address to, 
    uint deadline
) external nonReentrant returns (uint amountOut) {
    require(block.timestamp <= deadline, "Expired");
    require(tokenIn == token0 || tokenIn == token1, "Invalid token");
    require(to != token0 && to != token1, "Invalid recipient");
    // 确定交换方向
    bool isInput0 = (tokenIn == token0);
    (uint112 _reserve0, uint112 _reserve1) = (reserve0, reserve1);
    require(_reserve0 > 0 && _reserve1 > 0, "Pool is empty");
    address outToken = isInput0 ? token1 : token0;
    uint112 reserveIn = isInput0 ? _reserve0 : _reserve1;
    uint112 reserveOut = isInput0 ? _reserve1 : _reserve0;
    // 记录初始余额
    uint balanceInBefore = IERC20(tokenIn).balanceOf(address(this));
    uint balanceOutBefore = IERC20(outToken).balanceOf(address(this));
    // 从用户转入输入代币
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    // 计算并提取协议手续费（如果设置了 feeTo）
    uint feeAmount = 0;
    if (feeTo != address(0)) {
        feeAmount = (amountIn * feeBps) / 10000;
        if (feeAmount > 0) {
            IERC20(tokenIn).transfer(feeTo, feeAmount);
        }
    }
    // 计算净输入量
    uint netIn = IERC20(tokenIn).balanceOf(address(this)) - balanceInBefore;
    // 根据常数乘积公式计算输出数量
    // amountOut = reserveOut * netIn / (reserveIn + netIn)
    amountOut = (reserveOut * netIn) / (reserveIn + netIn);
    require(amountOut > 0, "No output");
    require(amountOut >= minOut, "Slippage limit");
    // 将输出代币发送给目标地址
    IERC20(outToken).transfer(to, amountOut);
    // 更新储备为最新余额
    uint newBalance0 = IERC20(token0).balanceOf(address(this));
    uint newBalance1 = IERC20(token1).balanceOf(address(this));
    reserve0 = uint112(newBalance0);
    reserve1 = uint112(newBalance1);
}

