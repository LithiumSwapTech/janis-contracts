// File contracts/JanisMasterChef.sol

pragma solidity 0.8.16;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../libraries/BoringOwnable.sol";
import "../minting/MintableERC20.sol";
import "../minting/JanisMinter.sol";


library ERC20FactoryLib {
    function createERC20(string memory name_, string memory symbol_, uint8 decimals) external returns(address) 
    {
        ERC20 token = new MintableERC20(name_, symbol_, decimals);
        return address(token);
    }
}

interface IAbilityNFT {
    function getAbility(uint tokenId) external view returns(uint);
}


contract JanisMasterChef is BoringOwnable, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Info of each user.
    struct UserInfo {
        uint amount;         // How many LP tokens the user has provided.
        uint rewardDebtJanis;     // Reward debt. See explanation below.
        uint rewardDebtYieldToken;     // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        ERC20 lpToken;              // Address of LP token contract.
        bool isNFT;
        uint endTime;
        bool usesPremint;
        uint totalLocked;
        uint allocPointJanis;      // How many allocation points assigned to this pool. Janis to distribute per unix time.
        uint allocPointYieldToken;   // How many allocation points assigned to this pool. YieldToken to distribute per unix time.
        uint lastRewardTime;      // Last unix time number that J & WETH distribution occurs.
        uint accJanisPerShare;     // Accumulated J & WETH per share, times 1e24. See below.
        uint accYieldTokenPerShare;  // Accumulated J & WETH per share, times 1e24. See below.
        uint depositFeeBPOrNFTETHFee;        // Deposit fee in basis points
        address receiptToken;
        bool isExtinctionPool;
    }

    struct NFTSlot {
        address slot1;
        uint tokenId1;
        address slot2;
        uint tokenId2;
        address slot3;
        uint tokenId3;
        address slot4;
        uint tokenId4;
        address slot5;
        uint tokenId5;
    }

    JanisMinter public janisMinter;

    // The Janis TOKEN!
    ERC20 public Janis;
    // Janis tokens created per unix time.
    uint public JanisPerSecond;
    // The YieldToken TOKEN!
    ERC20 public yieldToken;
    // YieldToken tokens created per unix time.
    uint public yieldTokenPerSecond;

    address public reserveFund;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint => mapping(address => UserInfo)) public userInfo;

    // NFTs which can be staked as boosters
    mapping(address => bool) public isWhitelistedBoosterNFT;
    // NFTs which we use the ability stat of for boosting
    mapping(address => bool) public isNFTAbilityEnabled;
    // The base boost of NFTs we read the ability of
    mapping(address => uint) public nftAbilityBaseBoost;
    // The ability boost of NFTs we read the ability of
    mapping(address => uint) public nftAbilityBoostScalar;
    // NFT boost for a set, if not ability enabled
    mapping(address => uint) public nonAbilityBoost;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalAllocPointJanis;
    uint public totalAllocPointYieldToken;
    // The unix time number when J & WETH mining starts.
    uint public immutable globalStartTime;

    mapping(ERC20 => bool) public poolExistence;
    mapping(address => mapping(uint => NFTSlot)) public userDepositedNFTMap; // user => pid => nft slot;

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);
    event UpdateJanisEmissionRate(address indexed user, uint JanisPerSecond);
    event UpdateYieldTokenEmissionRate(address indexed user, uint yieldTokenPerSecond);

    event UpdateBoosterNFTWhitelist(address indexed user, address indexed _nft, bool enabled, uint _boostRate, bool isAbilityEnabled, uint abilityNFTBaseBoost, uint _nftAbilityBoostScalar);

    event UpdateNewReserveFund(address newReserveFund);

    // max NFTs a single user can stake in a pool. This is to ensure finite gas usage on emergencyWithdraw.
    uint public MAX_NFT_COUNT = 150;

    // Mapping of user address to total nfts staked, per series.
    mapping(address => mapping(uint => uint)) public userStakeCounts;

    function hasUserStakedNFT(address _user, address _series, uint _tokenId) external view returns (bool) {
        return userStakedMap[_user][_series][_tokenId];
    }
    // Mapping of NFT contract address to which NFTs a user has staked.
    mapping(address => mapping(address => mapping(uint => bool))) public userStakedMap;
    // Mapping of NFT contract address to array of NFT IDs a user has staked.
    mapping(address => mapping(address => EnumerableSet.UintSet)) private userNftIdsMapArray;

    function onERC721Received(
        address,
        address,
        uint,
        bytes calldata
    ) external override returns(bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    constructor(
        address _Janis,
        address _JanisMinter,
        uint _JanisPerSecond,
        ERC20 _yieldToken,
        uint _yieldTokenPerSecond,
        uint _globalSartTime
    ) {
        require(_Janis != address(0), "_Janis!=0");
        require(_JanisMinter != address(0), "_JanisMinter!=0");

        Janis = ERC20(_Janis);
        janisMinter = JanisMinter(_JanisMinter);
        JanisPerSecond = _JanisPerSecond;

        yieldToken = _yieldToken;
        yieldTokenPerSecond = _yieldTokenPerSecond;

        totalAllocPointJanis = 0;
        totalAllocPointYieldToken = 0;

        globalStartTime = _globalSartTime;

        reserveFund = msg.sender;
    }

    /* ========== Modifiers ========== */


    modifier nonDuplicated(ERC20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    /* ========== NFT View Functions ========== */

    function getBoostRateJanis(address _nft, uint _nftId) public view returns (uint) {
        if (isNFTAbilityEnabled[_nft]) {
            // getAbility returns a 1e4 basis point number
            return nftAbilityBaseBoost[_nft] + nftAbilityBoostScalar[_nft] * IAbilityNFT(_nft).getAbility(_nftId) / 1e4;
        } else
            return nonAbilityBoost[_nft];
    }

    function getBoostJanis(address _account, uint _pid) public view returns (uint) {
        NFTSlot memory slot = userDepositedNFTMap[_account][_pid];
        uint boost1 = getBoostRateJanis(slot.slot1, slot.tokenId1);
        uint boost2 = getBoostRateJanis(slot.slot2, slot.tokenId2);
        uint boost3 = getBoostRateJanis(slot.slot3, slot.tokenId3);
        uint boost4 = getBoostRateJanis(slot.slot4, slot.tokenId4);
        uint boost5 = getBoostRateJanis(slot.slot5, slot.tokenId5);
        uint boost = boost1 + boost2 + boost3 + boost4 + boost5;
        return boost;
    }

    function getSlots(address _account, uint _pid) external view returns (address, address, address, address, address) {
        NFTSlot memory slot = userDepositedNFTMap[_account][_pid];
        return (slot.slot1, slot.slot2, slot.slot3, slot.slot4, slot.slot5);
    }

    function getTokenIds(address _account, uint _pid) external view returns (uint, uint, uint, uint, uint) {
        NFTSlot memory slot = userDepositedNFTMap[_account][_pid];
        return (slot.tokenId1, slot.tokenId2, slot.tokenId3, slot.tokenId4, slot.tokenId5);
    }

    /* ========== View Functions ========== */

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // Return reward multiplier over the given _from to _to unix time.
    function getMultiplier(uint _from, uint _to) public pure returns (uint) {
        return _to - _from;
    }

    // View function to see pending J & WETH on frontend.
    function pendingJanis(uint _pid, address _user) external view returns (uint) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint accJanisPerShare = pool.accJanisPerShare;
        uint lpSupply = pool.totalLocked;
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint JanisReward = multiplier * JanisPerSecond * pool.allocPointJanis / totalAllocPointJanis;
            accJanisPerShare = accJanisPerShare + (JanisReward * 1e24 / lpSupply);
        }
        return (user.amount * accJanisPerShare / 1e24) - user.rewardDebtJanis;
    }

    // View function to see pending J & WETH on frontend.
    function pendingYieldToken(uint _pid, address _user) external view returns (uint) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint accYieldTokenPerShare = pool.accYieldTokenPerShare;
        uint lpSupply = pool.totalLocked;
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint yieldTokenReward = multiplier * yieldTokenPerSecond * pool.allocPointYieldToken / totalAllocPointYieldToken;
            accYieldTokenPerShare = accYieldTokenPerShare + (yieldTokenReward * 1e24 / lpSupply);
        }
        return (user.amount * accYieldTokenPerShare / 1e24) - user.rewardDebtYieldToken;
    }

    /* ========== Owner Functions ========== */

    // Add a new lp to the pool. Can only be called by the owner.
    function add(bool _isExtinctionPool, bool _isNFT, uint _startTime, uint _endTime, bool _usesPremint, uint _allocPointJanis, uint _allocPointYieldToken, ERC20 _lpToken, uint _depositFeeBPOrNFTETHFee, bool _withMassUpdate) external onlyOwner nonDuplicated(_lpToken) {
        require(_startTime == 0 || _startTime > block.timestamp, "invalid startTime!");
        require(_endTime == 0 || (_startTime == 0 && _endTime > block.timestamp + 20) || (_startTime > block.timestamp && _endTime > _startTime + 20), "invalid endTime!");
        require(_depositFeeBPOrNFTETHFee <= 1000, "too high fee"); // <= 10%

        // If it isn't an NFT or ERC20, it will likely revert here:
        _lpToken.balanceOf(address(this));

        bool isReallyAnfNFT = false;

        try ERC721(address(_lpToken)).supportsInterface(0x80ac58cd) returns (bool supportsNFT) {
            isReallyAnfNFT = supportsNFT;
        } catch {}

        if (isReallyAnfNFT != _isNFT) {
            if (_isNFT) {
                revert("NFT address isn't and NFT Address!");
            } else {
                revert("ERC20 address isn't and ERC20 Address!");
            }
        }

        if (_isNFT) {
            _isExtinctionPool = false;
        }

        if (_withMassUpdate) {
            massUpdatePools();
        }

        uint lastRewardTime = _startTime == 0 ? (block.timestamp > globalStartTime ? block.timestamp : globalStartTime) : _startTime;
        totalAllocPointJanis = totalAllocPointJanis + _allocPointJanis;
        totalAllocPointYieldToken = totalAllocPointYieldToken + _allocPointYieldToken;

        poolExistence[_lpToken] = true;

        poolInfo.push(PoolInfo({
            isNFT: _isNFT,
            endTime: _endTime,
            usesPremint: _usesPremint,
            lpToken : _lpToken,
            allocPointJanis : _allocPointJanis,
            allocPointYieldToken : _allocPointYieldToken,
            lastRewardTime : lastRewardTime,
            accJanisPerShare : 0,
            accYieldTokenPerShare : 0,
            depositFeeBPOrNFTETHFee: _depositFeeBPOrNFTETHFee,
            totalLocked: 0,
            receiptToken: address(0),
            isExtinctionPool: _isExtinctionPool
        }));

        if (!_isExtinctionPool) {
            string memory receiptName = string.concat("J: ", _lpToken.name());
            string memory receiptSymbol = string.concat("J: ", _lpToken.symbol());
            poolInfo[poolInfo.length - 1].receiptToken = ERC20FactoryLib.createERC20(receiptName, receiptSymbol, _lpToken.decimals());
        }
    }

    // Update the given pool's J & WETH allocation point and deposit fee. Can only be called by the owner.
    function set(uint _pid, uint _startTime, uint _endTime, bool _usesPremint, uint _allocPointJanis, uint _allocPointYieldToken, uint _depositFeeBPOrNFTETHFee, bool _withMassUpdate) external onlyOwner {
        require(_startTime == 0 || _startTime > block.timestamp, "invalid startTime!");
        require(_endTime == 0 || (_startTime == 0 && _endTime > block.timestamp + 20) || (_startTime > block.timestamp && _endTime > _startTime + 20), "invalid endTime!");
        require(_depositFeeBPOrNFTETHFee <= 1000, "too high fee"); // <= 10%

        if (_withMassUpdate) {
            massUpdatePools();
        } else {
            updatePool(_pid);
        }

        totalAllocPointJanis = (totalAllocPointJanis - poolInfo[_pid].allocPointJanis) + _allocPointJanis;
        totalAllocPointYieldToken = (totalAllocPointYieldToken - poolInfo[_pid].allocPointYieldToken) + _allocPointYieldToken;

        uint lastRewardTime = _startTime == 0 ? (block.timestamp > globalStartTime ? block.timestamp : globalStartTime) : _startTime;

        poolInfo[_pid].lastRewardTime = lastRewardTime;
        poolInfo[_pid].endTime = _endTime;
        poolInfo[_pid].usesPremint = _usesPremint;
        poolInfo[_pid].allocPointJanis = _allocPointJanis;
        poolInfo[_pid].allocPointYieldToken = _allocPointYieldToken;
        poolInfo[_pid].depositFeeBPOrNFTETHFee = _depositFeeBPOrNFTETHFee;
    }

    function setUsePremintOnly(uint _pid, bool _usesPremint) external onlyOwner {
        poolInfo[_pid].usesPremint = _usesPremint;
    }

    function setAllocationPointsOnly(uint _pid, uint _allocPointJanis, uint _allocPointYieldToken, bool _withMassUpdate) external onlyOwner {
        if (_withMassUpdate) {
            massUpdatePools();
        } else {
            updatePool(_pid);
        }

        totalAllocPointJanis = (totalAllocPointJanis - poolInfo[_pid].allocPointJanis) + _allocPointJanis;
        totalAllocPointYieldToken = (totalAllocPointYieldToken - poolInfo[_pid].allocPointYieldToken) + _allocPointYieldToken;

        poolInfo[_pid].allocPointJanis = _allocPointJanis;
        poolInfo[_pid].allocPointYieldToken = _allocPointYieldToken;
    }

    function setDepositFeeOnly(uint _pid,  uint _depositFeeBPOrNFTETHFee, bool _withMassUpdate) public onlyOwner {
        require(_depositFeeBPOrNFTETHFee <= 1000, "too high fee"); // <= 10%

        if (_withMassUpdate) {
            massUpdatePools();
        } else {
            updatePool(_pid);
        }

        poolInfo[_pid].depositFeeBPOrNFTETHFee = _depositFeeBPOrNFTETHFee;
    }

    function setPoolScheduleKeepMultipliers(uint _pid, uint _startTime, uint _endTime, bool _withMassUpdate) external onlyOwner {
        require(_startTime == 0 || _startTime > block.timestamp, "invalid startTime!");
        require(_endTime == 0 || (_startTime == 0 && _endTime > block.timestamp + 20) || (_startTime > block.timestamp && _endTime > _startTime + 20), "invalid endTime!");

        if (_withMassUpdate) {
            massUpdatePools();
        } else {
            updatePool(_pid);
        }

        uint lastRewardTime = _startTime == 0 ? (block.timestamp > globalStartTime ? block.timestamp : globalStartTime) : _startTime;

        poolInfo[_pid].lastRewardTime = lastRewardTime;
        poolInfo[_pid].endTime = _endTime;
    }

    function setPoolScheduleAndMultipliers(uint _pid, uint _startTime, uint _endTime, uint _allocPointJanis, uint _allocPointYieldToken, bool _withMassUpdate) external onlyOwner {
        require(_startTime == 0 || _startTime > block.timestamp, "invalid startTime!");
        require(_endTime == 0 || (_startTime == 0 && _endTime > block.timestamp + 20) || (_startTime > block.timestamp && _endTime > _startTime + 20), "invalid endTime!");

        if (_withMassUpdate) {
            massUpdatePools();
        } else {
            updatePool(_pid);
        }

        uint lastRewardTime = _startTime == 0 ? (block.timestamp > globalStartTime ? block.timestamp : globalStartTime) : _startTime;

        poolInfo[_pid].lastRewardTime = lastRewardTime;
        poolInfo[_pid].endTime = _endTime;

        totalAllocPointJanis = (totalAllocPointJanis - poolInfo[_pid].allocPointJanis) + _allocPointJanis;
        totalAllocPointYieldToken = (totalAllocPointYieldToken - poolInfo[_pid].allocPointYieldToken) + _allocPointYieldToken;

        poolInfo[_pid].allocPointJanis = _allocPointJanis;
        poolInfo[_pid].allocPointYieldToken = _allocPointYieldToken;
    }

    function disablePoolKeepMultipliers(uint _pid, bool _withMassUpdate) external onlyOwner {
        if (_withMassUpdate) {
            massUpdatePools();
        } else {
            updatePool(_pid);
        }

        uint lastRewardTime = block.timestamp > globalStartTime ? block.timestamp : globalStartTime;

        poolInfo[_pid].lastRewardTime = lastRewardTime;
        poolInfo[_pid].endTime = lastRewardTime;
    }

    function zeroEndedMultipliersAndDecreaseEmissionVariables(uint startPid, uint endPid, bool _withMassUpdate) external onlyOwner {
        require(startPid < poolInfo.length, "startPid too high!");
        require(endPid < poolInfo.length, "endPid too high!");

        if (_withMassUpdate) {
            massUpdatePools();
        }

        uint janisAllocPointsEliminated = 0;
        uint yieldTokenllocPointsEliminated = 0;

        for (uint i = startPid;i<=endPid;i++) {
            if (poolInfo[i].lastRewardTime >= poolInfo[i].endTime) {
                janisAllocPointsEliminated += poolInfo[i].allocPointJanis;
                yieldTokenllocPointsEliminated += poolInfo[i].allocPointYieldToken;
                poolInfo[i].allocPointJanis = 0;
                poolInfo[i].allocPointYieldToken = 0;
            }
        }

        JanisPerSecond -= JanisPerSecond * janisAllocPointsEliminated / totalAllocPointJanis;
        yieldTokenPerSecond -= yieldTokenPerSecond * yieldTokenllocPointsEliminated / totalAllocPointYieldToken;

        totalAllocPointJanis -= janisAllocPointsEliminated;
        totalAllocPointYieldToken -= yieldTokenllocPointsEliminated;
    }

    /* ========== NFT External Functions ========== */

    // Depositing of NFTs
    function depositNFT(address _nft, uint _tokenId, uint _slot, uint _pid) public nonReentrant {
        require(_slot != 0 && _slot <= 5, "slot out of range 1-5!");
        require(isWhitelistedBoosterNFT[_nft], "only approved NFTs");
        require(ERC721(_nft).balanceOf(msg.sender) > 0, "user does not have specified NFT");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        //require(user.amount == 0, "not allowed to deposit");

        updatePool(_pid);
        transferPendingRewards(_pid);
        
        user.rewardDebtJanis = user.amount * pool.accJanisPerShare / 1e24;
        user.rewardDebtYieldToken = user.amount * pool.accYieldTokenPerShare / 1e24;

        NFTSlot memory slot = userDepositedNFTMap[msg.sender][_pid];

        address existingNFT;

        if (_slot == 1) existingNFT = slot.slot1;
        else if (_slot == 2) existingNFT = slot.slot2;
        else if (_slot == 3) existingNFT = slot.slot3;
        else if (_slot == 4) existingNFT = slot.slot4;
        else if (_slot == 5) existingNFT = slot.slot5;

        require(existingNFT == address(0), "you must empty this slot before depositing a new nft here!");

        if (_slot == 1) slot.slot1 = _nft;
        else if (_slot == 2) slot.slot2 = _nft;
        else if (_slot == 3) slot.slot3 = _nft;
        else if (_slot == 4) slot.slot4 = _nft;
        else if (_slot == 5) slot.slot5 = _nft;
        
        if (_slot == 1) slot.tokenId1 = _tokenId;
        else if (_slot == 2) slot.tokenId2 = _tokenId;
        else if (_slot == 3) slot.tokenId3 = _tokenId;
        else if (_slot == 4) slot.tokenId4 = _tokenId;
        else if (_slot == 5) slot.tokenId5 = _tokenId;

        userDepositedNFTMap[msg.sender][_pid] = slot;

        ERC721(_nft).transferFrom(msg.sender, address(this), _tokenId);
    }

    // Withdrawing of NFTs
    function withdrawNFT(uint _slot, uint _pid) public nonReentrant {
        address _nft;
        uint _tokenId;
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);
        transferPendingRewards(_pid);
        
        user.rewardDebtJanis = user.amount * pool.accJanisPerShare / 1e24;
        user.rewardDebtYieldToken = user.amount * pool.accYieldTokenPerShare / 1e24;

        NFTSlot memory slot = userDepositedNFTMap[msg.sender][_pid];

        if (_slot == 1) _nft = slot.slot1;
        else if (_slot == 2) _nft = slot.slot2;
        else if (_slot == 3) _nft = slot.slot3;
        else if (_slot == 4) _nft = slot.slot4;
        else if (_slot == 5) _nft = slot.slot5;
        
        if (_slot == 1) _tokenId = slot.tokenId1;
        else if (_slot == 2) _tokenId = slot.tokenId2;
        else if (_slot == 3) _tokenId = slot.tokenId3;
        else if (_slot == 4) _tokenId = slot.tokenId4;
        else if (_slot == 5) _tokenId = slot.tokenId5;

        if (_slot == 1) slot.slot1 = address(0);
        else if (_slot == 2) slot.slot2 = address(0);
        else if (_slot == 3) slot.slot3 = address(0);
        else if (_slot == 4) slot.slot4 = address(0);
        else if (_slot == 5) slot.slot5 = address(0);
        
        if (_slot == 1) slot.tokenId1 = uint(0);
        else if (_slot == 2) slot.tokenId2 = uint(0);
        else if (_slot == 3) slot.tokenId3 = uint(0);
        else if (_slot == 4) slot.tokenId4 = uint(0);
        else if (_slot == 5) slot.tokenId5 = uint(0);

        userDepositedNFTMap[msg.sender][_pid] = slot;
        
        ERC721(_nft).transferFrom(address(this), msg.sender, _tokenId);
    }

    /* ========== External Functions ========== */

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        if (pool.endTime != 0 && pool.lastRewardTime >= pool.endTime) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint lpSupply = pool.totalLocked;
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }

        uint currentTimeOrEndOfPoolTime = pool.endTime == 0 ? block.timestamp : pool.endTime;

        uint multiplier = getMultiplier(pool.lastRewardTime, currentTimeOrEndOfPoolTime);

        if (pool.allocPointJanis > 0) {
            uint JanisReward = multiplier * JanisPerSecond * pool.allocPointJanis / totalAllocPointJanis;
            if (JanisReward > 0) {
                if (!pool.usesPremint)
                    janisMinter.operatorMint(address(this), JanisReward);
                else
                    janisMinter.operatorFetchOrMint(address(this), JanisReward);
                pool.accJanisPerShare = pool.accJanisPerShare + (JanisReward * 1e24 / lpSupply);
            }
        }

        if (pool.allocPointYieldToken > 0) {
            uint yieldTokenReward = multiplier * yieldTokenPerSecond * pool.allocPointYieldToken / totalAllocPointYieldToken;
            if (yieldTokenReward > 0) {
                // We can't mint extra of the yield token, meant to be a 3rd party token like WETH, WBTC etc..
                pool.accYieldTokenPerShare = pool.accYieldTokenPerShare + (yieldTokenReward * 1e24 / lpSupply);
            }
        }

        pool.lastRewardTime = block.timestamp;
    }

    function transferPendingRewards(uint _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.amount > 0) {
            uint pendingJanisToPay = (user.amount * pool.accJanisPerShare / 1e24)  - user.rewardDebtJanis;
            if (pendingJanisToPay > 0) {
                safeJanisTransfer(msg.sender, pendingJanisToPay, _pid);
            }
            uint pendingYieldTokenToPay = (user.amount * pool.accYieldTokenPerShare / 1e24) - user.rewardDebtYieldToken;
            if (pendingYieldTokenToPay > 0) {
                safeYieldTokenTransfer(msg.sender, pendingYieldTokenToPay);
            }
        }
    }


    // Deposit LP tokens to MasterChef for J & WETH allocation.
    function deposit(uint _pid, uint _amountOrId, bool isNFTHarvest, address _referrer) public payable nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        transferPendingRewards(_pid);

        // We allow changing of referrals
        janisMinter.recordReferral(msg.sender, _referrer);

        if (!isNFTHarvest && pool.isNFT) {
            require(msg.value >= pool.depositFeeBPOrNFTETHFee, "ETH deposit fee too low!");

            if (pool.depositFeeBPOrNFTETHFee > 0) {
                (bool transferSuccess, ) = payable(reserveFund).call{
                    value: payable(address(this)).balance
                }("");
                require(transferSuccess, "Fee Transfer Failed!");
            }

            address series = address(pool.lpToken);

            userStakeCounts[msg.sender][_pid]++;
            require(userStakeCounts[msg.sender][_pid] <= MAX_NFT_COUNT,
                "you have aleady reached the maximum amount of NFTs you can stake in this pool");
            IERC721(series).safeTransferFrom(msg.sender, address(this), _amountOrId);

            userStakedMap[msg.sender][series][_amountOrId] = true;

            userNftIdsMapArray[msg.sender][series].add(_amountOrId);

            user.amount = user.amount + 1;
            pool.totalLocked = pool.totalLocked + 1;
        } else if (!pool.isNFT && _amountOrId > 0) {
            if (_amountOrId > 0) {
                uint lpBalanceBefore = pool.lpToken.balanceOf(address(this));
                pool.lpToken.safeTransferFrom(msg.sender, address(this), _amountOrId);
                _amountOrId = pool.lpToken.balanceOf(address(this)) - lpBalanceBefore;
                require(_amountOrId > 0, "No tokens received, high transfer tax?");
        
                uint userPoolBalanceBefore = user.amount;

                if (pool.isExtinctionPool) {
                    pool.lpToken.safeTransfer(reserveFund, _amountOrId);
                    user.amount += _amountOrId;
                    pool.totalLocked += _amountOrId;  
                } else if (pool.depositFeeBPOrNFTETHFee > 0) {
                    uint _depositFee = _amountOrId * pool.depositFeeBPOrNFTETHFee / 1e4;
                    pool.lpToken.safeTransfer(reserveFund, _depositFee);
                    user.amount = (user.amount + _amountOrId) - _depositFee;
                    pool.totalLocked = (pool.totalLocked + _amountOrId) - _depositFee;
                } else {
                    user.amount += _amountOrId;
                    pool.totalLocked += _amountOrId;
                }

                uint userPoolBalanceGained = user.amount - userPoolBalanceBefore;

                require(userPoolBalanceGained > 0, "Zero deposit gained, depositing small wei?");

                if (!pool.isExtinctionPool)
                    MintableERC20(pool.receiptToken).mint(msg.sender, userPoolBalanceGained);
            }
        }
    
        user.rewardDebtJanis = user.amount * pool.accJanisPerShare / 1e24;
        user.rewardDebtYieldToken = user.amount * pool.accYieldTokenPerShare / 1e24;
        emit Deposit(msg.sender, _pid, _amountOrId);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint _pid, uint _amountOrId) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        require(!pool.isExtinctionPool, "can't withdraw from extinction pools!");

        UserInfo storage user = userInfo[_pid][msg.sender];
        require(pool.isNFT || user.amount >= _amountOrId, "withdraw: not good");
        updatePool(_pid);
        transferPendingRewards(_pid);

        uint256 withdrawQuantity = 0;

        address tokenAddress = address(pool.lpToken);

        if (pool.isNFT) {
            require(userStakedMap[msg.sender][tokenAddress][_amountOrId], "nft not staked");

            userStakeCounts[msg.sender][_pid]--;

            userStakedMap[msg.sender][tokenAddress][_amountOrId] = false;

            userNftIdsMapArray[msg.sender][tokenAddress].remove(_amountOrId);

            withdrawQuantity = 1;
        } else if (_amountOrId > 0) {
            MintableERC20(pool.receiptToken).burn(msg.sender, _amountOrId);

             pool.lpToken.safeTransfer(msg.sender, _amountOrId);

            withdrawQuantity = _amountOrId;
        }

        user.amount -= withdrawQuantity;
        pool.totalLocked -= withdrawQuantity;

        user.rewardDebtJanis = user.amount * pool.accJanisPerShare / 1e24;
        user.rewardDebtYieldToken = user.amount * pool.accYieldTokenPerShare / 1e24;

        if (pool.isNFT)
            IERC721(tokenAddress).safeTransferFrom(address(this), msg.sender, _amountOrId);

        emit Withdraw(msg.sender, _pid, _amountOrId);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        require(!pool.isExtinctionPool, "can't withdraw from extinction pools!");

        UserInfo storage user = userInfo[_pid][msg.sender];
        uint amount = user.amount;

        user.amount = 0;
        user.rewardDebtJanis = 0;
        user.rewardDebtYieldToken = 0;

        userStakeCounts[msg.sender][_pid] = 0;

        // In the case of an accounting error, we choose to let the user emergency withdraw anyway
        if (pool.totalLocked >=  amount)
            pool.totalLocked = pool.totalLocked - amount;
        else
            pool.totalLocked = 0;

        MintableERC20(pool.receiptToken).burn(msg.sender, amount);

        if (pool.isNFT) {
            address series = address(pool.lpToken);
            EnumerableSet.UintSet storage nftStakedCollection = userNftIdsMapArray[msg.sender][series];

            for (uint j = 0;j < nftStakedCollection.length();j++) {
                uint nftId = nftStakedCollection.at(j);

                userStakedMap[msg.sender][series][nftId] = false;
                IERC721(series).safeTransferFrom(address(this), msg.sender, nftId);
            }

            // empty user nft Ids array
            delete userNftIdsMapArray[msg.sender][series];
        } else {
            pool.lpToken.safeTransfer(msg.sender, amount);
        }

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function viewStakerUserNFTs(address _series, address userAddress) public view returns (uint[] memory){
        EnumerableSet.UintSet storage nftStakedCollection = userNftIdsMapArray[userAddress][_series];

        uint[] memory nftStakedArray = new uint[](nftStakedCollection.length());

        for (uint i = 0;i < nftStakedCollection.length();i++)
           nftStakedArray[i] = nftStakedCollection.at(i);

        return nftStakedArray;
    }

    // Safe Janis transfer function, just in case if rounding error causes pool to not have enough Janis.
    function safeJanisTransfer(address _to, uint _amount, uint _pid) internal {
        uint boost = 0;
        Janis.transfer(_to, _amount);

        boost = getBoostJanis(_to, _pid) * _amount / 1e4;
        uint total = _amount + boost;

        if (boost > 0) janisMinter.operatorMint(_to, boost);
        janisMinter.mintReferralsOnly(_to, total);
        janisMinter.mintDaoShare(total);
    }

    // Safe YieldToken transfer function, just in case if rounding error causes pool to not have enough YieldToken.
    function safeYieldTokenTransfer(address _to, uint _amount) internal {
        uint currentYieldTokenBalance = yieldToken.balanceOf(address(this));
        if (currentYieldTokenBalance < _amount)
            yieldToken.safeTransfer(_to, currentYieldTokenBalance);
        else
            yieldToken.safeTransfer(_to, _amount);
    }

    /* ========== Set Variable Functions ========== */

    function updateJanisEmissionRate(uint _JanisPerSecond) public onlyOwner {
        require(_JanisPerSecond < 1e22, "emissions too high!");
        massUpdatePools();
        JanisPerSecond = _JanisPerSecond;
        emit UpdateJanisEmissionRate(msg.sender, _JanisPerSecond);
    }

    function updateYieldTokenEmissionRate(uint _yieldTokenPerSecond) public onlyOwner {
        require(_yieldTokenPerSecond < 1e22, "emissions too high!");
        massUpdatePools();
        yieldTokenPerSecond = _yieldTokenPerSecond;
        emit UpdateYieldTokenEmissionRate(msg.sender, _yieldTokenPerSecond);
    }

    /**
     * @dev set the maximum amount of NFTs a user is allowed to stake, useful if
     * too much gas is used by emergencyWithdraw
     * Can only be called by the current operator.
     */
    function set_MAX_NFT_COUNT(uint new_MAX_NFT_COUNT) external onlyOwner {
        require(new_MAX_NFT_COUNT >= 20, "MAX_NFT_COUNT must be greater than 0");
        require(new_MAX_NFT_COUNT <= 150, "MAX_NFT_COUNT must be less than 150");

        MAX_NFT_COUNT = new_MAX_NFT_COUNT;
    }

    function setBoosterNFTWhitelist(address _nft, bool enabled, uint _nonAbilityBoost, bool isAbilityEnabled, uint abilityNFTBaseBoost, uint _nftAbilityBoostScalar) public onlyOwner {
        require(_nft != address(0), "_nft!=0");
        require(enabled || (!enabled && !isAbilityEnabled), "Can't disable and also enable for ability boost!");
        require(_nonAbilityBoost <= 500, "Max non-abilitu boost is 5%!");
        require(abilityNFTBaseBoost<= 500, "Max ability base boost is 5%!");
        require(_nftAbilityBoostScalar<= 500, "Max ability scalar boost is 5%!");

        isWhitelistedBoosterNFT[_nft] = enabled;
        isNFTAbilityEnabled[_nft] = isAbilityEnabled;

        if (enabled && !isAbilityEnabled)
            nonAbilityBoost[_nft] = _nonAbilityBoost;
        else if (!enabled)
            nonAbilityBoost[_nft] = 0;

        if (isNFTAbilityEnabled[_nft]) {
            nftAbilityBaseBoost[_nft] = abilityNFTBaseBoost;
            nftAbilityBoostScalar[_nft] = _nftAbilityBoostScalar;
        } else {
            nftAbilityBaseBoost[_nft] = 0;
            nftAbilityBoostScalar[_nft] = 0;
        }

        emit UpdateBoosterNFTWhitelist(msg.sender, _nft, enabled, nonAbilityBoost[_nft], isAbilityEnabled, nftAbilityBaseBoost[_nft], nftAbilityBoostScalar[_nft]);
    }

    function setReserveFund(address newReserveFund) public onlyOwner {
        reserveFund = newReserveFund;
        emit UpdateNewReserveFund(newReserveFund);
    }

    function harvestAllRewards() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            if (userInfo[pid][msg.sender].amount > 0) {
                withdraw(pid, 0);
            }
        }
    }
}