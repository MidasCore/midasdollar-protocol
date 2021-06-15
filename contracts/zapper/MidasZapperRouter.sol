// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";

import "@openzeppelin/contracts-ethereum-package/contracts/Initializable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IValueLiquidRouter.sol";
import "../interfaces/IValueLiquidFormula.sol";
import "../interfaces/IValueLiquidPair.sol";
import "../interfaces/IMigratableToken.sol";

contract MidasZapperRouter is OwnableUpgradeSafe, IERC777Recipient, ReentrancyGuard {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    IERC1820Registry private constant _erc1820 = IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 private constant TOKENS_RECIPIENT_INTERFACE_HASH = keccak256("ERC777TokensRecipient");
    address private constant vswapRouter = address(0xb7e19a1188776f32E8C2B790D9ca578F2896Da7C);

    address public pancakeRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address public bdexRouter = address(0xC6747954a9B3A074d8E4168B444d7F397FeE76AA);
    address public bdexFormula = address(0xCB9f345c32e2216e5F13E1A816059C6435C92038);

    address[] public EMPTY_PATH;

    address public constant MDO_LEGACY = address(0x35e869B7456462b81cdB5e6e42434bD27f3F788c);
    address public constant MDO_V2 = address(0x113d0D0F8f31050D382Eb0B9f5f0bedddf8100cb);

    /* =================== Added variables (need to keep orders for proxy to work) =================== */
    /**

    /* ========== GOVERNANCE ========== */

    function initialize() public initializer {
        OwnableUpgradeSafe.__Ownable_init();

        pancakeRouter = address(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        bdexRouter = address(0xC6747954a9B3A074d8E4168B444d7F397FeE76AA);
        bdexFormula = address(0xCB9f345c32e2216e5F13E1A816059C6435C92038);

        _erc1820.setInterfaceImplementer(address(this), TOKENS_RECIPIENT_INTERFACE_HASH, address(this));
    }

    function setPancakeRouter(address _pancakeRouter) external onlyOwner {
        pancakeRouter = _pancakeRouter;
    }

    function setBdexRouter(address _bdexRouter) external onlyOwner {
        bdexRouter = _bdexRouter;
    }

    function setBdexFormula(address _bdexFormula) external onlyOwner {
        bdexFormula = _bdexFormula;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // type = 0: pancake, 1: bdex, 2: vswap
    function migrateAll(address _oldPair, address _newPair, uint8 _oldPairType, bool _zapping) external {
        migrate(_oldPair, _newPair, IUniswapV2Pair(_oldPair).balanceOf(msg.sender), _oldPairType, _zapping);
    }

    // [Bdex/Vlp or Pancake] -> [Bdex]
    function migrate(address _oldPair, address _newPair, uint256 _amount, uint8 _oldPairType, bool _zapping) public nonReentrant {
        uint32 tokenWeight0;
        uint32 tokenWeight1;
        if (_oldPairType > 0) {
            (tokenWeight0, tokenWeight1) = IValueLiquidPair(_oldPair).getTokenWeights();
            require(tokenWeight0 == 50 && tokenWeight1 == 50, "_oldPair not 50/50");
        }
        (tokenWeight0, tokenWeight1) = IValueLiquidPair(_newPair).getTokenWeights();
        require(tokenWeight0 == 50 && tokenWeight1 == 50, "_newPair not 50/50");
        address _tokenA = IUniswapV2Pair(_oldPair).token0();
        address _tokenB = IUniswapV2Pair(_oldPair).token1();
        if (_tokenA == MDO_LEGACY) {
            _tokenA = MDO_V2;
        } else if (_tokenB == MDO_LEGACY) {
            _tokenB = MDO_V2;
        }
        uint256 _beforeMDOLegacy = IUniswapV2Pair(MDO_LEGACY).balanceOf(address(this));
        uint256 _beforeA = IUniswapV2Pair(_tokenA).balanceOf(address(this));
        uint256 _beforeB = IUniswapV2Pair(_tokenB).balanceOf(address(this));
        if (_oldPairType == 0) {
            _pancakeRemoveLiquidity(_oldPair, _amount, address(this), true);
        } else if (_oldPairType == 1) {
            _bdexRemoveLiquidity(_oldPair, _amount, address(this), true);
        } else {
            _vswapRemoveLiquidity(_oldPair, _amount, address(this), true);
        }
        uint256 _amountMDOLegacy = IUniswapV2Pair(MDO_LEGACY).balanceOf(address(this)).sub(_beforeMDOLegacy);
        if (_amountMDOLegacy > 0) {
            IERC20(MDO_LEGACY).safeIncreaseAllowance(address(MDO_V2), _amountMDOLegacy);
            IMigratableToken(MDO_V2).migrate(_amountMDOLegacy);
        }
        uint256 _amountA = IUniswapV2Pair(_tokenA).balanceOf(address(this)).sub(_beforeA);
        uint256 _amountB = IUniswapV2Pair(_tokenB).balanceOf(address(this)).sub(_beforeB);
        _bdexAddLiquidity(_newPair, _tokenA, _tokenB, _amountA, _amountB, msg.sender, false);
        _amountA = IUniswapV2Pair(_tokenA).balanceOf(address(this)).sub(_beforeA);
        _amountB = IUniswapV2Pair(_tokenB).balanceOf(address(this)).sub(_beforeB);
        if (_zapping) {
            if (_amountA > 0) {
                _bdexSwapToken(_newPair, _tokenA, _tokenB, _amountA.div(2), address(this), false);
                _amountA = IUniswapV2Pair(_tokenA).balanceOf(address(this)).sub(_beforeA);
                _amountB = IUniswapV2Pair(_tokenB).balanceOf(address(this)).sub(_beforeB);
            } else if (_amountB > 0) {
                _bdexSwapToken(_newPair, _tokenB, _tokenA, _amountB.div(2), address(this), false);
                _amountA = IUniswapV2Pair(_tokenA).balanceOf(address(this)).sub(_beforeA);
                _amountB = IUniswapV2Pair(_tokenB).balanceOf(address(this)).sub(_beforeB);
            }
            if (_amountA > 0 && _amountB > 0) {
                _bdexAddLiquidity(_newPair, _tokenA, _tokenB, _amountA, _amountB, msg.sender, false);
                _amountA = IUniswapV2Pair(_tokenA).balanceOf(address(this)).sub(_beforeA);
                _amountB = IUniswapV2Pair(_tokenB).balanceOf(address(this)).sub(_beforeB);
            }
        }
        if (_amountA > 0) IERC20(_tokenA).safeTransfer(msg.sender, _amountA);
        if (_amountB > 0) IERC20(_tokenB).safeTransfer(msg.sender, _amountB);
    }

    function pancakeSwapToken(address[] memory _path, address _inputToken, address _outputToken, uint256 _amount) external nonReentrant {
        _pancakeSwapToken(_path, _inputToken, _outputToken, _amount, msg.sender, true);
    }

    function pancakeAddLiquidity(address _tokenA, address _tokenB, uint256 _amountADesired, uint256 _amountBDesired) external nonReentrant {
        _pancakeAddLiquidity(_tokenA, _tokenB, _amountADesired, _amountBDesired, msg.sender, true);
    }

    function pancakeAddLiquidityMax(address _tokenA, address _tokenB) external nonReentrant {
        _pancakeAddLiquidity(_tokenA, _tokenB, IUniswapV2Pair(_tokenA).balanceOf(msg.sender), IUniswapV2Pair(_tokenB).balanceOf(msg.sender), msg.sender, true);
    }

    function pancakeRemoveLiquidity(address _pair, uint256 _liquidity) external nonReentrant {
        _pancakeRemoveLiquidity(_pair, _liquidity, msg.sender, true);
    }

    function pancakeRemoveLiquidityMax(address _pair) external nonReentrant {
        _pancakeRemoveLiquidity(_pair, IUniswapV2Pair(_pair).balanceOf(msg.sender), msg.sender, true);
    }

    function bdexSwapToken(address _pair, address _inputToken, address _outputToken, uint256 _amount) external nonReentrant {
        _bdexSwapToken(_pair, _inputToken, _outputToken, _amount, msg.sender, true);
    }

    function bdexAddLiquidity(address _pair, address _tokenA, address _tokenB, uint256 _amountADesired, uint256 _amountBDesired) external nonReentrant {
        _bdexAddLiquidity(_pair, _tokenA, _tokenB, _amountADesired, _amountBDesired, msg.sender, true);
    }

    function bdexAddLiquidityMax(address _pair) external nonReentrant {
        address _tokenA = IUniswapV2Pair(_pair).token0();
        address _tokenB = IUniswapV2Pair(_pair).token1();
        _bdexAddLiquidity(_pair, _tokenA, _tokenB, IUniswapV2Pair(_tokenA).balanceOf(msg.sender), IUniswapV2Pair(_tokenB).balanceOf(msg.sender), msg.sender, true);
    }

    function bdexRemoveLiquidity(address _pair, uint256 _liquidity) external nonReentrant {
        _bdexRemoveLiquidity(_pair, _liquidity, msg.sender, true);
    }

    function bdexRemoveLiquidityMax(address _pair) external nonReentrant {
        _bdexRemoveLiquidity(_pair, IUniswapV2Pair(_pair).balanceOf(msg.sender), msg.sender, true);
    }

    /* ========== LIBRARIES ========== */

    function _pancakeSwapToken(address[] memory _path, address _inputToken, address _outputToken, uint256 _amount, address _receiver, bool _pulling) internal {
        if (_amount == 0) return;
        if (_path.length <= 1) {
            _path = new address[](2);
            _path[0] = _inputToken;
            _path[1] = _outputToken;
        }
        IERC20(_inputToken).safeTransferFrom(msg.sender, address(this), _amount);
        if (_pulling) {
            IERC20(_inputToken).safeIncreaseAllowance(address(pancakeRouter), _amount);
        }
        IUniswapV2Router(pancakeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(_amount, 1, _path, _receiver, now.add(60));
    }

    function _pancakeAddLiquidity(address _tokenA, address _tokenB, uint256 _amountADesired, uint256 _amountBDesired, address _receiver, bool _pulling) internal {
        if (_pulling) {
            IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountADesired);
            IERC20(_tokenB).safeTransferFrom(msg.sender, address(this), _amountBDesired);
        }
        IERC20(_tokenA).safeIncreaseAllowance(address(pancakeRouter), _amountADesired);
        IERC20(_tokenB).safeIncreaseAllowance(address(pancakeRouter), _amountBDesired);
        IUniswapV2Router(pancakeRouter).addLiquidity(_tokenA, _tokenB, _amountADesired, _amountBDesired, 1, 1, _receiver, now.add(60));
        uint256 _dustA = IUniswapV2Pair(_tokenA).balanceOf(address(this));
        uint256 _dustB = IUniswapV2Pair(_tokenB).balanceOf(address(this));
        if (_dustA > 0) IERC20(_tokenA).safeTransfer(_receiver, _dustA);
        if (_dustB > 0) IERC20(_tokenB).safeTransfer(_receiver, _dustB);
    }

    function _pancakeRemoveLiquidity(address _pair, uint256 _liquidity, address _receiver, bool _pulling) internal {
        address _tokenA = IUniswapV2Pair(_pair).token0();
        address _tokenB = IUniswapV2Pair(_pair).token1();
        if (_pulling) {
            IERC20(_pair).safeTransferFrom(msg.sender, address(this), _liquidity);
        }
        IERC20(_pair).safeIncreaseAllowance(address(pancakeRouter), _liquidity);
        IUniswapV2Router(pancakeRouter).removeLiquidity(_tokenA, _tokenB, _liquidity, 1, 1, _receiver, now.add(60));
    }

    function _bdexSwapToken(address _pair, address _inputToken, address _outputToken, uint256 _amount, address _receiver, bool _pulling) internal {
        if (_amount == 0) return;
        address[] memory _path = new address[](1);
        _path[0] = _pair;
        if (_pulling) {
            IERC20(_inputToken).safeTransferFrom(msg.sender, address(this), _amount);
        }
        IERC20(_inputToken).safeIncreaseAllowance(address(bdexRouter), _amount);
        IValueLiquidRouter(bdexRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(_inputToken, _outputToken, _amount, 1, _path, _receiver, now.add(60));
    }

    function _bdexAddLiquidity(address _pair, address _tokenA, address _tokenB, uint256 _amountADesired, uint256 _amountBDesired, address _receiver, bool _pulling) internal {
        if (_pulling) {
            IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountADesired);
            IERC20(_tokenB).safeTransferFrom(msg.sender, address(this), _amountBDesired);
        }
        IERC20(_tokenA).safeIncreaseAllowance(address(bdexRouter), _amountADesired);
        IERC20(_tokenB).safeIncreaseAllowance(address(bdexRouter), _amountBDesired);
        IValueLiquidRouter(bdexRouter).addLiquidity(_pair, _tokenA, _tokenB, _amountADesired, _amountBDesired, 0, 0, _receiver, now.add(60));
        uint256 _dustA = IUniswapV2Pair(_tokenA).balanceOf(address(this));
        uint256 _dustB = IUniswapV2Pair(_tokenB).balanceOf(address(this));
        if (_dustA > 0) IERC20(_tokenA).safeTransfer(_receiver, _dustA);
        if (_dustB > 0) IERC20(_tokenB).safeTransfer(_receiver, _dustB);
    }

    function _bdexRemoveLiquidity(address _pair, uint256 _liquidity, address _receiver, bool _pulling) internal {
        address _tokenA = IUniswapV2Pair(_pair).token0();
        address _tokenB = IUniswapV2Pair(_pair).token1();
        if (_pulling) {
            IERC20(_pair).safeTransferFrom(msg.sender, address(this), _liquidity);
        }
        IERC20(_pair).safeIncreaseAllowance(address(bdexRouter), _liquidity);
        IValueLiquidRouter(bdexRouter).removeLiquidity(_pair, _tokenA, _tokenB, _liquidity, 1, 1, _receiver, now.add(60));
    }

    function _vswapRemoveLiquidity(address _pair, uint256 _liquidity, address _receiver, bool _pulling) internal {
        address _tokenA = IUniswapV2Pair(_pair).token0();
        address _tokenB = IUniswapV2Pair(_pair).token1();
        if (_pulling) {
            IERC20(_pair).safeTransferFrom(msg.sender, address(this), _liquidity);
        }
        IERC20(_pair).safeIncreaseAllowance(address(vswapRouter), _liquidity);
        IValueLiquidRouter(vswapRouter).removeLiquidity(_pair, _tokenA, _tokenB, _liquidity, 1, 1, _receiver, now.add(60));
    }

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

    function pancakeExchangeRate(address _inputToken, address _outputToken, uint256 _tokenAmount) public view returns (uint256) {
        address[] memory _path = new address[](2);
        _path[0] = _inputToken;
        _path[1] = _outputToken;
        uint256[] memory amounts = IUniswapV2Router(pancakeRouter).getAmountsOut(_tokenAmount, _path);
        return amounts[amounts.length - 1];
    }

    function bdexExchangeRate(address _pair, address _inputToken, address _outputToken, uint256 _tokenAmount) public view returns (uint256) {
        address[] memory _path = new address[](1);
        _path[0] = _pair;
        uint256[] memory amounts = IValueLiquidFormula(bdexFormula).getAmountsOut(_inputToken, _outputToken, _tokenAmount, _path);
        return amounts[amounts.length - 1];
    }

    function pancake2BdexRate(address _pair, address _inputToken, address _outputToken, uint256 _tokenAmount) public view returns (uint256) {
        uint256 _gtPancakeRate = pancakeExchangeRate(_inputToken, _outputToken, _tokenAmount);
        uint256 _gtBdexRate = bdexExchangeRate(_pair, _outputToken, _inputToken, _gtPancakeRate);
        return _gtBdexRate;
    }

    function bdex2PancakeRate(address _pair, address _inputToken, address _outputToken, uint256 _tokenAmount) public view returns (uint256) {
        uint256 _gtBdexRate = bdexExchangeRate(_pair, _inputToken, _outputToken, _tokenAmount);
        uint256 _gtPancakeRate = pancakeExchangeRate(_outputToken, _inputToken, _gtBdexRate);
        return _gtPancakeRate;
    }

    function arbitrageBetweenBdexAndPancake(address _pair, address _inputToken, address _outputToken, uint256 _tokenAmount, bool forced) external returns (uint256 _profit) {
        uint256 _gtP2BRate = pancake2BdexRate(_pair, _inputToken, _outputToken, _tokenAmount);
        uint256 _gtB2PRate = bdex2PancakeRate(_pair, _inputToken, _outputToken, _tokenAmount);
        if (_gtP2BRate >= _gtB2PRate) {
            if (_gtP2BRate > _tokenAmount || forced) {
                uint256 _beforeOutput = IUniswapV2Pair(_outputToken).balanceOf(address(this));
                _pancakeSwapToken(EMPTY_PATH, _inputToken, _outputToken, _tokenAmount, address(this), true);
                uint256 _amountOutput = IUniswapV2Pair(_outputToken).balanceOf(address(this)).sub(_beforeOutput);
                _bdexSwapToken(_pair, _outputToken, _inputToken, _amountOutput, msg.sender, false);
                if (!forced) _profit = _gtP2BRate.sub(_tokenAmount);
            }
        } else {
            if (_gtB2PRate > _tokenAmount || forced) {
                uint256 _beforeOutput = IUniswapV2Pair(_outputToken).balanceOf(address(this));
                _bdexSwapToken(_pair, _inputToken, _outputToken, _tokenAmount, address(this), true);
                uint256 _amountOutput = IUniswapV2Pair(_outputToken).balanceOf(address(this)).sub(_beforeOutput);
                _pancakeSwapToken(EMPTY_PATH, _outputToken, _inputToken, _amountOutput, msg.sender, false);
                if (!forced) _profit = _gtP2BRate.sub(_tokenAmount);
            }
        }
    }

    function bdexAmongRate(address _pairAB, address _pairBC, address _pairCA, address _tokenA, address _tokenB, address _tokenC, uint256 _tokenAmountA) public view returns (uint256) {
        uint256 _amountB = bdexExchangeRate(_pairAB, _tokenA, _tokenB, _tokenAmountA);
        uint256 _amountC = bdexExchangeRate(_pairBC, _tokenB, _tokenC, _amountB);
        uint256 _outputAmountA = bdexExchangeRate(_pairCA, _tokenC, _tokenA, _amountC);
        return _outputAmountA;
    }

    // A -> B -> C -> A
    function arbitrageAmongBdex(address _pairAB, address _pairBC, address _pairCA, address _tokenA, address _tokenB, address _tokenC, uint256 _tokenAmountA, bool forced) external returns (uint256 _profit) {
        uint256 _outputAmountA = bdexAmongRate(_pairAB, _pairBC, _pairCA, _tokenA, _tokenB, _tokenC, _tokenAmountA);
        if (_outputAmountA > _tokenAmountA || forced) {
            uint256 _beforeB = IUniswapV2Pair(_tokenB).balanceOf(address(this));
            _bdexSwapToken(_pairAB, _tokenA, _tokenB, _tokenAmountA, address(this), true);
            uint256 _amountB = IUniswapV2Pair(_tokenB).balanceOf(address(this)).sub(_beforeB);
            uint256 _beforeC = IUniswapV2Pair(_tokenC).balanceOf(address(this));
            _bdexSwapToken(_pairBC, _tokenB, _tokenC, _amountB, address(this), false);
            uint256 _amountC = IUniswapV2Pair(_tokenC).balanceOf(address(this)).sub(_beforeC);
            _bdexSwapToken(_pairCA, _tokenC, _tokenA, _amountC, msg.sender, false);
            if (!forced) _profit = _outputAmountA.sub(_tokenAmountA);
        }
    }

    function tokensReceived(address operator, address from, address to, uint256 amount, bytes calldata userData, bytes calldata operatorData) external override {
    }

    /* ========== EMERGENCY ========== */

    function skim(address _token) external {
        IERC20(_token).safeTransfer(owner(), IERC20(_token).balanceOf(address(this)));
    }

    event ExecuteTransaction(address indexed target, uint256 value, string signature, bytes data);

    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data) public onlyOwner returns (bytes memory) {
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