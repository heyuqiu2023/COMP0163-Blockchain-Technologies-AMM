// Factory contract for AMM Pairs. Allows creation of new AMM pools for token pairs.
pragma solidity ^0.8.18;

import "./AMMPair.sol";

contract AMMFactory {
    // Event emitted when a new pair is created
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    // Mapping to store pair address by token combination (token0 => token1 => pair address)
    mapping(address => mapping(address => address)) public getPair;
    // Array of all pair addresses
    address[] public allPairs;

    address public feeTo;         // Address to which fees can be sent (if protocol fee is turned on)
    address public feeToSetter;   // Address that is allowed to change feeTo

    constructor() {
        feeToSetter = msg.sender;
    }

    // Function to return number of pairs created
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    // Create a new AMM pair for the two given tokens. 
    // This will deploy a new AMMPair contract and register it, if a pair for the tokens does not already exist.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL_ADDRESSES");
        // Sort token addresses to ensure token0 < token1 (address comparison) to avoid duplicate pairs in reverse order
        address token0 = tokenA < tokenB ? tokenA : tokenB;
        address token1 = tokenA < tokenB ? tokenB : tokenA;
        require(token0 != address(0), "ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "PAIR_EXISTS");
        // Deploy new AMMPair contract
        AMMPair newPair = new AMMPair(token0, token1);
        pair = address(newPair);
        // Store the pair address in mappings for both token orders
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // Set the address that will receive protocol fees (if implemented in future).
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        feeTo = _feeTo;
    }

    // Change the feeToSetter to a new address (transfer admin rights).
    function setFeeToSetter(address _newSetter) external {
        require(msg.sender == feeToSetter, "FORBIDDEN");
        feeToSetter = _newSetter;
    }
}
