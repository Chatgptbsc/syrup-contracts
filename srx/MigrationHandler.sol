//SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IAmmRouter.sol";
import "./interfaces/ISrxMigrator.sol";
import "../core/interfaces/IVault.sol";

contract MigrationHandler is ReentrancyGuard {
    using SafeMath for uint256;

    uint256 public constant USDG_PRECISION = 10 ** 18;

    bool public isInitialized;

    address public admin;
    address public ammRouterV1;
    address public ammRouterV2;

    address public vault;

    address public smt;
    address public xsmt;
    address public usdg;
    address public bnb;
    address public busd;

    mapping(address => mapping(address => uint256)) public refundedAmounts;

    modifier onlyAdmin() {
        require(msg.sender == admin, "MigrationHandler: forbidden");
        _;
    }

    constructor() public {
        admin = msg.sender;
    }

    function initialize(
        address _ammRouterV1,
        address _ammRouterV2,
        address _vault,
        address _smt,
        address _xsmt,
        address _usdg,
        address _bnb,
        address _busd
    ) public onlyAdmin {
        require(!isInitialized, "MigrationHandler: already initialized");
        isInitialized = true;

        ammRouterV1 = _ammRouterV1;
        ammRouterV2 = _ammRouterV2;

        vault = _vault;

        smt = _smt;
        xsmt = _xsmt;
        usdg = _usdg;
        bnb = _bnb;
        busd = _busd;
    }

    function redeemUsdg(
        address _migrator,
        address _redemptionToken,
        uint256 _usdgAmount
    ) external onlyAdmin nonReentrant {
        IERC20(usdg).transferFrom(_migrator, vault, _usdgAmount);
        uint256 amount = IVault(vault).sellUSDG(
            _redemptionToken,
            address(this)
        );

        address[] memory path = new address[](2);
        path[0] = bnb;
        path[1] = busd;

        if (_redemptionToken != bnb) {
            path = new address[](3);
            path[0] = _redemptionToken;
            path[1] = bnb;
            path[2] = busd;
        }

        IERC20(_redemptionToken).approve(ammRouterV2, amount);
        IAmmRouter(ammRouterV2).swapExactTokensForTokens(
            amount,
            0,
            path,
            _migrator,
            block.timestamp
        );
    }

    function swap(
        address _migrator,
        uint256 _smtAmountForUsdg,
        uint256 _xsmtAmountForUsdg,
        uint256 _smtAmountForBusd
    ) external onlyAdmin nonReentrant {
        address[] memory path = new address[](2);

        path[0] = smt;
        path[1] = usdg;
        IERC20(smt).transferFrom(_migrator, address(this), _smtAmountForUsdg);
        IERC20(smt).approve(ammRouterV2, _smtAmountForUsdg);
        IAmmRouter(ammRouterV2).swapExactTokensForTokens(
            _smtAmountForUsdg,
            0,
            path,
            _migrator,
            block.timestamp
        );

        path[0] = xsmt;
        path[1] = usdg;
        IERC20(xsmt).transferFrom(_migrator, address(this), _xsmtAmountForUsdg);
        IERC20(xsmt).approve(ammRouterV2, _xsmtAmountForUsdg);
        IAmmRouter(ammRouterV2).swapExactTokensForTokens(
            _xsmtAmountForUsdg,
            0,
            path,
            _migrator,
            block.timestamp
        );

        path[0] = smt;
        path[1] = busd;
        IERC20(smt).transferFrom(_migrator, address(this), _smtAmountForBusd);
        IERC20(smt).approve(ammRouterV1, _smtAmountForBusd);
        IAmmRouter(ammRouterV1).swapExactTokensForTokens(
            _smtAmountForBusd,
            0,
            path,
            _migrator,
            block.timestamp
        );
    }

    function refund(
        address _migrator,
        address _account,
        address _token,
        uint256 _usdgAmount
    ) external onlyAdmin nonReentrant {
        address iouToken = ISrxMigrator(_migrator).iouTokens(_token);
        uint256 iouBalance = IERC20(iouToken).balanceOf(_account);
        uint256 iouTokenAmount = _usdgAmount.div(2); // each SRX is priced at $2

        uint256 refunded = refundedAmounts[_account][iouToken];
        refundedAmounts[_account][iouToken] = refunded.add(iouTokenAmount);

        require(
            refundedAmounts[_account][iouToken] <= iouBalance,
            "MigrationHandler: refundable amount exceeded"
        );

        IERC20(usdg).transferFrom(_migrator, _account, _usdgAmount);
    }
}
