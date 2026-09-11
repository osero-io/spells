// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.34;

import {Ethereum as OseroEthereum} from "osero-address-registry/Ethereum.sol";
import {SparkLend} from "spark-address-registry/SparkLend.sol";

import {PASAuthorizeInPAU} from "pas/deploy/PASAuthorizeInPAU.sol";

import {BaseSpell} from "../BaseSpell.sol";
import {RateLimitsHelper} from "../libraries/RateLimitsHelper.sol";

/// @title  September 24, 2026 Osero Ethereum Proposal
/// @notice Authorizes the Sky PAS Configurator on the Osero PAU and raises the USDS mint and
///         SparkLend USDS deposit rate limits to 50,000,000 USDS max and 50,000,000 USDS per day.
/// @custom:forum https://forum.skyeco.com/t/september-24-2026-proposed-changes-to-osero-for-upcoming-spell/28224
contract OseroEthereum_20260924 is BaseSpell {
    // Contract: USDS / Source: https://chainlog.skyeco.com/ (key: USDS)
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    // Contract: Sky PAS Configurator / Source: https://chainlog.skyeco.com/ (key: PAS_CONFIGURATOR)
    address public constant PAS_CONFIGURATOR = 0xb7E61Df6CAb0A51E9A5dab1A7DD3f942dDe5b929;

    uint256 public constant USDS_MINT_MAX_LIMIT = 50_000_000e18;
    uint256 public constant USDS_MINT_SLOPE = uint256(50_000_000e18) / 1 days;

    uint256 public constant SPARKLEND_USDS_DEPOSIT_MAX = 50_000_000e18;
    uint256 public constant SPARKLEND_USDS_DEPOSIT_SLOPE = uint256(50_000_000e18) / 1 days;

    function execute() external override {
        // [Ethereum] Authorize the Sky PAS Configurator on the Osero AccessControls and RateLimits
        //   Forum : https://forum.skyeco.com/t/september-24-2026-proposed-changes-to-osero-for-upcoming-spell/28224
        PASAuthorizeInPAU.authorize({
            configurator: PAS_CONFIGURATOR,
            accessControls: OseroEthereum.OSERO_ACCESS_CONTROLS,
            rateLimits: OseroEthereum.OSERO_RATE_LIMITS
        }); // BEFORE: Configurator holds neither admin role; SubProxy retains both.

        // [Ethereum] Raise the USDS mint and SparkLend USDS deposit rate limits on the PAU rate limits
        //   Forum : https://forum.skyeco.com/t/september-24-2026-proposed-changes-to-osero-for-upcoming-spell/28224
        _setupRateLimits();
    }

    function _setupRateLimits() private {
        // USDS mint:              BEFORE: 5,000,000 max, 5,000,000 / day slope. AFTER: 50,000,000 max, 50,000,000 / day slope.
        RateLimitsHelper.setUsdsMintRateLimit(OseroEthereum.OSERO_RATE_LIMITS, USDS_MINT_MAX_LIMIT, USDS_MINT_SLOPE);

        // SparkLend USDS deposit: BEFORE: 5,000,000 max, 5,000,000 / day slope. AFTER: 50,000,000 max, 50,000,000 / day slope.
        RateLimitsHelper.setSparkLendDepositRateLimit(
            OseroEthereum.OSERO_RATE_LIMITS,
            SparkLend.USDS_SPTOKEN,
            USDS,
            SPARKLEND_USDS_DEPOSIT_MAX,
            SPARKLEND_USDS_DEPOSIT_SLOPE
        );
    }
}
