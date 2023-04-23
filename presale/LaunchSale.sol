// File contracts/LaunchSale.sol

pragma solidity 0.8.16;

import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../minting/JanisMinter.sol";
import "../libraries/BoringOwnable.sol";

/// @title Launch Sale Contract
contract LaunchSale is
    BoringOwnable, Pausable, ReentrancyGuard
{
    using SafeERC20 for IERC20;

    mapping(address => bool) public admins;

    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    uint public startTime;
    uint public endTime;

    // Ownership token will be 18 decimal
    uint public immutable ownershipTokenTotal;

    // Janis will be 18 decimal
    uint public immutable JanisPresaleTotal;
    uint public constant JanisPresaleAllocation = 1e6 * 1e18;
    uint public immutable JanisLPAmount;

    // This ratio guarantees a 3x in price for presale participants
    uint public constant JanisPresaleAllcationToTotalRatioE18 = 1416666666666666666;

    // 20% of raise goes to fund development
    uint public constant orgShare = 20;
    address public constant orgAddress = 0x9B031C4DbA4758C1Fb4251E6135d20B139C86196;

    struct BuyerData {
        uint purchasedAmount;
        uint claimedJanisTokens;
        uint claimedOwnershipTokens;
    }

    IUniswapV2Router02 public SwapRouter;

    IERC20 public immutable JanisToken;
    IERC20 public immutable OwnershipToken;

    mapping(address => BuyerData) public buyerData;

    uint public totalValueSupplied;
    uint public finishedSecond;
    uint public immutable releasePeriodSeconds;

    bool public liquidityAdded = false;
    bool public refundsEnabled = false;

    JanisMinter public janisMinter;

    receive() external payable {}

    event Buy(address indexed _buyAddress, uint _amount);
    event Refund(address indexed _refundAddress, uint _amount);
    event ClaimedTokens(address indexed _claimerAddress, uint _janisAmount, uint _ownershipTokenAmount);
    event SwapRouterChanged(address oldStatus, address newStatus);
    event RefundEnabledChanged(bool oldStatus, bool newStatus);
    event StartTimeChanged(uint newStartTime, uint newEndTime);
    event AdminSet(address admin, bool value);

    modifier onlyAdmin {
        require(admins[msg.sender], "Invalid permissions!");
        _;
    }

    constructor(
        uint _startTime,
        uint _endTime,
        address _JanisToken,
        address _OwnershipToken,
        uint _ownershipTokenTotal,
        uint _releasePeriodSeconds,
        address _janisMinter
    ) {
        require(block.timestamp < _startTime, "Cannot set start block in the past!");
        require(_startTime < _endTime, "End time must be after start time!");
        require(_JanisToken != address(0), "_JanisToken!=0");
        require(_ownershipTokenTotal != 0, "_ownershipTokenTotal!=0");
        require(_releasePeriodSeconds != 0, "_releasePeriodSeconds!=0");
        require(_janisMinter != address(0), "_releasePeriodSeconds!=0");

        startTime = _startTime;
        endTime = _endTime;

        JanisPresaleTotal = JanisPresaleAllocation * JanisPresaleAllcationToTotalRatioE18 / 1e18;
        JanisLPAmount = JanisPresaleTotal - JanisPresaleAllocation;

        JanisToken = IERC20(_JanisToken);
        OwnershipToken = IERC20(_OwnershipToken);

        ownershipTokenTotal = _ownershipTokenTotal;
        releasePeriodSeconds = _releasePeriodSeconds;

        admins[msg.sender] = true;
        admins[orgAddress] = true;

        janisMinter = JanisMinter(_janisMinter);
    }

    /// @notice Used to increase the buy order amount for the user. Can be called multiple times.
    function buy(address _referrer) external payable nonReentrant whenNotPaused {
        require(block.timestamp >= startTime, "Presale hasn't started yet!");
        require(block.timestamp < endTime, "Presale has ended!!");
        require(msg.value > 0, "Can't buy with 0 ETH!");

        buyerData[msg.sender].purchasedAmount += msg.value;
        totalValueSupplied += msg.value;

        // We allow changing of referrals
        janisMinter.recordReferral(msg.sender, _referrer);

        emit Buy(msg.sender, msg.value);
    }

    /// @notice Used to refund all the buy positions for the caller.
    function refund() external nonReentrant whenNotPaused {
        require(refundsEnabled, "Purchases are currently non refundable");
        require(block.timestamp > endTime, "Can only enable refunds after presale has ended");
        require(buyerData[msg.sender].purchasedAmount > 0, "Nothing to refund");

        uint refundAmount = buyerData[msg.sender].purchasedAmount;
        totalValueSupplied -= refundAmount;
        buyerData[msg.sender].purchasedAmount = 0;

        sendETH(msg.sender, refundAmount);

        emit Refund(msg.sender, refundAmount);
    }

    /// @notice Returns the amount of Janis + Ownership tokens that can be claimed by the user
    /// @dev It linearly releases tokens for 'releasePeriodSeconds' seconds from the moment the presale is over
    /// @return tokens The amount minted in Janis tokens, and the amount of Ownership tokens.
    function pendingTokens() public view returns (uint, uint) {
        return (pendingJanisTokens(), pendingOwnershipTokens());
    }

    /// @notice Returns the amount of Janis tokens that can be claimed by the user
    /// @dev It linearly releases tokens for 'releasePeriodSeconds' seconds from the moment the presale is over
    /// @return tokens The amount minted in Janis tokens
    function pendingJanisTokens() public view returns (uint) {
        if (block.timestamp <= endTime) return 0;

        uint totalUserTokens = (JanisPresaleAllocation *
            buyerData[msg.sender].purchasedAmount) / totalValueSupplied;

        uint releasedUserTokens = ((block.timestamp - finishedSecond) >=
            releasePeriodSeconds)
            ? totalUserTokens
            : (((block.timestamp - finishedSecond) * totalUserTokens) /
                releasePeriodSeconds);

        return
            (releasedUserTokens <= buyerData[msg.sender].claimedJanisTokens)
                ? 0
                : releasedUserTokens - buyerData[msg.sender].claimedJanisTokens;
    }

    /// @notice Returns the amount of Ownership tokens that can be claimed by the user
    /// @dev It releases all tokens upon the claim process starting
    /// @return tokens The amount minted in Ownership tokens
    function pendingOwnershipTokens() public view returns (uint) {
        if (block.timestamp <= endTime) return 0;

        uint releasedUserTokens = (ownershipTokenTotal *
            buyerData[msg.sender].purchasedAmount) / totalValueSupplied;

        return
            (releasedUserTokens <= buyerData[msg.sender].claimedOwnershipTokens)
                ? 0
                : releasedUserTokens - buyerData[msg.sender].claimedOwnershipTokens;
    }

    /// @notice Used to claim all the tokens made available to the caller up to the current block
    /// @dev Reverts if the redemption hasn't started yet
    function claimTokens() external whenNotPaused {
        require(block.timestamp > endTime && liquidityAdded, "Presale not over yet!!");
        require(!refundsEnabled, "Can't claim if refunds are enabled");

        (uint pendingJanisAmount, uint pendingOwnershipTokenAmount) = pendingTokens();

        require(pendingJanisAmount > 0 || pendingOwnershipTokenAmount > 0, "Nothing to claim");

        if (pendingJanisAmount > 0) {
            buyerData[msg.sender].claimedJanisTokens += pendingJanisAmount;
            JanisToken.safeTransfer(
                msg.sender,
                pendingJanisAmount
            );
            janisMinter.mintReferralsOnly(msg.sender, pendingJanisAmount);
        }
        if (pendingOwnershipTokenAmount > 0) {
            buyerData[msg.sender].claimedOwnershipTokens += pendingOwnershipTokenAmount;
            OwnershipToken.safeTransfer(
                msg.sender,
                pendingOwnershipTokenAmount
            );
        }
        emit ClaimedTokens(msg.sender, pendingJanisAmount, pendingOwnershipTokenAmount);
    }

    /// @notice Used to finish the sale, provide the initial liquidity with raised ETH
    function finishSale()
        external
        onlyAdmin
        nonReentrant
    {
        require(block.timestamp > endTime, "Presale not over yet!!");
        require(!refundsEnabled, "Refunds are enabled, something wrong?");
        require(address(SwapRouter) != address(0), "Please configure the Uniswapv2 Swap Router!");

        liquidityAdded = true;
        finishedSecond = block.timestamp;

        uint orgETH = totalValueSupplied * orgShare / 100;

        sendETH(orgAddress, orgETH);

        // Allow SwapRouter to spend tokens in order to add liquidity
        JanisToken.safeApprove(
            address(SwapRouter),
            JanisLPAmount
        );

        uint JanisETH = totalValueSupplied - orgETH;

        // Add 'JanisLPAmount' tokens and 'JanisETH' ETH as liquidity
        (uint addedToken, uint addedEth,) = 
            SwapRouter.addLiquidityETH{value: JanisETH}(
                address(JanisToken),
                JanisLPAmount,
                0,
                0,
                orgAddress,
                block.timestamp + 1
        );

        uint ethNotUsed = JanisETH - addedEth;
        uint janisNotUsed = JanisLPAmount - addedToken;

        sendETH(orgAddress, ethNotUsed);

        if (janisNotUsed > 0) {
            JanisToken.safeTransfer(
                orgAddress,
                janisNotUsed
            );
        }
    }

    function setSwapRouter(address _swapRouterAddress) external onlyAdmin {
        require(!liquidityAdded, "Liquidity already added!");
        require(_swapRouterAddress != address(0), "_swapRouterAddress!=0");

        address oldSwap = address(SwapRouter);

        SwapRouter = IUniswapV2Router02(_swapRouterAddress);

        require(SwapRouter.WETH() == WETH, "Invalid format of Uniswap v2 Router");

        emit SwapRouterChanged(oldSwap, _swapRouterAddress);
    }

    function setRefundsEnabled(bool _refundsEnabled) external onlyAdmin {
        require(block.timestamp > endTime, "Can only enable refunds after presale has ended");
        require(!liquidityAdded, "Can't enable refunds if liquidity has already been added!");

        bool oldStatus = refundsEnabled;

        refundsEnabled = _refundsEnabled;

        emit RefundEnabledChanged(oldStatus, refundsEnabled);
    }

    function setStartTime(uint _newStartTime, uint _newEndTime) external onlyAdmin {
        require(block.timestamp < startTime, "Presale has already started!");
        require(block.timestamp < _newStartTime, "Cannot set start block in the past!");
        require(_newStartTime < _newEndTime, "End time must be after start time!");
        require(startTime < _newStartTime, "Can't make presale sooner, only later!");

        startTime = _newStartTime;
        endTime = _newEndTime;

        emit StartTimeChanged(startTime, endTime);
    }

    function setAdmins(address _newAdmin, bool status) public onlyOwner {
        admins[_newAdmin] = status;

        emit AdminSet(_newAdmin, status);
    }

  function sendETH(address to, uint amount) internal {
    if (amount > 0) {
      (bool transferSuccess, ) = payable(to).call{
          value: amount
      }("");
      require(transferSuccess, "ETH transfer failed");
    }
  }
}