// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeFiMath} from "./libraries/DeFiMath.sol";
import {StockOracle} from "./StockOracle.sol";
import {aToken} from "./tokens/aToken.sol";

/**
 * @title PerpEngine
 * @author AnchorStock
 * @notice 永续合约引擎：支持使用 aToken 作为保证金开设美股多/空仓位 / Perpetual engine: support using aToken as collateral to open long/short positions
 * @dev 实现简化版 PnL 计算与资金费率，所有计算归一化到 1e18 精度 / Implements simplified PnL calculation and funding rate, all calculations normalized to 1e18
 *
 * 核心功能 / Core Features:
 * - 使用 aToken 作为保证金 / Use aToken as collateral
 * - 支持多/空仓位 / Support long/short positions
 * - PnL 计算（基于当前价格和开仓价格）/ PnL calculation (based on current price and entry price)
 * - 资金费率（简化版，基于时间） / Funding rate (simplified, based on time)
 * - 价格过期检测（Market Hours Trap）/ Stale price detection (Market Hours Trap)
 */
contract PerpEngine is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using DeFiMath for uint256;

    /// @notice 仓位方向枚举 / Position direction enum
    enum PositionSide {
        LONG, // 做多 / Long
        SHORT // 做空 / Short
    }

    /// @notice 仓位信息结构体 / Position information struct
    struct Position {
        PositionSide side; // 仓位方向 / Position side
        uint256 size; // 仓位大小（归一化到 18 位精度）/ Position size (normalized to 18 decimals)
        uint256 entryPrice; // 开仓价格（归一化到 18 位精度）/ Entry price (normalized to 18 decimals)
        uint256 collateral; // 保证金（aToken 数量，18 位精度）/ Collateral (aToken amount, 18 decimals)
        uint256 entryTimestamp; // 开仓时间戳 / Entry timestamp
        uint256 lastFundingTimestamp; // 上次资金费率更新时间戳 / Last funding rate update timestamp
    }

    /// @notice 价格预言机 / Price oracle
    StockOracle public oracle;

    /// @notice 股票符号 / Stock symbol
    string public stockSymbol;

    /// @notice aToken 地址（作为保证金）/ aToken address (as collateral)
    aToken public collateralToken;

    /// @notice 用户仓位映射 / User position mapping
    mapping(address => Position) public positions;

    /// @notice 初始保证金率（默认 10%，归一化到 18 位精度）/ Initial margin rate (default 10%, normalized to 18 decimals)
    uint256 public initialMarginRate = 0.1 * 1e18; // 10%

    /// @notice 维持保证金率（默认 5%，归一化到 18 位精度）/ Maintenance margin rate (default 5%, normalized to 18 decimals)
    uint256 public maintenanceMarginRate = 0.05 * 1e18; // 5%

    /// @notice 资金费率（年化，归一化到 18 位精度，默认 0.01 = 1%）/ Funding rate (annualized, normalized to 18 decimals, default 0.01 = 1%)
    uint256 public fundingRate = 0.01 * 1e18; // 1% per year

    /// @notice 资金费率更新间隔（秒，默认 8 小时）/ Funding rate update interval (seconds, default 8 hours)
    uint256 public fundingInterval = 8 hours;

    /// @notice 事件：开仓 / Event: Position opened
    event PositionOpened(address indexed user, PositionSide side, uint256 size, uint256 entryPrice, uint256 collateral);

    /// @notice 事件：平仓 / Event: Position closed
    event PositionClosed(
        address indexed user, PositionSide side, uint256 size, uint256 exitPrice, uint256 pnl, uint256 fundingFee
    );

    /// @notice 事件：追加保证金 / Event: Collateral added
    event CollateralAdded(address indexed user, uint256 amount);

    /// @notice 事件：提取保证金 / Event: Collateral withdrawn
    event CollateralWithdrawn(address indexed user, uint256 amount);

    /// @notice 事件：清算 / Event: Liquidation
    event PositionLiquidated(
        address indexed user,
        address indexed liquidator,
        PositionSide side,
        uint256 size,
        uint256 collateralSeized,
        uint256 liquidationBonus
    );

    /// @notice 清算奖励率（默认 5%，归一化到 18 位精度）/ Liquidation bonus rate (default 5%, normalized to 18 decimals)
    uint256 public liquidationBonusRate = 0.05 * 1e18; // 5%

    // ============ 检查失败事件（埋点含相关参数）/ Check Failure Events (with relevant params) ============
    /// @notice 检查失败：无效地址 / Check failed: invalid address
    event CheckFailedInvalidAddress(string reason, address value);
    /// @notice 检查失败：金额/数量必须大于 0 / Check failed: amount/size must be greater than 0
    event CheckFailedAmountZero(address indexed user, string context);
    /// @notice 检查失败：价格过期 / Check failed: price stale
    event CheckFailedPriceStale(address indexed user, string context);
    /// @notice 检查失败：保证金不足 / Check failed: insufficient collateral
    event CheckFailedInsufficientCollateral(address indexed user, uint256 required, uint256 provided);
    /// @notice 检查失败：反向仓位需先平仓 / Check failed: must close opposite position first
    event CheckFailedOppositePosition(address indexed user);
    /// @notice 检查失败：平仓数量超过持仓 / Check failed: close size exceeds position size
    event CheckFailedCloseSizeExceedsPosition(address indexed user, uint256 closeSize, uint256 positionSize);
    /// @notice 检查失败：无仓位可清算 / Check failed: no position to liquidate
    event CheckFailedNoPositionToLiquidate(address indexed user);
    /// @notice 检查失败：健康因子未低至可清算 / Check failed: health factor not low enough for liquidation
    event CheckFailedLiquidationHealthFactor(address indexed user, uint256 healthFactor);
    /// @notice 检查失败：提取后保证金不足 / Check failed: insufficient collateral after withdrawal
    event CheckFailedInsufficientCollateralAfterWithdraw(
        address indexed user, uint256 newCollateral, uint256 requiredMaintenance
    );
    /// @notice 检查失败：健康因子过低（提取保证金）/ Check failed: health factor too low (withdraw)
    event CheckFailedHealthFactorTooLow(address indexed user, uint256 healthFactor);
    /// @notice 检查失败：参数超限（admin）/ Check failed: parameter out of range (admin)
    event CheckFailedParamOutOfRange(string param, uint256 value, uint256 minOrMax);

    /// @notice 错误：仓位不存在 / Error: Position does not exist
    error PositionNotFound();

    /// @notice 错误：价格已过期 / Error: Price is stale
    error PriceStale();

    /// @notice 错误：保证金不足 / Error: Insufficient collateral
    error InsufficientCollateral();

    /// @notice 错误：健康因子过低 / Error: Health factor too low
    error HealthFactorTooLow();

    /// @notice 错误：无效的仓位方向 / Error: Invalid position side
    error InvalidPositionSide();

    /// @notice 错误：无效的仓位大小 / Error: Invalid position size
    error InvalidPositionSize();

    /**
     * @notice 构造函数 / Constructor
     * @param _oracle 价格预言机地址 / Price oracle address
     * @param _stockSymbol 股票符号（如 "NVDA"）/ Stock symbol (e.g., "NVDA")
     * @param _collateralToken aToken 地址（作为保证金）/ aToken address (as collateral)
     * @param _owner 合约所有者地址 / Contract owner address
     */
    constructor(address _oracle, string memory _stockSymbol, address _collateralToken, address _owner) Ownable(_owner) {
        if (_oracle == address(0)) {
            emit CheckFailedInvalidAddress("PerpEngine: invalid oracle", _oracle);
            require(false, "PerpEngine: invalid oracle");
        }
        if (_collateralToken == address(0)) {
            emit CheckFailedInvalidAddress("PerpEngine: invalid collateral token", _collateralToken);
            require(false, "PerpEngine: invalid collateral token");
        }
        if (_owner == address(0)) {
            emit CheckFailedInvalidAddress("PerpEngine: invalid owner", _owner);
            require(false, "PerpEngine: invalid owner");
        }

        oracle = StockOracle(_oracle);
        stockSymbol = _stockSymbol;
        collateralToken = aToken(_collateralToken);
    }

    /**
     * @notice 开仓（做多或做空）/ Open position (long or short)
     * @param side 仓位方向（LONG 或 SHORT）/ Position side (LONG or SHORT)
     * @param size 仓位大小（归一化到 18 位精度）/ Position size (normalized to 18 decimals)
     * @param collateralAmount 保证金数量（aToken，18 位精度）/ Collateral amount (aToken, 18 decimals)
     */
    function openPosition(PositionSide side, uint256 size, uint256 collateralAmount) external nonReentrant {
        if (size == 0) {
            emit CheckFailedAmountZero(msg.sender, "openPosition: size");
            require(false, "PerpEngine: size must be greater than 0");
        }
        if (collateralAmount == 0) {
            emit CheckFailedAmountZero(msg.sender, "openPosition: collateral");
            require(false, "PerpEngine: collateral must be greater than 0");
        }

        // 检查价格是否过期（Market Hours Trap）/ Check if price is stale (Market Hours Trap)
        (uint256 normalizedPrice,, bool isStale) = oracle.getPriceWithStaleCheck(stockSymbol);
        if (isStale && oracle.circuitBreakerEnabled()) {
            emit CheckFailedPriceStale(msg.sender, "openPosition");
            revert PriceStale();
        }

        // normalizedPrice 已经从 getPriceWithStaleCheck 返回（已归一化）/ normalizedPrice already returned from getPriceWithStaleCheck (normalized)

        // 检查初始保证金率 / Check initial margin rate
        uint256 requiredCollateral = DeFiMath.mul(size, initialMarginRate);
        if (collateralAmount < requiredCollateral) {
            emit CheckFailedInsufficientCollateral(msg.sender, requiredCollateral, collateralAmount);
            require(false, "PerpEngine: insufficient collateral for initial margin");
        }

        // 如果用户已有仓位，检查是否可以合并 / If user has existing position, check if can merge
        Position storage position = positions[msg.sender];
        if (position.size > 0) {
            // 如果方向相同，合并仓位 / If same direction, merge positions
            if (position.side == side) {
                // 计算加权平均开仓价格 / Calculate weighted average entry price
                uint256 totalValue =
                    DeFiMath.mul(position.size, position.entryPrice) + DeFiMath.mul(size, normalizedPrice);
                uint256 totalSize = position.size + size;
                position.entryPrice = DeFiMath.div(totalValue, totalSize);
                position.size = totalSize;
                position.collateral += collateralAmount;
            } else {
                // 方向相反，先平仓再开新仓 / Opposite direction, close first then open new
                emit CheckFailedOppositePosition(msg.sender);
                revert("PerpEngine: cannot open opposite position, close first");
            }
        } else {
            // 新开仓位 / Open new position
            position.side = side;
            position.size = size;
            position.entryPrice = normalizedPrice;
            position.collateral = collateralAmount;
            position.entryTimestamp = block.timestamp;
            position.lastFundingTimestamp = block.timestamp;
        }

        // 转移保证金 / Transfer collateral
        IERC20(address(collateralToken)).safeTransferFrom(msg.sender, address(this), collateralAmount);

        emit PositionOpened(msg.sender, side, size, normalizedPrice, collateralAmount);
    }

    /**
     * @notice 平仓 / Close position
     * @param size 平仓数量（归一化到 18 位精度），0 表示全部平仓 / Close size (normalized to 18 decimals), 0 means close all
     */
    function closePosition(uint256 size) external nonReentrant {
        Position storage position = positions[msg.sender];
        if (position.size == 0) {
            revert PositionNotFound();
        }

        // 如果 size 为 0，平仓全部 / If size is 0, close all
        if (size == 0) {
            size = position.size;
        }

        if (size > position.size) {
            emit CheckFailedCloseSizeExceedsPosition(msg.sender, size, position.size);
            require(false, "PerpEngine: close size exceeds position size");
        }

        // 获取当前价格 / Get current price
        (uint256 normalizedPrice,,) = oracle.getPriceWithStaleCheck(stockSymbol);

        // 计算 PnL / Calculate PnL
        uint256 pnl = _calculatePnL(position, size, normalizedPrice);

        // 计算资金费率费用 / Calculate funding fee
        uint256 fundingFee = _calculateFundingFee(position, size);

        // 计算净收益（PnL - 资金费率费用）/ Calculate net profit (PnL - funding fee)
        int256 netPnL = int256(pnl) - int256(fundingFee);

        // 计算应返还的保证金 / Calculate collateral to return
        uint256 collateralRatio = DeFiMath.div(position.collateral, position.size);
        uint256 collateralToReturn = DeFiMath.mul(size, collateralRatio);

        // 如果净收益为正，添加到保证金中 / If net PnL is positive, add to collateral
        if (netPnL > 0) {
            collateralToReturn += uint256(netPnL);
        } else {
            // 如果净收益为负，从保证金中扣除 / If net PnL is negative, deduct from collateral
            uint256 loss = uint256(-netPnL);
            if (loss > collateralToReturn) {
                // 保证金不足以覆盖损失，全部扣除 / Collateral insufficient to cover loss, deduct all
                collateralToReturn = 0;
            } else {
                collateralToReturn -= loss;
            }
        }

        // 更新仓位 / Update position
        position.size -= size;
        position.collateral -= DeFiMath.mul(size, collateralRatio);

        // 如果仓位已全部平仓，清除仓位信息 / If position is fully closed, clear position info
        if (position.size == 0) {
            delete positions[msg.sender];
        } else {
            // 更新资金费率时间戳 / Update funding timestamp
            position.lastFundingTimestamp = block.timestamp;
        }

        // 返还保证金 / Return collateral
        if (collateralToReturn > 0) {
            IERC20(address(collateralToken)).safeTransfer(msg.sender, collateralToReturn);
        }

        emit PositionClosed(msg.sender, position.side, size, normalizedPrice, pnl, fundingFee);
    }

    /**
     * @notice 追加保证金 / Add collateral
     * @param amount 追加的保证金数量（aToken，18 位精度）/ Collateral amount to add (aToken, 18 decimals)
     */
    function addCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) {
            emit CheckFailedAmountZero(msg.sender, "addCollateral");
            require(false, "PerpEngine: amount must be greater than 0");
        }

        Position storage position = positions[msg.sender];
        if (position.size == 0) {
            revert PositionNotFound();
        }

        position.collateral += amount;
        IERC20(address(collateralToken)).safeTransferFrom(msg.sender, address(this), amount);

        emit CollateralAdded(msg.sender, amount);
    }

    /**
     * @notice 清算仓位（当健康因子过低时，任何人都可以清算）/ Liquidate position (anyone can liquidate when health factor is too low)
     * @param user 被清算用户地址 / User address to liquidate
     * @dev 清算人会获得清算奖励，被清算用户会失去所有保证金 / Liquidator gets bonus, liquidated user loses all collateral
     */
    function liquidatePosition(address user) external nonReentrant {
        Position storage position = positions[user];
        if (position.size == 0) {
            emit CheckFailedNoPositionToLiquidate(user);
            require(false, "PerpEngine: no position to liquidate");
        }

        // 检查健康因子是否过低（< 1.0 表示可以清算）/ Check if health factor is too low (< 1.0 means can be liquidated)
        uint256 healthFactor = getPositionHealthFactor(user);
        if (healthFactor >= 1e18) {
            emit CheckFailedLiquidationHealthFactor(user, healthFactor);
            require(false, "PerpEngine: health factor not low enough");
        }

        // 获取当前价格 / Get current price
        (uint256 normalizedPrice,,) = oracle.getPriceWithStaleCheck(stockSymbol);

        // 计算 PnL 和资金费率费用 / Calculate PnL and funding fee
        uint256 pnl = _calculatePnL(position, position.size, normalizedPrice);
        uint256 fundingFee = _calculateFundingFee(position, position.size);

        // 计算实际盈亏 / Calculate actual PnL
        int256 actualPnL;
        if (position.side == PositionSide.LONG) {
            if (normalizedPrice >= position.entryPrice) {
                actualPnL = int256(pnl) - int256(fundingFee);
            } else {
                uint256 loss = DeFiMath.mul(position.size, position.entryPrice - normalizedPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        } else {
            if (normalizedPrice <= position.entryPrice) {
                actualPnL = int256(pnl) - int256(fundingFee);
            } else {
                uint256 loss = DeFiMath.mul(position.size, normalizedPrice - position.entryPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        }

        // 计算净保证金（可能为负）/ Calculate net collateral (may be negative)
        int256 netCollateral = int256(position.collateral) + actualPnL;

        // 清算人可以获得所有剩余保证金 + 清算奖励 / Liquidator gets all remaining collateral + liquidation bonus
        uint256 collateralToLiquidator = 0;
        if (netCollateral > 0) {
            // 如果还有剩余保证金，清算人获得剩余部分 + 奖励 / If there's remaining collateral, liquidator gets remainder + bonus
            uint256 remainingCollateral = uint256(netCollateral);
            uint256 liquidationBonus = DeFiMath.mul(remainingCollateral, liquidationBonusRate);
            collateralToLiquidator = remainingCollateral + liquidationBonus;

            // 如果奖励超过合约余额，只给合约中有的部分 / If bonus exceeds contract balance, only give what's available
            uint256 contractBalance = collateralToken.balanceOf(address(this));
            if (collateralToLiquidator > contractBalance) {
                collateralToLiquidator = contractBalance;
            }
        } else {
            // 如果净保证金为负，清算人仍然可以获得清算奖励（从系统资金池中） / If net collateral is negative, liquidator still gets bonus (from system pool)
            // 这里简化处理：如果合约有余额，给清算人一部分作为奖励 / Simplified: if contract has balance, give liquidator part as bonus
            uint256 contractBalance = collateralToken.balanceOf(address(this));
            if (contractBalance > 0) {
                uint256 minBonus = DeFiMath.mul(position.collateral, liquidationBonusRate);
                collateralToLiquidator = minBonus > contractBalance ? contractBalance : minBonus;
            }
        }

        // 保存仓位信息用于事件 / Save position info for event
        PositionSide side = position.side;
        uint256 size = position.size;
        uint256 collateral = position.collateral;

        // 清除仓位 / Clear position
        delete positions[user];

        // 转移保证金给清算人 / Transfer collateral to liquidator
        if (collateralToLiquidator > 0) {
            IERC20(address(collateralToken)).safeTransfer(msg.sender, collateralToLiquidator);
        }

        emit PositionLiquidated(user, msg.sender, side, size, collateral, collateralToLiquidator);
    }

    /**
     * @notice 提取保证金（需要满足维持保证金率）/ Withdraw collateral (must satisfy maintenance margin rate)
     * @param amount 提取的保证金数量（aToken，18 位精度）/ Collateral amount to withdraw (aToken, 18 decimals)
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "PerpEngine: amount must be greater than 0");

        Position storage position = positions[msg.sender];
        if (position.size == 0) {
            revert PositionNotFound();
        }

        // 检查提取后是否满足维持保证金率 / Check if withdrawal satisfies maintenance margin rate
        uint256 newCollateral = position.collateral - amount;
        uint256 requiredMaintenanceMargin = DeFiMath.mul(position.size, maintenanceMarginRate);

        require(newCollateral >= requiredMaintenanceMargin, "PerpEngine: insufficient collateral after withdrawal");

        // 检查健康因子 / Check health factor
        uint256 healthFactor = getPositionHealthFactor(msg.sender);
        require(healthFactor >= 1e18, "PerpEngine: health factor too low");

        position.collateral = newCollateral;
        IERC20(address(collateralToken)).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    /**
     * @notice 获取仓位 PnL / Get position PnL
     * @param user 用户地址 / User address
     * @return pnl 未实现盈亏（归一化到 18 位精度）/ Unrealized PnL (normalized to 18 decimals)
     * @return fundingFee 累计资金费率费用（归一化到 18 位精度）/ Accumulated funding fee (normalized to 18 decimals)
     */
    function getPositionPnL(address user) external view returns (int256 pnl, uint256 fundingFee) {
        Position memory position = positions[user];
        if (position.size == 0) {
            return (0, 0);
        }

        // 获取当前价格 / Get current price
        (uint256 price,) = oracle.getPrice(stockSymbol);
        uint256 normalizedPrice = DeFiMath.normalizeOraclePrice(price);

        // 计算 PnL（只返回盈利部分）/ Calculate PnL (only returns profit)
        uint256 pnlAmount = _calculatePnL(position, position.size, normalizedPrice);

        // 计算资金费率费用 / Calculate funding fee
        fundingFee = _calculateFundingFee(position, position.size);

        // 计算实际盈亏（考虑亏损情况）/ Calculate actual PnL (considering loss)
        // 做多：如果价格下跌，计算亏损 / Long: if price drops, calculate loss
        // 做空：如果价格上涨，计算亏损 / Short: if price rises, calculate loss
        int256 actualPnL;
        if (position.side == PositionSide.LONG) {
            if (normalizedPrice >= position.entryPrice) {
                // 做多盈利 / Long profit
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                // 做多亏损 / Long loss
                uint256 loss = DeFiMath.mul(position.size, position.entryPrice - normalizedPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        } else {
            if (normalizedPrice <= position.entryPrice) {
                // 做空盈利 / Short profit
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                // 做空亏损 / Short loss
                uint256 loss = DeFiMath.mul(position.size, normalizedPrice - position.entryPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        }

        pnl = actualPnL;
    }

    /**
     * @notice 获取仓位健康因子 / Get position health factor
     * @param user 用户地址 / User address
     * @return 健康因子（归一化到 18 位精度），>= 1e18 表示健康 / Health factor (normalized to 18 decimals), >= 1e18 means healthy
     */
    function getPositionHealthFactor(address user) public view returns (uint256) {
        Position memory position = positions[user];
        if (position.size == 0) {
            return type(uint256).max;
        }

        // 获取当前价格 / Get current price
        (uint256 price,) = oracle.getPrice(stockSymbol);
        uint256 normalizedPrice = DeFiMath.normalizeOraclePrice(price);

        // 计算 PnL（只返回盈利部分）/ Calculate PnL (only returns profit)
        uint256 pnlAmount = _calculatePnL(position, position.size, normalizedPrice);

        // 计算资金费率费用 / Calculate funding fee
        uint256 fundingFee = _calculateFundingFee(position, position.size);

        // 计算实际盈亏（考虑亏损情况）/ Calculate actual PnL (considering loss)
        int256 actualPnL;
        if (position.side == PositionSide.LONG) {
            if (normalizedPrice >= position.entryPrice) {
                // 做多盈利 / Long profit
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                // 做多亏损 / Long loss
                uint256 loss = DeFiMath.mul(position.size, position.entryPrice - normalizedPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        } else {
            if (normalizedPrice <= position.entryPrice) {
                // 做空盈利 / Short profit
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                // 做空亏损 / Short loss
                uint256 loss = DeFiMath.mul(position.size, normalizedPrice - position.entryPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        }

        // 计算净保证金（保证金 + 实际 PnL）/ Calculate net collateral (collateral + actual PnL)
        int256 netCollateral = int256(position.collateral) + actualPnL;

        if (netCollateral < 0) {
            return 0;
        }

        // 计算维持保证金要求 / Calculate maintenance margin requirement
        uint256 requiredMargin = DeFiMath.mul(position.size, maintenanceMarginRate);

        if (requiredMargin == 0) {
            return type(uint256).max;
        }

        // 健康因子 = 净保证金 / 维持保证金要求 / Health factor = net collateral / maintenance margin requirement
        return DeFiMath.div(uint256(netCollateral) * 1e18, requiredMargin);
    }

    /**
     * @notice 计算 PnL / Calculate PnL
     * @param position 仓位信息 / Position information
     * @param size 仓位大小 / Position size
     * @param currentPrice 当前价格（归一化到 18 位精度）/ Current price (normalized to 18 decimals)
     * @return pnl 盈亏（归一化到 18 位精度，可能为 0 如果亏损）/ PnL (normalized to 18 decimals, may be 0 if loss)
     * @dev 只返回盈利部分，亏损由调用方从保证金中扣除 / Only returns profit, loss is deducted from collateral by caller
     */
    function _calculatePnL(Position memory position, uint256 size, uint256 currentPrice)
        internal
        pure
        returns (uint256)
    {
        if (position.side == PositionSide.LONG) {
            // 做多：价格上涨盈利 / Long: profit when price rises
            if (currentPrice > position.entryPrice) {
                // 盈利 = 仓位大小 * (当前价格 - 开仓价格) / 开仓价格 / Profit = size * (currentPrice - entryPrice) / entryPrice
                return DeFiMath.mul(size, currentPrice - position.entryPrice) / position.entryPrice;
            }
        } else {
            // 做空：价格下跌盈利 / Short: profit when price falls
            if (currentPrice < position.entryPrice) {
                // 盈利 = 仓位大小 * (开仓价格 - 当前价格) / 开仓价格 / Profit = size * (entryPrice - currentPrice) / entryPrice
                return DeFiMath.mul(size, position.entryPrice - currentPrice) / position.entryPrice;
            }
        }
        // 亏损或价格未变化，返回 0 / Loss or no price change, return 0
        return 0;
    }

    /**
     * @notice 计算资金费率费用 / Calculate funding fee
     * @param position 仓位信息 / Position information
     * @param size 仓位大小 / Position size
     * @return fee 资金费率费用（归一化到 18 位精度）/ Funding fee (normalized to 18 decimals)
     */
    function _calculateFundingFee(Position memory position, uint256 size) internal view returns (uint256) {
        if (position.lastFundingTimestamp == 0) {
            return 0;
        }

        // 计算经过的时间（秒）/ Calculate elapsed time (seconds)
        uint256 elapsedTime = block.timestamp - position.lastFundingTimestamp;

        // 计算资金费率费用 = 仓位大小 * 资金费率 * 经过时间 / 年 / Funding fee = position size * funding rate * elapsed time / year
        uint256 fee = DeFiMath.mul(size, fundingRate);
        fee = DeFiMath.mul(fee, elapsedTime);
        fee = fee / 365 days;

        return fee;
    }

    /**
     * @notice 设置初始保证金率 / Set initial margin rate
     * @param _rate 新的初始保证金率（归一化到 18 位精度）/ New initial margin rate (normalized to 18 decimals)
     */
    function setInitialMarginRate(uint256 _rate) external onlyOwner {
        if (_rate == 0 || _rate > 1e18) {
            emit CheckFailedParamOutOfRange("initialMarginRate", _rate, 1e18);
            require(false, "PerpEngine: invalid initial margin rate");
        }
        initialMarginRate = _rate;
    }

    /**
     * @notice 设置维持保证金率 / Set maintenance margin rate
     * @param _rate 新的维持保证金率（归一化到 18 位精度）/ New maintenance margin rate (normalized to 18 decimals)
     */
    function setMaintenanceMarginRate(uint256 _rate) external onlyOwner {
        if (_rate == 0 || _rate >= initialMarginRate) {
            emit CheckFailedParamOutOfRange("maintenanceMarginRate", _rate, initialMarginRate);
            require(false, "PerpEngine: invalid maintenance margin rate");
        }
        maintenanceMarginRate = _rate;
    }

    /**
     * @notice 设置资金费率 / Set funding rate
     * @param _rate 新的资金费率（年化，归一化到 18 位精度）/ New funding rate (annualized, normalized to 18 decimals)
     */
    function setFundingRate(uint256 _rate) external onlyOwner {
        fundingRate = _rate;
    }

    /**
     * @notice 设置资金费率更新间隔 / Set funding rate update interval
     * @param _interval 新的更新间隔（秒）/ New update interval (seconds)
     */
    function setFundingInterval(uint256 _interval) external onlyOwner {
        if (_interval == 0) {
            emit CheckFailedParamOutOfRange("fundingInterval", _interval, 0);
            require(false, "PerpEngine: invalid funding interval");
        }
        fundingInterval = _interval;
    }

    /**
     * @notice 设置清算奖励率 / Set liquidation bonus rate
     * @param _rate 新的清算奖励率（归一化到 18 位精度）/ New liquidation bonus rate (normalized to 18 decimals)
     */
    function setLiquidationBonusRate(uint256 _rate) external onlyOwner {
        if (_rate == 0 || _rate > 0.2 * 1e18) {
            emit CheckFailedParamOutOfRange("liquidationBonusRate", _rate, 0.2 * 1e18);
            require(false, "PerpEngine: invalid liquidation bonus rate"); // 最大 20% / Max 20%
        }
        liquidationBonusRate = _rate;
    }
}
