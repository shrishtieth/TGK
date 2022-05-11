// SPDX-License-Identifier: MIT
pragma solidity =0.8.10;

interface IStakingPlatform {
    function deposit(uint256 amount) external;
    function withdrawAll() external;
    function withdraw(uint256 amount) external;
    function amountStaked(address stakeHolder) external view returns (uint256);
    function totalDeposited() external view returns (uint256);
    function rewardOf(address stakeHolder) external view returns (uint256);
    function claimRewards() external;
    event Deposit(address indexed owner, uint256 amount);
    event Withdraw(address indexed owner, uint256 amount);
    event Claim(address indexed stakeHolder, uint256 amount);
    event StartStaking(uint256 startPeriod, uint256 lockupPeriod, uint256 endingPeriod);
}
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";

interface IUniswapV2Pair {

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

}

interface IETHPrice{
   function getLatestPrice() external view returns(int);
}

contract StakingPlatform is IStakingPlatform, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token;

    uint256 public fixedAPY;

    uint256 public fees = 700;

    uint256 public stakingDuration;
    uint256 public lockupDuration;
    uint256 public  stakingMax;

    uint256 public startPeriod;
    uint256 public lockupPeriod;
    uint256 public endPeriod;

    uint256 private _totalStaked;
    uint256 internal _precision = 1E6;

    mapping(address => uint256) public staked;
    mapping(address => uint256) private _rewardsToClaim;
    mapping(address => uint256) private _userStartTime;
    mapping(address => uint256) private _userLastTime;

    IUniswapV2Pair public pairContract;
    IETHPrice public ETHPrice;
    uint256 public _index;

    uint256 public minimumStakingAmount = 4700000000000000000;
    uint256 public basicPrice = 5000000000000000000;
    uint256 public silverPrice = 10000000000000000000;
    uint256 public goldPrice = 15000000000000000000;
    uint256 public diamondPrice = 20000000000000000000;


    /**
     * @notice constructor contains all the parameters of the staking platform
     * @dev all parameters are 
     */
    constructor(
        address _token,
        uint256 _fixedAPY,
        uint256 _duration,
        uint256 _lockDuration,
        uint _maxAmountStaked,
        address pair,
        address oracle
    ) {
        stakingDuration = _duration;
        lockupDuration = _lockDuration;
        token = IERC20(_token);
        fixedAPY = _fixedAPY;
        stakingMax = _maxAmountStaked;
        startPeriod = block.timestamp;
        endPeriod = block.timestamp + stakingDuration;
        pairContract = IUniswapV2Pair(pair);
          ETHPrice = IETHPrice(oracle);
        (address token0, ) = (pairContract.token0(), pairContract.token1());
        _index = _token == token0 ? 0 : 1;
        emit StartStaking(startPeriod, lockupDuration, endPeriod);
       
    }

    function getTokensFromPrice(uint256 requiredPrice) public view returns(uint256 amount){
       uint256 price = TgkPriceInUSD();
       return(requiredPrice*(10**18)/price);
    }

    function TgkPriceInUSD() public view returns(uint256){
        (uint112 reserve0, uint112 reserve1, ) = pairContract.getReserves();
        uint256 _ETHPrice = uint256(ETHPrice.getLatestPrice());
       uint256 price = _index == 0? (reserve1*(10**8))/(reserve0): (reserve0*(10**8))/(reserve1);
        
        return(price*(_ETHPrice));
    }



    function getUserLevel(address user) external view returns(string memory level){
        if(staked[user]>=getTokensFromPrice(minimumStakingAmount) && staked[user]<getTokensFromPrice(silverPrice)){
            return("Basic");
        }
        else if(staked[user]>=getTokensFromPrice(silverPrice) && staked[user]<getTokensFromPrice(goldPrice))
            return("Silver");
        else if(staked[user]>=getTokensFromPrice(goldPrice) && staked[user]<getTokensFromPrice(diamondPrice))
            return("Gold");
        else if(staked[user]>=getTokensFromPrice(diamondPrice))
            return("Diamond");
    }

   
    function deposit(uint256 amount) external override {
        require(amount >= getTokensFromPrice(minimumStakingAmount),"Amount Too Low");
        require(
            endPeriod == 0 || endPeriod > block.timestamp,
            "Staking period ended"
        );
        require(
            _totalStaked + amount <= stakingMax,
            "Amount staked exceeds MaxStake"
        );
        require(amount > 0, "Amount must be greater than 0");

        if (_userStartTime[_msgSender()] == 0) {
            _userStartTime[_msgSender()] = block.timestamp;
        }

        _userLastTime[msg.sender] = block.timestamp;

        _updateRewards();

        staked[_msgSender()] += amount;
        _totalStaked += amount;
        token.safeTransferFrom(_msgSender(), address(this), amount);
        emit Deposit(_msgSender(), amount);
    }

   
    function withdraw(uint256 amount) external override {
        require(
            block.timestamp >= _userLastTime[msg.sender] + lockupPeriod,
            "No withdraw until lockup ends"
        );
        require(amount > 0, "Amount must be greater than 0");
        require(
            amount <= staked[_msgSender()],
            "Amount higher than stakedAmount"
        );

        _updateRewards();
        if (_rewardsToClaim[_msgSender()] > 0) {
            _claimRewards();
        }
        _totalStaked -= amount;
        staked[_msgSender()] -= amount;
        token.safeTransfer(_msgSender(), amount);

        emit Withdraw(_msgSender(), amount);
    }

    function withdrawAndPayFees(uint256 amount) external {
        require(
            block.timestamp <= _userLastTime[msg.sender] + lockupPeriod,
            "Already Unlocked"
        );
        require(amount > 0, "Amount must be greater than 0");
        require(
            amount <= staked[_msgSender()],
            "Amount higher than stakedAmount"
        );

        _updateRewards();
        if (_rewardsToClaim[_msgSender()] > 0) {
            _claimRewards();
        }
        _totalStaked -= amount;
        staked[_msgSender()] -= amount;
        uint256 _fees = amount*fees/10000;
        token.safeTransfer(_msgSender(), amount - _fees);

        emit Withdraw(_msgSender(), amount);
    }

    
    function withdrawAll() external override {
        require(
            block.timestamp >= lockupPeriod,
            "No withdraw until lockup ends"
        );

        _updateRewards();
        if (_rewardsToClaim[_msgSender()] > 0) {
            _claimRewards();
        }

        _userStartTime[_msgSender()] = 0;
        _userLastTime[_msgSender()] = 0;
        _totalStaked -= staked[_msgSender()];
        uint256 stakedBalance = staked[_msgSender()];
        staked[_msgSender()] = 0;
        token.safeTransfer(_msgSender(), stakedBalance);

        emit Withdraw(_msgSender(), stakedBalance);
    }

    function withdrawAllAndPayFees() external {
        require(
            block.timestamp <= _userLastTime[msg.sender] + lockupPeriod,
            "Already Unlocked"
        );

        _updateRewards();
        if (_rewardsToClaim[_msgSender()] > 0) {
            _claimRewards();
        }

        _userStartTime[_msgSender()] = 0;
        _userLastTime[_msgSender()] = 0;
        _totalStaked -= staked[_msgSender()];
        uint256 stakedBalance = staked[_msgSender()];
        staked[_msgSender()] = 0;
        uint256 _fees = stakedBalance*fees/10000;
        token.safeTransfer(_msgSender(), stakedBalance - _fees);

        emit Withdraw(_msgSender(), stakedBalance);
    }

    /**
     * @notice claim all remaining balance on the contract
     * Residual balance is all the remaining tokens that have not been distributed
     * (e.g, in case the number of stakeholders is not sufficient)
     * @dev Can only be called one year after the end of the staking period
     * Cannot claim initial stakeholders deposit
     */
    function withdrawResidualBalance() external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        uint256 residualBalance = balance - (_totalStaked);
        require(residualBalance > 0, "No residual Balance to withdraw");
        token.safeTransfer(owner(), residualBalance);
    }

    /**
     * @notice function that returns the amount of total Staked tokens
     * for a specific user
     * @param stakeHolder, address of the user to check
     * @return uint256 amount of the total deposited Tokens by the caller
     */
    function amountStaked(address stakeHolder)
        external
        view
        override
        returns (uint256)
    {
        return staked[stakeHolder];
    }

    /**
     * @notice function that returns the amount of total Staked tokens
     * on the smart contract
     * @return uint256 amount of the total deposited Tokens
     */
    function totalDeposited() external view override returns (uint256) {
        return _totalStaked;
    }

    /**
     * @notice function that returns the amount of pending rewards
     * that can be claimed by the user
     * @param stakeHolder, address of the user to be checked
     * @return uint256 amount of claimable rewards
     */
    function rewardOf(address stakeHolder)
        external
        view
        override
        returns (uint256)
    {
        return _calculateRewards(stakeHolder);
    }

    /**
     * @notice function that claims pending rewards
     * @dev transfer the pending rewards to the `msg.sender`
     */
    function claimRewards() external override {
        _claimRewards();
    }

    /**
     * @notice calculate rewards based on the `fixedAPY`, `_percentageTimeRemaining()`
     * @dev the higher is the precision and the more the time remaining will be precise
     * @param stakeHolder, address of the user to be checked
     * @return uint256 amount of claimable tokens of the specified address
     */
    function _calculateRewards(address stakeHolder)
        internal
        view
        returns (uint256)
    {
        if (startPeriod == 0 || staked[stakeHolder] == 0) {
            return 0;
        }

        return
            (((staked[stakeHolder] * fixedAPY) *
                _percentageTimeRemaining(stakeHolder)) / (_precision * 100)) +
            _rewardsToClaim[stakeHolder];
    }


    function _percentageTimeRemaining(address stakeHolder)
        internal
        view
        returns (uint256)
    {
        bool early = startPeriod > _userStartTime[stakeHolder];
        uint256 startTime;
        if (endPeriod > block.timestamp) {
            startTime = early ? startPeriod : _userStartTime[stakeHolder];
            uint256 timeRemaining = stakingDuration -
                (block.timestamp - startTime);
            return
                (_precision * (stakingDuration - timeRemaining)) /
                stakingDuration;
        }
        startTime = early
            ? 0
            : stakingDuration - (endPeriod - _userStartTime[stakeHolder]);
        return (_precision * (stakingDuration - startTime)) / stakingDuration;
    }

    function _claimRewards() private {
        _updateRewards();

        uint256 rewardsToClaim = _rewardsToClaim[_msgSender()];
        require(rewardsToClaim > 0, "Nothing to claim");

        _rewardsToClaim[_msgSender()] = 0;
        token.safeTransfer(_msgSender(), rewardsToClaim);
        emit Claim(_msgSender(), rewardsToClaim);
    }

    function _updateRewards() private {
        _rewardsToClaim[_msgSender()] = _calculateRewards(_msgSender());
        _userStartTime[_msgSender()] = (block.timestamp >= endPeriod)
            ? endPeriod
            : block.timestamp;
    }
}
