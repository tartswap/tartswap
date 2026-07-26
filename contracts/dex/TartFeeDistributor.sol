// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TartFeeDistributor
 * @notice Receives TartSwap protocol fees and splits them between treasury,
 * farm rewards, staking rewards and reserve/buyback wallets.
 * @dev This contract does not custody user principal. It only holds protocol fees
 * until anyone calls distributeToken/distributeNative.
 */
contract TartFeeDistributor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct SplitConfig {
        address treasury;
        address farmRewards;
        address stakingRewards;
        address reserve;
        uint16 treasuryBps;
        uint16 farmBps;
        uint16 stakingBps;
        uint16 reserveBps;
    }

    SplitConfig public split;

    // Pull-payment ledger: if a split leg fails (a recipient rejects the transfer, or a
    // token transfer reverts/returns false), the amount is credited here instead of
    // reverting the WHOLE distribution. The recipient later pulls it via claimNative/claimToken.
    mapping(address => uint256) public owedNative;
    mapping(address => mapping(address => uint256)) public owedToken; // token => recipient => amount
    uint256 public totalOwedNative;
    mapping(address => uint256) public totalOwedToken; // token => total reserved for pull-payments

    event SplitUpdated(
        address indexed treasury,
        address indexed farmRewards,
        address indexed stakingRewards,
        address reserve,
        uint16 treasuryBps,
        uint16 farmBps,
        uint16 stakingBps,
        uint16 reserveBps
    );
    event TokenDistributed(address indexed token, uint256 amount, uint256 treasuryAmount, uint256 farmAmount, uint256 stakingAmount, uint256 reserveAmount);
    event NativeDistributed(uint256 amount, uint256 treasuryAmount, uint256 farmAmount, uint256 stakingAmount, uint256 reserveAmount);
    event FeesDistributed(address indexed token, uint256 amount, uint256 treasuryAmount, uint256 farmAmount, uint256 stakingAmount, uint256 reserveAmount);
    event NativeOwed(address indexed recipient, uint256 amount);
    event TokenOwed(address indexed token, address indexed recipient, uint256 amount);
    event NativeClaimed(address indexed recipient, uint256 amount);
    event TokenClaimed(address indexed token, address indexed recipient, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event NativeOwedRedirected(address indexed from, address indexed to, uint256 amount);
    event TokenOwedRedirected(address indexed token, address indexed from, address indexed to, uint256 amount);

    constructor(
        address initialOwner,
        address treasury_,
        address farmRewards_,
        address stakingRewards_,
        address reserve_
    ) Ownable(initialOwner) {
        _setSplit(treasury_, farmRewards_, stakingRewards_, reserve_, 4000, 3000, 2000, 1000);
    }

    receive() external payable {}

    function setSplit(
        address treasury_,
        address farmRewards_,
        address stakingRewards_,
        address reserve_,
        uint16 treasuryBps_,
        uint16 farmBps_,
        uint16 stakingBps_,
        uint16 reserveBps_
    ) external onlyOwner {
        _setSplit(treasury_, farmRewards_, stakingRewards_, reserve_, treasuryBps_, farmBps_, stakingBps_, reserveBps_);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function distributeToken(address token) external nonReentrant whenNotPaused {
        // Only distribute the balance that is NOT already reserved for a pending pull-payment.
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = totalOwedToken[token];
        uint256 amount = balance > reserved ? balance - reserved : 0;
        require(amount > 0, "No token fees");
        (uint256 t, uint256 f, uint256 s, uint256 r) = _splitAmounts(amount);
        _sendOrOweToken(token, split.treasury, t);
        _sendOrOweToken(token, split.farmRewards, f);
        _sendOrOweToken(token, split.stakingRewards, s);
        _sendOrOweToken(token, split.reserve, r);
        emit TokenDistributed(token, amount, t, f, s, r);
        emit FeesDistributed(token, amount, t, f, s, r);
    }

    function distributeNative() external nonReentrant whenNotPaused {
        // Only distribute the balance that is NOT already reserved for a pending pull-payment.
        uint256 balance = address(this).balance;
        uint256 amount = balance > totalOwedNative ? balance - totalOwedNative : 0;
        require(amount > 0, "No native fees");
        (uint256 t, uint256 f, uint256 s, uint256 r) = _splitAmounts(amount);
        _sendOrOweNative(split.treasury, t);
        _sendOrOweNative(split.farmRewards, f);
        _sendOrOweNative(split.stakingRewards, s);
        _sendOrOweNative(split.reserve, r);
        emit NativeDistributed(amount, t, f, s, r);
        emit FeesDistributed(address(0), amount, t, f, s, r);
    }

    /// @notice A recipient pulls native fees that could not be pushed during distribution.
    function claimNative() external nonReentrant {
        uint256 amount = owedNative[msg.sender];
        require(amount > 0, "Nothing owed");
        owedNative[msg.sender] = 0;
        totalOwedNative -= amount;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Native transfer failed");
        emit NativeClaimed(msg.sender, amount);
    }

    /// @notice A recipient pulls token fees that could not be pushed during distribution.
    function claimToken(address token) external nonReentrant {
        uint256 amount = owedToken[token][msg.sender];
        require(amount > 0, "Nothing owed");
        owedToken[token][msg.sender] = 0;
        totalOwedToken[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenClaimed(token, msg.sender, amount);
    }

    /// @notice Rescues only the native balance in excess of what is reserved for pull-payments.
    function rescueNative(address to) external onlyOwner nonReentrant {
        require(to != address(0), "Zero receiver");
        uint256 balance = address(this).balance;
        uint256 excess = balance > totalOwedNative ? balance - totalOwedNative : 0;
        require(excess > 0, "No excess");
        (bool ok, ) = payable(to).call{value: excess}("");
        require(ok, "Native transfer failed");
        emit NativeRescued(to, excess);
    }

    /// @notice Rescues token balance in excess of what is reserved for pull-payments.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Zero receiver");
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = totalOwedToken[token];
        require(balance >= reserved && balance - reserved >= amount, "Exceeds excess");
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @notice Owner escape hatch for a STRANDED owed-native entry. If a split leg was
    ///         booked to a recipient that can neither receive BNB nor call claimNative
    ///         (e.g. a contract with no receive()/fallback), its owed balance would be
    ///         locked forever — rescueNative excludes reserved amounts, and only the
    ///         recipient itself can claim. This reassigns the full owed amount to a
    ///         payable/claimable address. Conservation-preserving: totalOwedNative is
    ///         unchanged, so it can never mint or destroy reserved funds — the receiver
    ///         then pulls via claimNative().
    function redirectOwedNative(address from, address to) external onlyOwner {
        require(to != address(0), "Zero receiver");
        require(from != to, "Same recipient");
        uint256 amount = owedNative[from];
        require(amount > 0, "Nothing owed");
        owedNative[from] = 0;
        owedNative[to] += amount;
        emit NativeOwedRedirected(from, to, amount);
    }

    /// @notice Owner escape hatch for a STRANDED owed-token entry (a recipient that can't
    ///         call claimToken, or that the token blacklists). Reassigns the full owed
    ///         amount to a claimable address. Conservation-preserving: totalOwedToken is
    ///         unchanged; the receiver then pulls via claimToken().
    function redirectOwedToken(address token, address from, address to) external onlyOwner {
        require(to != address(0), "Zero receiver");
        require(from != to, "Same recipient");
        uint256 amount = owedToken[token][from];
        require(amount > 0, "Nothing owed");
        owedToken[token][from] = 0;
        owedToken[token][to] += amount;
        emit TokenOwedRedirected(token, from, to, amount);
    }

    function _setSplit(
        address treasury_,
        address farmRewards_,
        address stakingRewards_,
        address reserve_,
        uint16 treasuryBps_,
        uint16 farmBps_,
        uint16 stakingBps_,
        uint16 reserveBps_
    ) internal {
        require(treasury_ != address(0) && farmRewards_ != address(0) && stakingRewards_ != address(0) && reserve_ != address(0), "Zero recipient");
        require(uint256(treasuryBps_) + farmBps_ + stakingBps_ + reserveBps_ == BPS_DENOMINATOR, "Bad split");
        split = SplitConfig(treasury_, farmRewards_, stakingRewards_, reserve_, treasuryBps_, farmBps_, stakingBps_, reserveBps_);
        emit SplitUpdated(treasury_, farmRewards_, stakingRewards_, reserve_, treasuryBps_, farmBps_, stakingBps_, reserveBps_);
    }

    function _splitAmounts(uint256 amount) internal view returns (uint256 t, uint256 f, uint256 s, uint256 r) {
        t = amount * split.treasuryBps / BPS_DENOMINATOR;
        f = amount * split.farmBps / BPS_DENOMINATOR;
        s = amount * split.stakingBps / BPS_DENOMINATOR;
        r = amount - t - f - s;
    }

    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "Native transfer failed");
    }

    function _sendOrOweNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) {
            owedNative[to] += amount;
            totalOwedNative += amount;
            emit NativeOwed(to, amount);
        }
    }

    function _sendOrOweToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        // Low-level transfer so a reverting/false-returning token cannot abort the whole split.
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (success && (data.length == 0 || abi.decode(data, (bool)))) return;
        owedToken[token][to] += amount;
        totalOwedToken[token] += amount;
        emit TokenOwed(token, to, amount);
    }
}
