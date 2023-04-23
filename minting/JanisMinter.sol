// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../libraries/BoringOwnable.sol";
import "./MintableERC20.sol";

contract JanisMinter is BoringOwnable {
    using SafeERC20 for IERC20;
    using SafeERC20 for MintableERC20;

    MintableERC20 public JanisToken;
    address public daoAddress;

    // 5%
    uint public constant MAX_BONUS = 500;
    // 3%
    uint public referralBonusE4 = 300;
    // 2%
    uint public refereeBonusE4 = 200;

    // 25%
    uint public constant MAX_DAO_SHARE = 2500;
    // 12%
    uint public daoShareE4 = 1200;

    mapping(address => bool) public operators;
    mapping(address => address) public referrers; // user address => referrer address
    mapping(address => uint) public referralsCount; // referrer address => referrals count

    mapping(address => uint) public totalReferralCommission; // referrer address => total referral commission
    mapping(address => mapping(address => uint)) public totalReferralCommissionPerUser; // referrer address => user address => total referral commission

    mapping(address => uint) public totalRefereeReward; // referrer address => total reward for being referred
    mapping(address => mapping(address => uint)) public totalRefereeRewardPerReferrer; // user address => referrer address => total reward for being referred

    event ReferralRecorded(address indexed user, address indexed oldReferrer, address indexed newReferrer);
    event ReferralCommissionRecorded(address indexed referrer, address indexed user, uint commission);
    event HasRefereeRewardRecorded(address indexed user, address indexed referrer, uint reward);
    event JanisMinted(address indexed destination, uint amount);

    event ReferralBonusUpdated(uint oldBonus, uint newBonus);
    event RefereeBonusUpdated(uint oldBonus, uint newBonus);
    event JanisTokenUpdated(address oldJanisToken, address janisToken);
    event DaoAddressUpdated(address oldDaoAddress, address daoAddress);
    event OperatorUpdated(address indexed operator, bool indexed status);

    modifier onlyOperator {
        require(operators[msg.sender], "Operator: caller is not the operator");
        _;
    }

    constructor(
        address _JanisToken,
        address _DaoAddress
    ) {
        require(_JanisToken != address(0), "_JanisToken!=0");
        require(_DaoAddress != address(0), "_DaoAddress!=0");

        JanisToken = MintableERC20(_JanisToken);
        daoAddress = _DaoAddress;

        operators[msg.sender] = true;
    }

    function recordReferral(address _user, address _referrer) external onlyOperator {
        if (_user != address(0)
            && _referrer != address(0)
            && _user != _referrer
            && referrers[_user] != _referrer
        ) {
            address oldReferrer = address(0);
            if (referrers[_user] != address(0)) {
                // Instead of this being a new referral, we are changing the referrer,
                // so we need to subtract from the old referrers count
                oldReferrer = referrers[_user];
                referralsCount[oldReferrer] -= 1;
            }

            referralsCount[_referrer] += 1;
            referrers[_user] = _referrer;
            
            emit ReferralRecorded(_user, oldReferrer, _referrer);
        }
    }

    function operatorMint(address _destination, uint _minting) external onlyOperator {
        mintWithoutReferrals(_destination, _minting);
    }
    
    function operatorMintForReserves(uint _minting) external onlyOperator {
        mintWithoutReferrals(address(this), _minting);
    }

    function operatorFetchOrMint(address _destination, uint _minting) external onlyOperator {
        uint currentJanisBalance = JanisToken.balanceOf(address(this));
        if (currentJanisBalance < _minting) {
            JanisToken.mint(address(this), _minting - currentJanisBalance);
            emit JanisMinted(address(this), _minting);
        }
        JanisToken.safeTransfer(_destination, _minting);
    }

    function mintWithReferrals(address _user, uint _minting) external onlyOperator {
        mintWithoutReferrals(_user, _minting);
        mintReferralsOnly(_user, _minting);
    }

    function mintWithoutReferrals(address _user, uint _minting) public onlyOperator {
        if (_user != address(0) && _minting > 0) {
            JanisToken.mint(_user, _minting);
            emit JanisMinted(_user, _minting);
        }
    }

    function mintReferralsOnly(address _user, uint _minting) public onlyOperator {
        uint commission = _minting * referralBonusE4 / 1e4;
        uint reward =  _minting * refereeBonusE4 / 1e4;

        address referrer = referrers[_user];

        if (referrer != address(0) && _user != address(0) && commission > 0) {
            totalReferralCommission[referrer] += commission;
            totalReferralCommissionPerUser[referrer][_user] += commission;

            JanisToken.mint(referrer, commission);

            emit JanisMinted(referrer, commission);
            emit ReferralCommissionRecorded(referrer, _user, commission);
        }
        if (_user != address(0) && referrer != address(0) && reward > 0) {
            totalRefereeReward[_user] += reward;
            totalRefereeRewardPerReferrer[_user][referrer] += reward;

            JanisToken.mint(_user, reward);

            emit JanisMinted(_user, reward);
            emit ReferralCommissionRecorded(_user, referrer, reward);
        }
    }

    function mintDaoShare(uint _minting) public onlyOperator {
        uint daoShare = _minting * daoShareE4 / 1e4;

        JanisToken.mint(daoAddress, daoShare);

        emit JanisMinted(daoAddress, daoShare);
    }

    // Get the referrer address that referred the user
    function getReferrer(address _user) external view returns (address) {
        return referrers[_user];
    }

    // Update the referrer bonus
    function updateReferralBonus(uint _bonus) external onlyOwner {
        require(_bonus <= MAX_BONUS, "Max bonus is 5%");

        uint oldBonus = referralBonusE4;
        referralBonusE4 = _bonus;
        emit ReferralBonusUpdated(oldBonus, referralBonusE4);
    }

    // Update the referee bonus
    function updateRefereeBonus(uint _bonus) external onlyOwner {
        require(_bonus <= MAX_BONUS, "Max bonus is 5%");

        uint oldBonus = refereeBonusE4;
        refereeBonusE4 = _bonus;
        emit ReferralBonusUpdated(oldBonus, refereeBonusE4);
    }

    // Update the dao share percentage
    function updateDaoShare(uint _perc) external onlyOwner {
        require(_perc <= MAX_DAO_SHARE, "Max bonus is 25%");

        uint oldPerc = daoShareE4;
        daoShareE4 = _perc;
        emit ReferralBonusUpdated(oldPerc, daoShareE4);
    }

    // Update the status of the operator
    function setJanisToken(address _JanisToken) external onlyOwner {
        require(_JanisToken != address(0), "_JanisToken!=0");

        address oldJanisToken = address(JanisToken);
        JanisToken = MintableERC20(_JanisToken);
        emit JanisTokenUpdated(oldJanisToken, _JanisToken);
    }


    // Update the status of the operator
    function setDaoAddress(address _DaoAddress) external onlyOwner {
        require(_DaoAddress != address(0), "_DaoAddress!=0");

        address oldDaoAddress = daoAddress;
        daoAddress = _DaoAddress;
        emit DaoAddressUpdated(oldDaoAddress, daoAddress);
    }

    // Update the status of the operator
    function updateOperator(address _operator, bool _status) external onlyOwner {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }

    // Owner can drain tokens that are sent here by mistake
    function drainERC20Token(IERC20 _token, uint _amount, address _to) external onlyOwner {
        _token.safeTransfer(_to, _amount);
    }
}