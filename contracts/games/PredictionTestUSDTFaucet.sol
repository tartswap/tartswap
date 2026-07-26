// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMintableTestUSDT {
    function mint(address account, uint256 amount) external;
}

contract PredictionTestUSDTFaucet {
    IMintableTestUSDT public immutable token;
    address public owner;
    uint256 public claimAmount;
    uint256 public cooldown;

    mapping(address account => uint256 lastClaimedAt) public lastClaimedAt;

    event Claimed(address indexed account, uint256 amount);
    event ClaimAmountUpdated(uint256 amount);
    event CooldownUpdated(uint256 cooldown);
    event OwnerTransferred(address indexed previousOwner, address indexed nextOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address token_, uint256 claimAmount_, uint256 cooldown_) {
        require(token_ != address(0), "Token required");
        token = IMintableTestUSDT(token_);
        owner = msg.sender;
        claimAmount = claimAmount_;
        cooldown = cooldown_;
    }

    function claim() external {
        uint256 lastClaim = lastClaimedAt[msg.sender];
        require(lastClaim == 0 || block.timestamp >= lastClaim + cooldown, "Faucet cooldown");
        lastClaimedAt[msg.sender] = block.timestamp;
        token.mint(msg.sender, claimAmount);
        emit Claimed(msg.sender, claimAmount);
    }

    function setClaimAmount(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount required");
        claimAmount = amount;
        emit ClaimAmountUpdated(amount);
    }

    function setCooldown(uint256 cooldown_) external onlyOwner {
        cooldown = cooldown_;
        emit CooldownUpdated(cooldown_);
    }

    function transferOwnership(address nextOwner) external onlyOwner {
        require(nextOwner != address(0), "Owner required");
        emit OwnerTransferred(owner, nextOwner);
        owner = nextOwner;
    }
}
