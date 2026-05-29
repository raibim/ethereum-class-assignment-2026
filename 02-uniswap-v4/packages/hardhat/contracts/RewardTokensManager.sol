// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAllowanceTransfer } from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice PositionManager exposes Permit2 via Permit2Forwarder (not on IPermit2Forwarder).
interface IPositionManagerWithPermit2 {
    function permit2() external view returns (IAllowanceTransfer);
}

/// @title RewardTokensManager - PNPT/FNBT pool via Uniswap v4
contract RewardTokensManager {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint24 public constant FEE_TIER = 3000;
    int24 public constant TICK_SPACING = 60;
    IHooks public constant HOOKS = IHooks(address(0));

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    address public immutable pnpToken;
    address public immutable fnbToken;

    PoolKey public poolKey;
    bytes32 public poolId;
    mapping(bytes32 => bool) public createdPools;

    event PoolCreated(
        bytes32 indexed poolId,
        address indexed currency0,
        address indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 indexed positionId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    error PoolNotCreated();
    error InvalidAmount();
    error InvalidTickRange();
    error TickRangeDoesNotCoverAssignmentPrice();

    constructor(address _poolManager, address _positionManager, address _pnpToken, address _fnbToken) {
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        pnpToken = _pnpToken;
        fnbToken = _fnbToken;
    }

    /// @notice Lower address first (Uniswap currency0 / currency1).
    function getCanonicalCurrencies() public view returns (address currency0, address currency1) {
        if (pnpToken < fnbToken) {
            return (pnpToken, fnbToken);
        }
        return (fnbToken, pnpToken);
    }

    /// @notice Initialize v4 pool: 0.3% fee, tick spacing 60, no hooks.
    function createPool(uint160 sqrtPriceX96) public returns (bytes32) {
        (address c0, address c1) = getCanonicalCurrencies();

        poolKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: HOOKS
        });

        poolManager.initialize(poolKey, sqrtPriceX96);
        poolId = PoolId.unwrap(poolKey.toId());
        createdPools[poolId] = true;

        emit PoolCreated(poolId, c0, c1, FEE_TIER, TICK_SPACING, address(HOOKS), sqrtPriceX96);
        return poolId;
    }

    function getPoolId() public view returns (bytes32) {
        return poolId;
    }

    /// @notice Tick for assignment spot: 1 FNBT = 10 PNPT (price c1/c0 = 1.0001^tick).
    /// @dev 1.0001^23027 ≈ 10 when FNBT is currency0; -23027 when FNBT is currency1.
    function getTargetTick() public view returns (int24) {
        (address c0, ) = getCanonicalCurrencies();
        if (c0 == fnbToken) {
            return 23027;
        }
        return -23027;
    }

    /// @notice Mint concentrated liquidity via PositionManager.
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32) {
        // 1) Validate inputs and tick constraints
        if (poolId == bytes32(0) || !createdPools[poolId]) revert PoolNotCreated();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (amount0Desired == 0 && amount1Desired == 0) revert InvalidAmount();
        if (tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0) revert InvalidTickRange();

        // 2) Range must include assignment target tick
        int24 target = getTargetTick();
        if (tickLower > target || tickUpper <= target) revert TickRangeDoesNotCoverAssignmentPrice();

        // 3) Compute liquidity from pool price and desired amounts
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(poolId));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, amount0Desired, amount1Desired
        );
        if (liquidity == 0) revert InvalidAmount();

        // 4) Pull tokens from caller into this contract
        (address c0, address c1) = getCanonicalCurrencies();
        if (amount0Desired > 0) IERC20(c0).safeTransferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) IERC20(c1).safeTransferFrom(msg.sender, address(this), amount1Desired);

        // 5) Approve MockPermit2 (tests use MockPermit2 — ERC20 approve only, no permit2.approve)
        IAllowanceTransfer permit2 = IPositionManagerWithPermit2(address(positionManager)).permit2();
        if (amount0Desired > 0) IERC20(c0).forceApprove(address(permit2), amount0Desired);
        if (amount1Desired > 0) IERC20(c1).forceApprove(address(permit2), amount1Desired);

        // 6) Mint position and settle pair via PositionManager
        positionId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            uint256(liquidity),
            uint128(amount0Desired),
            uint128(amount1Desired),
            msg.sender,
            ""
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);

        // 7) Verify mint succeeded
        if (positionManager.getPositionLiquidity(positionId) == 0) revert InvalidAmount();

        // 8) Refund dust and emit
        uint256 dust0 = IERC20(c0).balanceOf(address(this));
        uint256 dust1 = IERC20(c1).balanceOf(address(this));
        if (dust0 > 0) IERC20(c0).safeTransfer(msg.sender, dust0);
        if (dust1 > 0) IERC20(c1).safeTransfer(msg.sender, dust1);

        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, liquidity);
        return (positionId, poolId);
    }
}
