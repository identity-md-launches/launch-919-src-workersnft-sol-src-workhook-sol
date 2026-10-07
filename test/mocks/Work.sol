// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev TEST ONLY. Stand-in for the launch token that IMD deploys; never part of a deployment.
contract Work {
    string public constant name = "Work";
    string public constant symbol = "WORK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply = 1_000_000_000 ether;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    error InvalidTransfer();

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidTransfer();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @notice Atomic initial allocation by the supply holder; never spends another account's funds.
    function distributeLaunch(address swarm, address pool) external {
        if (swarm == address(0) || pool == address(0)) revert InvalidTransfer();
        _transfer(msg.sender, swarm, 100_000_000 ether);
        _transfer(msg.sender, pool, 700_000_000 ether);
        _transfer(msg.sender, 0xc9EAFE33A510a3a3d95A94c4f85AdaF6a3EA12a0, 200_000_000 ether);
    }
}
