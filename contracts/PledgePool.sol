// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./library/SafeMath.sol";
import "./library/SafeTransfer.sol";
import "./interface/IDebtToken.sol";

contract PledgePool is SafeTransfer {
    constructor(){

    }

    using SafeMath for uint256;
    // default decimal
    uint256 constant internal calDecimal = 1e18;
    // Based on the decimal of the commission and interest
    uint256 constant internal baseDecimal = 1e8;
    // 最小金额
    uint256 public minAmount = 100e18;
    // one years
    uint256 constant baseYear = 365 days;

    // 借贷费用
    uint256 public lendFee;
    // 质押费用
    uint256 public borrowFee;
    // 交换路由地址
    address public swapRouter;
    // 手续费接收地址
    address public feeAddress;
    

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
        IDebtToken spCoin;// sp_token的erc20地址 (比如 spBUSD_1..)
        IDebtToken jpCoin;// jp_token的erc20地址 (比如 jpBTC_1..)
        uint256 autoLiquidateThreshold;// 自动清算阈值 (触发清算阈值)
        PoolState state;
    }
    PoolBaseInfo[] public poolBaseInfo;

    struct PoolDataInfo {
        uint256 settleAmountLend;// 结算时的实际借出金额
        uint256 settleAmountBorrow;// 结算时的实际借款金额
        uint256 finishAmountLend;// 完成时的实际借出金额
        uint256 finishAmountBorrow;// 完成时的实际借款金额
        uint256 liquidationAmountLend;// 清算时的实际借出金额
        uint256 liquidationAmountBorrow;// 清算时的实际借款金额
    }
    PoolDataInfo[] public poolDataInfo;

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
            spCoin: IDebtToken(_spToken),
            jpCoin: IDebtToken(_jpToken),
            autoLiquidateThreshold: _autoLiquidateThreshold,
            state: defaultChoice,
            lendSupply: 0
        }));

        // 初始化质押池数据信息并写入数组
        poolDataInfo.push(PoolDataInfo({
            settleAmountLend: 0,
            settleAmountBorrow: 0,
            finishAmountLend: 0,
            finishAmountBorrow: 0,
            liquidationAmountLend: 0,
            liquidationAmountBorrow: 0
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
    // 借出退款事件，from是退款者地址，token是退款的代币地址，refund是退款的数量
    event RefundLend(address indexed from, address indexed token, uint256 refund); 
    // 借出索赔事件，from是索赔者地址，token是索赔的代币地址，amount是索赔的数量
    event ClaimLend(address indexed from, address indexed token, uint256 amount); 

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

    /**
     * @dev 退还过量的存款给存款人
     * @notice 池状态不能等于匹配和未完成
     * @param _pid 池索引
     */
    function refundLend(uint256 _pid) external timeAfter(_pid) stateNotMatchUndone(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid];// 获取池的基本信息
        PoolDataInfo storage data = poolDataInfo[_pid];// 获取池的数据信息
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid];// 获取用户的出借信息
        // 限制金额
        // 需要用户已经质押了一定数量
        require(lendInfo.stakeAmount > 0, "refundLend: lend amount must greater than 0.");
        // 需要池中还有未退还的金额
        require(pool.lendSupply.sub(data.settleAmountLend) > 0, "refundLend: out of lend supply amount in this pool.");
        // 需要用户没有重复退款
        require(!lendInfo.hasNoRefund, "refundLend: Already refunded.");
        // 用户份额 = 当前质押金额 / 当前池中总金额
        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply);
        // refundAmount = 总退款金额 * 用户份额
        uint256 refundAmount = (pool.lendSupply.sub(data.settleAmountLend)).mul(userShare).div(calDecimal);
        // 退款操作
        _redeem(payable(msg.sender), pool.lendToken, refundAmount);
        // 更新用户信息
        lendInfo.hasNoRefund = true;
        lendInfo.refundAmount = lendInfo.refundAmount.add(refundAmount);
        emit RefundLend(msg.sender, pool.lendToken, refundAmount);
    }

    /**
     * @dev 存款人接收 sp_toke,主要功能是让存款人领取 sp_token
     * @notice 池状态不等于匹配和未完成
     * @param _pid 是池索引
     */
    function claimLend(uint256 _pid) external timeAfter(_pid) stateNotMatchUndone(_pid) {
        PoolBaseInfo storage pool = poolBaseInfo[_pid]; // 获取池的基本信息
        PoolDataInfo storage data = poolDataInfo[_pid]; // 获取池的数据信息
        LendInfo storage lendInfo = userLendInfo[msg.sender][_pid]; // 获取用户的借款信息
        // 金额限制
        require(lendInfo.stakeAmount > 0, "claimLend: lend amount must greater than 0.");
        require(!lendInfo.hasNoClaim, "claimLend: Already claim.");
        // 用户份额 = 当前质押金额 / 总金额
        uint256 userShare = lendInfo.stakeAmount.mul(calDecimal).div(pool.lendSupply);
        // totalSpAmount = settleAmountLend
        uint256 totalSpAmount = data.settleAmountLend;// 总的sp金额 = 借款结算金额
        // 用户sp金额 = totalSpAmount * 用户份额
        uint256 spAmount = totalSpAmount.mul(userShare).div(calDecimal);
        // 铸造sp token
        pool.spCoin.mint(msg.sender, spAmount);
        // 更新领取标志
        lendInfo.hasNoClaim = true;
        emit ClaimLend(msg.sender, pool.borrowToken, spAmount); 
    }

    // 校验: 当前时间 < 池的结算事件
    modifier timeBefore(uint256 _pid) {
        require(block.timestamp < poolBaseInfo[_pid].settleTime, "Less than this time.");
        _;
    }

    // 校验: 当前时间 > 池的结算事件
    modifier timeAfter(uint256 _pid) {
        require(block.timestamp > poolBaseInfo[_pid].settleTime, "Greate than this time");
        _;
    }

    // 校验: 池状态 == MATCH
    modifier stateMatch(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.MATCH, "state: Pool status is not equal to match.");
        _;
    }

    // 校验：池状态 == FINISH || LIQUIDATION
    modifier stateFinishOrLiquidation(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION, "state: Pool status is not equal to liquidation.");
        _;
    }

    // 校验：池状态 == EXECUTION || FINISH || LIQUIDATION
    modifier stateNotMatchUndone(uint256 _pid) {
        require(poolBaseInfo[_pid].state == PoolState.EXECUTION || poolBaseInfo[_pid].state == PoolState.FINISH || poolBaseInfo[_pid].state == PoolState.LIQUIDATION,"state: not match and undone");
        _;
    }
}