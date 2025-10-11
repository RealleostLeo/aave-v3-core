// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TickMath.sol";
import "./FullMath.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/IUniswapV3Pool.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract UniswapV3TWAPWithFallback {
    address public owner;
    uint32 public twapDuration; // seconds
    address public baseCurrency;
    uint256 public baseCurrencyUnit;

    struct Manual {
        uint256 priceX18;
        uint256 updatedAt;
    }

    mapping(address => address) public assetToPool;
    mapping(address => bool) public assetIsToken0;
    mapping(address => Manual) public manualPrice;
    mapping(address => bool) public useManualFallback;

    event PoolSet(address indexed asset, address indexed pool, bool assetIsToken0);
    event PoolRemoved(address indexed asset);
    event TwapDurationSet(uint32 newDuration);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event ManualPriceSet(address indexed asset, uint256 priceX18);
    event ManualPriceCleared(address indexed asset);
    event UseManualFallbackSet(address indexed asset, bool enabled);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    constructor(uint32 _twapDuration, uint256 _baseCurrencyUnit, address _baseCurrency) {
        require(_twapDuration > 0, "twap>0");
        require(_baseCurrency != address(0), "base=0");
        owner = msg.sender;
        twapDuration = _twapDuration;
        baseCurrency = _baseCurrency;
        baseCurrencyUnit = _baseCurrencyUnit;
    }

    // ---------- admin ----------
    function transferOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPool(address asset, address pool, bool _assetIsToken0) external onlyOwner {
        require(asset != address(0) && pool != address(0), "zero addr");
        assetToPool[asset] = pool;
        assetIsToken0[asset] = _assetIsToken0;
        emit PoolSet(asset, pool, _assetIsToken0);
    }

    function removePool(address asset) external onlyOwner {
        delete assetToPool[asset];
        delete assetIsToken0[asset];
        emit PoolRemoved(asset);
    }

    function setTwapDuration(uint32 _twapDuration) external onlyOwner {
        require(_twapDuration > 0, "twap>0");
        twapDuration = _twapDuration;
        emit TwapDurationSet(_twapDuration);
    }

    function setManualPrice(address asset, uint256 priceX18) external onlyOwner {
        require(asset != address(0), "zero asset");
        require(priceX18 > 0, "price>0");
        manualPrice[asset] = Manual(priceX18, block.timestamp);
        emit ManualPriceSet(asset, priceX18);
    }

    function clearManualPrice(address asset) external onlyOwner {
        delete manualPrice[asset];
        emit ManualPriceCleared(asset);
    }

    function setUseManualFallback(address asset, bool enabled) external onlyOwner {
        useManualFallback[asset] = enabled;
        emit UseManualFallbackSet(asset, enabled);
    }

    // ---------- view / main ----------
    function getAssetPrice(address asset) external view returns (uint256) {
        if (asset == baseCurrency) {
            return baseCurrencyUnit; // baseCurrency itself = 1.0 * baseCurrencyUnit
        }

        address pool = assetToPool[asset];
        require(pool != address(0), "pool not set");

        uint32 ;
        secondsAgos[0] = twapDuration;
        secondsAgos[1] = 0;

        // try the DEX TWAP path
        try IUniswapV3Pool(pool).observe(secondsAgos)
            returns (int56[] memory tickCumulatives, uint160[] memory)
        {
            int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
            int24 twapTick = int24(tickDelta / int56(int32(twapDuration)));
            if (tickDelta < 0 && (tickDelta % int56(int32(twapDuration)) != 0)) {
                twapTick--; // rounding toward negative infinity
            }

            uint256 dexPriceX18 = _priceFromTick(pool, asset, twapTick);
            if (dexPriceX18 > 0) {
                return dexPriceX18;
            }
        } catch {
            // observe failed, continue to fallback
        }

        // fallback to manual
        if (useManualFallback[asset]) {
            Manual memory m = manualPrice[asset];
            if (m.priceX18 > 0) return m.priceX18;
        }

        revert("price unavailable");
    }

    function _priceFromTick(
        address pool,
        address asset,
        int24 twapTick
    ) internal view returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(twapTick);
        if (sqrtPriceX96 == 0) return 0;

        unchecked {
            uint256 sqrtPriceSquared = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            uint256 denom = uint256(1) << 192;

            if (assetIsToken0[asset]) {
                // asset = token0, want quote (=token1)
                return FullMath.mulDiv(sqrtPriceSquared, baseCurrencyUnit, denom);
            } else {
                // asset = token1, want quote (=token0)
                return FullMath.mulDiv(denom, baseCurrencyUnit, sqrtPriceSquared);
            }
        }
    }
}
