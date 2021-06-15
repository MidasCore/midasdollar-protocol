// SPDX-License-Identifier: MIT

pragma experimental ABIEncoderV2;
pragma solidity 0.6.12;

import "./EuroBet.sol";

contract EuroBetFactory {
    address public governance;
    address public fund;
    mapping(address => bool) private _isBet;

    constructor(address _fund) public {
        require(_fund != address(0), "zero");
        fund = _fund;
        governance = msg.sender;
    }

    modifier onlyGovernance() {
        require(msg.sender == governance, "!governance");
        _;
    }

    function setGovernance(address _governance) external onlyGovernance {
        require(_governance != address(0), "zero");
        governance = _governance;
    }

    function setFund(address _fund) external onlyGovernance {
        require(_fund != address(0), "zero");
        fund = _fund;
    }

    function isEuroBet(address _bet) external view returns (bool) {
        return _isBet[_bet];
    }

    function createEuroBet(string memory _matchName, uint256 _startBettingTime, uint256 _endBettingTime,
        string[] memory _betDescriptions, uint32[] memory _odds1x2, uint32[] memory _oddsHandicap, uint32[] memory _oddsOverUnder, uint256[] memory _maxBudgets) external returns (EuroBet bet) {
        bet = new EuroBet();
        bet.addMatchInfo(_matchName, _startBettingTime, _endBettingTime,
            _betDescriptions[0], _odds1x2, _betDescriptions[1], _oddsHandicap, _betDescriptions[2], _oddsOverUnder,
            _maxBudgets, fund);
        bet.setAdminStatus(msg.sender, true);
        bet.transferOwnership(msg.sender);
        _isBet[address(bet)] = true;
    }

    function governanceRecoverUnsupported(IERC20 _token, address _to, uint256 _amount) external onlyGovernance {
        _token.transfer(_to, _amount);
    }
}
