// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./VotingStrategy.sol";
import "./LoanStrategy.sol";
import "./HTTokenInterface.sol";

contract Wallet is AccessControl {
    using SafeMath for uint256;

    struct RedeemingState {
        uint256 blockNumber;
        uint256 amount;
    }

    // struct LiquidateObject {
    //     address voter;
    //     // uint256 voted;
    //     uint256 debt;
    //     address firstLiquidater;
    //     address secondLiquidater;
    //     // uint256 revokeVoteBlock;
    // }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    VotingStrategy public votingContract;
    LoanStrategy public loanContract;
    bool public isLiquidating = false;
    bool public isExist = false;

    address private _owner;
    uint256 private _minVoteAmount = 1e18;//投票合约需要取整.
    uint256 private _borrowRate = 80;
    uint256 private _emergencyBorrowRate = 98;
    uint256 private _liquidateRate = 90;
    uint256 private _bonusRateForLiquidater = 3;
    // LiquidateObject[] private _liquidateObjects;
    address private _firstLiquidater;
    address private _secondLiquidater;
    uint256 private _loan;
    uint256 private _totalVoted;
    mapping(uint256 => uint256) private _voted;
    address payable private _deployedVoteContract = payable(address(0x123));
    address payable private _deployedLoanContract = payable(address(0x123));
    HTTokenInterface private _HTT = HTTokenInterface(address(0x123));

    // Events
    event voteEvent(address voter, uint256 pid, uint256 amount);

    constructor(address owner) {
        _setupRole(ADMIN_ROLE, msg.sender);
        _setupRole(CONFIG_ROLE, msg.sender);

        isExist = true;

        _owner = owner;
        votingContract = VotingStrategy(_deployedVoteContract);
        loanContract = LoanStrategy(_deployedLoanContract);
    }

    function setConfigRole(address configRoleAddress) public {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not admin.");
        _setupRole(CONFIG_ROLE, configRoleAddress);
    }

    function vote(uint256 pid) public payable {
        uint256 amount = msg.value;

        //取整，退回
        require(amount > _minVoteAmount);

        bool done = votingContract.vote{value: amount}(pid);
        if (done == true) {
            _voted[pid] += amount;
            _totalVoted += amount;

            _HTT.mint(amount);
            //校验。
            loanContract.mint(amount);

            emit voteEvent(msg.sender, pid, amount);
        }
    }

    function claim() public {
        // 这个接口似乎不正确。
        votingContract.claim(payable(msg.sender));
        //转帐给用户。
    }

    function revokeVote(uint256 pid, uint256 amount) public {
        uint256 tempAmount;
        (tempAmount, , ) = votingContract.revokingInfo(address(this), pid);
        require(tempAmount == 0);

        require(_voted[pid] >= amount);
        votingContract.revokeVote(pid, amount);
    }

    function isWithdrawable(uint256 pid) public returns (bool) {
        return votingContract.isWithdrawable(address(this), pid);
    }

    function withdraw(uint256 pid) public returns (uint256) {
        require(isWithdrawable(pid) == true);
        //判断可提取的值……提htt从loan.

        // setp 1.
        uint256 tempAmount = votingContract.withdraw(pid);
        _voted[pid] -= tempAmount;
        _totalVoted -= tempAmount;

        // setp 2.
        payable(msg.sender).transfer(tempAmount);
        // _HTT.burn(amount, caller);

        return tempAmount;
    }

    function rePay(uint256 repayAmount) public payable {
        address payable caller = payable(msg.sender);
        require(caller.balance >= repayAmount);
        loanContract.repayBorrow(caller, repayAmount);
    }

    function redeemAndRePay(uint256 pid) public {
        require(_loan <= _voted[pid].mul(_borrowRate).div(100));
        require(isWithdrawable(pid) == true);

        uint256 lockingEndTime;
        (, , lockingEndTime) = votingContract.revokingInfo(address(this), pid);
        require(lockingEndTime < block.timestamp);

        // 需要amount,
        uint256 amount = withdraw(pid);
        _HTT.burn(amount);
        votingContract.withdraw(pid);
        loanContract.repayBorrow(payable(msg.sender), amount);
        // 提取htt
        // htt.burn()
    }

    // 改名revokeALl()
    function beginLiquidate() public {
        //从filda读取借款使用率。and
        // 判断msg.sender是不是本人。
        uint256 total = votingContract.getPoolLength();
        for (uint256 i = 0; i < total; i++) {
            if (_voted[i] > 0) {
                revokeVote(i, _voted[i]);
            }
        }

        //从filda读取借款使用率。不超为0。
        _firstLiquidater = msg.sender;
    }

    function liquidate() public {
        //从filda读取借款使用率。
        // require(isLiquidating == true);

        uint256 total = votingContract.getPoolLength();
        for (uint256 i = 0; i < total; i++) {
            if (_voted[i] > 0) {
                withdraw(i);
                _voted[i] = 0;
            }
        }

        _secondLiquidater = msg.sender;

        loanContract.repayBorrow(
            payable(_owner),
            loanContract.borrowBalanceCurrent(msg.sender)
        );

        _HTT.burn(_totalVoted);

        uint256 bonus = _totalVoted.mul(_bonusRateForLiquidater).div(100).div(
            2
        );
        payable(_firstLiquidater).transfer(bonus);
        payable(_secondLiquidater).transfer(bonus);

        _totalVoted = 0;
        _loan = 0;
        isLiquidating = false;
    }

    function borrow(uint256 pid, uint256 borrowAmount) public {
        require(borrowAmount > 0);
        //从filda读取数据来计算可借的量。
        require(borrowAmount <= _voted[pid].mul(_borrowRate).div(100));

        loanContract.borrow(borrowAmount);
        payable(msg.sender).transfer(borrowAmount);
        _loan += borrowAmount;

        // _setAsLiquidateable();
    }

    function emergencyWithdraw(uint256 borrowAmount) public {
        // 参数不必要。
        require(borrowAmount > 0);
        require(borrowAmount <= _totalVoted.mul(_emergencyBorrowRate).div(100));

        //根据filda的数据来算。
        loanContract.borrow(borrowAmount);
        payable(msg.sender).transfer(borrowAmount);

        //revokeAll()
        //清算开始。

        // _setAsLiquidateable();
    }


    // function _setAsLiquidateable() private {
    //     if (
    //         loanContract.borrowBalanceCurrent(msg.sender) >=
    //         _totalVoted.mul(_liquidateRate).div(100)
    //     ) {
    //         isLiquidating = true;
    //     }
    // }
}
