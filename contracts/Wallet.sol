// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./GlobalConfig.sol";
import "./HTTokenInterface.sol";
import "./LoanInterface.sol";
import "./ComptrollerInterface.sol";

interface HecoNodeVoteInterface {
	function deposit() external payable;

	function exitVote(uint256 _amount) external;

	function withdraw() external;

	function getPendingReward(address _voter) external view returns (uint256);

	function voters(address voter)
		external
		view
		returns (
			uint256 amount,
			uint256 rewardDebt,
			uint256 withdrawPendingAmount,
			uint256 withdrawExitBlock
		);
}

interface BankInterface {
	function mint(uint256 mintAmount) external returns (uint256);

	function borrow(uint256 borrowAmount) external returns (uint256);

	function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

	function repayBorrow() external payable;

	function balanceOf(address owner) external view returns (uint256);

	function exchangeRateCurrent() external returns (uint256);
}

contract Wallet is AccessControl {
	using SafeMath for uint256;
	using Math for uint256;
	using Address for address;

	address private _owner;
	address internal _firstLiquidater;
	address internal _secondLiquidater;
	bool private _isLiquidating = false;
	GlobalConfig private _config;
	HTTokenInterface private _HTT;
	LoanInterface private _loanContract;
	BankInterface private _borrowContract;
	BankInterface private _depositContract;
	ComptrollerInterface private _comptrollerContract;
	address[] private _voted;

	event VoteEvent(address voter, uint256 amount);
	event BorrowEvent(address borrower, uint256 amount);
	event BurnHTTEvent(address voter, uint256 amount);
	event ClaimEvent(address caller, uint256 pid, uint256 amount);
	event WithdrawEvent(address voter, address validator, uint256 amount);
	event RevokeEvent(address voter, address validator, uint256 amount);
	event LiquidateEvent(address voter, uint256 amount);
	event RepayVotingPoolEvent(address voter, address validator, uint256 amount);
	event RepayEvent(address caller, uint256 amount);
	event EnterMarkets(address caller, address market);

	constructor(address owner, address config) {
		_owner = owner;
		_config = GlobalConfig(config);
		_HTT = HTTokenInterface(_config.HTT());
		_loanContract = LoanInterface(_config.loanContract());
		_depositContract = BankInterface(_config.depositContract());
		_borrowContract = BankInterface(_config.borrowContract());
		_comptrollerContract = ComptrollerInterface(_config.comptrollerContract());

		address[] memory args = new address[](1);
		args[0] = _config.depositContract();
		_enterMarkets(args);
	}

	receive() external payable {}

	function vote(address validator) external payable {
		require(_config.validators(validator) == true, "it's not a validator");

		_voteOn();
		_isOwner();
		_checkLiquidationOff();

		HecoNodeVoteInterface voting = HecoNodeVoteInterface(validator);

		uint256 amount = msg.value;
		require(amount > 0, "amount == 0");

		voting.deposit{ value: amount }();
		_depositHTT(amount);

		(bool isVoted, ) = _isVoted(validator);
		if (!isVoted) {
			_voted.push(validator);
		}

		emit VoteEvent(msg.sender, amount);
	}

	function checkMembership() external view returns (bool) {
		return _comptrollerContract.checkMembership(address(this), CTokenInterface(_config.depositContract()));
	}

	function getUserVotingSummary(address validator)
		external
		view
		returns (
			uint256 amount,
			uint256 rewardDebt,
			uint256 withdrawPendingAmount,
			uint256 withdrawExitBlock
		)
	{
		HecoNodeVoteInterface voting = HecoNodeVoteInterface(validator);
		return voting.voters(address(this));
	}

	function getExchangeRate() public returns (uint256) {
		return _exchangeRateStored();
	}

	function getBorrowLimit() public returns (uint256) {
		uint256 borrowAble = _getBorrowableAmount().mul(_config.borrowRate()).div(_config.denominator());
		uint256 borrowed = getBorrowed();
		if (borrowAble > borrowed) {
			return borrowAble.sub(borrowed);
		} else {
			return 0;
		}
	}

	function getBorrowed() public returns (uint256) {
		return _loanContract.borrowBalanceCurrent(address(this));
	}

	function borrow(uint256 borrowAmount) external {
		_isOwner();
		_checkLiquidationOff();

		require(borrowAmount > 0 && borrowAmount <= getBorrowLimit(), "amount > limit");
		require(_borrowContract.borrow(borrowAmount) == 0, "Failed to borrow");

		payable(msg.sender).transfer(borrowAmount);
		emit BorrowEvent(msg.sender, borrowAmount);
	}

	function getBalance() external view returns (uint256) {
		return address(this).balance;
	}

	function pendingReward(address validator) external view returns (uint256) {
		HecoNodeVoteInterface voting = HecoNodeVoteInterface(validator);
		return voting.getPendingReward(address(this));
	}

	function getPendingRewardFilda() external returns (uint256 balance, uint256 allocated) {
		return _loanContract.getCompBalanceWithAccrued(address(this));
	}

	function claimFilda() external {
		_isOwner();
		require(_loanContract.claimComp(address(this)), "claim filda error");
		uint256 fildaBalance = _config.filda().balanceOf(address(this));
		if (fildaBalance > 0) {
			_config.filda().transfer(msg.sender, fildaBalance);
		}
	}

	function revokeVote(address validator, uint256 amount) public returns (bool success) {
		_isOwner();

		(bool isVoted, ) = _isVoted(validator);
		require(isVoted, "didn't vote for it");

		return _revokeVote(validator, amount);
	}

	function withdrawAndRepay(address validator) external returns (uint256 withdrawal) {
		_checkLiquidationOff();
		_isOwner();
		_withdrawalOn();

		(bool isVoted, uint8 index) = _isVoted(validator);
		require(isVoted, "didn't vote for it");

		withdrawal = _withdrawOrRepay(validator, true);

		// remove the validator from _voted.
		(uint256 totalAmount, , , ) = this.getUserVotingSummary(validator);
		if (totalAmount == 0) {
			delete _voted[index];
			_voted[index] = _voted[_voted.length - 1];
			_voted.pop();
		}

		uint256 balance = address(this).balance;
		if (balance > 0) {
			payable(msg.sender).transfer(balance);
		}
		emit WithdrawEvent(msg.sender, validator, withdrawal);
	}

	function withdrawAndRepayAll() external {
		_isOwner();
		_withdrawalOn();

		uint256 withdrawal = _withdrawAllVoting(true);
		payable(msg.sender).transfer(address(this).balance);
		emit WithdrawEvent(msg.sender, address(0), withdrawal);
	}

	function liquidate() external payable {
		require(msg.sender.isContract() == false, "msg.sender is contract");

		uint256 borrowBalanceCurrentAmount = getBorrowed();
		uint256 savingBalance = _getBorrowableAmount();
		uint256 borrowed = borrowBalanceCurrentAmount.mul(_config.denominator()).div(savingBalance);
		require(borrowed > _config.liquidateRate(), "borrowed < liquidate limit");

		if (_haveAllVotesBeenRevoked() == false) {
			// Step 1: revoke all votes.
			_checkLiquidationOff();

			require(msg.value == 0, "no need to pay");

			uint256 amount;
			address validator;
			for (uint8 i = 0; i < _voted.length; i++) {
				validator = _voted[i];
				(amount, , , ) = this.getUserVotingSummary(validator);
				revokeVote(validator, amount);
			}

			_isLiquidating = true;
			_firstLiquidater = msg.sender;
		} else {
			// Step 2: withdraw all.
			require(msg.value >= borrowBalanceCurrentAmount, "insufficient amount");

			uint256 total = _withdrawAllVoting(true);

			_secondLiquidater = msg.sender;

			uint256 bonus = 0;
			if (_firstLiquidater == address(0)) {
				bonus = total.mul(_config.bonusRateForLiquidater()).div(_config.denominator());
			} else {
				bonus = total.mul(_config.bonusRateForLiquidater()).div(_config.denominator()).div(2);

				if (_firstLiquidater != _owner) payable(_firstLiquidater).transfer(bonus);
			}

			if (_secondLiquidater != _owner) payable(_secondLiquidater).transfer(bonus);

			payable(_owner).transfer(address(this).balance);

			_isLiquidating = false;

			emit LiquidateEvent(address(this), total);
		}
	}

	function _haveAllVotesBeenRevoked() private view returns (bool allDone) {
		allDone = true;

		uint256 withdrawExitBlock;
		for (uint8 i = 0; i < _voted.length; i++) {
			(, , , withdrawExitBlock) = this.getUserVotingSummary(_voted[i]);
			if (block.number.sub(withdrawExitBlock) < _config.withdrawLockPeriod()) {
				return allDone = false;
			}
		}
	}

	function _withdrawOrRepay(address validator, bool toRepay) private returns (uint256 withdrawal) {
		uint256 oldBalance = address(this).balance;
		HecoNodeVoteInterface voting = HecoNodeVoteInterface(validator);
		voting.withdraw();
		uint256 newBalance = address(this).balance;
		withdrawal = newBalance.sub(oldBalance);

		if (toRepay) {
			// uint256 borrowed = _loanContract.borrowBalanceCurrent(msg.sender);
			uint256 borrowed = getBorrowed();
			uint256 repayAmount = borrowed.min(address(this).balance);

			if (repayAmount > 0) {
				_borrowContract.repayBorrow{ value: repayAmount }();
				emit RepayVotingPoolEvent(msg.sender, validator, repayAmount);
			}

			oldBalance = _HTT.balanceOf(address(this));
			_depositContract.redeemUnderlying(withdrawal);
			newBalance = _HTT.balanceOf(address(this));

			require(newBalance.sub(oldBalance) == withdrawal, "Incorrect withdrawal amount");
			require(_HTT.burn(withdrawal), "burn error");

			emit BurnHTTEvent(msg.sender, withdrawal);
		}
	}

	function _withdrawAllVoting(bool toRepay) private returns (uint256 totalAmount) {
		uint256 withdrawPendingAmount;
		address validator;
		for (uint8 i = 0; i < _voted.length; i++) {
			validator = _voted[i];
			(, , withdrawPendingAmount, ) = this.getUserVotingSummary(validator);

			_withdrawOrRepay(validator, toRepay);
			delete _voted[i];

			totalAmount += withdrawPendingAmount;
		}

		// clean up _voted
		_voted = new address[](0);
	}

	function _exchangeRateStored() private returns (uint256) {
		// return _loanContract.exchangeRateCurrent();
		return _depositContract.exchangeRateCurrent();
	}

	function _checkLiquidationOff() private view {
		require(_isLiquidating == false, "liquidating...");
	}

	function _voteOn() private view {
		require(_config.voteOn() == true, "Vote disabled.");
	}

	function _withdrawalOn() private view {
		require(_config.withdrawalOn() == true, "Withdrawal disabled");
	}

	function _isOwner() private view {
		require(msg.sender == _owner, "not owner");
	}

	function _revokeVote(address validator, uint256 amount) private returns (bool success) {
		HecoNodeVoteInterface voting = HecoNodeVoteInterface(validator);
		voting.exitVote(amount);
		emit RevokeEvent(msg.sender, validator, amount);
		return true;
	}

	function _enterMarkets(address[] memory args) private returns (uint256[] memory result) {
		result = _comptrollerContract.enterMarkets(args);
		emit EnterMarkets(address(this), _config.depositContract());
	}

	function _approve(uint256 amount) private returns (bool) {
		return _HTT.approve(_config.depositContract(), amount);
	}

	function _depositHTT(uint256 integerAmount) private {
		_isOwner();

		require(_approve(integerAmount));

		uint256 oldBalance = _HTT.balanceOf(address(this));

		require(_HTT.mint(integerAmount), "mint error");

		uint256 newBalance = _HTT.balanceOf(address(this));

		require(newBalance.sub(oldBalance) == integerAmount, "the minted HTT amount wrong");
		require(_depositContract.mint(integerAmount) == 0, "deposit error");
	}

	function _getBorrowableAmount() private returns (uint256) {
		return _depositContract.balanceOf(address(this)).mul(getExchangeRate()).div(1e18);
	}

	function _isVoted(address validator) private view returns (bool isVoted, uint8 index) {
		for (uint8 i = 0; i < _voted.length; i++) {
			if (_voted[i] == validator) {
				index = i;
				isVoted = true;
				break;
			}
		}
	}
}
