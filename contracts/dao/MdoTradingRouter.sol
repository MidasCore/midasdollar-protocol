// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IValueLiquidRouter.sol";

contract MdoTradingRouter {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public operator;
    bool public initialized = false;

    address[] public EMPTY_PATH;

    address public constant mdo = address(0x35e869B7456462b81cdB5e6e42434bD27f3F788c);
    address public constant mds = address(0x242E46490397ACCa94ED930F2C4EdF16250237fa);
    address public constant mdb = address(0xCaD2109CC2816D47a796cB7a0B57988EC7611541);

    address public constant busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address public constant usdt = address(0x55d398326f99059fF775485246999027B3197955);
    address public constant wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    address public constant mdoBusdPancakePool = address(0xD65F81878517039E39c359434d8D8bD46CC4531F);
    address public constant mdoUsdtPancakePool = address(0xd245BDb115707730136F0459e2aa9b0b19023724);

    address public pancakeRouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address public vswapRouter = address(0xb7e19a1188776f32E8C2B790D9ca578F2896Da7C);

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    // ...

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "!operator");
        _;
    }

    modifier notInitialized() {
        require(!initialized, "initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize() public notInitialized {
        pancakeRouter = address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
        vswapRouter = address(0xb7e19a1188776f32E8C2B790D9ca578F2896Da7C);
        initialized = true;
        operator = msg.sender;
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function pancakeSwapToken(address[] memory _path, address _inputToken, address _outputToken, uint256 _amount) public {
        if (_amount == 0) return;
        if (_path.length <= 1) {
            _path = new address[](2);
            _path[0] = _inputToken;
            _path[1] = _outputToken;
        }
        IERC20(_inputToken).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(_inputToken).safeIncreaseAllowance(address(pancakeRouter), _amount);
        IUniswapV2Router(pancakeRouter).swapExactTokensForTokens(_amount, 1, _path, msg.sender, now.add(1800));
    }

    function pancakeAddLiquidity(address _tokenA, address _tokenB, uint256 _amountADesired, uint256 _amountBDesired) public {
        IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountADesired);
        IERC20(_tokenB).safeTransferFrom(msg.sender, address(this), _amountBDesired);
        IERC20(_tokenA).safeIncreaseAllowance(address(pancakeRouter), _amountADesired);
        IERC20(_tokenB).safeIncreaseAllowance(address(pancakeRouter), _amountBDesired);
        IUniswapV2Router(pancakeRouter).addLiquidity(_tokenA, _tokenB, _amountADesired, _amountBDesired, 1, 1, msg.sender, now.add(1800));
        uint256 _dustA = IERC20(_tokenA).balanceOf(address(this));
        uint256 _dustB = IERC20(_tokenB).balanceOf(address(this));
        if (_dustA > 0) IERC20(_tokenA).safeTransfer(msg.sender, _dustA);
        if (_dustB > 0) IERC20(_tokenB).safeTransfer(msg.sender, _dustB);
    }

    function pancakeRemoveLiquidity(address _pair, uint256 _liquidity) public {
        address _tokenA = IUniswapV2Pair(_pair).token0();
        address _tokenB = IUniswapV2Pair(_pair).token1();
        IERC20(_pair).safeTransferFrom(msg.sender, address(this), _liquidity);
        IERC20(_pair).safeIncreaseAllowance(address(pancakeRouter), _liquidity);
        IUniswapV2Router(pancakeRouter).removeLiquidity(_tokenA, _tokenB, _liquidity, 1, 1, msg.sender, now.add(1800));
    }

    function vswapSwapToken(address _pair, address _inputToken, address _outputToken, uint256 _amount) public {
        if (_amount == 0) return;
        address[] memory _paths = new address[](1);
        _paths[0] = _pair;
        IERC20(_inputToken).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(_inputToken).safeIncreaseAllowance(address(vswapRouter), _amount);
        IValueLiquidRouter(vswapRouter).swapExactTokensForTokens(_inputToken, _outputToken, _amount, 1, _paths, msg.sender, now.add(1800));
    }

    function vswapAddLiquidity(address _pair, address _tokenA, address _tokenB, uint256 _amountADesired, uint256 _amountBDesired) public {
        IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountADesired);
        IERC20(_tokenB).safeTransferFrom(msg.sender, address(this), _amountBDesired);
        IERC20(_tokenA).safeIncreaseAllowance(address(vswapRouter), _amountADesired);
        IERC20(_tokenB).safeIncreaseAllowance(address(vswapRouter), _amountBDesired);
        IValueLiquidRouter(vswapRouter).addLiquidity(_pair, _tokenA, _tokenB, _amountADesired, _amountBDesired, 0, 0, msg.sender, now.add(1800));
        uint256 _dustA = IERC20(_tokenA).balanceOf(address(this));
        uint256 _dustB = IERC20(_tokenB).balanceOf(address(this));
        if (_dustA > 0) IERC20(_tokenA).safeTransfer(msg.sender, _dustA);
        if (_dustB > 0) IERC20(_tokenB).safeTransfer(msg.sender, _dustB);
    }

    function vswapRemoveLiquidity(address _pair, uint256 _liquidity) public {
        address _tokenA = IUniswapV2Pair(_pair).token0();
        address _tokenB = IUniswapV2Pair(_pair).token1();
        IERC20(_pair).safeTransferFrom(msg.sender, address(this), _liquidity);
        IERC20(_pair).safeIncreaseAllowance(address(vswapRouter), _liquidity);
        IValueLiquidRouter(vswapRouter).removeLiquidity(_pair, _tokenA, _tokenB, _liquidity, 1, 1, msg.sender, now.add(1800));
    }

    function buyMDO(address _inputToken, uint256 _amount) public {
        address[] memory _path = new address[](2);
        _path[0] = _inputToken;
        _path[1] = mdo;
        pancakeSwapToken(_path, _inputToken, mdo, _amount);
    }

    function concurrentBuyMdo(uint256 _busdAmountToBuy) external {
        (uint256 _busdLpRes, ) = getReserves(mdo, busd, mdoBusdPancakePool);
        (uint256 _usdtLpRes, ) = getReserves(mdo, usdt, mdoUsdtPancakePool);
        uint256 _totalRes = _busdLpRes.add(_usdtLpRes);

        uint256 _busdAmount = _busdAmountToBuy.mul(_busdLpRes).div(_totalRes);
        uint256 _usdtAmount = _busdAmountToBuy.mul(_usdtLpRes).div(_totalRes);

        buyMDO(busd, _busdAmount);
        buyMDO(usdt, _usdtAmount);
    }

    /* ========== LIBRARIES ========== */

    function getReserves(address tokenA, address tokenB, address pair) public view returns (uint256 _reserveA, uint256 _reserveB) {
        address _token0 = IUniswapV2Pair(pair).token0();
        address _token1 = IUniswapV2Pair(pair).token1();
        (uint112 _reserve0, uint112 _reserve1, ) = IUniswapV2Pair(pair).getReserves();
        if (_token0 == tokenA) {
            if (_token1 == tokenB) {
                _reserveA = uint256(_reserve0);
                _reserveB = uint256(_reserve1);
            }
        } else if (_token0 == tokenB) {
            if (_token1 == tokenA) {
                _reserveA = uint256(_reserve1);
                _reserveB = uint256(_reserve0);
            }
        }
    }

    function getRatio(address tokenA, address tokenB, address pair) public view returns (uint256 _ratioAoB) {
        (uint256 _reserveA, uint256 _reserveB) = getReserves(tokenA, tokenB, pair);
        if (_reserveA > 0 && _reserveB > 0) {
            _ratioAoB = _reserveA.mul(1e18).div(_reserveB);
        }
    }

    /* ========== EMERGENCY ========== */

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        _token.safeTransfer(_to, _amount);
    }

    event ExecuteTransaction(address indexed target, uint256 value, string signature, bytes data);

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data) public onlyOperator returns (bytes memory) {
        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        // solium-disable-next-line security/no-call-value
        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        require(success, string("CommunityFund::executeTransaction: Transaction execution reverted."));

        emit ExecuteTransaction(target, value, signature, data);

        return returnData;
    }

    receive() external payable {}
}
