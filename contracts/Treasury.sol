// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";
import "./interfaces/ICommissionBoardroom.sol";
import "./interfaces/ITreasury.sol";

/**
 * @title Basis Dollar Treasury contract
 * @notice Monetary policy logic to adjust supplies of basis dollar assets
 * @author Summer Smith & Rick Sanchez
 */
contract Treasury is ContractGuard, ITreasury {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public migrated = false;
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public lastEpochTime;
    uint256 private _epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public dollar = address(0x35e869B7456462b81cdB5e6e42434bD27f3F788c);
    address public share = address(0x242E46490397ACCa94ED930F2C4EdF16250237fa);
    address public bond = address(0xCaD2109CC2816D47a796cB7a0B57988EC7611541);

    address public boardroom;
    address public dollarOracle;

    // price
    uint256 public dollarPriceOne;
    uint256 public dollarPriceCeiling;

    uint256 public seigniorageSaved;

    // protocol parameters - https://github.com/MidasCore/midasdollar-protocol/tree/master/docs/ProtocolParameters.md
    uint256 public maxSupplyExpansionPercent;
    uint256 public maxSupplyExpansionPercentInDebtPhase;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDeptRatioPercent;

    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    uint256 public previousEpochDollarPrice;
    uint256 public allocateSeigniorageSalary;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra MDO during dept phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public miVaultsFund;
    uint256 public miVaultsFundSharedPercent;
    address public marketingFund;
    uint256 public marketingFundSharedPercent;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    address public commissionBoardroom;
    uint256 public commissionBoardroomSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event Migration(address indexed target);
    event RedeemedBonds(address indexed from, uint256 dollarAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 dollarAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event CommissionBoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event MiVaultsFundFunded(uint256 timestamp, uint256 seigniorage);
    event MarketingFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition {
        require(!migrated, "Treasury: migrated");
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        uint256 _nextEpochPoint = nextEpochPoint();
        require(now >= _nextEpochPoint, "Treasury: not opened yet");

        _;

        lastEpochTime = _nextEpochPoint;
        _epoch = _epoch.add(1);
        epochSupplyContractionLeft = (getDollarPrice() > dollarPriceCeiling) ? 0 : IERC20(dollar).totalSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(dollar).operator() == address(this) &&
                IBasisAsset(bond).operator() == address(this) &&
                IBasisAsset(share).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    // flags
    function isMigrated() public view returns (bool) {
        return migrated;
    }

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function epoch() public override view returns (uint256) {
        return _epoch;
    }

    function nextEpochPoint() public override view returns (uint256) {
        return lastEpochTime.add(nextEpochLength());
    }

    function nextEpochLength() public override view returns (uint256 _length) {
        if (_epoch <= bootstrapEpochs) {
            // 21 first epochs with 8h long
            _length = 8 hours;
        } else {
            uint256 dollarPrice = getDollarPrice();
            _length = (dollarPrice > dollarPriceCeiling) ? 8 hours : 6 hours;
        }
    }

    // oracle
    function getDollarPrice() public override view returns (uint256 dollarPrice) {
        try IOracle(dollarOracle).consult(dollar, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult dollar price from the oracle");
        }
    }

    function getDollarUpdatedPrice() public view returns (uint256 _dollarPrice) {
        try IOracle(dollarOracle).twap(dollar, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult dollar price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableDollarLeft() public view returns (uint256 _burnableDollarLeft) {
        uint256  _dollarPrice = getDollarPrice();
        if (_dollarPrice <= dollarPriceOne) {
            uint256 _dollarSupply = IERC20(dollar).totalSupply();
            uint256 _bondMaxSupply = _dollarSupply.mul(maxDeptRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableDollar = _maxMintableBond.mul(_dollarPrice).div(1e18);
                _burnableDollarLeft = Math.min(epochSupplyContractionLeft, _maxBurnableDollar);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256  _dollarPrice = getDollarPrice();
        if (_dollarPrice > dollarPriceCeiling) {
            uint256 _totalDollar = IERC20(dollar).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalDollar.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _dollarPrice = getDollarPrice();
        if (_dollarPrice <= dollarPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = dollarPriceOne;
            } else {
                uint256 _bondAmount = dollarPriceOne.mul(1e18).div(_dollarPrice); // to burn 1 dollar
                uint256 _discountAmount = _bondAmount.sub(dollarPriceOne).mul(discountPercent).div(10000);
                _rate = dollarPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _dollarPrice = getDollarPrice();
        if (_dollarPrice > dollarPriceCeiling) {
            if (premiumPercent == 0) {
                // no premium bonus
                _rate = dollarPriceOne;
            } else {
                uint256 _premiumAmount = _dollarPrice.sub(dollarPriceOne).mul(premiumPercent).div(10000);
                _rate = dollarPriceOne.add(_premiumAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _dollar,
        address _bond,
        address _share,
        uint256 _startTime
    ) public notInitialized {
        dollar = _dollar;
        bond = _bond;
        share = _share;
        startTime = _startTime;
        lastEpochTime = _startTime.sub(8 hours);

        dollarPriceOne = 10**18;
        dollarPriceCeiling = dollarPriceOne.mul(101).div(100);

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion
        maxSupplyExpansionPercentInDebtPhase = 600; // Upto 4.5% supply for expansion in debt phase (to pay debt faster)
        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 5000; // At least 50% of expansion reserved for boardroom
        maxSupplyContractionPercent = 400; // Upto 4.0% supply for contraction (to burn MDO and mint MDB)
        maxDeptRatioPercent = 5000; // Upto 50% supply of MDB to purchase

        // First 21 epochs with 4.0% expansion
        bootstrapEpochs = 21;
        bootstrapSupplyExpansionPercent = 400;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(dollar).balanceOf(address(this));

        allocateSeigniorageSalary = 1 ether; // 1 MDO salary for calling allocateSeigniorage

        maxDiscountRate = 13e17; // 30% - when purchasing bond
        maxPremiumRate = 13e17; // 30% - when redeeming bond

        discountPercent = 0; // no discount
        premiumPercent = 6500; // 65% premium

        mintingFactorForPayingDebt = 10000; // 100%

        daoFundSharedPercent = 2500; // 25% toward Midas DAO Fund
        miVaultsFundSharedPercent = 0;
        marketingFundSharedPercent = 0;

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function resetStartTime(uint256 _startTime) external onlyOperator {
        require(_epoch == 0, "already started");
        startTime = _startTime;
        lastEpochTime = _startTime.sub(8 hours);
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setDollarOracle(address _dollarOracle) external onlyOperator {
        dollarOracle = _dollarOracle;
    }

    function setDollarPriceCeiling(uint256 _dollarPriceCeiling) external onlyOperator {
        require(_dollarPriceCeiling >= dollarPriceOne && _dollarPriceCeiling <= dollarPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        dollarPriceCeiling = _dollarPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent, uint256 _maxSupplyExpansionPercentInDebtPhase) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        require(_maxSupplyExpansionPercentInDebtPhase >= 10 && _maxSupplyExpansionPercentInDebtPhase <= 1500, "_maxSupplyExpansionPercentInDebtPhase: out of range"); // [0.1%, 15%]
        require(_maxSupplyExpansionPercent <= _maxSupplyExpansionPercentInDebtPhase, "_maxSupplyExpansionPercent is over _maxSupplyExpansionPercentInDebtPhase");
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
        maxSupplyExpansionPercentInDebtPhase = _maxSupplyExpansionPercentInDebtPhase;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDeptRatioPercent(uint256 _maxDeptRatioPercent) external onlyOperator {
        require(_maxDeptRatioPercent >= 1000 && _maxDeptRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDeptRatioPercent = _maxDeptRatioPercent;
    }

    function setBootstrapParams(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 90, "_bootstrapSupplyExpansionPercent: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(address _daoFund, uint256 _daoFundSharedPercent,
        address _miVaultsFund, uint256 _miVaultsFundSharedPercent,
        address _marketingFund, uint256 _marketingFundSharedPercent,
        address _commissionBoardroom, uint256 _commissionBoardroomSharedPercent) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_miVaultsFund != address(0) || _miVaultsFundSharedPercent == 0, "zero");
        require(_miVaultsFundSharedPercent <= 1000, "out of range"); // <= 10%
        require(_marketingFund != address(0) || _marketingFundSharedPercent == 0, "zero");
        require(_marketingFundSharedPercent <= 1000, "out of range"); // <= 10%
        require(_commissionBoardroom != address(0) || _commissionBoardroomSharedPercent == 0, "zero");
        require(_commissionBoardroomSharedPercent <= 2000, "out of range"); // <= 20%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        miVaultsFund = _miVaultsFund;
        miVaultsFundSharedPercent = _miVaultsFundSharedPercent;
        marketingFund = _marketingFund;
        marketingFundSharedPercent = _marketingFundSharedPercent;
        commissionBoardroom = _commissionBoardroom;
        commissionBoardroomSharedPercent = _commissionBoardroomSharedPercent;
    }

    function setAllocateSeigniorageSalary(uint256 _allocateSeigniorageSalary) external onlyOperator {
        require(_allocateSeigniorageSalary <= 100 ether, "Treasury: dont pay too much");
        allocateSeigniorageSalary = _allocateSeigniorageSalary;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    function migrate(address target) external onlyOperator checkOperator {
        require(!migrated, "Treasury: migrated");

        // dollar
        Operator(dollar).transferOperator(target);
        Operator(dollar).transferOwnership(target);
        IERC20(dollar).transfer(target, IERC20(dollar).balanceOf(address(this)));

        // bond
        Operator(bond).transferOperator(target);
        Operator(bond).transferOwnership(target);
        IERC20(bond).transfer(target, IERC20(bond).balanceOf(address(this)));

        // share
        Operator(share).transferOperator(target);
        Operator(share).transferOwnership(target);
        IERC20(share).transfer(target, IERC20(share).balanceOf(address(this)));

        migrated = true;
        emit Migration(target);
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateDollarPrice() internal {
        try IOracle(dollarOracle).update() {} catch {}
    }

    function buyBonds(uint256 _dollarAmount, uint256 targetPrice) external override onlyOneBlock checkCondition checkOperator {
        require(_epoch >= bootstrapEpochs, "Treasury: still in boostrap");
        require(_dollarAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, "Treasury: dollar price moved");
        require(
            dollarPrice < dollarPriceOne, // price < $1
            "Treasury: dollarPrice not eligible for bond purchase"
        );

        require(_dollarAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _dollarAmount.mul(_rate).div(1e18);
        uint256 dollarSupply = IERC20(dollar).totalSupply();
        uint256 newBondSupply = IERC20(bond).totalSupply().add(_bondAmount);
        require(newBondSupply <= dollarSupply.mul(maxDeptRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(dollar).burnFrom(msg.sender, _dollarAmount);
        IBasisAsset(bond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_dollarAmount);
        _updateDollarPrice();

        emit BoughtBonds(msg.sender, _dollarAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external override onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 dollarPrice = getDollarPrice();
        require(dollarPrice == targetPrice, "Treasury: dollar price moved");
        require(
            dollarPrice > dollarPriceCeiling, // price > $1.01
            "Treasury: dollarPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _dollarAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(dollar).balanceOf(address(this)) >= _dollarAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _dollarAmount));

        IBasisAsset(bond).burnFrom(msg.sender, _bondAmount);
        IERC20(dollar).safeTransfer(msg.sender, _dollarAmount);

        _updateDollarPrice();

        emit RedeemedBonds(msg.sender, _dollarAmount, _bondAmount);
    }

    function _sendToBoardRoom(uint256 _amount) internal {
        IBasisAsset(dollar).mint(address(this), _amount);
        if (daoFundSharedPercent > 0) {
            uint256 _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(dollar).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
            _amount = _amount.sub(_daoFundSharedAmount);
        }
        if (miVaultsFundSharedPercent > 0) {
            uint256 _miVaultsFundSharedAmount = _amount.mul(miVaultsFundSharedPercent).div(10000);
            IERC20(dollar).transfer(miVaultsFund, _miVaultsFundSharedAmount);
            emit MiVaultsFundFunded(now, _miVaultsFundSharedAmount);
            _amount = _amount.sub(_miVaultsFundSharedAmount);
        }
        if (marketingFundSharedPercent > 0) {
            uint256 _marketingSharedAmount = _amount.mul(marketingFundSharedPercent).div(10000);
            IERC20(dollar).transfer(marketingFund, _marketingSharedAmount);
            emit MarketingFundFunded(now, _marketingSharedAmount);
            _amount = _amount.sub(_marketingSharedAmount);
        }
        if (commissionBoardroomSharedPercent > 0) {
            uint256 _commissionBoardroomSharedAmount = _amount.mul(commissionBoardroomSharedPercent).div(10000);
            IERC20(dollar).safeIncreaseAllowance(commissionBoardroom, _commissionBoardroomSharedAmount);
            IBoardroom(commissionBoardroom).allocateSeigniorage(_commissionBoardroomSharedAmount);
            emit CommissionBoardroomFunded(now, _commissionBoardroomSharedAmount);
            _amount = _amount.sub(_commissionBoardroomSharedAmount);
        }
        IERC20(dollar).safeIncreaseAllowance(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateDollarPrice();
        previousEpochDollarPrice = getDollarPrice();
        uint256 dollarSupply = IERC20(dollar).totalSupply().sub(seigniorageSaved);
        if (_epoch < bootstrapEpochs) {// 21 first epochs with 4.0% expansion
            _sendToBoardRoom(dollarSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochDollarPrice > dollarPriceCeiling) {
                // Expansion ($MDO Price > 1$): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bond).totalSupply();
                uint256 _percentage = previousEpochDollarPrice.sub(dollarPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardRoom;
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {// saved enough to pay dept, mint as usual rate
                    uint256 _mse = maxSupplyExpansionPercent.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    _savedForBoardRoom = dollarSupply.mul(_percentage).div(1e18);
                } else {// have not saved enough to pay dept, mint more
                    uint256 _mse = maxSupplyExpansionPercentInDebtPhase.mul(1e14);
                    if (_percentage > _mse) {
                        _percentage = _mse;
                    }
                    uint256 _seigniorage = dollarSupply.mul(_percentage).div(1e18);
                    _savedForBoardRoom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardRoom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardRoom > 0) {
                    _sendToBoardRoom(_savedForBoardRoom);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(dollar).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
        if (allocateSeigniorageSalary > 0) {
            IBasisAsset(dollar).mint(address(msg.sender), allocateSeigniorageSalary);
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(dollar), "dollar");
        require(address(_token) != address(bond), "bond");
        require(address(_token) != address(share), "share");
        _token.safeTransfer(_to, _amount);
    }

    /* ========== BOARDROOM CONTROLLING FUNCTIONS ========== */

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(address _token, uint256 _amount, address _to) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }

    /* ========== COMMISSION BOARDROOM CONTROLLING FUNCTIONS ========== */

    function commissionBoardroomAddRewardPool(address _rewardToken, uint256 _startBlock, uint256 _endRewardBlock, uint256 _rewardPerBlock) external onlyOperator {
        ICommissionBoardroom(commissionBoardroom).addRewardPool(_rewardToken, _startBlock, _endRewardBlock, _rewardPerBlock);
    }

    function commissionBoardroomSetRewardPool(uint256 _pid, uint256 _endRewardBlock, uint256 _rewardPerBlock) external onlyOperator {
        ICommissionBoardroom(commissionBoardroom).setRewardPool(_pid, _endRewardBlock, _rewardPerBlock);
    }

    function commissionBoardroomGovernanceRecoverUnsupported(address _token, uint256 _amount, address _to) external onlyOperator {
        ICommissionBoardroom(commissionBoardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
