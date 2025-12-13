// SPDX-License-Identifier: MIT
// A minimal ERC20 token implementation for testing the AMM system.
pragma solidity ^0.8.18;

contract MinimalERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint public totalSupply;
    address public owner;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    // Events as per ERC20 standard
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);

    // Constructor sets the token's metadata and mints an initial supply to the deployer (owner).
    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint _initialSupply) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        owner = msg.sender;
        if (_initialSupply > 0) {
            totalSupply = _initialSupply;
            balanceOf[msg.sender] = _initialSupply;
            emit Transfer(address(0), msg.sender, _initialSupply);
        }
    }

    // Transfer tokens to a specified address.
    function transfer(address to, uint value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "BALANCE_TOO_LOW");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    // Approve an address to spend the specified amount of tokens on behalf of msg.sender.
    function approve(address spender, uint value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    // Transfer tokens from one address to another, using an allowance.
    function transferFrom(address from, address to, uint value) external returns (bool) {
        require(balanceOf[from] >= value, "BALANCE_TOO_LOW");
        require(allowance[from][msg.sender] >= value, "ALLOWANCE_TOO_LOW");
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    // Mint new tokens to a specified address. Only the contract owner can call this.
    function mint(address to, uint value) external {
        require(msg.sender == owner, "NOT_OWNER");
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }
}
