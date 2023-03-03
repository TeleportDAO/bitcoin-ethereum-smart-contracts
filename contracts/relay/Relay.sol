// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

// import "../libraries/BitcoinHelper.sol";
import "./interfaces/IRelay.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Relay is IRelay, Ownable, ReentrancyGuard, Pausable {

    // using BitcoinHelper for bytes29;
    using SafeERC20 for IERC20;

    // Public variables
    uint constant ONE_HUNDRED_PERCENT = 10000;
    uint constant MAX_FINALIZATION_PARAMETER = 432; // roughly 3 days

    uint public override initialHeight;
    uint public override lastVerifiedHeight;
    uint public override finalizationParameter;
    uint public override rewardAmountInTDT;
    uint public override relayerPercentageFee; // A number between [0, 10000)
    uint public override submissionGasUsed; // Gas used for submitting a block header
    uint public override epochLength;
    uint public override baseQueries;
    uint public override currentEpochQueries;
    uint public override lastEpochQueries;
    uint public override disputeTime;
    uint public override proofTime;
    address public override TeleportDAOToken;
    bytes32 public override relayGenesisHash; // Initial block header of relay
    uint public override minCollateralRelayer;
    uint public override minCollateralDisputer;
    uint public override disputeRewardPercentage;

    // Private and internal variables
    mapping(uint => blockHeader[]) private chain; // height => list of block headers
    mapping(bytes32 => bytes32) internal previousBlock; // block header hash => parent header hash
    mapping(bytes32 => uint256) internal blockHeight; // block header hash => block height
    mapping(address => uint) internal relayers; // relayer address => locked collateral
    mapping(address => uint) internal disputers; // disputer address => locked collateral

    /// @notice                   Gives a starting point for the relay
    /// @param  _genesisHeader    The starting header
    /// @param  _height           The starting height
    /// @param  _periodStart      The hash of the first header in the genesis epoch
    /// @param  _TeleportDAOToken The address of the TeleportDAO ERC20 token contract
    constructor(
        bytes memory _genesisHeader,
        uint256 _height,
        bytes32 _periodStart,
        address _TeleportDAOToken
    ) {
        // Adds the initial block header to the chain
        // bytes29 _genesisView = _genesisHeader.ref(0).tryAsHeader();
        // require(_genesisView.notNull(), "Relay: stop being dumb");

        // genesis header and period start can be same
        bytes32 _genesisHash = _genesisView.hash256();
        relayGenesisHash = _genesisHash;
        blockHeader memory newBlockHeader;
        newBlockHeader.selfHash = _genesisHash;
        newBlockHeader.parentHash = _genesisView.parent();
        newBlockHeader.merkleRoot = _genesisView.merkleRoot();
        newBlockHeader.relayer = _msgSender();
        newBlockHeader.gasPrice = 0;
        chain[_height].push(newBlockHeader);
        require(
            _periodStart & bytes32(0x0000000000000000000000000000000000000000000000000000000000ffffff) == bytes32(0),
            "Period start hash does not have work. Hint: wrong byte order?");
        blockHeight[_genesisHash] = _height;
        blockHeight[_periodStart] = _height - (_height % BitcoinHelper.RETARGET_PERIOD_BLOCKS);

        // Relay parameters
        _setFinalizationParameter(3);
        initialHeight = _height;
        lastVerifiedHeight = _height;
        
        _setTeleportDAOToken(_TeleportDAOToken);
        _setRelayerPercentageFee(500);
        _setEpochLength(BitcoinHelper.RETARGET_PERIOD_BLOCKS);
        _setBaseQueries(epochLength);
        lastEpochQueries = baseQueries;
        currentEpochQueries = 0;
        _setSubmissionGasUsed(300000); // in wei
    }

    function renounceOwnership() public virtual override onlyOwner {}

    /// @notice        Pause the relay
    /// @dev           Only functions with whenPaused modifier can be called
    function pauseRelay() external override onlyOwner {
        _pause();
    }

    /// @notice        Unpause the relay
    /// @dev           Only functions with whenNotPaused modifier can be called
    function unpauseRelay() external override onlyOwner {
        _unpause();
    }

    /// @notice             Getter for a specific block header's hash in the stored chain
    /// @param  _height     The height of the desired block header
    /// @param  _index      The index of the desired block header in that height
    /// @return             Block header's hash
    function getBlockHeaderHash (uint _height, uint _index) external view override returns(bytes32) {
        return chain[_height][_index].selfHash;
    }

    /// @notice             Getter for a specific block header's fee price for a query
    /// @param  _height     The height of the desired block header
    /// @param  _index      The index of the desired block header in that height
    /// @return             Block header's fee price for a query
    function getBlockHeaderFee (uint _height, uint _index) external view override returns(uint) {
        return _calculateFee(chain[_height][_index].gasPrice);
    }

    /// @notice             Getter for the number of block headers in the same height
    /// @dev                This shows the number of temporary forks in that specific height
    /// @param  _height     The desired height of the blockchain
    /// @return             Number of block headers stored in the same height
    function getNumberOfSubmittedHeaders (uint _height) external view override returns (uint) {
        return chain[_height].length;
    }

    /// @notice             Getter for available TDT in treasury
    /// @return             Amount of TDT available in Relay treasury
    function availableTDT() external view override returns(uint) {
        return IERC20(TeleportDAOToken).balanceOf(address(this));
    }

    /// @notice             Getter for available target native token in treasury
    /// @return             Amount of target blockchain native token available in Relay treasury
    function availableTNT() external view override returns(uint) {
        return address(this).balance;
    }

    /// @notice         Finds the height of a header by its hash
    /// @dev            Will fail if the header is unknown
    /// @param _hash  The header hash to search for
    /// @return         The height of the header, or error if unknown
    function findHeight(bytes32 _hash) external view override returns (uint256) {
        return _findHeight(_hash);
    }

    /// @notice         Finds an ancestor for a block by its hash
    /// @dev            Will fail if the header is unknown
    /// @param _hash    The header hash to search for
    /// @return         The height of the header, or error if unknown
    function findAncestor(bytes32 _hash, uint256 _offset) external view override returns (bytes32) {
        return _findAncestor(_hash, _offset);
    }

    /// @notice             Checks if a hash is an ancestor of the current one
    /// @dev                Limit the amount of lookups (and thus gas usage) with _limit
    /// @param _ancestor    The prospective ancestor
    /// @param _descendant  The descendant to check
    /// @param _limit       The maximum number of blocks to check
    /// @return             true if ancestor is at most limit blocks lower than descendant, otherwise false
    function isAncestor(bytes32 _ancestor, bytes32 _descendant, uint256 _limit) external view override returns (bool) {
        return _isAncestor(_ancestor, _descendant, _limit);
    }

    /// @notice                             External setter for rewardAmountInTDT
    /// @dev                                This award is for the relayer who has a finalized block header
    /// @param _rewardAmountInTDT           The reward amount in TDT
    function setRewardAmountInTDT(uint _rewardAmountInTDT) external override onlyOwner {
        _setRewardAmountInTDT(_rewardAmountInTDT);
    }

    /// @notice                             External setter for finalizationParameter
    /// @dev                                This might change if finalization rule of the source chain gets updated
    /// @param _finalizationParameter       The finalization parameter of the source chain
    function setFinalizationParameter(uint _finalizationParameter) external override onlyOwner {
        _setFinalizationParameter(_finalizationParameter);
    }

    /// @notice                             External setter for relayerPercentageFee
    /// @dev                                This is updated when we want to change the Relayer reward
    /// @param _relayerPercentageFee        Ratio > 1 that determines percentage of reward to the Relayer
    function setRelayerPercentageFee(uint _relayerPercentageFee) external override onlyOwner {
        _setRelayerPercentageFee(_relayerPercentageFee);
    }

    /// @notice                             External setter for teleportDAO token
    /// @dev                                This is updated when we want to change the teleportDAO token 
    /// @param _TeleportDAOToken            The teleportDAO token address
    function setTeleportDAOToken(address _TeleportDAOToken) external override onlyOwner {
        _setTeleportDAOToken(_TeleportDAOToken);
    }

    /// @notice                             External setter for epochLength
    /// @param _epochLength                 The length of epochs for estimating the user queries hence their fees
    function setEpochLength(uint _epochLength) external override onlyOwner {
        _setEpochLength(_epochLength);
    }

    /// @notice                             External setter for baseQueries
    /// @param _baseQueries                 The base amount of queries we assume in each epoch
    ///                                     (This is for preventing user fees to grow significantly)
    function setBaseQueries(uint _baseQueries) external override onlyOwner {
        _setBaseQueries(_baseQueries);
    }

    /// @notice                             External setter for submissionGasUsed
    /// @dev                                This is updated when the smart contract changes the way of getting block headers
    /// @param _submissionGasUsed           The gas used for submitting one block header
    function setSubmissionGasUsed(uint _submissionGasUsed) external override onlyOwner {
        _setSubmissionGasUsed(_submissionGasUsed);
    }

    /// @notice                             External setter for disputeTime
    /// @dev                                This is updated when duration in which a block can be disputed changes
    /// @param _disputeTime                 The duration in which a block can be disputed after getting submitted
    function setDisputeTime(uint _disputeTime) external override onlyOwner {
        _setDisputeTime(_disputeTime);
    }

    /// @notice                             External setter for proofTime
    /// @dev                                This is updated when duration in which a header proof can be provided changes
    /// @param _proofTime                   The duration in which a header proof can be provided after dispute
    function setProofTime(uint _proofTime) external override onlyOwner {
        _setProofTime(_proofTime);
    }

    /// @notice                             External setter for minCollateralRelayer
    /// @param _minCollateralRelayer        The min amount of collateral needed for submitting one block
    function setMinCollateralRelayer(uint _minCollateralRelayer) external override onlyOwner {
        _setMinCollateralRelayer(_minCollateralRelayer);
    }

    /// @notice                             External setter for minCollateralDisputer
    /// @param _minCollateralDisputer       The min amount of collateral needed for disputing one block
    function setMinCollateralDisputer(uint _minCollateralDisputer) external override onlyOwner {
        _setMinCollateralDisputer(_minCollateralDisputer);
    }

    /// @notice                             Internal setter for disputeRewardPercentage
    /// @param _disputeRewardPercentage     A percentage of the relayer collateral that goes to the disputer
    function setDisputeRewardPercentage(uint _disputeRewardPercentage) external override onlyOwner {
        _setDisputeRewardPercentage(_disputeRewardPercentage);
    }

    /// @notice                             Internal setter for rewardAmountInTDT
    /// @dev                                This award is for the relayer who has a finalized block header
    /// @param _rewardAmountInTDT           The reward amount in TDT
    function _setRewardAmountInTDT(uint _rewardAmountInTDT) private {
        emit NewRewardAmountInTDT(rewardAmountInTDT, _rewardAmountInTDT);
        // this reward can be zero as well
        rewardAmountInTDT = _rewardAmountInTDT;
    }

    /// @notice                             Internal setter for finalizationParameter
    /// @dev                                This might change if finalization rule of the source chain gets updated
    /// @param _finalizationParameter       The finalization parameter of the source chain
    function _setFinalizationParameter(uint _finalizationParameter) private {
        emit NewFinalizationParameter(finalizationParameter, _finalizationParameter);
        require(
            _finalizationParameter > 0 && _finalizationParameter <= MAX_FINALIZATION_PARAMETER,
            "Relay: invalid finalization param"
        );

        finalizationParameter = _finalizationParameter;
    }

    /// @notice                             Internal setter for relayerPercentageFee
    /// @dev                                This is updated when we want to change the Relayer reward
    /// @param _relayerPercentageFee               Ratio > 1 that determines percentage of reward to the Relayer
    function _setRelayerPercentageFee(uint _relayerPercentageFee) private {
        emit NewRelayerPercentageFee(relayerPercentageFee, _relayerPercentageFee);
        require(
            _relayerPercentageFee <= ONE_HUNDRED_PERCENT,
            "Relay: relay fee is above max"
        );
        relayerPercentageFee = _relayerPercentageFee;
    }

    /// @notice                             Internal setter for teleportDAO token
    /// @dev                                This is updated when we want to change the teleportDAO token
    /// @param _TeleportDAOToken            The teleportDAO token address
    function _setTeleportDAOToken(address _TeleportDAOToken) private {
        emit NewTeleportDAOToken(TeleportDAOToken, _TeleportDAOToken);
        TeleportDAOToken = _TeleportDAOToken;
    }

    /// @notice                             Internal setter for epochLength
    /// @param _epochLength                 The length of epochs for estimating the user queries hence their fees
    function _setEpochLength(uint _epochLength) private {
        emit NewEpochLength(epochLength, _epochLength);
        require(
            _epochLength > 0,
            "Relay: zero epoch length"
        );
        epochLength = _epochLength;
    }

    /// @notice                             Internal setter for baseQueries
    /// @param _baseQueries                 The base amount of queries we assume in each epoch
    ///                                     (This is for preventing user fees to grow significantly)
    function _setBaseQueries(uint _baseQueries) private {
        emit NewBaseQueries(baseQueries, _baseQueries);
        require(
            _baseQueries > 0,
            "Relay: zero base query"
        );
        baseQueries = _baseQueries;
    }

    /// @notice                             Internal setter for submissionGasUsed
    /// @dev                                This is updated when the smart contract changes the way of getting block headers
    /// @param _submissionGasUsed           The gas used for submitting one block header
    function _setSubmissionGasUsed(uint _submissionGasUsed) private {
        emit NewSubmissionGasUsed(submissionGasUsed, _submissionGasUsed);
        submissionGasUsed = _submissionGasUsed;
    }

    /// @notice                             Internal setter for disputeTime
    /// @dev                                This is updated when duration in which a block can be disputed changes
    /// @param _disputeTime                 The duration in which a block can be disputed after getting submitted
    function _setDisputeTime(uint _disputeTime) private {
        emit NewDisputeTime(disputeTime, _disputeTime);
        disputeTime = _disputeTime;
    }

    /// @notice                             External setter for proofTime
    /// @dev                                This is updated when duration in which a header proof can be provided changes
    /// @param _proofTime                   The duration in which a header proof can be provided after disputefunction _setProofTime(uint _proofTime) private {
    function _setProofTime(uint _proofTime) private {
        emit NewProofTime(proofTime, _proofTime);
        proofTime = _proofTime;
    }

    /// @notice                             Internal setter for minCollateralRelayer
    /// @param _minCollateralRelayer        The min amount of collateral needed for submitting one block
    function _setMinCollateralRelayer(uint _minCollateralRelayer) private {
        emit NewMinCollateralRelayer(minCollateralRelayer, _minCollateralRelayer);
        minCollateralRelayer = _minCollateralRelayer;
    }

    /// @notice                             Internal setter for minCollateralDisputer
    /// @param _minCollateralDisputer       The min amount of collateral needed for disputing one block
    function _setMinCollateralDisputer(uint _minCollateralDisputer) private {
        emit NewMinCollateralDisputer(minCollateralDisputer, _minCollateralDisputer);
        minCollateralDisputer = _minCollateralDisputer;
    }

    /// @notice                             Internal setter for disputeRewardPercentage
    /// @param _disputeRewardPercentage     A percentage of the relayer collateral that goes to the disputer
    function _setDisputeRewardPercentage(uint _disputeRewardPercentage) private {
        emit NewDisputeRewardPercentage(disputeRewardPercentage, _disputeRewardPercentage);
        disputeRewardPercentage = _disputeRewardPercentage;
    }

    /// @notice                         Checks if a tx is included and finalized on the source blockchain
    /// @dev                            Checks if the block is finalized, and Merkle proof is correct
    /// @param  _txid                   Desired tx Id in LE form
    /// @param  _blockHeight            Block height of the desired tx
    /// @param  _intermediateNodes      Part of the Merkle tree from the tx to the root (Merkle proof) in LE form
    /// @param  _index                  The index of the tx in Merkle tree
    /// @return                         True if the provided tx is confirmed on the source blockchain, False otherwise
    function checkTxProof (
        bytes32 _txid, // In LE form
        uint _blockHeight,
        bytes calldata _intermediateNodes, // In LE form
        uint _index
    ) external payable nonReentrant whenNotPaused override returns (bool) {
        require(_txid != bytes32(0), "Relay: txid should be non-zero");
        // Revert if the block is not finalized
        require(
            _blockHeight + finalizationParameter < lastVerifiedHeight + 1,
            "Relay: block is not finalized on the relay"
        );
        // Block header exists on the relay
        require(
            _blockHeight >= initialHeight,
            "Relay: the requested height is not submitted on the relay (too old)"
        );
        
        // Count the query for next epoch fee calculation
        currentEpochQueries += 1;

        // Get the relay fee from the user
        require(
            _getFee(chain[_blockHeight][0].gasPrice), 
            "Relay: getting fee was not successful"
        );
        
        // Check the inclusion of the transaction
        bytes32 _merkleRoot = chain[_blockHeight][0].merkleRoot;
        bytes29 intermediateNodes = _intermediateNodes.ref(0).tryAsMerkleArray(); // Check for errors if any
        return BitcoinHelper.prove(_txid, _merkleRoot, intermediateNodes, _index);
    }

    /// @notice             Adds header to storage
    /// @dev                
    /// @param  _anchor     The header immediately preceeding the new chain
    /// @param  _header     A 80-byte Bitcoin header
    /// @return             True if successfully written, error otherwise
    function addHeader(
        bytes calldata _anchor, 
        bytes calldata _header
    ) external payable nonReentrant whenNotPaused override returns (bool) {
        // check relayer has enough available collateral
        require(msg.value >= minCollateralRelayer, "Relay: no enough collateral -- relayer");
        relayers[_msgSender()] += msg.value;
        
        bytes29 _headerView = _header.ref(0).tryAsHeaderArray();
        bytes29 _anchorView = _anchor.ref(0).tryAsHeader();

        _checkInputSizeAddHeaders(_headerView, _anchorView);
        _addHeader(_anchorView, _headerView);

        return true;
    }

    /// @notice             Disputes an unverified block header
    /// @dev                
    /// @param  _height     Height of the Bitcoin header
    /// @return             True if successfully passed, error otherwise
    function disputeHeader(uint _height, bytes32 _headerHash) external payable nonReentrant whenNotPaused override returns (bool) {
        /*
            1. check the caller is paying enough collateral
            2. check if the block header exists
            3. check its dispute time has not passed
            4. check it has not been disputed before
        */
        
        require(msg.value >= minCollateralDisputer, "Relay: no enough collateral -- disputer");
        // save collateral amount
        disputers[_msgSender()] += msg.value;
        require(
            _getHeaderIdx(_height, _headerHash) < chain[_height].length, 
            "Relay: header doesn't exist"
        );
        require(chain[_height][idx].startDisputeTime + disputeTime > now, "Relay: dispute time has passed");
        require(chain[_height][idx].disputer == address(0), "Relay: header disputed before");

        chain[_height][idx].disputer = _msgSender();
        chain[_height][idx].startProofTime = now;

        return true;
    }

    // todo think which functions should be pausible which not

    function getDisputeReward(uint _height, bytes32 _headerHash) external nonReentrant whenNotPaused override returns (bool) {
        /* 
            1. check if the block header exists
            2. check the header has been disputed
            3. check the proof time is passed
            4. check the header has not been verified
        */
        uint idx = _getHeaderIdx(_height, _headerHash);
        require(idx < chain[_height].length, "Relay: header doesn't exist");
        require(_disputed(_height, idx), "Relay: header not disputed");
        require(_proofTimePassed(_height, idx), "Relay: proof time not passed");
        require(!chain[_height][idx].verified, "Relay: header has been verified");

        // send the disputer reward + its collateral
        Address.sendValue(
            payable(chain[_height][idx].disputer), 
            relayers[relayer] * disputeRewardPercentage / ONE_HUNDRED_PERCENT + disputer[chain[_height][idx].disputer]
        );
        relayers[relayer] = 0;
        disputer[chain[_height][idx].disputer] = 0;
        return true;
    }

    function provideHeaderProof() external nonReentrant whenNotPaused override returns (bool) {
    } // todo modify inputs interface
    // todo emit events everywhere

    function provideHeaderProofWithRetarget() external nonReentrant whenNotPaused override returns (bool) {
    } // todo modify inputs interface

    /// @notice                 Checks the size of addHeader inputs 
    /// @param  _headerView     Input to the addHeader and ownerAddHeaders functions
    /// @param  _anchorView     Input to the addHeader and ownerAddHeaders functions
    function _checkInputSizeAddHeaders(bytes29 _headerView, bytes29 _anchorView) internal pure {
        require(_headerView.notNull(), "Relay: header array length must be divisible by 80");
        require(_anchorView.notNull(), "Relay: anchor must be 80 bytes");
    }

    /// @notice             Finds the height of a header by its hash
    /// @dev                Will fail if the header is unknown
    /// @param _hash        The header hash to search for
    /// @return             The height of the header
    function _findHeight(bytes32 _hash) internal view returns (uint256) {
        if (blockHeight[_hash] == 0) {
            revert("Relay: unknown block");
        }
        else {
            return blockHeight[_hash];
        }
    }

    /// @notice             Finds an ancestor for a block by its hash
    /// @dev                Will fail if the header is unknown
    /// @param _hash        The header hash to search for
    /// @param _offset      The depth which is going to be searched
    /// @return             The height of the header, or error if unknown
    function _findAncestor(bytes32 _hash, uint256 _offset) internal view returns (bytes32) {
        bytes32 _current = _hash;
        for (uint256 i = 0; i < _offset; i++) {
            _current = previousBlock[_current];
        }
        require(_current != bytes32(0), "Relay: unknown ancestor");
        return _current;
    }

    /// @notice             Checks if a hash is an ancestor of the current one
    /// @dev                Limit the amount of lookups (and thus gas usage) with _limit
    /// @param _ancestor    The prospective ancestor
    /// @param _descendant  The descendant to check
    /// @param _limit       The maximum number of blocks to check
    /// @return             true if ancestor is at most limit blocks lower than descendant, otherwise false
    function _isAncestor(bytes32 _ancestor, bytes32 _descendant, uint256 _limit) internal view returns (bool) {
        bytes32 _current = _descendant;
        /* NB: 200 gas/read, so gas is capped at ~200 * limit */
        for (uint256 i = 0; i < _limit; i++) {
            if (_current == _ancestor) {
                return true;
            }
            _current = previousBlock[_current];
        }
        return false;
    }

    /// @notice                 Gets fee from the user
    /// @dev                    Fee is paid in target blockchain native token
    /// @param gasPrice         The gas price had been used for adding the bitcoin block header
    /// @return                 True if the fee payment was successful
    function _getFee(uint gasPrice) internal returns (bool){
        uint feeAmount;
        feeAmount = _calculateFee(gasPrice);
        require(msg.value >= feeAmount, "Relay: fee is not enough");
        Address.sendValue(payable(_msgSender()), msg.value - feeAmount);
        return true;
    }

    /// @notice                 Calculates the fee amount
    /// @dev                    Fee is paid in target blockchain native token
    /// @param gasPrice         The gas price had been used for adding the bitcoin block header
    /// @return                 The fee amount 
    function _calculateFee(uint gasPrice) private view returns (uint) {
        return (submissionGasUsed * gasPrice * (ONE_HUNDRED_PERCENT + relayerPercentageFee) * epochLength) / lastEpochQueries / ONE_HUNDRED_PERCENT;
    }

    /// @notice                 Finds the index of a header hash in a specific height
    /// @param _height          The height of the block header
    /// @param _headerHash      The hash of the block header
    /// @return                 If the header exists: its index, if not: # of headers in that height
    function _getHeaderIdx(uint _height, bytes32 calldata _headerHash) internal returns (uint) {
        for (uint i = 0; i < chain[_height].length; i++) {
            if (chain[_height][i].selfHash == _headerHash) {
                return i;
            }
        }
        return chain[_height].length;
    }

    function _sendBackRelayerCollateral(address relayer) internal {
        // send back the collateral
        Address.sendValue(payable(relayer), relayers[relayer]);
        relayers[relayer] = 0;
    }

    /// @notice             Adds headers to storage
    /// @dev                We do not get a block on top of an unverified block
    /// @return             True if successfully written, error otherwise
    function _addHeader(bytes29 _anchor, bytes29 _header) internal returns (bool) {

        // Extract basic info
        bytes32 _previousHash = _anchor.hash256();
        uint256 _anchorHeight = _findHeight(_previousHash); // revert if the block is unknown
        uint256 _height = _anchorHeight + 1;
        bytes32 _currentHash = _header.hash256();

        /*
        1. check if a previous height block gets verified
        2. check the previous block is verified
        3. check that the blockheader is not a replica
        4. Store the block connection
        5. Store the height
        6. store the block in the chain
        */

        // check if a previous height block gets verified
        // todo test: when no prev block exists, and when two exist,also check now is correct and
        // does not have a huge error
        require(
            _getHeaderIdx(_anchorHeight, _previousHash) < chain[_anchorHeight].length, 
            "Relay: anchor doesn't exist"
        );

        if (!_disputed(_anchorHeight, idx)) {
            require(_disputeTimePassed(_anchorHeight, idx), "Relay: previous block not verified yet");
            if (!chain[_anchorHeight][idx].verified){
                chain[_anchorHeight][idx].verified = true;
                _sendBackRelayerCollateral(chain[_anchorHeight][idx].relayer);
            }
        } else {
            require(chain[_anchorHeight][idx].verified, "Relay: previous block not verified");
        }

        // check if any block gets finalized
        if(_anchorHeight > lastVerifiedHeight){
            lastVerifiedHeight += 1;
            _updateFee();
            _pruneChain();
        }

        // The below check prevents adding a replicated block header
        require(
            previousBlock[_currentHash] == bytes32(0),
            "Relay: the block header exists on the relay"
        );

        previousBlock[_currentHash] = _previousHash; // todo do we need this mapping at all?
        blockHeight[_currentHash] = _height;
        emit BlockAdded(_height, _currentHash, _previousHash, _msgSender());
        _addToChain(_header, _height);
        
        return true;
    }

    function _disputed(uint _height, uint idx) internal returns (bool) {
        return (chain[_height][idx].disputer == address(0))? false: true;
    }

    function _disputeTimePassed(uint _height, uint idx) internal returns (bool) {
        return (now - chain[_height][idx].startDisputeTime >= disputeTime)? true: false;
    }
    
    function _proofTimePassed(uint _height, uint idx) internal returns (bool) {
        return (now - chain[_height][idx].startProofTime >= proofTime)? true: false;
    }

    /// @notice                     Sends reward and compensation to the relayer
    /// @dev                        We pay the block submission cost in TNT and the extra reward in TDT
    /// @param  _relayer            The relayer address
    /// @param  _height             The height of the bitcoin block
    /// @return                     Reward in native token
    /// @return                     Reward in TDT token
    function _sendReward(address _relayer, uint _height) internal returns (uint, uint) {

        // Reward in TNT
        uint rewardAmountInTNT = submissionGasUsed * chain[_height][0].gasPrice * (ONE_HUNDRED_PERCENT + relayerPercentageFee) / ONE_HUNDRED_PERCENT;

        // Reward in TDT
        uint contractTDTBalance = 0;
        if (TeleportDAOToken != address(0)) {
            contractTDTBalance = IERC20(TeleportDAOToken).balanceOf(address(this));
        }

        // Send reward in TDT
        bool sentTDT;
        if (rewardAmountInTDT <= contractTDTBalance && rewardAmountInTDT > 0) {
            // Call ERC20 token contract to transfer reward tokens to the relayer
            IERC20(TeleportDAOToken).safeTransfer(_relayer, rewardAmountInTDT);
            sentTDT = true;
        }

        // Send reward in TNT
        bool sentTNT;
        if (address(this).balance > rewardAmountInTNT && rewardAmountInTNT > 0) {
            // note: no need to revert if failed
            (sentTNT,) = payable(_relayer).call{value: rewardAmountInTNT}("");
        }

        if (sentTNT) {
            return sentTDT ? (rewardAmountInTNT, rewardAmountInTDT) : (rewardAmountInTNT, 0);
        } else {
            return sentTDT ? (0, rewardAmountInTDT) : (0, 0);
        }
    }

    /// @notice                     Adds a header to the chain
    /// @param  _header             The new block header
    /// @param  _height             The height of the new block header
    function _addToChain(bytes29 _header, uint _height) internal {
        // Prevent relayers to submit too old block headers
        require(_height + finalizationParameter > lastVerifiedHeight, "Relay: block header is too old");
        blockHeader memory newBlockHeader;
        newBlockHeader.selfHash = _header.hash256();
        newBlockHeader.parentHash = _header.parent();
        newBlockHeader.merkleRoot = _header.merkleRoot();
        newBlockHeader.relayer = _msgSender();
        newBlockHeader.gasPrice = tx.gasprice;
        newBlockHeader.verified = false;
        newBlockHeader.startDisputeTime = now;
        chain[_height].push(newBlockHeader);
    }

    /// @notice                     Reset the number of users in an epoch when a new epoch starts
    /// @dev                        This parameter is used when calculating the fee that relay gets from a user in the next epoch
    function _updateFee() internal {
        if (lastVerifiedHeight % epochLength == 0) {
            lastEpochQueries = (currentEpochQueries < baseQueries) ? baseQueries : currentEpochQueries;
            currentEpochQueries = 0;
        }
    }

    /// @notice                     Finalizes a block header and removes all the other headers in the same height
    /// @dev                        Note that when a chain gets pruned, it only deletes other blocks in the same 
    ///                             height as the finalized blocks. Other blocks on top of the non finalized blocks 
    ///                             of that height will exist until their height gets finalized.
    function _pruneChain() internal {
        // Make sure that we have at least finalizationParameter blocks on relay
        if ((lastVerifiedHeight - initialHeight) >= finalizationParameter){
            uint idx = finalizationParameter;
            uint currentHeight = lastVerifiedHeight;
            uint stableIdx = 0;
            while (idx > 0) {
                // bytes29 header = chain[currentHeight][stableIdx];
                bytes32 parentHeaderHash = chain[currentHeight][stableIdx].parentHash;
                stableIdx = _findIndex(parentHeaderHash, currentHeight-1);
                idx--;
                currentHeight--;
            }
            // Keep the finalized block header and delete rest of headers
            chain[currentHeight][0] = chain[currentHeight][stableIdx];
            if(chain[currentHeight].length > 1){
                _pruneHeight(currentHeight);
            }
            // A new block has been finalized, we send its relayer's reward
            uint rewardAmountTNT;
            uint rewardAmountTDT;
            (rewardAmountTNT, rewardAmountTDT) = _sendReward(chain[currentHeight][0].relayer, currentHeight);

            emit BlockFinalized(
                currentHeight,
                chain[currentHeight][0].selfHash,
                chain[currentHeight][0].parentHash,
                chain[currentHeight][0].relayer,
                rewardAmountTNT,
                rewardAmountTDT
            );
        }
    }

    /// @notice                     Finds the index of a block header in a specific height
    /// @dev
    /// @param  _headerHash         The block header hash
    /// @param  _height             The height of the block header
    /// @return  index              Index of the block header
    function _findIndex(bytes32 _headerHash, uint _height) internal view returns(uint index) {
        for (uint256 _index = 0; _index < chain[_height].length; _index++) {
            if(_headerHash == chain[_height][_index].selfHash) {
                index = _index;
            }
        }
    }

    /// @notice                     Deletes all the block header in the same height except the first header
    /// @dev                        The first header is the one that has gotten finalized
    /// @param  _height             The height of the new block header
    function _pruneHeight(uint _height) internal {
        uint idx = chain[_height].length - 1;
        while(idx > 0){
            chain[_height].pop();
            idx -= 1;
        }
    }
}
