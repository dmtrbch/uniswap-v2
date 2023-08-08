// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.19;

import {SafeTransferLib, ERC20} from "solmate/mixins/ERC4626.sol";
import "solmate/utils/FixedPointMathLib.sol";
import "solmate/utils/ReentrancyGuard.sol";
// import "./libraries/Math.sol";
// import "./libraries/UQ112x112.sol";
import {IERC3156FlashBorrower, IERC3156FlashLender} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";

error AlreadyInitialized();
error BalanceOverflow();
error InsufficientLiquidityMinted();
error InsufficientLiquidityBurned();
error InsufficientInputAmount();
error InsufficientOutputAmount();
error InsufficientLiquidity();
error InvalidK();
error InsufficientFlashLoanAmount();
error CallbackFailed();

contract UniswapV2Pair is IERC3156FlashLender, ERC20, ReentrancyGuard {
    // using UQ112x112 for uint224;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint128;

    uint256 constant MINIMUM_LIQUIDITY = 1000;

    address public token0;
    address public token1;
    // we need to track pool reserves on our side
    // to avoid price manipulations that can happen
    // if only relying on balanceOf

    // uint112 private reserve0;
    // uint112 private reserve1;
    // uint32 private blockTimestampLast;

    uint128 private reserve0;
    uint128 private reserve1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    uint32 public blockTimestampLast;

    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address to
    );
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Sync(uint256 reserve0, uint256 reserve1);
    event Swap(
        address indexed sender,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    constructor() ERC20("LpTokenATokenB", "LpTKNATKNB", 18) {}

    function initialize(address token0_, address token1_) public {
        // it this check is removed is will be HUGE security vulnerability
        if (token0 != address(0) || token1 != address(0))
            revert AlreadyInitialized();

        token0 = token0_;
        token1 = token1_;
    }

    function mint(address to) public nonReentrant returns (uint256 liquidity) {
        (uint128 reserve0_, uint128 reserve1_) = getReserves();

        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0_;
        uint256 amount1 = balance1 - reserve1_;

        if (totalSupply == 0) {
            // the initial liquidity reserve ratio doesn’t affect the value of a pool share
            // MINIMUM_LIQUIDITY protects from someone making one pool token share
            // (1e-18, 1 wei) too expensive, which would turn away small liquidity providers.
            liquidity =
                FixedPointMathLib.sqrt(amount0 * amount1) -
                MINIMUM_LIQUIDITY;
            // liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // choose the smaller deposited amount of tokens
            // punish for depositing of unbalanced liquidity
            // (liquidity providers would get fewer LP-tokens)

            liquidity = (amount0 * totalSupply) / reserve0_ <
                (amount1 * totalSupply) / reserve1_
                ? (amount0 * totalSupply) / reserve0_
                : (amount1 * totalSupply) / reserve1_;
        }

        if (liquidity <= 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);

        _update(balance0, balance1, reserve0_, reserve1_);

        emit Mint(to, amount0, amount1);
    }

    function burn(
        address to
    ) public nonReentrant returns (uint256 amount0, uint256 amount1) {
        // why don't we use the reserves instead? is it more gas efficient?
        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        // why don't we use the reserves instead?
        // what does it mean: using balances ensures pro-rata distribution?
        /**
            is it possible that someone has transferred amounts of tokenA and/or
            tokenB and it would be more accurate to take the balances into account
            instead of the reserves??
         */
        amount0 = (liquidity * balance0) / totalSupply;
        amount1 = (liquidity * balance1) / totalSupply;

        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);

        ERC20(token0).safeTransfer(to, amount0);
        ERC20(token1).safeTransfer(to, amount1);

        balance0 = ERC20(token0).balanceOf(address(this));
        balance1 = ERC20(token1).balanceOf(address(this));

        (uint128 reserve0_, uint128 reserve1_) = getReserves();
        _update(balance0, balance1, reserve0_, reserve1_);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) public nonReentrant {
        if (amount0Out == 0 && amount1Out == 0)
            revert InsufficientOutputAmount();

        (uint128 reserve0_, uint128 reserve1_) = getReserves();

        if (amount0Out > reserve0_ || amount1Out > reserve1_)
            revert InsufficientLiquidity();

        if (amount0Out > 0) ERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) ERC20(token1).safeTransfer(to, amount1Out);

        //mistake
        //uint256 balance0 = ERC20(token0).balanceOf(address(this)) - amount0Out;
        //uint256 balance1 = ERC20(token1).balanceOf(address(this)) - amount1Out;

        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > reserve0 - amount0Out
            ? balance0 - (reserve0 - amount0Out)
            : 0;

        uint256 amount1In = balance1 > reserve1 - amount1Out
            ? balance1 - (reserve1 - amount1Out)
            : 0;

        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // current balances minus swap fees
        // we have to multiply balances by 1000 and amounts by 3 to “emulate”
        // multiplication of the input amounts by 0.003 (0.3%).
        // why do we need to do this, when we are substracting swap fees in getAmountOut
        // we must do this to check if the 0.3% calculated with getAmount out
        // has indeed been applied
        uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
        uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);

        // uniswap v2 uses safe math here
        if (
            balance0Adjusted * balance1Adjusted <
            uint256(reserve0_) * uint256(reserve1_) * (1000 ** 2)
        ) revert InvalidK();

        _update(balance0, balance1, reserve0_, reserve1_);

        emit Swap(msg.sender, amount0Out, amount1Out, to);
    }

    function sync() public {
        (uint128 reserve0_, uint128 reserve1_) = getReserves();
        _update(
            ERC20(token0).balanceOf(address(this)),
            ERC20(token1).balanceOf(address(this)),
            reserve0_,
            reserve1_
        );
    }

    function getReserves() public view returns (uint128, uint128) {
        return (reserve0, reserve1);
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint128 reserve0_,
        uint128 reserve1_
    ) private {
        // if (balance0 > type(uint112).max || balance1 > type(uint112).max)
        //    revert BalanceOverflow();

        // if (balance0 > type(uint256).max / 1e18 || balance1 > type(uint256).max / 1e18)
        //    revert BalanceOverflow();

        if (balance0 > type(uint128).max || balance1 > type(uint128).max)
            revert BalanceOverflow();

        unchecked {
            uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;

            /*if (timeElapsed > 0 && reserve0_ > 0 && reserve1_ > 0) {
                price0CumulativeLast +=
                    uint256(UQ112x112.encode(reserve1_).uqdiv(reserve0_)) *
                    timeElapsed;
                price1CumulativeLast +=
                    uint256(UQ112x112.encode(reserve0_).uqdiv(reserve1_)) *
                    timeElapsed;
            }*/

            if (timeElapsed > 0 && reserve0_ > 0 && reserve1_ > 0) {
                // * never overflows, and + overflow is desired?? why
                price0CumulativeLast +=
                    reserve1_.divWadDown(reserve0_) *
                    timeElapsed;

                price1CumulativeLast +=
                    reserve0_.divWadDown(reserve1_) *
                    timeElapsed;
            }
        }

        // reserve0 = uint112(balance0);
        // reserve1 = uint112(balance1);
        reserve0 = uint128(balance0);
        reserve1 = uint128(balance1);
        blockTimestampLast = uint32(block.timestamp);

        emit Sync(reserve0, reserve1);
    }

    function maxFlashLoan(address _token) public view returns (uint256) {
        if (_token == token0) return uint256(reserve0);
        else if (_token == token1) return uint256(reserve1);
        else return 0;
    }

    function flashFee(
        address _token,
        uint256 _amount
    ) public view returns (uint256) {
        require(_token == token0 || _token == token1, "Invalid token");

        uint256 fee = (_amount * 1000) / 997 - _amount + 1;
        return fee;
    }

    function flashLoan(
        IERC3156FlashBorrower _receiver,
        address _token,
        uint256 _amount,
        bytes calldata _data
    ) external returns (bool) {
        require(_token == token0 || _token == token1, "Invalid token");

        uint256 fee = flashFee(_token, _amount);
        uint256 balance = ERC20(_token).balanceOf(address(this));

        if (balance < _amount) revert InsufficientFlashLoanAmount();

        ERC20(_token).safeTransfer(address(_receiver), _amount);

        (uint128 reserve0_, uint128 reserve1_) = getReserves();
        if (_token == token0) {
            uint256 balance1 = ERC20(token1).balanceOf(address(this));
            _update(balance + fee, balance1, reserve0_, reserve1_);
        } else {
            uint256 balance0 = ERC20(token0).balanceOf(address(this));
            _update(balance0, balance + fee, reserve0_, reserve1_);
        }

        if (
            _receiver.onFlashLoan(msg.sender, _token, _amount, fee, _data) !=
            keccak256("IERC3156FlashBorrower.onFlashLoan")
        ) revert CallbackFailed();

        ERC20(_token).safeTransferFrom(
            address(_receiver),
            address(this),
            _amount + fee
        );

        return true;
    }
}
