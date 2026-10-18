// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title QmoosaToken
 * @notice Governance token with checkpointed historical voting power and delegation.
 *         Immune to flash-loan vote borrowing by evaluating voting power strictly at
 *         past snapshot blocks.
 */
contract QmoosaToken {
    string public name = "QMOOSA Governance Token";
    string public symbol = "QGOV";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => address) public delegates;
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;

    // Checkpointed total supply
    mapping(uint32 => Checkpoint) public totalSupplyCheckpoints;
    uint32 public numTotalSupplyCheckpoints;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousBalance, uint256 newBalance);

    error BlockNotYetMined();
    error ZeroAddress();

    constructor(uint256 initialSupply, address initialHolder) {
        if (initialHolder == address(0)) revert ZeroAddress();
        _mint(initialHolder, initialSupply);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _mint(address account, uint256 amount) internal {
        if (account == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[account] += amount;
        emit Transfer(address(0), account, amount);

        _writeTotalSupplyCheckpoint(totalSupply);
        _moveVotingPower(address(0), delegates[account], amount);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "INSUFFICIENT_ALLOWANCE");
            allowance[from][msg.sender] -= value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        require(balanceOf[from] >= value, "INSUFFICIENT_BALANCE");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);

        _moveVotingPower(delegates[from], delegates[to], value);
    }

    function delegate(address delegatee) external {
        address currentDelegate = delegates[msg.sender];
        delegates[msg.sender] = delegatee;
        emit DelegateChanged(msg.sender, currentDelegate, delegatee);

        uint256 delegatorBalance = balanceOf[msg.sender];
        if (delegatorBalance > 0) {
            _moveVotingPower(currentDelegate, delegatee, delegatorBalance);
        }
    }

    function getCurrentVotes(address account) external view returns (uint256) {
        uint32 nCheckpoints = numCheckpoints[account];
        return nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert BlockNotYetMined();

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) return 0;

        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256) {
        if (blockNumber >= block.number) revert BlockNotYetMined();

        uint32 nCheckpoints = numTotalSupplyCheckpoints;
        if (nCheckpoints == 0) return 0;

        if (totalSupplyCheckpoints[nCheckpoints - 1].fromBlock <= blockNumber) {
            return totalSupplyCheckpoints[nCheckpoints - 1].votes;
        }

        if (totalSupplyCheckpoints[0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            Checkpoint memory cp = totalSupplyCheckpoints[center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return totalSupplyCheckpoints[lower].votes;
    }

    function _moveVotingPower(address src, address dst, uint256 amount) internal {
        if (src != dst && amount > 0) {
            if (src != address(0)) {
                uint32 srcRepNum = numCheckpoints[src];
                uint256 srcRepOld = srcRepNum > 0 ? checkpoints[src][srcRepNum - 1].votes : 0;
                uint256 srcRepNew = srcRepOld - amount;
                _writeCheckpoint(src, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dst != address(0)) {
                uint32 dstRepNum = numCheckpoints[dst];
                uint256 dstRepOld = dstRepNum > 0 ? checkpoints[dst][dstRepNum - 1].votes : 0;
                uint256 dstRepNew = dstRepOld + amount;
                _writeCheckpoint(dst, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(address delegatee, uint32 nCheckpoints, uint256 oldVotes, uint256 newVotes) internal {
        uint32 blockNumber = uint32(block.number);

        if (nCheckpoints > 0 && checkpoints[delegatee][nCheckpoints - 1].fromBlock == blockNumber) {
            checkpoints[delegatee][nCheckpoints - 1].votes = uint224(newVotes);
        } else {
            checkpoints[delegatee][nCheckpoints] = Checkpoint(blockNumber, uint224(newVotes));
            numCheckpoints[delegatee] = nCheckpoints + 1;
        }
        emit DelegateVotesChanged(delegatee, oldVotes, newVotes);
    }

    function _writeTotalSupplyCheckpoint(uint256 newSupply) internal {
        uint32 blockNumber = uint32(block.number);
        uint32 n = numTotalSupplyCheckpoints;

        if (n > 0 && totalSupplyCheckpoints[n - 1].fromBlock == blockNumber) {
            totalSupplyCheckpoints[n - 1].votes = uint224(newSupply);
        } else {
            totalSupplyCheckpoints[n] = Checkpoint(blockNumber, uint224(newSupply));
            numTotalSupplyCheckpoints = n + 1;
        }
    }
}
