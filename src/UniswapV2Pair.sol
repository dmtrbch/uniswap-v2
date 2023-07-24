// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.19;

import "solmate/tokens/ERC20.sol";
import "./libraries/Math.sol";

interface IERC20 {
    function balanceOf() external returns (uint256);
}

contract UniswapV2Pair is ERC20, Math {
    uint256 private reserve0;
    uint256 private reserve1;

    function mint() public {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        uint256 liquidity;

        if (totalSupply == 0) {
            //  liquidity = ???
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            //liquidity = ???
        }

        if (liquidity <= 0) revert InsufficientLiquidityMinted();

        _mint(msg.sender, liquidity);

        _update(balance0, balance1);

        emit Mint(msg.sender, amount0, amount1);
    }
}
