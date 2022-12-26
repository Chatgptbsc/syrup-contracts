// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/ISlpManager.sol";
import "../access/Governable.sol";

contract RewardRouter is ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public weth;

    address public srx;
    address public esSrx;
    address public bnSrx;

    address public slp; // SRX Liquidity Provider token

    address public stakedSrxTracker;
    address public bonusSrxTracker;
    address public feeSrxTracker;

    address public stakedSlpTracker;
    address public feeSlpTracker;

    address public slpManager;

    event StakeSrx(address account, uint256 amount);
    event UnstakeSrx(address account, uint256 amount);

    event StakeSlp(address account, uint256 amount);
    event UnstakeSlp(address account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _srx,
        address _esSrx,
        address _bnSrx,
        address _slp,
        address _stakedSrxTracker,
        address _bonusSrxTracker,
        address _feeSrxTracker,
        address _feeSlpTracker,
        address _stakedSlpTracker,
        address _slpManager
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        weth = _weth;

        srx = _srx;
        esSrx = _esSrx;
        bnSrx = _bnSrx;

        slp = _slp;

        stakedSrxTracker = _stakedSrxTracker;
        bonusSrxTracker = _bonusSrxTracker;
        feeSrxTracker = _feeSrxTracker;

        feeSlpTracker = _feeSlpTracker;
        stakedSlpTracker = _stakedSlpTracker;

        slpManager = _slpManager;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function batchStakeSrxForAccount(
        address[] memory _accounts,
        uint256[] memory _amounts
    ) external nonReentrant onlyGov {
        address _srx = srx;
        for (uint256 i = 0; i < _accounts.length; i++) {
            _stakeSrx(msg.sender, _accounts[i], _srx, _amounts[i]);
        }
    }

    function stakeSrxForAccount(
        address _account,
        uint256 _amount
    ) external nonReentrant onlyGov {
        _stakeSrx(msg.sender, _account, srx, _amount);
    }

    function stakeSrx(uint256 _amount) external nonReentrant {
        _stakeSrx(msg.sender, msg.sender, srx, _amount);
    }

    function stakeEsSrx(uint256 _amount) external nonReentrant {
        _stakeSrx(msg.sender, msg.sender, esSrx, _amount);
    }

    function unstakeSrx(uint256 _amount) external nonReentrant {
        _unstakeSrx(msg.sender, srx, _amount);
    }

    function unstakeEsSrx(uint256 _amount) external nonReentrant {
        _unstakeSrx(msg.sender, esSrx, _amount);
    }

    function mintAndStakeSlp(
        address _token,
        uint256 _amount,
        uint256 _minUsdg,
        uint256 _minSlp
    ) external nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        address account = msg.sender;
        uint256 slpAmount = ISlpManager(slpManager).addLiquidityForAccount(
            account,
            account,
            _token,
            _amount,
            _minUsdg,
            _minSlp
        );
        IRewardTracker(feeSlpTracker).stakeForAccount(
            account,
            account,
            slp,
            slpAmount
        );
        IRewardTracker(stakedSlpTracker).stakeForAccount(
            account,
            account,
            feeSlpTracker,
            slpAmount
        );

        emit StakeSlp(account, slpAmount);

        return slpAmount;
    }

    function mintAndStakeSlpETH(
        uint256 _minUsdg,
        uint256 _minSlp
    ) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "RewardRouter: invalid msg.value");

        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).approve(slpManager, msg.value);

        address account = msg.sender;
        uint256 slpAmount = ISlpManager(slpManager).addLiquidityForAccount(
            address(this),
            account,
            weth,
            msg.value,
            _minUsdg,
            _minSlp
        );

        IRewardTracker(feeSlpTracker).stakeForAccount(
            account,
            account,
            slp,
            slpAmount
        );
        IRewardTracker(stakedSlpTracker).stakeForAccount(
            account,
            account,
            feeSlpTracker,
            slpAmount
        );

        emit StakeSlp(account, slpAmount);

        return slpAmount;
    }

    function unstakeAndRedeemSlp(
        address _tokenOut,
        uint256 _slpAmount,
        uint256 _minOut,
        address _receiver
    ) external nonReentrant returns (uint256) {
        require(_slpAmount > 0, "RewardRouter: invalid _slpAmount");

        address account = msg.sender;
        IRewardTracker(stakedSlpTracker).unstakeForAccount(
            account,
            feeSlpTracker,
            _slpAmount,
            account
        );
        IRewardTracker(feeSlpTracker).unstakeForAccount(
            account,
            slp,
            _slpAmount,
            account
        );
        uint256 amountOut = ISlpManager(slpManager).removeLiquidityForAccount(
            account,
            _tokenOut,
            _slpAmount,
            _minOut,
            _receiver
        );

        emit UnstakeSlp(account, _slpAmount);

        return amountOut;
    }

    function unstakeAndRedeemSlpETH(
        uint256 _slpAmount,
        uint256 _minOut,
        address payable _receiver
    ) external nonReentrant returns (uint256) {
        require(_slpAmount > 0, "RewardRouter: invalid _slpAmount");

        address account = msg.sender;
        IRewardTracker(stakedSlpTracker).unstakeForAccount(
            account,
            feeSlpTracker,
            _slpAmount,
            account
        );
        IRewardTracker(feeSlpTracker).unstakeForAccount(
            account,
            slp,
            _slpAmount,
            account
        );
        uint256 amountOut = ISlpManager(slpManager).removeLiquidityForAccount(
            account,
            weth,
            _slpAmount,
            _minOut,
            address(this)
        );

        IWETH(weth).withdraw(amountOut);

        _receiver.sendValue(amountOut);

        emit UnstakeSlp(account, _slpAmount);

        return amountOut;
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeSrxTracker).claimForAccount(account, account);
        IRewardTracker(feeSlpTracker).claimForAccount(account, account);

        IRewardTracker(stakedSrxTracker).claimForAccount(account, account);
        IRewardTracker(stakedSlpTracker).claimForAccount(account, account);
    }

    function claimEsSrx() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(stakedSrxTracker).claimForAccount(account, account);
        IRewardTracker(stakedSlpTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeSrxTracker).claimForAccount(account, account);
        IRewardTracker(feeSlpTracker).claimForAccount(account, account);
    }

    function compound() external nonReentrant {
        _compound(msg.sender);
    }

    function compoundForAccount(
        address _account
    ) external nonReentrant onlyGov {
        _compound(_account);
    }

    function batchCompoundForAccounts(
        address[] memory _accounts
    ) external nonReentrant onlyGov {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function _compound(address _account) private {
        _compoundSrx(_account);
        _compoundSlp(_account);
    }

    function _compoundSrx(address _account) private {
        uint256 esSrxAmount = IRewardTracker(stakedSrxTracker).claimForAccount(
            _account,
            _account
        );
        if (esSrxAmount > 0) {
            _stakeSrx(_account, _account, esSrx, esSrxAmount);
        }

        uint256 bnSrxAmount = IRewardTracker(bonusSrxTracker).claimForAccount(
            _account,
            _account
        );
        if (bnSrxAmount > 0) {
            IRewardTracker(feeSrxTracker).stakeForAccount(
                _account,
                _account,
                bnSrx,
                bnSrxAmount
            );
        }
    }

    function _compoundSlp(address _account) private {
        uint256 esSrxAmount = IRewardTracker(stakedSlpTracker).claimForAccount(
            _account,
            _account
        );
        if (esSrxAmount > 0) {
            _stakeSrx(_account, _account, esSrx, esSrxAmount);
        }
    }

    function _stakeSrx(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount
    ) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IRewardTracker(stakedSrxTracker).stakeForAccount(
            _fundingAccount,
            _account,
            _token,
            _amount
        );
        IRewardTracker(bonusSrxTracker).stakeForAccount(
            _account,
            _account,
            stakedSrxTracker,
            _amount
        );
        IRewardTracker(feeSrxTracker).stakeForAccount(
            _account,
            _account,
            bonusSrxTracker,
            _amount
        );

        emit StakeSrx(_account, _amount);
    }

    function _unstakeSrx(
        address _account,
        address _token,
        uint256 _amount
    ) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedSrxTracker).stakedAmounts(
            _account
        );

        IRewardTracker(feeSrxTracker).unstakeForAccount(
            _account,
            bonusSrxTracker,
            _amount,
            _account
        );
        IRewardTracker(bonusSrxTracker).unstakeForAccount(
            _account,
            stakedSrxTracker,
            _amount,
            _account
        );
        IRewardTracker(stakedSrxTracker).unstakeForAccount(
            _account,
            _token,
            _amount,
            _account
        );

        uint256 bnSrxAmount = IRewardTracker(bonusSrxTracker).claimForAccount(
            _account,
            _account
        );
        if (bnSrxAmount > 0) {
            IRewardTracker(feeSrxTracker).stakeForAccount(
                _account,
                _account,
                bnSrx,
                bnSrxAmount
            );
        }

        uint256 stakedBnSrx = IRewardTracker(feeSrxTracker).depositBalances(
            _account,
            bnSrx
        );
        if (stakedBnSrx > 0) {
            uint256 reductionAmount = stakedBnSrx.mul(_amount).div(balance);
            IRewardTracker(feeSrxTracker).unstakeForAccount(
                _account,
                bnSrx,
                reductionAmount,
                _account
            );
            IMintable(bnSrx).burn(_account, reductionAmount);
        }

        emit UnstakeSrx(_account, _amount);
    }
}
