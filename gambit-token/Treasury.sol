// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "../amm/interfaces/IPancakeRouter.sol";
import "./interfaces/ISMT.sol";
import "../peripherals/interfaces/ITimelockTarget.sol";

contract Treasury is ReentrancyGuard, ITimelockTarget {
    using SafeMath for uint256;

    uint256 constant PRECISION = 1000000;
    uint256 constant BASIS_POINTS_DIVISOR = 10000;

    bool public isInitialized;
    bool public isSwapActive = true;
    bool public isLiquidityAdded = false;

    address public smt;
    address public busd;
    address public router;
    address public fund;

    uint256 public smtPresalePrice;
    uint256 public smtListingPrice;
    uint256 public busdSlotCap;
    uint256 public busdHardCap;
    uint256 public busdBasisPoints;
    uint256 public unlockTime;

    uint256 public busdReceived;

    address public gov;

    mapping(address => uint256) public swapAmounts;
    mapping(address => bool) public swapWhitelist;

    modifier onlyGov() {
        require(msg.sender == gov, "Treasury: forbidden");
        _;
    }

    constructor() public {
        gov = msg.sender;
    }

    function initialize(
        address[] memory _addresses,
        uint256[] memory _values
    ) external onlyGov {
        require(!isInitialized, "Treasury: already initialized");
        isInitialized = true;

        smt = _addresses[0];
        busd = _addresses[1];
        router = _addresses[2];
        fund = _addresses[3];

        smtPresalePrice = _values[0];
        smtListingPrice = _values[1];
        busdSlotCap = _values[2];
        busdHardCap = _values[3];
        busdBasisPoints = _values[4];
        unlockTime = _values[5];
    }

    function setGov(address _gov) external override onlyGov nonReentrant {
        gov = _gov;
    }

    function setFund(address _fund) external onlyGov nonReentrant {
        fund = _fund;
    }

    function extendUnlockTime(
        uint256 _unlockTime
    ) external onlyGov nonReentrant {
        require(_unlockTime > unlockTime, "Treasury: invalid _unlockTime");
        unlockTime = _unlockTime;
    }

    function addWhitelists(
        address[] memory _accounts
    ) external onlyGov nonReentrant {
        for (uint256 i = 0; i < _accounts.length; i++) {
            address account = _accounts[i];
            swapWhitelist[account] = true;
        }
    }

    function removeWhitelists(
        address[] memory _accounts
    ) external onlyGov nonReentrant {
        for (uint256 i = 0; i < _accounts.length; i++) {
            address account = _accounts[i];
            swapWhitelist[account] = false;
        }
    }

    function updateWhitelist(
        address prevAccount,
        address nextAccount
    ) external onlyGov nonReentrant {
        require(swapWhitelist[prevAccount], "Treasury: invalid prevAccount");
        swapWhitelist[prevAccount] = false;
        swapWhitelist[nextAccount] = true;
    }

    function swap(uint256 _busdAmount) external nonReentrant {
        address account = msg.sender;
        require(swapWhitelist[account], "Treasury: forbidden");
        require(isSwapActive, "Treasury: swap is no longer active");
        require(_busdAmount > 0, "Treasury: invalid _busdAmount");

        busdReceived = busdReceived.add(_busdAmount);
        require(busdReceived <= busdHardCap, "Treasury: busdHardCap exceeded");

        swapAmounts[account] = swapAmounts[account].add(_busdAmount);
        require(
            swapAmounts[account] <= busdSlotCap,
            "Treasury: busdSlotCap exceeded"
        );

        // receive BUSD
        uint256 busdBefore = IERC20(busd).balanceOf(address(this));
        IERC20(busd).transferFrom(account, address(this), _busdAmount);
        uint256 busdAfter = IERC20(busd).balanceOf(address(this));
        require(
            busdAfter.sub(busdBefore) == _busdAmount,
            "Treasury: invalid transfer"
        );

        // send SMT
        uint256 smtAmount = _busdAmount.mul(PRECISION).div(smtPresalePrice);
        IERC20(smt).transfer(account, smtAmount);
    }

    function addLiquidity() external onlyGov nonReentrant {
        require(!isLiquidityAdded, "Treasury: liquidity already added");
        isLiquidityAdded = true;

        uint256 busdAmount = busdReceived.mul(busdBasisPoints).div(
            BASIS_POINTS_DIVISOR
        );
        uint256 smtAmount = busdAmount.mul(PRECISION).div(smtListingPrice);

        IERC20(busd).approve(router, busdAmount);
        IERC20(smt).approve(router, smtAmount);

        ISMT(smt).endMigration();

        IPancakeRouter(router).addLiquidity(
            busd, // tokenA
            smt, // tokenB
            busdAmount, // amountADesired
            smtAmount, // amountBDesired
            0, // amountAMin
            0, // amountBMin
            address(this), // to
            block.timestamp // deadline
        );

        ISMT(smt).beginMigration();

        uint256 fundAmount = busdReceived.sub(busdAmount);
        IERC20(busd).transfer(fund, fundAmount);
    }

    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external override onlyGov nonReentrant {
        require(
            block.timestamp > unlockTime,
            "Treasury: unlockTime not yet passed"
        );
        IERC20(_token).transfer(_account, _amount);
    }

    function increaseBusdBasisPoints(
        uint256 _busdBasisPoints
    ) external onlyGov nonReentrant {
        require(
            _busdBasisPoints > busdBasisPoints,
            "Treasury: invalid _busdBasisPoints"
        );
        busdBasisPoints = _busdBasisPoints;
    }

    function endSwap() external onlyGov nonReentrant {
        isSwapActive = false;
    }
}
