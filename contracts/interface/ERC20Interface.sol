// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ERC20Interface {
  function balanceOf(address user) external view returns (uint256);
}