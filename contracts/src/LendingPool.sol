// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeFiMath} from "./libraries/DeFiMath.sol";
import {StockOracle} from "./StockOracle.sol";
import {USStockRWA} from "./tokens/USStockRWA.sol";
import {aToken} from "./tokens/aToken.sol";
import {MockUSD} from "./tokens/MockUSD.sol";

/**
 * @title LendingPool
 * @author AnchorStock
 * @notice 借贷池：支持存入 RWA 借出 USD，或存入 USD 赚取利息 / Lending pool: deposit RWA to borrow USD, or deposit USD to earn interest
 * @dev 使用线性利息模型，所有计算归一化到 1e18 精度 / Uses linear interest model, all calculations normalized to 1e18
 *
 * 核心功能 / Core Features:
 * - Deposit RWA -> Mint aToken (存款凭证) / Deposit RWA -> Mint aToken (deposit receipt)
 * - Borrow USD (基于抵押品) / Borrow USD (based on collateral)
 * - 线性利息计算 / Linear interest calculation
 * - 健康因子计算 / Health factor calculation
 */
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using DeFiMath for uint256;

    /// @notice 股票 RWA 代币地址 / Stock RWA token address
    USStockRWA public rwaToken;

    /// @notice USD 代币地址 / USD token address
    MockUSD public usdToken;

    /// @notice 价格预言机 / Price oracle
    StockOracle public oracle;

    /// @notice aToken 地址映射 / aToken address mapping
    mapping(address => address) public aTokens; // underlyingAsset => aToken

    /// @notice 用户存款余额（归一化到 18 位精度）/ User deposit balance (normalized to 18 decimals)
    mapping(address => mapping(address => uint256)) public deposits; // user => asset => normalizedAmount

    /// @notice 用户借款余额（归一化到 18 位精度）/ User borrow balance (normalized to 18 decimals)
    mapping(address => uint256) public borrows; // user => normalizedAmount

    /// @notice 用户借款时间戳 / User borrow timestamp
    mapping(address => uint256) public borrowTimestamps; // user => timestamp

    /// @notice 年化存款利率（18位精度，例如 5% = 0.05 * 1e18）/ Annual deposit interest rate (18 decimals, e.g., 5% = 0.05 * 1e18)
    uint256 public depositRate = 0.05 * 1e18; // 5% APY

    /// @notice 年化借款利率（18位精度，例如 8% = 0.08 * 1e18）/ Annual borrow interest rate (18 decimals, e.g., 8% = 0.08 * 1e18)
    uint256 public borrowRate = 0.08 * 1e18; // 8% APY

    /// @notice 贷款价值比（LTV，18位精度，例如 70% = 0.7 * 1e18）/ Loan-to-value ratio (18 decimals, e.g., 70% = 0.7 * 1e18)
    uint256 public ltv = 0.7 * 1e18; // 70%

    /// @notice 清算阈值（健康因子低于此值时可以被清算，18位精度）/ Liquidation threshold (can be liquidated if health factor below this, 18 decimals)
    uint256 public liquidationThreshold = 1.0 * 1e18; // 1.0

    /// @notice 清算奖励率（默认 5%，归一化到 18 位精度）/ Liquidation bonus rate (default 5%, normalized to 18 decimals)
    uint256 public liquidationBonusRate = 0.05 * 1e18; // 5%

    /// @notice 股票符号（用于查询价格）/ Stock symbol (for price query)
    string public stockSymbol;

    /// @notice 事件：存款 / Event: Deposit
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 aTokenAmount);

    /// @notice 事件：提取 / Event: Withdraw
    event Withdrawn(address indexed user, address indexed asset, uint256 amount, uint256 aTokenAmount);

    /// @notice 事件：借款 / Event: Borrow
    event Borrowed(address indexed user, uint256 amount, uint256 timestamp);

    /// @notice 事件：还款 / Event: Repay
    event Repaid(address indexed user, uint256 amount, uint256 interest);

    /// @notice 事件：清算 / Event: Liquidation
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 liquidationBonus
    );

    // ============ 检查失败事件（埋点含相关参数）/ Check Failure Events (with relevant params) ============
    /// @notice 检查失败：无效地址 / Check failed: invalid address
    event CheckFailedInvalidAddress(string reason, address value);
    /// @notice 检查失败：金额必须大于 0 / Check failed: amount must be greater than 0
    event CheckFailedAmountZero(address indexed user, string context);
    /// @notice 检查失败：存款不足 / Check failed: insufficient deposit
    event CheckFailedInsufficientDeposit(address indexed user, uint256 requested, uint256 available);
    /// @notice 检查失败：健康因子过低 / Check failed: health factor too low
    event CheckFailedHealthFactorTooLow(address indexed user, uint256 healthFactor, uint256 threshold);
    /// @notice 检查失败：借款超额 / Check failed: borrow limit exceeded
    event CheckFailedBorrowLimitExceeded(address indexed user, uint256 requested, uint256 maxBorrow);
    /// @notice 检查失败：利率/参数超限 / Check failed: rate or parameter out of range
    event CheckFailedRateOutOfRange(string param, uint256 value, uint256 maxAllowed);
    /// @notice 检查失败：清算健康因子未达标 / Check failed: health factor not low enough for liquidation
    event CheckFailedLiquidationHealthFactor(address indexed user, uint256 healthFactor, uint256 threshold);
    /// @notice 检查失败：内部存款不足（_calculateHealthFactorAfterWithdraw）/ Check failed: internal insufficient deposit
    event CheckFailedInternalInsufficientDeposit(address indexed user, uint256 requested, uint256 currentDeposit);

    /// @notice 错误：健康因子过低 / Error: Health factor too low
    error HealthFactorTooLow(uint256 healthFactor);

    /// @notice 错误：借款金额超过限额 / Error: Borrow amount exceeds limit
    error BorrowLimitExceeded();

    /// @notice 错误：资产未支持 / Error: Asset not supported
    error AssetNotSupported();

    /**
     * @notice 构造函数 / Constructor
     * @param _rwaToken RWA 代币地址 / RWA token address
     * @param _usdToken USD 代币地址 / USD token address
     * @param _oracle 价格预言机地址 / Price oracle address
     * @param _stockSymbol 股票符号（如 "NVDA"）/ Stock symbol (e.g., "NVDA")
     * @param _owner 合约所有者 / Contract owner
     */
    constructor(address _rwaToken, address _usdToken, address _oracle, string memory _stockSymbol, address _owner)
        Ownable(_owner)
    {
        if (_rwaToken == address(0)) {
            emit CheckFailedInvalidAddress("LendingPool: invalid RWA token", _rwaToken);
            require(false, "LendingPool: invalid RWA token");
        }
        if (_usdToken == address(0)) {
            emit CheckFailedInvalidAddress("LendingPool: invalid USD token", _usdToken);
            require(false, "LendingPool: invalid USD token");
        }
        if (_oracle == address(0)) {
            emit CheckFailedInvalidAddress("LendingPool: invalid oracle", _oracle);
            require(false, "LendingPool: invalid oracle");
        }

        rwaToken = USStockRWA(_rwaToken);
        usdToken = MockUSD(_usdToken);
        oracle = StockOracle(_oracle);
        stockSymbol = _stockSymbol;

        // 创建对应的 aToken，owner 设为当前 LendingPool，这样只有 LendingPool 能调用 mint/burn
        // Create aToken with owner = this LendingPool, so only LendingPool can call mint/burn
        string memory rwaName = rwaToken.name();
        string memory rwaSymbol = rwaToken.symbol();
        string memory aTokenName = string(abi.encodePacked("Anchor ", rwaName));
        string memory aTokenSymbol = string(abi.encodePacked("a", rwaSymbol));

        aToken aRWA = new aToken(aTokenName, aTokenSymbol, _rwaToken, address(this));
        aTokens[_rwaToken] = address(aRWA);
    }

    /**
     * @notice 存款 RWA / Deposit RWA
     * @param amount 存款数量（18位精度）/ Deposit amount (18 decimals)
     */
    function depositRWA(uint256 amount) external nonReentrant {
        if (amount == 0) {
            emit CheckFailedAmountZero(msg.sender, "depositRWA");
            require(false, "LendingPool: amount must be greater than 0");
        }

        // 转移 RWA 代币到池子 / Transfer RWA tokens to pool
        IERC20(address(rwaToken)).safeTransferFrom(msg.sender, address(this), amount);

        // 更新存款余额（已经是 18 位精度，无需归一化）/ Update deposit balance (already 18 decimals, no normalization needed)
        deposits[msg.sender][address(rwaToken)] += amount;

        // 铸造 aToken 给用户 / Mint aToken to user
        address aTokenAddress = aTokens[address(rwaToken)];
        aToken(aTokenAddress).mint(msg.sender, amount);

        emit Deposited(msg.sender, address(rwaToken), amount, amount);
    }

    /**
     * @notice 提取 RWA / Withdraw RWA
     * @param amount 提取数量（18位精度）/ Withdraw amount (18 decimals)
     */
    function withdrawRWA(uint256 amount) external nonReentrant {
        if (amount == 0) {
            emit CheckFailedAmountZero(msg.sender, "withdrawRWA");
            require(false, "LendingPool: amount must be greater than 0");
        }
        if (deposits[msg.sender][address(rwaToken)] < amount) {
            emit CheckFailedInsufficientDeposit(msg.sender, amount, deposits[msg.sender][address(rwaToken)]);
            require(false, "LendingPool: insufficient deposit");
        }

        // 检查健康因子（提取后不能低于清算阈值）/ Check health factor (must not be below liquidation threshold after withdrawal)
        uint256 newHealthFactor = _calculateHealthFactorAfterWithdraw(msg.sender, amount);
        if (newHealthFactor < liquidationThreshold) {
            emit CheckFailedHealthFactorTooLow(msg.sender, newHealthFactor, liquidationThreshold);
            require(false, "LendingPool: health factor too low");
        }

        // 更新存款余额 / Update deposit balance
        deposits[msg.sender][address(rwaToken)] -= amount;

        // 销毁 aToken / Burn aToken
        address aTokenAddress = aTokens[address(rwaToken)];
        aToken(aTokenAddress).burn(msg.sender, amount);

        // 转移 RWA 代币给用户 / Transfer RWA tokens to user
        IERC20(address(rwaToken)).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, address(rwaToken), amount, amount);
    }

    /**
     * @notice 借款 USD / Borrow USD
     * @param amount 借款数量（6位精度，USDC 格式）/ Borrow amount (6 decimals, USDC format)
     */
    function borrowUSD(uint256 amount) external nonReentrant {
        if (amount == 0) {
            emit CheckFailedAmountZero(msg.sender, "borrowUSD");
            require(false, "LendingPool: amount must be greater than 0");
        }

        // 归一化借款金额到 18 位精度 / Normalize borrow amount to 18 decimals
        uint256 normalizedAmount = DeFiMath.normalizeUSDC(amount);

        // 检查借款限额 / Check borrow limit
        uint256 maxBorrow = _calculateMaxBorrow(msg.sender);
        if (normalizedAmount > maxBorrow) {
            emit CheckFailedBorrowLimitExceeded(msg.sender, normalizedAmount, maxBorrow);
            require(false, "LendingPool: borrow limit exceeded");
        }

        // 更新借款余额 / Update borrow balance
        if (borrows[msg.sender] == 0) {
            borrowTimestamps[msg.sender] = block.timestamp;
        }
        borrows[msg.sender] += normalizedAmount;

        // 检查健康因子 / Check health factor
        uint256 healthFactor = getAccountHealthFactor(msg.sender);
        require(healthFactor >= liquidationThreshold, "LendingPool: health factor too low");

        // 转移 USD 给用户（反归一化到 6 位精度）/ Transfer USD to user (denormalize to 6 decimals)
        uint256 usdAmount = DeFiMath.denormalizeToUSDC(normalizedAmount);
        IERC20(address(usdToken)).safeTransfer(msg.sender, usdAmount);

        emit Borrowed(msg.sender, normalizedAmount, block.timestamp);
    }

    /**
     * @notice 还款 USD / Repay USD
     * @param amount 还款数量（6位精度，USDC 格式）/ Repay amount (6 decimals, USDC format)
     */
    function repayUSD(uint256 amount) external nonReentrant {
        if (amount == 0) {
            emit CheckFailedAmountZero(msg.sender, "repayUSD");
            require(false, "LendingPool: amount must be greater than 0");
        }

        // 归一化还款金额到 18 位精度 / Normalize repay amount to 18 decimals
        uint256 normalizedAmount = DeFiMath.normalizeUSDC(amount);

        // 计算应还总额（本金 + 利息）/ Calculate total amount to repay (principal + interest)
        uint256 totalDebt = getTotalDebt(msg.sender);

        // 如果还款金额超过总债务，只还总债务 / If repay amount exceeds total debt, only repay total debt
        if (normalizedAmount > totalDebt) {
            normalizedAmount = totalDebt;
            amount = DeFiMath.denormalizeToUSDC(normalizedAmount);
        }

        // 计算利息 / Calculate interest
        uint256 currentPrincipal = borrows[msg.sender];
        uint256 interest = totalDebt > currentPrincipal ? totalDebt - currentPrincipal : 0;

        // 先还利息，再还本金 / Pay interest first, then principal
        uint256 principal = 0;
        if (normalizedAmount > interest) {
            principal = normalizedAmount - interest;
        } else {
            // 如果还款金额小于利息，只还部分利息 / If repay amount is less than interest, only pay part of interest
            interest = normalizedAmount;
            principal = 0;
        }

        // 更新借款余额 / Update borrow balance
        if (principal > 0) {
            borrows[msg.sender] -= principal;
        }

        // 如果本金已还清，重置时间戳 / If principal is cleared, reset timestamp
        if (borrows[msg.sender] == 0) {
            borrowTimestamps[msg.sender] = 0;
        }

        // 转移 USD 到池子 / Transfer USD to pool
        IERC20(address(usdToken)).safeTransferFrom(msg.sender, address(this), amount);

        emit Repaid(msg.sender, normalizedAmount, interest);
    }

    /**
     * @notice 获取账户健康因子 / Get account health factor
     * @param user 用户地址 / User address
     * @return healthFactor 健康因子（18位精度，< 1.0 表示可清算）/ Health factor (18 decimals, < 1.0 means can be liquidated)
     */
    function getAccountHealthFactor(address user) public view returns (uint256 healthFactor) {
        uint256 totalCollateralValue = _calculateTotalCollateralValue(user);
        uint256 totalDebtValue = getTotalDebt(user);

        if (totalDebtValue == 0) {
            return type(uint256).max; // 无债务，健康因子为最大值 / No debt, health factor is max
        }

        // 健康因子 = 抵押品价值 / 债务价值 / Health factor = collateral value / debt value
        healthFactor = DeFiMath.div(totalCollateralValue, totalDebtValue);
    }

    /**
     * @notice 获取总债务（本金 + 利息，归一化到 18 位精度）/ Get total debt (principal + interest, normalized to 18 decimals)
     * @param user 用户地址 / User address
     * @return totalDebt 总债务（18位精度）/ Total debt (18 decimals)
     */
    function getTotalDebt(address user) public view returns (uint256 totalDebt) {
        uint256 principal = borrows[user];
        if (principal == 0) {
            return 0;
        }

        // 计算线性利息 / Calculate linear interest
        uint256 timeElapsed = block.timestamp - borrowTimestamps[user];
        uint256 interest = _calculateLinearInterest(principal, borrowRate, timeElapsed);

        totalDebt = principal + interest;
    }

    /**
     * @notice 计算最大可借款金额（归一化到 18 位精度）/ Calculate maximum borrowable amount (normalized to 18 decimals)
     * @param user 用户地址 / User address
     * @return maxBorrow 最大可借款金额（18位精度）/ Maximum borrowable amount (18 decimals)
     */
    function getMaxBorrow(address user) external view returns (uint256 maxBorrow) {
        return _calculateMaxBorrow(user);
    }

    /**
     * @notice 清算账户 / Liquidate account
     * @param user 被清算用户地址 / User address to liquidate
     * @dev 清算人会获得清算奖励（2%-5%），以激励维护协议安全 / Liquidator gets liquidation bonus (2%-5%) to incentivize protocol security
     */
    function liquidate(address user) external nonReentrant {
        uint256 healthFactor = getAccountHealthFactor(user);
        if (healthFactor >= liquidationThreshold) {
            emit CheckFailedLiquidationHealthFactor(user, healthFactor, liquidationThreshold);
            require(false, "LendingPool: health factor not low enough");
        }

        uint256 totalDebt = getTotalDebt(user);
        uint256 collateralAmount = deposits[user][address(rwaToken)];

        // 计算清算奖励 / Calculate liquidation bonus
        uint256 liquidationBonus = DeFiMath.mul(collateralAmount, liquidationBonusRate);
        uint256 collateralToLiquidator = collateralAmount + liquidationBonus;

        // 检查合约余额是否足够支付清算奖励 / Check if contract balance is sufficient for liquidation bonus
        uint256 contractBalance = IERC20(address(rwaToken)).balanceOf(address(this));
        if (collateralToLiquidator > contractBalance) {
            // 如果余额不足，只给合约中有的部分 / If balance insufficient, only give what's available
            collateralToLiquidator = contractBalance;
        }

        // 更新存款和借款余额 / Update deposit and borrow balances
        deposits[user][address(rwaToken)] = 0;
        borrows[user] = 0;
        borrowTimestamps[user] = 0;

        // 销毁 aToken / Burn aToken
        address aTokenAddress = aTokens[address(rwaToken)];
        aToken(aTokenAddress).burn(user, collateralAmount);

        // 转移抵押品和清算奖励给清算人 / Transfer collateral and liquidation bonus to liquidator
        IERC20(address(rwaToken)).safeTransfer(msg.sender, collateralToLiquidator);

        emit Liquidated(user, msg.sender, collateralAmount, totalDebt, liquidationBonus);
    }

    // ============ 内部函数 / Internal Functions ============

    /**
     * @notice 计算总抵押品价值（归一化到 18 位精度）/ Calculate total collateral value (normalized to 18 decimals)
     * @param user 用户地址 / User address
     * @return totalValue 总抵押品价值（18位精度）/ Total collateral value (18 decimals)
     */
    function _calculateTotalCollateralValue(address user) internal view returns (uint256 totalValue) {
        uint256 depositAmount = deposits[user][address(rwaToken)];
        if (depositAmount == 0) {
            return 0;
        }

        // 获取 RWA 价格（已归一化到 18 位精度）/ Get RWA price (already normalized to 18 decimals)
        (uint256 price,) = oracle.getPrice(stockSymbol);

        // 计算抵押品价值：数量 * 价格（都是 18 位精度，需要除以 1e18）/ Calculate collateral value: amount * price (both 18 decimals, need to divide by 1e18)
        totalValue = DeFiMath.mul(depositAmount, price);
    }

    /**
     * @notice 计算最大可借款金额（归一化到 18 位精度）/ Calculate maximum borrowable amount (normalized to 18 decimals)
     * @param user 用户地址 / User address
     * @return maxBorrow 最大可借款金额（18位精度）/ Maximum borrowable amount (18 decimals)
     */
    function _calculateMaxBorrow(address user) internal view returns (uint256 maxBorrow) {
        uint256 totalCollateralValue = _calculateTotalCollateralValue(user);

        // 最大借款 = 抵押品价值 * LTV / Maximum borrow = collateral value * LTV
        maxBorrow = DeFiMath.mul(totalCollateralValue, ltv);

        // 减去当前债务 / Subtract current debt
        uint256 currentDebt = getTotalDebt(user);
        if (maxBorrow > currentDebt) {
            maxBorrow -= currentDebt;
        } else {
            maxBorrow = 0;
        }
    }

    /**
     * @notice 计算线性利息 / Calculate linear interest
     * @param principal 本金（18位精度）/ Principal (18 decimals)
     * @param rate 年化利率（18位精度）/ Annual interest rate (18 decimals)
     * @param timeElapsed 经过的时间（秒）/ Time elapsed (seconds)
     * @return interest 利息（18位精度）/ Interest (18 decimals)
     */
    function _calculateLinearInterest(uint256 principal, uint256 rate, uint256 timeElapsed)
        internal
        pure
        returns (uint256 interest)
    {
        // 线性利息公式：利息 = 本金 * 利率 * 时间 / 年秒数
        // Linear interest formula: interest = principal * rate * time / seconds per year
        // 所有值都是 18 位精度，所以需要除以 1e18 两次（一次是 rate，一次是结果）
        // All values are 18 decimals, so need to divide by 1e18 twice (once for rate, once for result)
        uint256 secondsPerYear = 365 days;
        interest = DeFiMath.mul(principal, rate);
        interest = DeFiMath.mul(interest, timeElapsed);
        interest = interest / secondsPerYear;
    }

    /**
     * @notice 计算提取后的健康因子 / Calculate health factor after withdrawal
     * @param user 用户地址 / User address
     * @param withdrawAmount 提取数量（18位精度）/ Withdraw amount (18 decimals)
     * @return healthFactor 健康因子（18位精度）/ Health factor (18 decimals)
     */
    function _calculateHealthFactorAfterWithdraw(address user, uint256 withdrawAmount)
        internal
        view
        returns (uint256 healthFactor)
    {
        uint256 currentDeposit = deposits[user][address(rwaToken)];
        if (currentDeposit < withdrawAmount) {
            require(false, "LendingPool: insufficient deposit");
        }

        // 计算提取后的抵押品价值 / Calculate collateral value after withdrawal
        uint256 newDeposit = currentDeposit - withdrawAmount;
        (uint256 price,) = oracle.getPrice(stockSymbol);
        uint256 newCollateralValue = DeFiMath.mul(newDeposit, price);

        uint256 totalDebtValue = getTotalDebt(user);

        if (totalDebtValue == 0) {
            return type(uint256).max;
        }

        healthFactor = DeFiMath.div(newCollateralValue, totalDebtValue);
    }

    // ============ 管理员函数 / Admin Functions ============

    /**
     * @notice 设置存款利率 / Set deposit interest rate
     * @param _rate 年化利率（18位精度）/ Annual interest rate (18 decimals)
     */
    function setDepositRate(uint256 _rate) external onlyOwner {
        if (_rate > 1e18) {
            emit CheckFailedRateOutOfRange("depositRate", _rate, 1e18);
            require(false, "LendingPool: rate too high"); // 最大 100% / Max 100%
        }
        depositRate = _rate;
    }

    /**
     * @notice 设置借款利率 / Set borrow interest rate
     * @param _rate 年化利率（18位精度）/ Annual interest rate (18 decimals)
     */
    function setBorrowRate(uint256 _rate) external onlyOwner {
        if (_rate > 1e18) {
            emit CheckFailedRateOutOfRange("borrowRate", _rate, 1e18);
            require(false, "LendingPool: rate too high"); // 最大 100% / Max 100%
        }
        borrowRate = _rate;
    }

    /**
     * @notice 设置 LTV / Set LTV
     * @param _ltv 贷款价值比（18位精度）/ Loan-to-value ratio (18 decimals)
     */
    function setLTV(uint256 _ltv) external onlyOwner {
        require(_ltv <= 1e18, "LendingPool: LTV too high"); // 最大 100% / Max 100%
        ltv = _ltv;
    }

    /**
     * @notice 设置清算阈值 / Set liquidation threshold
     * @param _threshold 清算阈值（18位精度）/ Liquidation threshold (18 decimals)
     */
    function setLiquidationThreshold(uint256 _threshold) external onlyOwner {
        if (_threshold == 0) {
            emit CheckFailedRateOutOfRange("liquidationThreshold", _threshold, 0);
            require(false, "LendingPool: threshold must be greater than 0");
        }
        liquidationThreshold = _threshold;
    }

    /**
     * @notice 设置清算奖励率 / Set liquidation bonus rate
     * @param _rate 新的清算奖励率（归一化到 18 位精度，建议 2%-5%）/ New liquidation bonus rate (normalized to 18 decimals, recommended 2%-5%)
     */
    function setLiquidationBonusRate(uint256 _rate) external onlyOwner {
        if (_rate == 0 || _rate > 0.2 * 1e18) {
            emit CheckFailedRateOutOfRange("liquidationBonusRate", _rate, 0.2 * 1e18);
            require(false, "LendingPool: invalid liquidation bonus rate"); // 最大 20% / Max 20%
        }
        liquidationBonusRate = _rate;
    }
}
