// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

contract EuroBet is Ownable {
    using SafeMath for uint256;
    using SafeMath for uint8;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    bool public initialized = false;

    address public mdo = address(0x113d0D0F8f31050D382Eb0B9f5f0bedddf8100cb);

    string name;
    uint256 startBettingTime;
    uint256 endBettingTime;
    uint256 numTickets;
    uint8 matchStatus; // 0-NEW 1-FINISH 8-CANCEL/POSTPONE
    address public fund;

    struct BetType { // 3 doors: A WIN, DRAW, B WIN
        string description;
        uint8 numDoors;
        uint32[] odds;
        uint8[] doorResults; // 0-PENDING 1-WIN 2-LOSE 3-WIN-HALF 4-LOSE-HALF
        uint256 numTickets;
        uint256 totalBetAmount;
        uint256 totalPayoutAmount;
        uint256[] doorBetAmount;
        uint256 maxBudget;
        uint8 status; // 0-NEW 1-FINISH 8-CANCEL/POSTPONE
    }

    struct Ticket {
        uint256 index;
        address player;
        uint8 betTypeId;
        uint8 betDoor;
        uint32 betOdd;
        uint256 betAmount;
        uint256 payout;
        uint256 bettingTime;
        uint256 claimedTime;
        uint8 status; // 0-PENDING 1-WIN 2-LOSE 3-WIN-HALF 4-LOSE-HALF 8-REFUND
    }

    struct PlayerStat {
        uint256 totalBet;
        uint256 totalPayout;
    }

    uint256 public standardPrice = 10 ether;
    uint256 public losePayoutRate = 100; // payback even you lose

    BetType[] public matchBetTypes; // 0: 1x2, 1: Handcap, 2: Over/Under
    Ticket[] public tickets; // All tickets of player
    mapping(address => uint256[]) public ticketsOf; // Store all ticket of player: player => ticket_id

    mapping(address => PlayerStat) public playerStats;
    uint256 public totalBetAmount;
    uint256 public totalPayoutAmount;

    mapping(address => bool) public admin;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ...

    /* ========== EVENTS ========== */

    event SetAdminStatus(address account, bool adminStatus);
    event AddMatchInfo(string matchName, uint256 startBettingTime, uint256 endBettingTime);
    event AddBetType(uint8 betTypeId, string betDescription, uint8 numDoors, uint32[] odds, uint256 maxBudget);
    event EditBetTypeOdds(uint8 betTypeId, uint32[] odds);
    event EditBetTypeBudget(uint8 betTypeId, uint256 maxBudget);
    event CancelMatch();
    event SettleMatchResult(uint8 betTypeId, uint8[] doorResults);
    event NewTicket(address player, uint256 ticketIndex, uint8 betTypeId, uint256 betAmount, uint256 bettingTime);
    event DrawTicket(address player, uint256 ticketIndex, uint8 betTypeId, uint256 payout, uint256 claimedTime);

    constructor() public {
    }

    modifier onlyAdmin() {
        require(admin[msg.sender], "!admin");
        _;
    }

    modifier notInitialized() {
        require(!initialized, "initialized");
        _;
    }

    function setAdminStatus(address _account, bool _isAdmin) external onlyOwner {
        admin[_account] = _isAdmin;

        emit SetAdminStatus(_account, _isAdmin);
    }

    function setStandardPrice(uint256 _standardPrice) external onlyOwner {
        require(_standardPrice >= 0.01 ether, "too low");
        standardPrice = _standardPrice;
    }

    function setStartBettingTime(uint256 _startBettingTime) external onlyOwner {
        startBettingTime = _startBettingTime;
    }

    function setEndBettingTime(uint256 _endBettingTime) external onlyOwner {
        endBettingTime = _endBettingTime;
    }

    function setLosePayout(uint256 _losePayoutRate) external onlyOwner {
        require(_losePayoutRate <= 1000, "too high"); // <= 10%
        losePayoutRate = _losePayoutRate;
    }

    function setFund(address _fund) external onlyOwner {
        require(_fund != address(0), "zero");
        fund = _fund;
    }

    function totalNumberOfBets(address _player) public view returns (uint256) {
        return (_player == address(0x0)) ? tickets.length : ticketsOf[_player].length;
    }

    function getMaxBetAmount(uint8 _betTypeId, uint8 _door) public view returns (uint256 _amount) {
        BetType memory betType = matchBetTypes[_betTypeId];
        uint256 _odd = betType.odds[_door];
        return betType.totalBetAmount.add(betType.maxBudget).sub(betType.doorBetAmount[_door].mul(_odd).div(10000)).mul(10000).div(_odd.sub(10000));
    }

    function addMatchInfo(string memory _matchName, uint256 _startBettingTime, uint256 _endBettingTime,
        string memory _betDescription1x2, uint32[] memory _odds1x2,
        string memory _betDescriptionHandicap, uint32[] memory _oddsHandicap,
        string memory _betDescriptionOverUnder, uint32[] memory _oddsOverUnder, uint256[] memory _maxBudgets, address _fund) external notInitialized {
        // // 0: 1x2, 1: Handcap, 2: Over/Under
        require(_startBettingTime < _endBettingTime && now < _endBettingTime, "Invalid _endBettingTime");
        require(_maxBudgets.length == 3, "Invalid _betDescriptions length");
        require(_odds1x2.length == 3, "Invalid _odds1x2 length");
        require(_oddsHandicap.length == 2, "Invalid _oddsHandicap length");
        require(_oddsOverUnder.length == 2, "Invalid _oddsOverUnder length");

        require(_odds1x2[0] > 10000 && _odds1x2[1] > 10000 && _odds1x2[2] > 10000, "_odds1x2 must be greater than x1");
        require(_oddsHandicap[0] > 10000 && _oddsHandicap[1] > 10000, "_oddsHandicap must be greater than x1");
        require(_oddsOverUnder[0] > 10000 && _oddsOverUnder[1] > 10000, "_oddsOverUnder must be greater than x1");

        initialized = true;

        name = _matchName;
        startBettingTime = _startBettingTime;
        endBettingTime = _endBettingTime;
        numTickets = 0;
        matchStatus = 0;
        fund = _fund;

        matchBetTypes.push(
            BetType({
                description: _betDescription1x2,
                numDoors: 3,
                odds: _odds1x2,
                doorResults: new uint8[](3),
                numTickets: 0,
                totalBetAmount: 0,
                totalPayoutAmount: 0,
                doorBetAmount: new uint256[](3),
                maxBudget: _maxBudgets[0],
                status : 0
            })
        );

        matchBetTypes.push(
            BetType({
                description: _betDescriptionHandicap,
                numDoors: 2,
                odds: _oddsHandicap,
                doorResults: new uint8[](2),
                numTickets: 0,
                totalBetAmount: 0,
                totalPayoutAmount: 0,
                doorBetAmount: new uint256[](2),
                maxBudget: _maxBudgets[1],
                status : 0
            })
        );

        matchBetTypes.push(
            BetType({
                description: _betDescriptionOverUnder,
                numDoors: 2,
                odds: _oddsHandicap,
                doorResults: new uint8[](2),
                numTickets: 0,
                totalBetAmount: 0,
                totalPayoutAmount: 0,
                doorBetAmount: new uint256[](2),
                maxBudget: _maxBudgets[2],
                status : 0
            })
        );

        emit AddMatchInfo(_matchName, _startBettingTime, _endBettingTime);
        emit AddBetType(0, _betDescription1x2, 3, _odds1x2, _maxBudgets[0]);
        emit AddBetType(1, _betDescriptionHandicap, 2, _oddsHandicap, _maxBudgets[1]);
        emit AddBetType(2, _betDescriptionOverUnder, 2, _oddsOverUnder, _maxBudgets[2]);
    }

    function editMatchBetTypeOdds(uint8 _betTypeId, uint32[] memory _odds) external onlyAdmin {
        require(now <= endBettingTime, "late");

        BetType storage betType = matchBetTypes[_betTypeId];
        require(betType.odds.length == _odds.length, "Invalid _odds");

        uint256 _numDoors = _odds.length;
        for (uint256 i = 0; i < _numDoors; i++) {
            require(_odds[i] > 10000, "odd must be greater than x1");
        }

        betType.odds = _odds;

        emit EditBetTypeOdds(_betTypeId, _odds);
    }

    function editMatchBetTypeBudget(uint8 _betTypeId, uint256 _maxBudget) external onlyAdmin {
        require(now <= endBettingTime, "late");

        BetType storage betType = matchBetTypes[_betTypeId];
        betType.maxBudget = _maxBudget;

        emit EditBetTypeBudget(_betTypeId, _maxBudget);
    }

    function cancelMatch() external onlyAdmin {
        require(matchStatus == 0, "match is not new"); // 0-NEW 1-FINISH 2-CANCEL/POSTPONE
        matchStatus = 8;

        emit CancelMatch();
    }

    function settleMatchResult(uint8[] memory _doorResults1x2, uint8[] memory _doorResultsHandicap, uint8[] memory _doorResultsOverUnder) external onlyAdmin {
        require(_doorResults1x2.length == 3, "Invalid _doorResults1x2 length");
        require(_doorResultsHandicap.length == 2, "Invalid _doorResultsHandicap length");
        require(_doorResultsOverUnder.length == 2, "Invalid _doorResultsOverUnder length");

        if (msg.sender != owner() || now > endBettingTime.add(48 hours)) { // owner has rights to over-write the match result in 48 hours (in case admin made mistake)
            require(matchStatus == 0, "match is not new"); // 0-NEW 1-FINISH 2-CANCEL/POSTPONE
        }
        matchStatus = 1;

        matchBetTypes[0].doorResults = _doorResults1x2;
        matchBetTypes[1].doorResults = _doorResultsHandicap;
        matchBetTypes[2].doorResults = _doorResultsOverUnder;

        emit SettleMatchResult(0, _doorResults1x2);
        emit SettleMatchResult(1, _doorResultsHandicap);
        emit SettleMatchResult(2, _doorResultsOverUnder);
    }

    function buyTicket(uint8 _betTypeId, uint8 _betDoor, uint32 _betOdd, uint256 _betAmount) public returns (uint256 _ticketIndex) {
        require(_betAmount >= standardPrice, "_betAmount less than standard price");

        uint256 _maxBetAmount = getMaxBetAmount(_betTypeId, _betDoor);
        require(_betAmount <= _maxBetAmount, "_betAmount exceeds _maxBetAmount");

        require(now >= startBettingTime, "early");
        require(now <= endBettingTime, "late");
        require(matchStatus == 0, "match not opened for ticket"); // 0-NEW 1-FINISH 2-CANCEL/POSTPONE

        BetType storage betType = matchBetTypes[_betTypeId];
        require(_betDoor < betType.numDoors, "Invalid _betDoor");
        require(_betOdd == betType.odds[_betDoor], "Invalid _betOdd");

        address _player = msg.sender;
        IERC20(mdo).safeTransferFrom(_player, address(fund), _betAmount);

        _ticketIndex = tickets.length;

        tickets.push(
            Ticket({
                index : _ticketIndex,
                player : _player,
                betTypeId : _betTypeId,
                betDoor : _betDoor,
                betOdd : _betOdd,
                betAmount : _betAmount,
                payout : 0,
                bettingTime : now,
                claimedTime : 0,
                status : 0 // 0-PENDING 1-WIN 2-LOSE 3-REFUND
            })
        );

        numTickets = numTickets.add(1);
        betType.numTickets = betType.numTickets.add(1);
        betType.totalBetAmount = betType.totalBetAmount.add(_betAmount);
        betType.doorBetAmount[_betDoor] = betType.doorBetAmount[_betDoor].add(_betAmount);
        totalBetAmount = totalBetAmount.add(_betAmount);
        ticketsOf[_player].push(_ticketIndex);
        playerStats[_player].totalBet = playerStats[_player].totalBet.add(_betAmount);

        emit NewTicket(_player, _ticketIndex, _betTypeId, _betAmount, now);
    }

    function settleBet(uint256 _ticketIndex) external returns (address _player, uint256 _payout) {
        require(_ticketIndex < tickets.length, "_ticketIndex out of range");
        require(now > endBettingTime, "early");

        Ticket storage ticket = tickets[_ticketIndex];
        require(ticket.status == 0, "ticket settled");

        uint8 _betTypeId = ticket.betTypeId;
        BetType storage betType = matchBetTypes[_betTypeId];

        uint256 _betAmount = ticket.betAmount;
        // Ticket status: 0-PENDING 1-WIN 2-LOSE 3-REFUND
        if (matchStatus == 8) { // CANCEL/POSTPONE
            _payout = _betAmount;
            ticket.status = 8; // REFUND
        } else if (matchStatus == 1) { // FINISH
            uint8 _betDoor = ticket.betDoor;
            uint8 _betDoorResult = betType.doorResults[_betDoor];
            if (_betDoorResult == 1) {
                _payout = _betAmount.mul(uint256(ticket.betOdd)).div(10000);
                ticket.status = 1; // WIN
            } else if (_betDoorResult == 2) {
                _payout = _betAmount.mul(losePayoutRate).div(10000);
                ticket.status = 2; // LOSE
            } else if (_betDoorResult == 3) {
                uint256 _fullAmount = _betAmount.mul(uint256(ticket.betOdd)).div(10000);
                _payout = _betAmount.add(_fullAmount.sub(_betAmount).div(2)); // = BET + (WIN - BET) * 0.5
                ticket.status = 3; // WIN-HALF
            } else if (_betDoorResult == 4) {
                _payout = _betAmount.div(2);
                ticket.status = 4; // LOSE-HALF
            } else {
                revert("no bet door result");
            }
        } else {
            revert("match is not opened for settling");
        }

        _player = ticket.player;
        betType.totalPayoutAmount = betType.totalPayoutAmount.add(_payout);
        totalPayoutAmount = totalPayoutAmount.add(_payout);
        playerStats[_player].totalPayout = playerStats[_player].totalPayout.add(_payout);
        ticket.claimedTime = now;

        if (_payout > 0) {
            IERC20(mdo).safeTransferFrom(address(fund), address(this), _betAmount);
            IERC20(mdo).safeTransfer(_player, _payout);
        }

        emit DrawTicket(_player, _ticketIndex, _betTypeId, _payout, now);
    }

    // This function allows governance to take unsupported tokens out of the contract. This is in an effort to make someone whole, should they seriously mess up.
    // There is no guarantee governance will vote to return these. It also allows for removal of airdropped tokens.
    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOwner {
        _token.safeTransfer(to, amount);
    }
}
