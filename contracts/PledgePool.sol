// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./library/SafeMath.sol";
import "./library/SafeTransfer.sol";

contract PledgePool is SafeTransfer {
    constructor(){

    }

    using SafeMath for uint256;

    // 借贷费用
    uint256 public lendFee;
    // 质押费用
    uint256 public borrowFee;
    // 交换路由地址
    address public swapRouter;
    // 手续费接收地址
    address public feeAddress;
    // 最小金额
    uint256 public minAmount = 100e18;

    enum PoolState{MATCH, EXECUTION, FINISH, LIQUIDATION, UNDONE}
    PoolState constant defaultChoice = PoolState.MATCH;

    // 质押池基本信息
    struct PoolBaseInfo {
        uint256 settleTime;// 结算时间
        uint256 endTime;// 结束时间
        uint256 interestRate;// 池的固定利率，单位是1e8 (1e8)
        uint256 maxSupply;// 最大供应量, 池的最大限额
        uint256 lendSupply;// 当前供应量
        uint256 martgageRate;// 池的抵押率，单位是1e8 (1e8)
        address lendToken;// 借贷代币地址 借款方代币地址 (比如 BUSD..)
        address borrowToken;// 质押代币地址 借款方代币地址 (比如 BTC..)
        address spToken;// sp_token的erc20地址 (比如 spBUSD_1..)
        address jpToken;// jp_token的erc20地址 (比如 jpBTC_1..)
        uint256 autoLiquidateThreshold;// 自动清算阈值 (触发清算阈值)
        PoolState state;
    }

    PoolBaseInfo[] public poolBaseInfo;

    // 借款用户信息
    struct LendInfo {
        uint256 stakeAmount;// 当前借款的质押金额
        uint256 refundAmount;// 超额退款金额
        bool hasNoRefund;// 默认为false, false = 无退款, true = 已退款
        bool hasNoClaim;// 默认为false, false = 无索赔, true = 已索赔
    }
    // 地址: (池索引: 借款用户信息)
    mapping (address => mapping (uint256 => LendInfo)) public userLendInfo;

    /*
        创建质押池的两个条件:
        1.结束时间大于结算时间。
        2.spToken 和 jpToken 地址不为零地址。
    */
    function createPoolInfo(
        uint256 _endTime,
        uint256 _settleTime,
        uint256 _interestRate,
        uint256 _maxSupply,
        uint256 _martgageRate,
        address _lendToken,
        address _borrowToken,
        address _spToken,
        address _jpToken,
        uint256 _autoLiquidateThreshold) public {
        // 1.结束时间大于结算时间。
        require(_endTime > _settleTime, "reatePool:end time grate than settle time");
        // 2.spToken 和 jpToken 地址不为零地址。 todo

        // 初始化质押池基本信息并写入数组
        poolBaseInfo.push(PoolBaseInfo({
            settleTime: _settleTime,
            endTime: _endTime,
            interestRate: _interestRate,
            maxSupply: _maxSupply,
            martgageRate: _martgageRate,
            lendToken: _lendToken,
            borrowToken: _borrowToken,
            spToken: _spToken,
            jpToken: _jpToken,
            autoLiquidateThreshold: _autoLiquidateThreshold,
            state: defaultChoice,
            lendSupply: 0
        }));
    }

    // 设置费用事件，newLendFee是新的借出费用，newBorrowFee是新的借入费用
    event SetFee(uint256 indexed newLendFee, uint256 indexed newBorrowFee);
    // 设置交换路由器地址事件，oldSwapAddress是旧的交换地址，newSwapAddress是新的交换地址
    event SetSwapRouterAddress(address indexed oldSwapAddress, address indexed newSwapAddress);
    // 设置手续费接收地址事件，oldFeeAddress是旧的手续费接收地址，newFeeAddress是新的手续费接收地址
    event SetFeeAddress(address indexed oldFeeAddress, address indexed newFeeAddress);
    // 设置最小金额事件，oldMinAmount是旧的最小金额，newMinAmount是新的最小金额
    event SetMinAmount(uint256 indexed oldMinAmount, uint256 indexed newMinAmount);
    // 存款借出事件，from是借出者地址，token是借出的代币地址，amount是借出的数量，mintAmount是生成的数量
    event DepositLend(address indexed from, address indexed token, uint256 amount, uint256 mintAmount); 

    // 设置费用
    function setFee(uint256 _lendFee, uint256 _borrowFee) external {
        lendFee = _lendFee;
        borrowFee = _borrowFee;
        emit SetFee(_lendFee, _borrowFee);
    }

    // 设置交换路由器地址
    function setSwapRouterAddress(address _swapRouter) external {
        require(_swapRouter != address(0), "Is zero address.");
        emit SetSwapRouterAddress(swapRouter, _swapRouter);
        swapRouter = _swapRouter;
    }

    // 设置手续费接收地址
    function setFeeAddress(address _feeAddress) external {
        require(_feeAddress != address(0), "Is zero address.");
        emit SetFeeAddress(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    // 设置最小金额
    function setMinAmount(uint256 _minAmount) external {
        emit SetMinAmount(minAmount, _minAmount);
        minAmount = _minAmount;
    }

    /**
     * @dev 存款借贷，存款人执行存款操作
     * @notice 当前时间小于结算时间, 质押池状态为 MATCH 
     * @param _pid 池索引
     * @param _stakeAmount 用户的质押金额
     */
    function depositLend(uint256 _pid, uint256 _stakeAmount) external payable stateMatch(_pid) timeBefore(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];
        // 质押金额小于等于质押池的最大供应量减去当前借贷供应量。
        require(_stakeAmount <= (pool.maxSupply).sub(pool.lendSupply), "depositLend: Out of max supply amount in this pool.");
        uint256 amount = getPayableAmount(pool.lendToken, _stakeAmount);
        // 质押金额大于最小金额。
        require(amount > minAmount,  "depositLend: Stake amount must greater than minAmount.");
        // 保存借款用户信息
        lendInfo.hasNoClaim = false;
        lendInfo.hasNoRefund = false;
        if (pool.lendToken == address(0)) {
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(msg.value);
            pool.lendSupply = pool.lendSupply.add(msg.value);
        } else {
            lendInfo.stakeAmount = lendInfo.stakeAmount.add(_stakeAmount);
            pool.lendSupply = pool.lendSupply.add(_stakeAmount);
        }
        emit DepositLend(msg.sender, pool.lendToken, _stakeAmount, amount);
    }

    // 校验: 当前时间 < 池的结算事件
    modifier timeBefore(uint256 _pid) {
        require(block.timestamp < poolBaseInfo[_pid].settleTime, "Less than this time.");
        _;
    }

    // 校验: 池状态 == MATCH
    modifier stateMatch(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.MATCH, "state: Pool status is not equal to match.");
        _;
    }
}
