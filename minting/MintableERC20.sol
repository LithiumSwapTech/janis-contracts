// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (token/ERC20/ERC20.sol)
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../libraries/BoringOwnable.sol";

contract MintableERC20 is ERC20, BoringOwnable {

    uint8 public immutable decimalsToUse;

    mapping(address => bool) public operators;

    event OperatorUpdated(address indexed operator, bool indexed status);

    modifier onlyOperatorOrOwner {
        require(owner == msg.sender || operators[msg.sender], "Operator: caller is not the operator");
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        decimalsToUse = decimals_;

        operators[msg.sender] = true;
    } 

    function mint(address account, uint256 amount) external onlyOperatorOrOwner {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external onlyOperatorOrOwner {
        _burn(account, amount);
    }

    function decimals() public view override returns (uint8){
        return decimalsToUse;
    }

    // Update the status of the operator
    function updateOperator(address _operator, bool _status) external onlyOwner {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }
}