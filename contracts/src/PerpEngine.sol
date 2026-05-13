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
 */
contract PerpEngine is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using DeFiMath for uint256;

    /// @notice 仓位方向枚举 / Position direction enum
    enum PositionSide {
        LONG,
        SHORT
    }

    /// @notice 仓位信息结构体 / Position information struct
    struct Position {
        PositionSide side;
        uint256 size;
        uint256 entryPrice;
        uint256 collateral;
        uint256 entryTimestamp;
        uint256 lastFundingTimestamp;
    }

    /// @notice 价格预言机 / Price oracle
    StockOracle public oracle;

    /// @notice 股票符号 / Stock symbol
    string public stockSymbol;

    /// @notice aToken 地址（作为保证金）/ aToken address (as collateral)
    aToken public collateralToken;

    /// @notice 用户仓位映射 / User position mapping
    mapping(address => Position) public positions;

    /// @notice 初始保证金率 / Initial margin rate
    uint256 public initialMarginRate = 0.1 * 1e18;

    /// @notice 维持保证金率 / Maintenance margin rate
    uint256 public maintenanceMarginRate = 0.05 * 1e18;

    /// @notice 资金费率（年化）/ Funding rate (annualized)
    uint256 public fundingRate = 0.01 * 1e18;

    /// @notice 资金费率更新间隔（秒）/ Funding rate update interval (seconds)
    uint256 public fundingInterval = 8 hours;

    /// @notice 清算奖励率 / Liquidation bonus rate
    uint256 public liquidationBonusRate = 0.05 * 1e18;

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

    /// @notice 事件：资金费率更新 / Event: Funding rate updated
    event FundingRateUpdated(uint256 oldRate, uint256 newRate);

    // ============ 检查失败事件 / Check Failure Events ============
    event CheckFailedInvalidAddress(string reason, address value);
    event CheckFailedAmountZero(address indexed user, string context);
    event CheckFailedPriceStale(address indexed user, string context);
    event CheckFailedInsufficientCollateral(address indexed user, uint256 required, uint256 provided);
    event CheckFailedOppositePosition(address indexed user);
    event CheckFailedCloseSizeExceedsPosition(address indexed user, uint256 closeSize, uint256 positionSize);
    event CheckFailedNoPositionToLiquidate(address indexed user);
    event CheckFailedLiquidationHealthFactor(address indexed user, uint256 healthFactor);
    event CheckFailedInsufficientCollateralAfterWithdraw(
        address indexed user, uint256 newCollateral, uint256 requiredMaintenance
    );
    event CheckFailedHealthFactorTooLow(address indexed user, uint256 healthFactor);
    event CheckFailedParamOutOfRange(string param, uint256 value, uint256 minOrMax);

    error PositionNotFound();
    error PriceStale();
    error InsufficientCollateral();
    error HealthFactorTooLow();
    error InvalidPositionSide();
    error InvalidPositionSize();

    /**
     * @notice 构造函数 / Constructor
     * @param oracleAddr 价格预言机地址 / Price oracle address
     * @param stockSymbolStr 股票符号 / Stock symbol
     * @param collateralTokenAddr aToken 地址 / aToken address
     * @param initialOwner 合约所有者地址 / Contract owner address
     */
    constructor(address oracleAddr, string memory stockSymbolStr, address collateralTokenAddr, address initialOwner)
        Ownable(initialOwner)
    {
        if (oracleAddr == address(0)) {
            emit CheckFailedInvalidAddress("PerpEngine: invalid oracle", oracleAddr);
            require(false, "PerpEngine: invalid oracle");
        }
        if (collateralTokenAddr == address(0)) {
            emit CheckFailedInvalidAddress("PerpEngine: invalid collateral token", collateralTokenAddr);
            require(false, "PerpEngine: invalid collateral token");
        }
        if (initialOwner == address(0)) {
            emit CheckFailedInvalidAddress("PerpEngine: invalid owner", initialOwner);
            require(false, "PerpEngine: invalid owner");
        }

        oracle = StockOracle(oracleAddr);
        stockSymbol = stockSymbolStr;
        collateralToken = aToken(collateralTokenAddr);
    }

    /**
     * @notice 开仓 / Open position
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

        // slither-disable-next-line unused-return
        (uint256 normalizedPrice,, bool isStale) = oracle.getPriceWithStaleCheck(stockSymbol);
        if (isStale && oracle.circuitBreakerEnabled()) {
            emit CheckFailedPriceStale(msg.sender, "openPosition");
            revert PriceStale();
        }

        uint256 requiredCollateral = DeFiMath.mul(size, initialMarginRate);
        if (collateralAmount < requiredCollateral) {
            emit CheckFailedInsufficientCollateral(msg.sender, requiredCollateral, collateralAmount);
            require(false, "PerpEngine: insufficient collateral for initial margin");
        }

        Position storage position = positions[msg.sender];
        if (position.size > 0) {
            if (position.side == side) {
                uint256 totalValue =
                    DeFiMath.mul(position.size, position.entryPrice) + DeFiMath.mul(size, normalizedPrice);
                uint256 totalSize = position.size + size;
                position.entryPrice = DeFiMath.div(totalValue, totalSize);
                position.size = totalSize;
                position.collateral += collateralAmount;
            } else {
                emit CheckFailedOppositePosition(msg.sender);
                revert("PerpEngine: cannot open opposite position, close first");
            }
        } else {
            position.side = side;
            position.size = size;
            position.entryPrice = normalizedPrice;
            position.collateral = collateralAmount;
            position.entryTimestamp = block.timestamp;
            position.lastFundingTimestamp = block.timestamp;
        }

        IERC20(address(collateralToken)).safeTransferFrom(msg.sender, address(this), collateralAmount);

        emit PositionOpened(msg.sender, side, size, normalizedPrice, collateralAmount);
    }

    /**
     * @notice 平仓 / Close position
     */
    function closePosition(uint256 size) external nonReentrant {
        Position storage position = positions[msg.sender];
        if (position.size == 0) {
            revert PositionNotFound();
        }

        if (size == 0) {
            size = position.size;
        }

        if (size > position.size) {
            emit CheckFailedCloseSizeExceedsPosition(msg.sender, size, position.size);
            require(false, "PerpEngine: close size exceeds position size");
        }

        // slither-disable-next-line unused-return
        (uint256 normalizedPrice,,) = oracle.getPriceWithStaleCheck(stockSymbol);

        uint256 pnl = _calculatePnL(position, size, normalizedPrice);
        uint256 fundingFee = _calculateFundingFee(position, size);
        int256 netPnL = int256(pnl) - int256(fundingFee);

        uint256 collateralRatio = DeFiMath.div(position.collateral, position.size);
        uint256 collateralToReturn = DeFiMath.mul(size, collateralRatio);

        if (netPnL > 0) {
            collateralToReturn += uint256(netPnL);
        } else {
            uint256 loss = uint256(-netPnL);
            if (loss > collateralToReturn) {
                collateralToReturn = 0;
            } else {
                collateralToReturn -= loss;
            }
        }

        position.size -= size;
        position.collateral -= DeFiMath.mul(size, collateralRatio);

        if (position.size == 0) {
            delete positions[msg.sender];
        } else {
            position.lastFundingTimestamp = block.timestamp;
        }

        if (collateralToReturn > 0) {
            IERC20(address(collateralToken)).safeTransfer(msg.sender, collateralToReturn);
        }

        emit PositionClosed(msg.sender, position.side, size, normalizedPrice, pnl, fundingFee);
    }

    /**
     * @notice 追加保证金 / Add collateral
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
     * @notice 清算仓位 / Liquidate position
     */
    function liquidatePosition(address user) external nonReentrant {
        Position storage position = positions[user];
        if (position.size == 0) {
            emit CheckFailedNoPositionToLiquidate(user);
            require(false, "PerpEngine: no position to liquidate");
        }

        uint256 healthFactor = getPositionHealthFactor(user);
        if (healthFactor >= 1e18) {
            emit CheckFailedLiquidationHealthFactor(user, healthFactor);
            require(false, "PerpEngine: health factor not low enough");
        }

        // slither-disable-next-line unused-return
        (uint256 normalizedPrice,,) = oracle.getPriceWithStaleCheck(stockSymbol);

        uint256 pnl = _calculatePnL(position, position.size, normalizedPrice);
        uint256 fundingFee = _calculateFundingFee(position, position.size);

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

        int256 netCollateral = int256(position.collateral) + actualPnL;

        uint256 collateralToLiquidator = 0;
        if (netCollateral > 0) {
            uint256 remainingCollateral = uint256(netCollateral);
            uint256 liquidationBonus = DeFiMath.mul(remainingCollateral, liquidationBonusRate);
            collateralToLiquidator = remainingCollateral + liquidationBonus;

            uint256 contractBalance = collateralToken.balanceOf(address(this));
            if (collateralToLiquidator > contractBalance) {
                collateralToLiquidator = contractBalance;
            }
        } else {
            uint256 contractBalance = collateralToken.balanceOf(address(this));
            if (contractBalance > 0) {
                uint256 minBonus = DeFiMath.mul(position.collateral, liquidationBonusRate);
                collateralToLiquidator = minBonus > contractBalance ? contractBalance : minBonus;
            }
        }

        PositionSide side = position.side;
        uint256 size = position.size;
        uint256 collateral = position.collateral;

        delete positions[user];

        if (collateralToLiquidator > 0) {
            IERC20(address(collateralToken)).safeTransfer(msg.sender, collateralToLiquidator);
        }

        emit PositionLiquidated(user, msg.sender, side, size, collateral, collateralToLiquidator);
    }

    /**
     * @notice 提取保证金 / Withdraw collateral
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "PerpEngine: amount must be greater than 0");

        Position storage position = positions[msg.sender];
        if (position.size == 0) {
            revert PositionNotFound();
        }

        uint256 newCollateral = position.collateral - amount;
        uint256 requiredMaintenanceMargin = DeFiMath.mul(position.size, maintenanceMarginRate);

        require(newCollateral >= requiredMaintenanceMargin, "PerpEngine: insufficient collateral after withdrawal");

        uint256 healthFactor = getPositionHealthFactor(msg.sender);
        require(healthFactor >= 1e18, "PerpEngine: health factor too low");

        position.collateral = newCollateral;
        IERC20(address(collateralToken)).safeTransfer(msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, amount);
    }

    /**
     * @notice 获取仓位 PnL / Get position PnL
     */
    function getPositionPnL(address user) external view returns (int256 pnl, uint256 fundingFee) {
        Position memory position = positions[user];
        if (position.size == 0) {
            return (0, 0);
        }

        // slither-disable-next-line unused-return
        (uint256 price,) = oracle.getPrice(stockSymbol);
        uint256 normalizedPrice = DeFiMath.normalizeOraclePrice(price);

        uint256 pnlAmount = _calculatePnL(position, position.size, normalizedPrice);
        fundingFee = _calculateFundingFee(position, position.size);

        int256 actualPnL;
        if (position.side == PositionSide.LONG) {
            if (normalizedPrice >= position.entryPrice) {
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                uint256 loss = DeFiMath.mul(position.size, position.entryPrice - normalizedPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        } else {
            if (normalizedPrice <= position.entryPrice) {
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                uint256 loss = DeFiMath.mul(position.size, normalizedPrice - position.entryPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        }

        pnl = actualPnL;
    }

    /**
     * @notice 获取仓位健康因子 / Get position health factor
     */
    function getPositionHealthFactor(address user) public view returns (uint256) {
        Position memory position = positions[user];
        if (position.size == 0) {
            return type(uint256).max;
        }

        // slither-disable-next-line unused-return
        (uint256 price,) = oracle.getPrice(stockSymbol);
        uint256 normalizedPrice = DeFiMath.normalizeOraclePrice(price);

        uint256 pnlAmount = _calculatePnL(position, position.size, normalizedPrice);
        uint256 fundingFee = _calculateFundingFee(position, position.size);

        int256 actualPnL;
        if (position.side == PositionSide.LONG) {
            if (normalizedPrice >= position.entryPrice) {
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                uint256 loss = DeFiMath.mul(position.size, position.entryPrice - normalizedPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        } else {
            if (normalizedPrice <= position.entryPrice) {
                actualPnL = int256(pnlAmount) - int256(fundingFee);
            } else {
                uint256 loss = DeFiMath.mul(position.size, normalizedPrice - position.entryPrice) / position.entryPrice;
                actualPnL = -int256(loss) - int256(fundingFee);
            }
        }

        int256 netCollateral = int256(position.collateral) + actualPnL;

        if (netCollateral < 0) {
            return 0;
        }

        uint256 requiredMargin = DeFiMath.mul(position.size, maintenanceMarginRate);

        if (requiredMargin == 0) {
            return type(uint256).max;
        }

        return DeFiMath.div(uint256(netCollateral) * 1e18, requiredMargin);
    }

    function _calculatePnL(Position memory position, uint256 size, uint256 currentPrice)
        internal
        pure
        returns (uint256)
    {
        if (position.side == PositionSide.LONG) {
            if (currentPrice > position.entryPrice) {
                return DeFiMath.mul(size, currentPrice - position.entryPrice) / position.entryPrice;
            }
        } else {
            if (currentPrice < position.entryPrice) {
                return DeFiMath.mul(size, position.entryPrice - currentPrice) / position.entryPrice;
            }
        }
        return 0;
    }

    function _calculateFundingFee(Position memory position, uint256 size) internal view returns (uint256) {
        if (position.lastFundingTimestamp == 0) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp - position.lastFundingTimestamp;
        uint256 fee = DeFiMath.mul(size, fundingRate);
        fee = DeFiMath.mul(fee, elapsedTime);
        fee = fee / 365 days;

        return fee;
    }

    // ============ 管理员函数 / Admin Functions ============

    function setInitialMarginRate(uint256 newRate) external onlyOwner {
        if (newRate == 0 || newRate > 1e18) {
            emit CheckFailedParamOutOfRange("initialMarginRate", newRate, 1e18);
            require(false, "PerpEngine: invalid initial margin rate");
        }
        initialMarginRate = newRate;
    }

    function setMaintenanceMarginRate(uint256 newRate) external onlyOwner {
        if (newRate == 0 || newRate >= initialMarginRate) {
            emit CheckFailedParamOutOfRange("maintenanceMarginRate", newRate, initialMarginRate);
            require(false, "PerpEngine: invalid maintenance margin rate");
        }
        maintenanceMarginRate = newRate;
    }

    /**
     * @notice 设置资金费率 / Set funding rate
     * @param newRate 新的资金费率（年化，归一化到 18 位精度）/ New funding rate (annualized, normalized to 18 decimals)
     */
    function setFundingRate(uint256 newRate) external onlyOwner {
        uint256 oldRate = fundingRate;
        fundingRate = newRate;
        emit FundingRateUpdated(oldRate, newRate);
    }

    function setFundingInterval(uint256 newInterval) external onlyOwner {
        if (newInterval == 0) {
            emit CheckFailedParamOutOfRange("fundingInterval", newInterval, 0);
            require(false, "PerpEngine: invalid funding interval");
        }
        fundingInterval = newInterval;
    }

    function setLiquidationBonusRate(uint256 newRate) external onlyOwner {
        if (newRate == 0 || newRate > 0.2 * 1e18) {
            emit CheckFailedParamOutOfRange("liquidationBonusRate", newRate, 0.2 * 1e18);
            require(false, "PerpEngine: invalid liquidation bonus rate");
        }
        liquidationBonusRate = newRate;
    }
}
