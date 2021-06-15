// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ICommissionBoardroom {
    function addRewardPool(address _rewardToken, uint256 _startBlock, uint256 _endRewardBlock, uint256 _rewardPerBlock) external;

    function setRewardPool(uint256 _pid, uint256 _endRewardBlock, uint256 _rewardPerBlock) external;

    function governanceRecoverUnsupported(address _token, uint256 _amount, address _to) external;
}
