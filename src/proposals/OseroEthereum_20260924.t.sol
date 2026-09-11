// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SparkLend} from "spark-address-registry/SparkLend.sol";

import {
    IALMProxyLike,
    IAccessControlsLike,
    IAllocatorVaultLike,
    IOseroPauControllerLike,
    IRateLimitsLike,
    ISpellLike
} from "../test-harness/OseroTestBase.sol";
import {CommonPauSpellTests, ExpectedIntegration} from "../test-harness/CommonPauSpellTests.sol";

import {OseroEthereum_20260924} from "./OseroEthereum_20260924.sol";

interface IPasConfiguratorLike {
    function beamState() external view returns (address);
    function setRateLimit(address rateLimits, bytes32 key, uint256 maxAmount, uint256 slope) external;
    function callControllerAction(address controller, bytes calldata data) external returns (bytes memory ret);
}

interface IPasBeamStateLike {
    function wards(address usr) external view returns (uint256);
    function stopped() external view returns (bool);
    function rateLimits(address rateLimits_) external view returns (uint256);
    function controllers(address controller) external view returns (uint256);
    function rateLimitsCBeams(address rateLimits_, address cBeam) external view returns (uint256);
    function controllersCBeams(address controller, address cBeam) external view returns (uint256);
    function getHop(address rateLimits_) external view returns (uint256);
    function addRateLimits(address rateLimits_) external;
    function addController(address controller) external;
    function addCBeam(address cBeam) external;
    function setCBeamForRateLimits(address rateLimits_, address cBeam) external;
    function setCBeamForController(address controller, address cBeam) external;
    function addInitRateLimits(bytes32 key, address rateLimits_, uint256 maxAmount, uint256 slope) external;
    function addInitControllerActions(bytes calldata data, address controller) external returns (bytes32 key);
}

contract OseroEthereum_20260924_Test is CommonPauSpellTests {
    // September 3, 2026: the pre-state readback block from the technical-scope forum post.
    uint256 internal constant MAINNET_FORK_BLOCK = 25_897_166;

    // Set once the September 24 payload is deployed.
    address internal constant DEPLOYED_PAYLOAD = address(0);

    // Sky PAS addresses from the chainlog, independently confirmed in the technical-scope forum post:
    // https://forum.skyeco.com/t/september-24-2026-proposed-changes-to-osero-for-upcoming-spell/28224
    address internal constant PAS_CONFIGURATOR = 0xb7E61Df6CAb0A51E9A5dab1A7DD3f942dDe5b929;
    address internal constant PAS_STATE = 0x1A1879E66547F90bfF87D45A5b0335950E019E02;

    address internal constant SPARKLEND_POOL = SparkLend.POOL;
    address internal constant SPARKLEND_USDS_SPTOKEN = SparkLend.USDS_SPTOKEN;

    bytes32 internal constant USDS_FACET_INTEGRATION_ID = "USDS_FACET";
    bytes32 internal constant AAVE_FACET_INTEGRATION_ID = "AAVE_FACET";

    // Rate-limit keys derived as in the diamond-pau USDSFacet/AaveFacet the controller dispatches to:
    // https://github.com/sky-ecosystem/diamond-pau/tree/5c5ad6ae174bf467081ca82342ced2bd42a5c732/src/facets
    bytes32 internal constant USDS_MINT_RATE_LIMIT_KEY = keccak256("LIMIT_USDS_MINT");
    bytes32 internal constant USDS_BURN_RATE_LIMIT_KEY = keccak256("LIMIT_USDS_BURN");
    bytes32 internal constant SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY =
        keccak256(abi.encode(keccak256("LIMIT_AAVE_DEPOSIT"), USDS, SPARKLEND_POOL, SPARKLEND_USDS_SPTOKEN));
    bytes32 internal constant SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY =
        keccak256(abi.encode(keccak256("LIMIT_AAVE_WITHDRAW"), SPARKLEND_POOL, SPARKLEND_USDS_SPTOKEN));

    uint256 internal constant USDS_MINT_MAX_LIMIT = 50_000_000e18;
    uint256 internal constant USDS_MINT_SLOPE = uint256(50_000_000e18) / 1 days;
    uint256 internal constant SPARKLEND_USDS_DEPOSIT_MAX = 50_000_000e18;
    uint256 internal constant SPARKLEND_USDS_DEPOSIT_SLOPE = uint256(50_000_000e18) / 1 days;
    uint256 internal constant SPARKLEND_USDS_MAX_SLIPPAGE = 0.9999e18;

    uint256 internal constant PREVIOUS_MAX_LIMIT = 5_000_000e18;
    uint256 internal constant PREVIOUS_SLOPE = uint256(5_000_000e18) / 1 days;
    uint256 internal constant UNLIMITED_LAST_UPDATED = 1_784_557_763;

    uint256 internal constant OPERATIONAL_TEST_AMOUNT = 6_000_000e18;
    // Short enough that the recovered amount stays below OPERATIONAL_TEST_AMOUNT (no max cap yet).
    uint256 internal constant PARTIAL_RECOVERY_TIME = 20 minutes;

    // --- PAS integration fixture (NOT part of this payload) ---
    // Osero registration and cBEAM pairing on the Sky-governed BeamState belong to a subsequent
    // Sky Core spell. The fixture below models that future state so the two DEFAULT_ADMIN_ROLE
    // grants in this payload can be exercised end-to-end through the Configurator.
    // Synthetic cBEAM standing in for the Osero cBEAM that Sky Core will pair.
    address internal constant FUTURE_OSERO_CBEAM = address(0xCBEA);
    // Configurator decrease within the registered default (no hop required).
    uint256 internal constant PAS_FIXTURE_LOWERED_MINT_MAX = 40_000_000e18;
    uint256 internal constant PAS_FIXTURE_LOWERED_MINT_SLOPE = uint256(40_000_000e18) / 1 days;
    // Configurator increase above the registered default: within BeamState maxChange (1.2x), after the hop.
    uint256 internal constant PAS_FIXTURE_RAISED_MINT_MAX = 55_000_000e18;
    // Controller admin action Sky Core would register for the Osero cBEAM; differs from the July value.
    uint256 internal constant PAS_FIXTURE_SPARKLEND_USDS_MAX_SLIPPAGE = 0.999e18;

    bytes32 internal constant ROLE_GRANTED = keccak256("RoleGranted(bytes32,address,address)");
    bytes32 internal constant ROLE_REVOKED = keccak256("RoleRevoked(bytes32,address,address)");
    bytes32 internal constant RATE_LIMIT_DATA_SET =
        keccak256("RateLimitDataSet(bytes32,uint256,uint256,uint256,uint256)");

    IERC20 internal constant spUsds = IERC20(SPARKLEND_USDS_SPTOKEN);
    IPasBeamStateLike internal constant beamState = IPasBeamStateLike(PAS_STATE);
    IPasConfiguratorLike internal constant configurator = IPasConfiguratorLike(PAS_CONFIGURATOR);

    // Configurator events (lib/pas/src/Configurator.sol), redeclared for `vm.expectEmit`.
    event SetRateLimit(address indexed rateLimits, bytes32 indexed key, uint256 maxAmount, uint256 slope);
    event CallControllerAction(address indexed controller, bytes data);

    constructor() {
        spellId = "20260924";
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), MAINNET_FORK_BLOCK);

        // The July launch and August PAS initialization are already on-chain at this block.
        // Osero registration and cBEAM pairing belong to a subsequent Sky Core spell.
        _setupPayload(DEPLOYED_PAYLOAD);
    }

    function test_ETHEREUM_scopeKeysAndEncodedParametersMatchTechnicalScope() public view {
        _assertContract(PAS_CONFIGURATOR, "pas-configurator");
        _assertContract(PAS_STATE, "pas-state");
        assertEq(IPasConfiguratorLike(PAS_CONFIGURATOR).beamState(), PAS_STATE, "configurator-beam-state-mismatch");
        assertEq(controller.accessControls(), OSERO_ACCESS_CONTROLS, "controller-access-controls-mismatch");
        assertEq(controller.rateLimits(), OSERO_RATE_LIMITS, "controller-rate-limits-mismatch");

        assertEq(controller.usds_mintRateLimitKey(), USDS_MINT_RATE_LIMIT_KEY, "mint-key-mismatch");
        assertEq(controller.usds_burnRateLimitKey(), USDS_BURN_RATE_LIMIT_KEY, "burn-key-mismatch");
        assertEq(
            controller.aave_getDepositRateLimitKey(SPARKLEND_USDS_SPTOKEN, SPARKLEND_POOL, USDS),
            SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY,
            "spark-deposit-key-mismatch"
        );
        assertEq(
            controller.aave_getWithdrawRateLimitKey(SPARKLEND_USDS_SPTOKEN, SPARKLEND_POOL),
            SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY,
            "spark-withdraw-key-mismatch"
        );

        OseroEthereum_20260924 spell = OseroEthereum_20260924(payload);
        assertEq(spell.USDS(), USDS, "payload-usds-mismatch");
        assertEq(spell.PAS_CONFIGURATOR(), PAS_CONFIGURATOR, "payload-configurator-mismatch");
        assertEq(spell.USDS_MINT_MAX_LIMIT(), USDS_MINT_MAX_LIMIT, "payload-mint-max-amount");
        assertEq(spell.USDS_MINT_SLOPE(), USDS_MINT_SLOPE, "payload-mint-slope");
        assertEq(spell.SPARKLEND_USDS_DEPOSIT_MAX(), SPARKLEND_USDS_DEPOSIT_MAX, "payload-deposit-max-amount");
        assertEq(spell.SPARKLEND_USDS_DEPOSIT_SLOPE(), SPARKLEND_USDS_DEPOSIT_SLOPE, "payload-deposit-slope");
    }

    function test_ETHEREUM_authorizePasConfigurator() public {
        IAccessControlsLike accessControls = IAccessControlsLike(OSERO_ACCESS_CONTROLS);

        assertFalse(accessControls.hasRole(DEFAULT_ADMIN_ROLE, PAS_CONFIGURATOR), "configurator-already-access-admin");
        assertFalse(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, PAS_CONFIGURATOR), "configurator-already-ratelimits-admin");
        assertEq(accessControls.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1, "access-admin-count-before");
        _assertRetainedRoles();

        _executeSpellViaStarGuard(payload);

        assertTrue(accessControls.hasRole(DEFAULT_ADMIN_ROLE, PAS_CONFIGURATOR), "configurator-missing-access-admin");
        assertTrue(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, PAS_CONFIGURATOR), "configurator-missing-ratelimits-admin");
        assertEq(accessControls.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2, "access-admin-count-after");
        _assertRetainedRoles();
    }

    function test_ETHEREUM_spellExecutionRaisesRateLimits() public {
        IRateLimitsLike.RateLimitData memory mintBefore = rateLimits.getRateLimitData(USDS_MINT_RATE_LIMIT_KEY);
        IRateLimitsLike.RateLimitData memory depositBefore =
            rateLimits.getRateLimitData(SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY);
        assertEq(mintBefore.maxAmount, PREVIOUS_MAX_LIMIT, "mint-max-before");
        assertEq(mintBefore.slope, PREVIOUS_SLOPE, "mint-slope-before");
        assertEq(depositBefore.maxAmount, PREVIOUS_MAX_LIMIT, "deposit-max-before");
        assertEq(depositBefore.slope, PREVIOUS_SLOPE, "deposit-slope-before");

        _executeSpellViaStarGuard(payload);

        _assertRateLimit(USDS_MINT_RATE_LIMIT_KEY, USDS_MINT_MAX_LIMIT, USDS_MINT_SLOPE, "mint");
        _assertRateLimit(
            SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY,
            SPARKLEND_USDS_DEPOSIT_MAX,
            SPARKLEND_USDS_DEPOSIT_SLOPE,
            "spark-deposit"
        );
    }

    function test_ETHEREUM_unlimitedRateLimitsAndLaunchConfigurationUnchanged() public {
        _assertLaunchConfiguration();
        _assertExistingUnlimitedRateLimit(USDS_BURN_RATE_LIMIT_KEY, "burn");
        _assertExistingUnlimitedRateLimit(SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY, "spark-withdraw");

        _executeSpellViaStarGuard(payload);

        _assertLaunchConfiguration();
        _assertExistingUnlimitedRateLimit(USDS_BURN_RATE_LIMIT_KEY, "burn");
        _assertExistingUnlimitedRateLimit(SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY, "spark-withdraw");
    }

    function test_ETHEREUM_spellEmitsOnlyExpectedRoleAndRateLimitChanges() public {
        vm.recordLogs();

        _executeSpellViaStarGuard(payload);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 accessGrants;
        uint256 rateLimitsGrants;
        uint256 mintUpdates;
        uint256 depositUpdates;

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            assertNotEq(logs[i].topics[0], ROLE_REVOKED, "unexpected-role-revoked");

            if (logs[i].topics[0] == ROLE_GRANTED) {
                assertEq(logs[i].topics[1], DEFAULT_ADMIN_ROLE, "unexpected-role-granted");
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(PAS_CONFIGURATOR))), "unexpected-role-grantee");
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(OSERO_PROXY))), "unexpected-role-sender");
                if (logs[i].emitter == OSERO_ACCESS_CONTROLS) accessGrants++;
                else if (logs[i].emitter == OSERO_RATE_LIMITS) rateLimitsGrants++;
                else fail("unexpected-role-emitter");
            }

            if (logs[i].topics[0] == RATE_LIMIT_DATA_SET) {
                assertEq(logs[i].emitter, OSERO_RATE_LIMITS, "unexpected-rate-limit-emitter");
                bytes32 key = logs[i].topics[1];
                if (key == USDS_MINT_RATE_LIMIT_KEY) mintUpdates++;
                else if (key == SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY) depositUpdates++;
                else fail("unexpected-rate-limit-key");
            }
        }

        assertEq(accessGrants, 1, "unexpected-access-grant-count");
        assertEq(rateLimitsGrants, 1, "unexpected-ratelimits-grant-count");
        assertEq(mintUpdates, 1, "unexpected-mint-update-count");
        assertEq(depositUpdates, 1, "unexpected-deposit-update-count");
    }

    function test_ETHEREUM_directPayloadExecutionRevertsWithoutSubProxyAuthority() public {
        // The first action grants a role on AccessControls, which requires DEFAULT_ADMIN_ROLE.
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", payload, DEFAULT_ADMIN_ROLE)
        );
        ISpellLike(payload).execute();
    }

    function test_ETHEREUM_pasRejectsUnpairedCallerAfterAuthorization() public {
        _executeSpellViaStarGuard(payload);

        vm.prank(PERMISSIONLESS_EXECUTOR);
        vm.expectRevert(bytes("Configurator/not-authorized-ratelimits-cBeam"));
        configurator.setRateLimit(OSERO_RATE_LIMITS, USDS_MINT_RATE_LIMIT_KEY, 1, 1);
    }

    function test_ETHEREUM_pasConfiguratorSetsRateLimitAfterAuthorizationAndFuturePairing() public {
        _executeSpellViaStarGuard(payload);
        _pairFutureOseroCBeamAsSkyCore();

        // Decrease within the registered default: no hop involved.
        vm.expectEmit(PAS_CONFIGURATOR);
        emit SetRateLimit(
            OSERO_RATE_LIMITS, USDS_MINT_RATE_LIMIT_KEY, PAS_FIXTURE_LOWERED_MINT_MAX, PAS_FIXTURE_LOWERED_MINT_SLOPE
        );
        vm.prank(FUTURE_OSERO_CBEAM);
        configurator.setRateLimit(
            OSERO_RATE_LIMITS, USDS_MINT_RATE_LIMIT_KEY, PAS_FIXTURE_LOWERED_MINT_MAX, PAS_FIXTURE_LOWERED_MINT_SLOPE
        );
        _assertRateLimit(
            USDS_MINT_RATE_LIMIT_KEY, PAS_FIXTURE_LOWERED_MINT_MAX, PAS_FIXTURE_LOWERED_MINT_SLOPE, "mint-lowered"
        );

        // Increase back to the registered default: consumes the hop and keeps the current capacity,
        // unlike the payload's setRateLimitData which resets lastAmount to maxAmount.
        vm.prank(FUTURE_OSERO_CBEAM);
        configurator.setRateLimit(OSERO_RATE_LIMITS, USDS_MINT_RATE_LIMIT_KEY, USDS_MINT_MAX_LIMIT, USDS_MINT_SLOPE);
        IRateLimitsLike.RateLimitData memory raised = rateLimits.getRateLimitData(USDS_MINT_RATE_LIMIT_KEY);
        assertEq(raised.maxAmount, USDS_MINT_MAX_LIMIT, "mint-raised-max-amount");
        assertEq(raised.slope, USDS_MINT_SLOPE, "mint-raised-slope");
        assertEq(raised.lastAmount, PAS_FIXTURE_LOWERED_MINT_MAX, "mint-raised-last-amount-not-preserved");
        assertEq(raised.lastUpdated, block.timestamp, "mint-raised-last-updated");
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY),
            PAS_FIXTURE_LOWERED_MINT_MAX,
            "mint-raised-current-limit"
        );

        // A further increase inside the hop window is rejected on the PAS side.
        vm.prank(FUTURE_OSERO_CBEAM);
        vm.expectRevert(bytes("Configurator/increment-too-soon"));
        configurator.setRateLimit(
            OSERO_RATE_LIMITS, USDS_MINT_RATE_LIMIT_KEY, PAS_FIXTURE_RAISED_MINT_MAX, USDS_MINT_SLOPE
        );

        // After the hop, an increase above the default is bounded by maxChange (1.2x the current max).
        uint256 hop = beamState.getHop(OSERO_RATE_LIMITS);
        vm.warp(block.timestamp + hop);
        uint256 recovered = PAS_FIXTURE_LOWERED_MINT_MAX + USDS_MINT_SLOPE * hop;
        uint256 expectedCapacity = recovered < USDS_MINT_MAX_LIMIT ? recovered : USDS_MINT_MAX_LIMIT;
        assertEq(rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY), expectedCapacity, "mint-capacity-after-hop");

        vm.prank(FUTURE_OSERO_CBEAM);
        configurator.setRateLimit(
            OSERO_RATE_LIMITS, USDS_MINT_RATE_LIMIT_KEY, PAS_FIXTURE_RAISED_MINT_MAX, USDS_MINT_SLOPE
        );
        raised = rateLimits.getRateLimitData(USDS_MINT_RATE_LIMIT_KEY);
        assertEq(raised.maxAmount, PAS_FIXTURE_RAISED_MINT_MAX, "mint-raised-above-default-max-amount");
        assertEq(raised.slope, USDS_MINT_SLOPE, "mint-raised-above-default-slope");
        assertEq(raised.lastAmount, expectedCapacity, "mint-raised-above-default-last-amount");
        assertEq(raised.lastUpdated, block.timestamp, "mint-raised-above-default-last-updated");

        _assertRetainedRoles();
    }

    function test_ETHEREUM_pasConfiguratorCannotLowerUnlimitedLimitsAfterFuturePairing() public {
        _executeSpellViaStarGuard(payload);
        _pairFutureOseroCBeamAsSkyCore();

        // Burn and withdraw stay unlimited with no BeamState default, so the Configurator may only
        // keep them at (max, 0) even though it now holds DEFAULT_ADMIN_ROLE on the RateLimits.
        vm.prank(FUTURE_OSERO_CBEAM);
        vm.expectRevert(bytes("Configurator/unlimited-incorrect-params"));
        configurator.setRateLimit(OSERO_RATE_LIMITS, USDS_BURN_RATE_LIMIT_KEY, USDS_MINT_MAX_LIMIT, USDS_MINT_SLOPE);

        vm.prank(FUTURE_OSERO_CBEAM);
        vm.expectRevert(bytes("Configurator/unlimited-incorrect-params"));
        configurator.setRateLimit(
            OSERO_RATE_LIMITS, SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY, USDS_MINT_MAX_LIMIT, USDS_MINT_SLOPE
        );

        _assertExistingUnlimitedRateLimit(USDS_BURN_RATE_LIMIT_KEY, "burn");
        _assertExistingUnlimitedRateLimit(SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY, "spark-withdraw");
    }

    function test_ETHEREUM_pasConfiguratorCallsControllerActionAfterAuthorizationAndFuturePairing() public {
        _executeSpellViaStarGuard(payload);
        _pairFutureOseroCBeamAsSkyCore();

        assertEq(controller.aave_getMaxSlippage(SPARKLEND_USDS_SPTOKEN), SPARKLEND_USDS_MAX_SLIPPAGE, "slippage-before");

        bytes memory data = _pasFixtureControllerAction();
        vm.expectEmit(PAS_CONFIGURATOR);
        emit CallControllerAction(OSERO_CONTROLLER, data);
        vm.prank(FUTURE_OSERO_CBEAM);
        configurator.callControllerAction(OSERO_CONTROLLER, data);

        assertEq(
            controller.aave_getMaxSlippage(SPARKLEND_USDS_SPTOKEN),
            PAS_FIXTURE_SPARKLEND_USDS_MAX_SLIPPAGE,
            "slippage-not-set-by-configurator"
        );
        _assertRetainedRoles();
    }

    function test_ETHEREUM_pasConfiguratorRejectsUnregisteredControllerActionAfterFuturePairing() public {
        _executeSpellViaStarGuard(payload);
        _pairFutureOseroCBeamAsSkyCore();

        // Only actions Sky Core registered in BeamState can be dispatched to the Osero controller.
        vm.prank(FUTURE_OSERO_CBEAM);
        vm.expectRevert(bytes("Configurator/not-valid-data"));
        configurator.callControllerAction(
            OSERO_CONTROLLER, abi.encodeCall(IOseroPauControllerLike.usds_setVault, (address(0)))
        );

        assertEq(controller.usds_vault(), OSERO_ALLOCATOR_VAULT, "vault-changed");
    }

    function test_ETHEREUM_pasOperationsRevertWithoutSpellGrantsEvenWhenPaired() public {
        // Pairing alone is not enough: without this payload's two grants, the Configurator passes
        // every PAS-side check and then fails on the Osero AccessControls / RateLimits role gate.
        _pairFutureOseroCBeamAsSkyCore();
        IRateLimitsLike.RateLimitData memory mintBefore = rateLimits.getRateLimitData(USDS_MINT_RATE_LIMIT_KEY);

        vm.prank(FUTURE_OSERO_CBEAM);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", PAS_CONFIGURATOR, DEFAULT_ADMIN_ROLE
            )
        );
        configurator.setRateLimit(
            OSERO_RATE_LIMITS, USDS_MINT_RATE_LIMIT_KEY, PAS_FIXTURE_LOWERED_MINT_MAX, PAS_FIXTURE_LOWERED_MINT_SLOPE
        );

        vm.prank(FUTURE_OSERO_CBEAM);
        vm.expectRevert(bytes("Configurator/call-failed"));
        configurator.callControllerAction(OSERO_CONTROLLER, _pasFixtureControllerAction());

        assertEq(
            controller.aave_getMaxSlippage(SPARKLEND_USDS_SPTOKEN), SPARKLEND_USDS_MAX_SLIPPAGE, "slippage-changed"
        );
        IRateLimitsLike.RateLimitData memory mintAfter = rateLimits.getRateLimitData(USDS_MINT_RATE_LIMIT_KEY);
        assertEq(mintAfter.maxAmount, mintBefore.maxAmount, "mint-max-changed-without-spell");
        assertEq(mintAfter.slope, mintBefore.slope, "mint-slope-changed-without-spell");
        assertEq(mintAfter.lastAmount, mintBefore.lastAmount, "mint-last-amount-changed-without-spell");
        assertEq(mintAfter.lastUpdated, mintBefore.lastUpdated, "mint-last-updated-changed-without-spell");
    }

    function test_ETHEREUM_usdsMintBurnOperationalThroughAdministeredAgent() public {
        _repayAllocatorDebtForOperationalTest();

        _executeSpellViaStarGuard(payload);

        uint256 proxyUsdsStart = usds.balanceOf(OSERO_ALM_PROXY);

        assertEq(rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY), USDS_MINT_MAX_LIMIT, "mint-limit-not-full");
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_BURN_RATE_LIMIT_KEY), type(uint256).max, "burn-limit-not-unlimited"
        );

        _callAsOseroActor(abi.encodeCall(IOseroPauControllerLike.usds_mint, (OPERATIONAL_TEST_AMOUNT)));

        assertEq(usds.balanceOf(OSERO_ALM_PROXY), proxyUsdsStart + OPERATIONAL_TEST_AMOUNT, "proxy-usds-not-minted");
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY),
            USDS_MINT_MAX_LIMIT - OPERATIONAL_TEST_AMOUNT,
            "mint-limit-not-decreased"
        );
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_BURN_RATE_LIMIT_KEY), type(uint256).max, "burn-limit-changed-after-mint"
        );

        _callAsOseroActor(abi.encodeCall(IOseroPauControllerLike.usds_burn, (OPERATIONAL_TEST_AMOUNT)));

        assertEq(usds.balanceOf(OSERO_ALM_PROXY), proxyUsdsStart, "proxy-usds-not-burned");
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY), USDS_MINT_MAX_LIMIT, "mint-limit-not-refilled"
        );
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_BURN_RATE_LIMIT_KEY),
            type(uint256).max,
            "burn-limit-not-still-unlimited"
        );
    }

    function test_ETHEREUM_usdsMintRateLimitRejectsOversizedMint() public {
        _executeSpellViaStarGuard(payload);

        _expectCallAsOseroActorRevert(
            bytes("RateLimits/rate-limit-exceeded"),
            abi.encodeCall(IOseroPauControllerLike.usds_mint, (USDS_MINT_MAX_LIMIT + 1))
        );
    }

    function test_ETHEREUM_usdsMintRateLimitRecoversOverTime() public {
        _repayAllocatorDebtForOperationalTest();

        _executeSpellViaStarGuard(payload);

        _callAsOseroActor(abi.encodeCall(IOseroPauControllerLike.usds_mint, (OPERATIONAL_TEST_AMOUNT)));
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY),
            USDS_MINT_MAX_LIMIT - OPERATIONAL_TEST_AMOUNT,
            "mint-limit-not-decreased"
        );

        vm.warp(block.timestamp + PARTIAL_RECOVERY_TIME);
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY),
            USDS_MINT_MAX_LIMIT - OPERATIONAL_TEST_AMOUNT + USDS_MINT_SLOPE * PARTIAL_RECOVERY_TIME,
            "mint-limit-not-recovering-at-slope"
        );

        vm.warp(block.timestamp + 1 days);
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY),
            USDS_MINT_MAX_LIMIT,
            "mint-limit-not-capped-at-max"
        );
    }

    function test_ETHEREUM_sparkUsdsDepositWithdrawOperationalThroughAdministeredAgent() public {
        _repayAllocatorDebtForOperationalTest();

        _executeSpellViaStarGuard(payload);

        uint256 proxyUsdsStart = usds.balanceOf(OSERO_ALM_PROXY);
        uint256 proxySpUsdsStart = spUsds.balanceOf(OSERO_ALM_PROXY);
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY),
            SPARKLEND_USDS_DEPOSIT_MAX,
            "deposit-limit-not-full"
        );
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY),
            type(uint256).max,
            "withdraw-limit-not-unlimited-before-deposit"
        );

        _callAsOseroActor(abi.encodeCall(IOseroPauControllerLike.usds_mint, (OPERATIONAL_TEST_AMOUNT)));
        assertEq(usds.balanceOf(OSERO_ALM_PROXY), proxyUsdsStart + OPERATIONAL_TEST_AMOUNT, "proxy-usds-not-minted");

        _callAsOseroActor(
            abi.encodeCall(IOseroPauControllerLike.aave_deposit, (SPARKLEND_USDS_SPTOKEN, OPERATIONAL_TEST_AMOUNT))
        );

        uint256 minSpUsdsOut = OPERATIONAL_TEST_AMOUNT * SPARKLEND_USDS_MAX_SLIPPAGE / 1e18;
        uint256 proxySpUsdsAfterDeposit = spUsds.balanceOf(OSERO_ALM_PROXY);
        assertEq(usds.balanceOf(OSERO_ALM_PROXY), proxyUsdsStart, "proxy-usds-not-deposited");
        assertGe(proxySpUsdsAfterDeposit - proxySpUsdsStart, minSpUsdsOut, "proxy-spusds-received-too-low");
        assertEq(usds.allowance(OSERO_ALM_PROXY, SPARKLEND_POOL), 0, "spark-pool-usds-approval-not-cleared");
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY),
            SPARKLEND_USDS_DEPOSIT_MAX - OPERATIONAL_TEST_AMOUNT,
            "deposit-limit-not-decreased"
        );
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY),
            type(uint256).max,
            "withdraw-limit-not-unlimited"
        );

        bytes memory withdrawResult = _callAsOseroActor(
            abi.encodeCall(IOseroPauControllerLike.aave_withdraw, (SPARKLEND_USDS_SPTOKEN, OPERATIONAL_TEST_AMOUNT))
        );
        assertEq(abi.decode(withdrawResult, (uint256)), OPERATIONAL_TEST_AMOUNT, "aave-withdraw-return-mismatch");

        assertEq(usds.balanceOf(OSERO_ALM_PROXY), proxyUsdsStart + OPERATIONAL_TEST_AMOUNT, "proxy-usds-not-withdrawn");
        uint256 proxySpUsdsAfterWithdraw = spUsds.balanceOf(OSERO_ALM_PROXY);
        assertLt(proxySpUsdsAfterWithdraw, proxySpUsdsAfterDeposit, "proxy-spusds-not-decreased");
        assertLe(
            proxySpUsdsAfterWithdraw,
            proxySpUsdsStart + (OPERATIONAL_TEST_AMOUNT - minSpUsdsOut),
            "proxy-spusds-residual-too-high"
        );
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY),
            SPARKLEND_USDS_DEPOSIT_MAX,
            "deposit-limit-not-refilled"
        );
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_WITHDRAW_RATE_LIMIT_KEY),
            type(uint256).max,
            "withdraw-limit-changed"
        );

        _callAsOseroActor(abi.encodeCall(IOseroPauControllerLike.usds_burn, (OPERATIONAL_TEST_AMOUNT)));

        assertEq(usds.balanceOf(OSERO_ALM_PROXY), proxyUsdsStart, "proxy-usds-not-restored");
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY),
            USDS_MINT_MAX_LIMIT,
            "mint-limit-not-refilled-after-burn"
        );
        assertEq(rateLimits.getCurrentRateLimit(USDS_BURN_RATE_LIMIT_KEY), type(uint256).max, "burn-limit-changed");
    }

    function test_ETHEREUM_sparkUsdsDepositRateLimitRejectsOversizedDeposit() public {
        _executeSpellViaStarGuard(payload);

        deal(USDS, OSERO_ALM_PROXY, SPARKLEND_USDS_DEPOSIT_MAX + 1);
        assertEq(usds.balanceOf(OSERO_ALM_PROXY), SPARKLEND_USDS_DEPOSIT_MAX + 1, "proxy-usds-deal-failed");

        _expectCallAsOseroActorRevert(
            bytes("RateLimits/rate-limit-exceeded"),
            abi.encodeCall(
                IOseroPauControllerLike.aave_deposit, (SPARKLEND_USDS_SPTOKEN, SPARKLEND_USDS_DEPOSIT_MAX + 1)
            )
        );
    }

    function test_ETHEREUM_sparkUsdsDepositRateLimitRecoversOverTime() public {
        _repayAllocatorDebtForOperationalTest();

        _executeSpellViaStarGuard(payload);

        _callAsOseroActor(abi.encodeCall(IOseroPauControllerLike.usds_mint, (OPERATIONAL_TEST_AMOUNT)));
        _callAsOseroActor(
            abi.encodeCall(IOseroPauControllerLike.aave_deposit, (SPARKLEND_USDS_SPTOKEN, OPERATIONAL_TEST_AMOUNT))
        );
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY),
            SPARKLEND_USDS_DEPOSIT_MAX - OPERATIONAL_TEST_AMOUNT,
            "deposit-limit-not-decreased"
        );

        vm.warp(block.timestamp + PARTIAL_RECOVERY_TIME);
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY),
            SPARKLEND_USDS_DEPOSIT_MAX - OPERATIONAL_TEST_AMOUNT + SPARKLEND_USDS_DEPOSIT_SLOPE * PARTIAL_RECOVERY_TIME,
            "deposit-limit-not-recovering-at-slope"
        );

        vm.warp(block.timestamp + 1 days);
        assertEq(
            rateLimits.getCurrentRateLimit(SPARKLEND_USDS_DEPOSIT_RATE_LIMIT_KEY),
            SPARKLEND_USDS_DEPOSIT_MAX,
            "deposit-limit-not-capped-at-max"
        );
    }

    function test_ETHEREUM_usdsMintStillSubjectToDebtCeiling() public {
        _executeSpellViaStarGuard(payload);

        // At the forum readback block, existing debt consumes all of the allocator's debt ceiling.
        _expectCallAsOseroActorRevert(
            bytes("Vat/ceiling-exceeded"), abi.encodeCall(IOseroPauControllerLike.usds_mint, (OPERATIONAL_TEST_AMOUNT))
        );
        assertEq(
            rateLimits.getCurrentRateLimit(USDS_MINT_RATE_LIMIT_KEY), USDS_MINT_MAX_LIMIT, "failed-mint-consumed-limit"
        );
    }

    function _repayAllocatorDebtForOperationalTest() internal {
        // The allocator has no debt-ceiling headroom at this block. Fund a repayment using the
        // existing unlimited burn path so the operational tests can mint/deposit above the old 5M
        // rate limit. This is test funding, not a coordinated Sky Core action or a debt-ceiling change.
        deal(USDS, OSERO_ALM_PROXY, usds.balanceOf(OSERO_ALM_PROXY) + OPERATIONAL_TEST_AMOUNT);
        _callAsOseroActor(abi.encodeCall(IOseroPauControllerLike.usds_burn, (OPERATIONAL_TEST_AMOUNT)));
    }

    /// @dev PAS integration fixture, NOT part of this payload. Models the subsequent Sky Core spell
    ///      that registers the Osero RateLimits/Controller with PAS, whitelists and pairs an Osero
    ///      cBEAM, and registers the approved defaults/actions. On-chain these go through the PAS
    ///      Timelock (registration) and Core Council (pairing); the test takes the PauseProxy ward
    ///      shortcut on BeamState since the outcome is identical.
    function _pairFutureOseroCBeamAsSkyCore() internal {
        // Pre-state at the fork block: PAS is live, Osero is not registered or paired.
        assertEq(beamState.wards(MCD_PAUSE_PROXY), 1, "pause-proxy-not-beamstate-ward");
        assertFalse(beamState.stopped(), "beamstate-stopped");
        assertEq(beamState.rateLimits(OSERO_RATE_LIMITS), 0, "osero-ratelimits-already-registered");
        assertEq(beamState.controllers(OSERO_CONTROLLER), 0, "osero-controller-already-registered");
        assertEq(
            beamState.rateLimitsCBeams(OSERO_RATE_LIMITS, FUTURE_OSERO_CBEAM), 0, "cbeam-already-paired-ratelimits"
        );
        assertEq(
            beamState.controllersCBeams(OSERO_CONTROLLER, FUTURE_OSERO_CBEAM), 0, "cbeam-already-paired-controller"
        );
        assertGt(beamState.getHop(OSERO_RATE_LIMITS), 0, "beamstate-hop-not-set");

        vm.startPrank(MCD_PAUSE_PROXY);
        beamState.addRateLimits(OSERO_RATE_LIMITS);
        beamState.addController(OSERO_CONTROLLER);
        beamState.addCBeam(FUTURE_OSERO_CBEAM);
        beamState.setCBeamForRateLimits(OSERO_RATE_LIMITS, FUTURE_OSERO_CBEAM);
        beamState.setCBeamForController(OSERO_CONTROLLER, FUTURE_OSERO_CBEAM);
        beamState.addInitRateLimits(USDS_MINT_RATE_LIMIT_KEY, OSERO_RATE_LIMITS, USDS_MINT_MAX_LIMIT, USDS_MINT_SLOPE);
        beamState.addInitControllerActions(_pasFixtureControllerAction(), OSERO_CONTROLLER);
        vm.stopPrank();

        assertEq(beamState.rateLimitsCBeams(OSERO_RATE_LIMITS, FUTURE_OSERO_CBEAM), 1, "cbeam-not-paired-ratelimits");
        assertEq(beamState.controllersCBeams(OSERO_CONTROLLER, FUTURE_OSERO_CBEAM), 1, "cbeam-not-paired-controller");
    }

    /// @dev The controller admin action the fixture registers for the Osero cBEAM.
    function _pasFixtureControllerAction() internal pure returns (bytes memory) {
        return abi.encodeCall(
            IOseroPauControllerLike.aave_setMaxSlippage,
            (SPARKLEND_USDS_SPTOKEN, PAS_FIXTURE_SPARKLEND_USDS_MAX_SLIPPAGE)
        );
    }

    function _assertRetainedRoles() internal view {
        IAccessControlsLike accessControls = IAccessControlsLike(OSERO_ACCESS_CONTROLS);
        IALMProxyLike almProxy = IALMProxyLike(OSERO_ALM_PROXY);
        assertTrue(accessControls.hasRole(DEFAULT_ADMIN_ROLE, OSERO_PROXY), "subproxy-missing-access-admin");
        assertTrue(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, OSERO_PROXY), "subproxy-missing-ratelimits-admin");
        assertTrue(accessControls.hasRole(ALLOCATOR_ROLE, OSERO_ADMINISTERED_AGENT), "agent-missing-allocator-role");
        assertEq(accessControls.getRoleMemberCount(ALLOCATOR_ROLE), 1, "allocator-role-count");
        assertTrue(rateLimits.hasRole(CONTROLLER, OSERO_CONTROLLER), "controller-missing-ratelimits-role");
        assertTrue(almProxy.hasRole(DEFAULT_ADMIN_ROLE, OSERO_PROXY), "subproxy-missing-almproxy-admin");
        assertTrue(almProxy.hasRole(CONTROLLER, OSERO_CONTROLLER), "controller-missing-almproxy-role");
        assertFalse(almProxy.hasRole(DEFAULT_ADMIN_ROLE, PAS_CONFIGURATOR), "configurator-unexpected-almproxy-admin");
    }

    function _assertLaunchConfiguration() internal view {
        assertEq(controller.usds_vault(), OSERO_ALLOCATOR_VAULT, "controller-vault-mismatch");
        assertEq(IAllocatorVaultLike(OSERO_ALLOCATOR_VAULT).wards(OSERO_ALM_PROXY), 1, "almproxy-not-vault-ward");
        assertEq(usds.allowance(OSERO_ALLOCATOR_BUFFER, OSERO_ALM_PROXY), type(uint256).max, "buffer-allowance-not-max");
        assertEq(controller.aave_getMaxSlippage(SPARKLEND_USDS_SPTOKEN), SPARKLEND_USDS_MAX_SLIPPAGE, "spark-slippage");
    }

    function _assertExistingUnlimitedRateLimit(bytes32 key, string memory label) internal view {
        // These limits must retain their July timestamps; resetting an unlimited limit is out of scope.
        IRateLimitsLike.RateLimitData memory data = rateLimits.getRateLimitData(key);
        assertEq(data.maxAmount, type(uint256).max, string.concat(label, "-unlimited-max-amount"));
        assertEq(data.slope, 0, string.concat(label, "-unlimited-slope"));
        assertEq(data.lastAmount, type(uint256).max, string.concat(label, "-unlimited-last-amount"));
        assertEq(data.lastUpdated, UNLIMITED_LAST_UPDATED, string.concat(label, "-unlimited-last-updated"));
        assertEq(
            rateLimits.getCurrentRateLimit(key), type(uint256).max, string.concat(label, "-unlimited-current-limit")
        );
    }

    /// @dev Config for the inherited `test_ETHEREUM_onlyExpectedControllerIntegrations`; update
    ///      only when the controller's integration config changes (e.g. a facet is onboarded).
    function _expectedControllerIntegrations() internal pure override returns (ExpectedIntegration[] memory expected) {
        expected = new ExpectedIntegration[](2);
        expected[0] = ExpectedIntegration(USDS_FACET_INTEGRATION_ID, SKY_PAU_USDS_FACET, 8, "usds");
        expected[1] = ExpectedIntegration(AAVE_FACET_INTEGRATION_ID, SKY_PAU_AAVE_FACET, 7, "aave");
    }
}
