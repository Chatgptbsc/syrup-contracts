// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ISrxIou {
    function mint(address account, uint256 amount) external returns (bool);
}
