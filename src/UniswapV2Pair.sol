// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.19;

import "solmate/tokens/ERC20.sol";
import "solmate/utils/ReentrancyGuard.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";
import "openzeppelin-contracts/contracts/interfaces/IERC3156FlashLender.sol";

interface IERC20 {
    function balanceOf(address) external returns (uint256);

    function transfer(address to, uint256 amount) external;
}

error AlreadyInitialized();
error BalanceOverflow();
error InsufficientLiquidityMinted();
error InsufficientLiquidityBurned();
error InsufficientInputAmount();
error InsufficientOutputAmount();
error InsufficientLiquidity();
error InvalidK();
error TransferFailed();
error InsufficientFlashLoanAmount();
error InsufficientFlashLoanReturn();
error CallbackFailed();

contract UniswapV2Pair is IERC3156FlashLender, ERC20, ReentrancyGuard, Math {
    using UQ112x112 for uint224;

    uint256 constant MINIMUM_LIQUIDITY = 1000;

    address public token0;
    address public token1;
    // we need to track pool reserves on our side
    // to avoid price manipulations that can happen
    // if only relying on balanceOf
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

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

    function intialize(address token0_, address token1_) public {
        // it this check is removed is will be HUGE security vulnerability
        if (token0 != address(0) || token1 != address(0))
            revert AlreadyInitialized();

        token0 = token0_;
        token1 = token1_;
    }

    function mint(address to) public nonReentrant returns (uint256 liquidity) {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0_;
        uint256 amount1 = balance1 - reserve1_;

        if (totalSupply == 0) {
            // the initial liquidity reserve ratio doesn’t affect the value of a pool share
            // MINIMUM_LIQUIDITY protects from someone making one pool token share
            // (1e-18, 1 wei) too expensive, which would turn away small liquidity providers.
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // choose the smaller deposited amount of tokens
            // punish for depositing of unbalanced liquidity
            // (liquidity providers would get fewer LP-tokens)
            liquidity = Math.min(
                (amount0 * totalSupply) / reserve0_,
                (amount1 * totalSupply) / reserve1_
            );
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
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
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

        _safeTransfer(token0, to, amount0);
        _safeTransfer(token1, to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
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

        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();

        if (amount0Out > reserve0_ || amount1Out > reserve1_)
            revert InsufficientLiquidity();

        if (amount0Out > 0) _safeTransfer(token0, to, amount0Out);
        if (amount1Out > 0) _safeTransfer(token1, to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this)) - amount0Out;
        uint256 balance1 = IERC20(token1).balanceOf(address(this)) - amount1Out;

        uint256 amount0In = balance0 > reserve0 - amount0Out
            ? balance0 - (reserve0 - amount0Out)
            : 0;

        uint256 amount1In = balance1 > reserve1 - amount1Out
            ? balance1 - (reserve1 - amount1Out)
            : 0;

        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        uint256 balance0Adjusted = (balance0 * 1000) - (amount0In * 3);
        uint256 balance1Adjusted = (balance1 * 1000) - (amount1In * 3);

        if (
            balance0Adjusted * balance1Adjusted <
            uint256(reserve0_) * uint256(reserve1_) * (1000 ** 2)
        ) revert InvalidK();

        _update(balance0, balance1, reserve0_, reserve1_);

        emit Swap(msg.sender, amount0Out, amount1Out, to);
    }

    function sync() public {
        (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0_,
            reserve1_
        );
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 reserve0_,
        uint112 reserve1_
    ) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max)
            revert BalanceOverflow();

        unchecked {
            uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;

            if (timeElapsed > 0 && reserve0_ > 0 && reserve1_ > 0) {
                price0CumulativeLast +=
                    uint256(UQ112x112.encode(reserve1_).uqdiv(reserve0_)) *
                    timeElapsed;
                price1CumulativeLast +=
                    uint256(UQ112x112.encode(reserve0_).uqdiv(reserve1_)) *
                    timeElapsed;
            }
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp);

        emit Sync(reserve0, reserve1);
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, value)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }

    function maxFlashLoan(
        address _token
    ) external view override returns (uint256) {
        if (_token == token0) return uint256(reserve0);
        else if (_token == token1) return uint256(reserve1);
        else return 0;
    }

    function flashFee(
        address _token,
        uint256 _amount
    ) public view override returns (uint256) {
        require(_token == token0 || _token == token1, "Invalid token");

        uint256 fee = (_amount * 1000) / 997 - _amount + 1;
        return fee;
    }

    function flashLoan(
        IERC3156FlashBorrower _receiver,
        address _token,
        uint256 _amount,
        bytes calldata _data
    ) external override nonReentrant returns (bool) {
        require(_token == token0 || _token == token1, "Invalid token");

        uint256 fee = flashFee(_token, _amount);
        uint256 balance = IERC20(_token).balanceOf(address(this));

        // this might be unnecessary
        if (balance < _amount) revert InsufficientFlashLoanAmount();

        _safeTransfer(_token, address(_receiver), _amount);

        if (
            _receiver.onFlashLoan(msg.sender, _token, _amount, fee, _data) !=
            keccak256("IERC3156FlashBorrower.onFlashLoan")
        ) revert CallbackFailed();

        uint256 newBalance = IERC20(_token).balanceOf(address(this));

        if (newBalance < balance + fee) revert InsufficientFlashLoanReturn();

        // (uint112 reserve0_, uint112 reserve1_, ) = getReserves();
        // _update(balance0, balance1, reserve0_, reserve1_);

        return true;
    }
}

// TODO: Output amount calculation
