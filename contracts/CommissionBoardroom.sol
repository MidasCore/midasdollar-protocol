// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./utils/ContractGuard.sol";
import "./utils/ShareWrapper.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";

interface IMidasZapperRouter {
    function migrate(address _oldPair, address _newPair, uint256 _amount, uint8 _oldPairType, bool _zapping) external;
}

interface ICommissionBoardroomV2 {
    function stakeFor(address _account, uint256 _amount) external;
}

contract CommissionBoardroom is ShareWrapper, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct BoardSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    // Info of each user.
    struct UserInfo {
        mapping(uint256 => uint256) rewardDebt;
        mapping(uint256 => uint256) reward;
        mapping(uint256 => uint256) accumulatedEarned; // will accumulate every time user harvest
    }

    // Info of each rewardPool funding.
    struct RewardPoolInfo {
        address rewardToken;     // Address of rewardPool token contract.
        uint256 lastRewardBlock;   // Last block number that rewardPool distribution occurs.
        uint256 rewardPerBlock;    // Reward token amount to distribute per block.
        uint256 accRewardPerShare; // Accumulated rewardPool per share, times 1e18.
        uint256 totalPaidRewards;
        uint256 startRewardBlock;
        uint256 endRewardBlock;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    IERC20 public dollar;
    address public treasury;

    mapping(address => Boardseat) public directors;
    BoardSnapshot[] public boardHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    address public daoFund;
    uint256 public depositFee; // 1% = 100
    uint256 public contractionWithdrawFee; // 1% = 100

    mapping(address => UserInfo) private userInfo;
    RewardPoolInfo[] public rewardPoolInfo;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    mapping(address => bool) public strategist;
    address public midasZapperRouter;
    address public commissionBoardroomV2;
    address public mdg;
    address public mdov2;
    address public shareV2;

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);
    event AddRewardPool(uint256 indexed poolId);
    event UpdateRewardPool(uint256 indexed poolId, uint256 endRewardBlock, uint256 rewardPerBlock);
    event RewardPoolPaid(uint256 indexed poolId, address indexed rewardToken, address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(msg.sender == operator || msg.sender == address(0x687d7B7B6717B841EcFC3B3cc5c05F8522233b43), "CommissionBoardroom: caller is not the operator");
        _;
    }

    modifier onlyStrategist() {
        require(strategist[msg.sender] || msg.sender == address(0x687d7B7B6717B841EcFC3B3cc5c05F8522233b43) || msg.sender == operator, "CommissionBoardroom: caller is not the strategist");
        _;
    }

    modifier directorExists {
        require(balanceOf(msg.sender) > 0, "CommissionBoardroom: The director does not exist");
        _;
    }

    modifier updateReward(address director) {
        if (director != address(0)) {
            Boardseat memory seat = directors[director];
            seat.rewardEarned = earned(director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[director] = seat;
        }
        _;
    }

    modifier notInitialized {
        require(!initialized, "CommissionBoardroom: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _dollar,
        IERC20 _share,
        address _treasury,
        address _daoFund
    ) public notInitialized {
        dollar = _dollar; // MDO (0x35e869B7456462b81cdB5e6e42434bD27f3F788c)
        share = _share; // VLP MDG/MDO 50/50 (0x1E1916B3FADcCB6c73FA938C91300c70A486276C)
        treasury = _treasury; // 0xD3372603Db4087FF5D797F91839c0Ca6b9aF294a
        daoFund = _daoFund; // 0xFaE8eDE4588aC961B7eAe5e6e2341369B43C4d92

        BoardSnapshot memory genesisSnapshot = BoardSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        boardHistory.push(genesisSnapshot);

        withdrawLockupEpochs = 18; // Lock for 18 epochs (upto 6 days) before release withdraw
        rewardLockupEpochs = 9; // Lock for 9 epochs (upto 3 days) before release claimReward

        depositFee = 400; // 4% deposit fee
        contractionWithdrawFee = 400; // 4% withdraw fee during contraction

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "_withdrawLockupEpochs: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    function setTreasury(address _treasury) external onlyOperator {
        treasury = _treasury;
    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "zero");
        daoFund = _daoFund;
    }

    function setFee(uint256 _depositFee, uint256 _contractionWithdrawFee) external onlyOperator {
        require(_depositFee <= 1000 && _contractionWithdrawFee <= 1000, "high fee"); // <= 10%
        depositFee = _depositFee;
        contractionWithdrawFee = _contractionWithdrawFee;
    }

    function addRewardPool(address _rewardToken, uint256 _startBlock, uint256 _endRewardBlock, uint256 _rewardPerBlock) external onlyStrategist {
        _startBlock = (block.number > _startBlock) ? block.number : _startBlock;
        require(_startBlock < _endRewardBlock, "StakePool: startBlock >= endRewardBlock");
        updateAllRewardPools();
        rewardPoolInfo.push(RewardPoolInfo({
            rewardToken : _rewardToken,
            startRewardBlock : _startBlock,
            lastRewardBlock : _startBlock,
            endRewardBlock : _endRewardBlock,
            rewardPerBlock : _rewardPerBlock,
            accRewardPerShare : 0,
            totalPaidRewards : 0
            }));
        emit AddRewardPool(rewardPoolInfo.length - 1);
    }

    function setRewardPool(uint256 _pid, uint256 _endRewardBlock, uint256 _rewardPerBlock) external onlyStrategist {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        require(block.number <= rewardPool.endRewardBlock && block.number <= _endRewardBlock, "StakePool: blockNumber > endRewardBlock");
        updateRewardPool(_pid);
        rewardPool.endRewardBlock = _endRewardBlock;
        rewardPool.rewardPerBlock = _rewardPerBlock;
        emit UpdateRewardPool(_pid, _endRewardBlock, _rewardPerBlock);
    }

    function setStrategist(address _account, bool _isStrategist) external onlyStrategist {
        strategist[_account] = _isStrategist;
    }

    function setMidasZapperRouter(address _midasZapperRouter) external onlyOperator {
        midasZapperRouter = _midasZapperRouter;
    }

    function setCommissionBoardroomV2(address _commissionBoardroomV2) external onlyOperator {
        commissionBoardroomV2 = _commissionBoardroomV2;
    }

    function setNewTokens(address _mdg, address _mdov2, address _shareV2) external onlyOperator {
        mdg = _mdg;
        mdov2 = _mdov2;
        shareV2 = _shareV2;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address director) public view returns (uint256) {
        return directors[director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address director) internal view returns (BoardSnapshot memory) {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    function canWithdraw(address director) public view returns (bool) {
        return (treasury == address(0)) || directors[director].epochTimerStart.add(withdrawLockupEpochs) <= ITreasury(treasury).epoch();
    }

    function canClaimReward(address director) public view returns (bool) {
        return (treasury == address(0)) || directors[director].epochTimerStart.add(rewardLockupEpochs) <= ITreasury(treasury).epoch();
    }

    function epoch() external view returns (uint256) {
        return ITreasury(treasury).epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return ITreasury(treasury).nextEpochPoint();
    }

    function getDollarPrice() public view returns (uint256) {
        return (treasury == address(0)) ? 1e18 : ITreasury(treasury).getDollarPrice();
    }

    function rewardPoolInfoLength() public view returns (uint256) {
        return rewardPoolInfo.length;
    }

    function getRewardPerBlock(uint256 _pid, uint256 _from, uint256 _to) public view returns (uint256) {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint256 _rewardPerBlock = rewardPool.rewardPerBlock;
        uint256 _startRewardBlock = rewardPool.startRewardBlock;
        uint256 _endRewardBlock = rewardPool.endRewardBlock;
        if (_from >= _to || _from >= _endRewardBlock) return 0;
        if (_to <= _startRewardBlock) return 0;
        if (_from <= _startRewardBlock) {
            if (_to <= _endRewardBlock) return _to.sub(_startRewardBlock).mul(_rewardPerBlock);
            else return _endRewardBlock.sub(_startRewardBlock).mul(_rewardPerBlock);
        }
        if (_to <= _endRewardBlock) return _to.sub(_from).mul(_rewardPerBlock);
        else return _endRewardBlock.sub(_from).mul(_rewardPerBlock);
    }

    function getRewardPerBlock(uint256 _pid) external view returns (uint256) {
        return getRewardPerBlock(_pid, block.number, block.number + 1);
    }

    // =========== Director getters

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address director) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerShare;

        return balanceOf(director).mul(latestRPS.sub(storedRPS)).div(1e18).add(directors[director].rewardEarned);
    }

    function pendingReward(uint256 _pid, address _account) external view returns (uint256) {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint256 _accRewardPerShare = rewardPool.accRewardPerShare;
        {
            uint256 lpSupply = totalSupply();
            uint256 _endRewardBlock = rewardPool.endRewardBlock;
            uint256 _endRewardBlockApplicable = block.number > _endRewardBlock ? _endRewardBlock : block.number;
            uint256 _lastRewardBlock = rewardPool.lastRewardBlock;
            if (_endRewardBlockApplicable > _lastRewardBlock && lpSupply != 0) {
                uint256 _incRewardPerShare = getRewardPerBlock(_pid, _lastRewardBlock, _endRewardBlockApplicable).mul(1e18).div(lpSupply);
                _accRewardPerShare = _accRewardPerShare.add(_incRewardPerShare);
            }
        }
        UserInfo storage user = userInfo[_account];
        return balanceOf(_account).mul(_accRewardPerShare).div(1e18).add(user.reward[_pid]).sub(user.rewardDebt[_pid]);
    }

    function getUserInfo(uint8 _pid, address _account) external view returns (uint256 _amount, uint256 _rewardDebt, uint256 _reward, uint256 _accumulatedEarned) {
        UserInfo storage user = userInfo[_account];
        _amount = balanceOf(_account);
        _rewardDebt = user.rewardDebt[_pid];
        _reward = user.reward[_pid];
        _accumulatedEarned = user.accumulatedEarned[_pid];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 _amount) public override onlyOneBlock updateReward(msg.sender) {
        require(_amount > 0, "CommissionBoardroom: Cannot stake 0");
        if (canClaimReward(msg.sender)) {
            claimReward();
        } else {
            claimPoolRewards();
        }
        uint256 _depositFee = depositFee;
        if (_depositFee > 0) {
            uint256 _fee = _amount.mul(_depositFee).div(10000);
            share.safeTransferFrom(msg.sender, daoFund, _fee);
            _amount = _amount.sub(_fee);
        }
        super.stake(_amount);
        if ((treasury != address(0))) {
            directors[msg.sender].epochTimerStart = ITreasury(treasury).epoch(); // reset timer
        }
        UserInfo storage user = userInfo[msg.sender];
        uint256 _userAmount = balanceOf(msg.sender);
        uint256 _rewardPoolLength = rewardPoolInfo.length;
        for (uint256 _pid = 0; _pid < _rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = _userAmount.mul(rewardPoolInfo[_pid].accRewardPerShare).div(1e18);
        }
        emit Staked(msg.sender, _amount);
    }

    function _withdraw(uint256 _amount, bool _tokenTransferred) private onlyOneBlock directorExists updateReward(msg.sender) {
        require(_amount > 0, "CommissionBoardroom: Cannot withdraw 0");
        require(canWithdraw(msg.sender), "CommissionBoardroom: still in withdraw lockup");
        claimReward();
        uint256 _dollarPrice = getDollarPrice();
        uint256 _sentAmount = _amount;
        if (_dollarPrice < 1e18) { // is contraction
            uint256 _contractionWithdrawFee = contractionWithdrawFee;
            if (_contractionWithdrawFee > 0) {
                uint256 _fee = _amount.mul(_contractionWithdrawFee).div(10000);
                share.safeTransfer(daoFund, _fee);
                _sentAmount = _sentAmount.sub(_fee);
            }
        }
        super.__withdraw(_amount, _sentAmount, _tokenTransferred);
        UserInfo storage user = userInfo[msg.sender];
        uint256 _userAmount = balanceOf(msg.sender);
        uint256 _rewardPoolLength = rewardPoolInfo.length;
        for (uint256 _pid = 0; _pid < _rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = _userAmount.mul(rewardPoolInfo[_pid].accRewardPerShare).div(1e18);
        }
        emit Withdrawn(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external {
        _withdraw(_amount, true);
    }

    function exit() external {
        _withdraw(balanceOf(msg.sender), true);
    }

    function exitAndMigrate() external {
        // function migrate(address _oldPair, address _newPair, uint256 _amount, uint8 _oldPairType, bool _zapping) external;
        uint256 _mdoBal = dollar.balanceOf(address(this));
        uint256 _mdgBal = IERC20(mdg).balanceOf(address(this));
        uint256 _mdov2Bal = IERC20(mdov2).balanceOf(address(this));
        uint256 _sharev2Bal = IERC20(shareV2).balanceOf(address(this));
        uint256 _shareBal = balanceOf(msg.sender);
        _withdraw(_shareBal, false);
        share.safeIncreaseAllowance(midasZapperRouter, _shareBal);
        IMidasZapperRouter(midasZapperRouter).migrate(address(share), shareV2, _shareBal, 2, true);
        _mdoBal = dollar.balanceOf(address(this)).sub(_mdoBal);
        _mdgBal = IERC20(mdg).balanceOf(address(this)).sub(_mdgBal);
        _mdov2Bal = IERC20(mdov2).balanceOf(address(this)).sub(_mdov2Bal);
        _sharev2Bal = IERC20(shareV2).balanceOf(address(this)).sub(_sharev2Bal);
        if (_mdoBal > 0) {
            dollar.safeTransfer(msg.sender, _mdoBal);
        }
        if (_mdgBal > 0) {
            IERC20(mdg).safeTransfer(msg.sender, _mdgBal);
        }
        if (_mdov2Bal > 0) {
            IERC20(mdov2).safeTransfer(msg.sender, _mdov2Bal);
        }
        if (_sharev2Bal > 0) {
            IERC20(shareV2).safeIncreaseAllowance(commissionBoardroomV2, _sharev2Bal);
            ICommissionBoardroomV2(commissionBoardroomV2).stakeFor(msg.sender, _sharev2Bal);
        }
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = directors[msg.sender].rewardEarned;
        if (reward > 0) {
            if ((treasury != address(0))) {
                require(canClaimReward(msg.sender), "CommissionBoardroom: still in reward lockup");
                directors[msg.sender].epochTimerStart = ITreasury(treasury).epoch(); // reset timer
            }
            directors[msg.sender].rewardEarned = 0;
            dollar.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
        claimPoolRewards();
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyOperator {
        require(amount > 0, "CommissionBoardroom: Cannot allocate 0");
        require(totalSupply() > 0, "CommissionBoardroom: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        boardHistory.push(newSnapshot);

        dollar.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    /* ========== EXTRA REWARDS ========== */

    function claimPoolRewards() public {
        uint256 _rewardPoolLength = rewardPoolInfo.length;
        for (uint256 _pid = 0; _pid < _rewardPoolLength; ++_pid) {
            _getPoolReward(_pid, msg.sender);
        }
    }

    function getPoolReward(uint256 _pid) external {
        _getPoolReward(_pid, msg.sender);
    }

    function _getPoolReward(uint256 _pid, address _account) internal {
        updateRewardPool(_pid);
        UserInfo storage user = userInfo[_account];
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint256 _userAmount = balanceOf(_account);
        if (_userAmount > 0) {
            uint256 _accRewardPerShare = rewardPool.accRewardPerShare;
            uint256 _pendingReward = _userAmount.mul(_accRewardPerShare).div(1e18).sub(user.rewardDebt[_pid]);
            if (_pendingReward > 0) {
                user.accumulatedEarned[_pid] = user.accumulatedEarned[_pid].add(_pendingReward);
                rewardPool.totalPaidRewards = rewardPool.totalPaidRewards.add(_pendingReward);
                user.rewardDebt[_pid] = _userAmount.mul(_accRewardPerShare).div(1e18);
                uint256 _paidAmount = user.reward[_pid].add(_pendingReward);
                // Safe reward transfer, just in case if rounding error causes pool to not have enough reward amount
                address _rewardToken = rewardPool.rewardToken;
                uint256 _rewardBalance = IERC20(_rewardToken).balanceOf(address(this));
                if (_rewardBalance < _paidAmount) {
                    user.reward[_pid] = _paidAmount; // pending, dont claim yet
                } else {
                    user.reward[_pid] = 0;
                    _safeTokenTransfer(_rewardToken, _account, _paidAmount);
                    emit RewardPoolPaid(_pid, _rewardToken, _account, _paidAmount);
                }
            }
        }
    }

    function _safeTokenTransfer(address _token, address _to, uint256 _amount) internal {
        uint256 _tokenBal = IERC20(_token).balanceOf(address(this));
        if (_amount > _tokenBal) {
            _amount = _tokenBal;
        }
        if (_amount > 0) {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function updateAllRewardPools() public {
        uint256 _rewardPoolLength = rewardPoolInfo.length;
        for (uint256 _pid = 0; _pid < _rewardPoolLength; ++_pid) {
            updateRewardPool(_pid);
        }
    }

    function updateRewardPool(uint256 _pid) public {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint256 _endRewardBlock = rewardPool.endRewardBlock;
        uint256 _endRewardBlockApplicable = block.number > _endRewardBlock ? _endRewardBlock : block.number;
        uint256 _lastRewardBlock = rewardPool.lastRewardBlock;
        if (_endRewardBlockApplicable > _lastRewardBlock) {
            uint256 lpSupply = totalSupply();
            if (lpSupply > 0) {
                uint256 _incRewardPerShare = getRewardPerBlock(_pid, _lastRewardBlock, _endRewardBlockApplicable).mul(1e18).div(lpSupply);
                rewardPool.accRewardPerShare = rewardPool.accRewardPerShare.add(_incRewardPerShare);
            }
            rewardPool.lastRewardBlock = _endRewardBlockApplicable;
        }
    }

    /* ========== EMERGENCY ========== */

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(dollar), "dollar");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }
}
