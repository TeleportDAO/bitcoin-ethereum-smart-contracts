// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.8.4;

import "../libraries/TypedMemView.sol";
import "../libraries/BitcoinHelper.sol";
import "./interfaces/IRelay.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Relay is IRelay, Ownable, ReentrancyGuard, Pausable {

    using TypedMemView for bytes;
    using TypedMemView for bytes29;
    using BitcoinHelper for bytes29;
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
    bytes32 public override relayGenesisMerkleRoot; // Initial block header of relay
    uint public override minCollateralRelayer;
    uint public override minCollateralDisputer;
    uint public override disputeRewardPercentage;
    uint public override proofRewardPercentage;

    // Private and internal variables
    mapping(uint => blockData[]) private chain; // height => list of block data
    mapping(bytes32 => bytes32) internal previousBlock; // block Merkle root => parent Merkle root
    mapping(bytes32 => uint256) internal blockHeight; // block Merkle root => block height
    mapping(address => uint) internal relayers; // relayer address => locked collateral
    mapping(address => uint) internal disputers; // disputer address => locked collateral

    // todo delete previousBlock[] of the blocks that has gotten finalized to save gas
    // but also add a bool to save submission of a block to prevent replicas

    /// @notice                   Gives a starting point for the relay
    /// @param  _genesisHeader    The starting header
    /// @param  _height           The starting height
    /// @param  _periodStart      The Merkle root of the first header in the genesis epoch
    /// @param  _TeleportDAOToken The address of the TeleportDAO ERC20 token contract
    constructor(
        bytes memory _genesisHeader,
        uint256 _height,
        bytes32 _periodStart,
        address _TeleportDAOToken
    ) {
        // Adds the initial block header to the chain
        bytes29 _genesisView = _genesisHeader.ref(0).tryAsHeader();
        require(_genesisView.notNull(), "Relay: stop being dumb");
        // genesis header and period start can be same
        bytes32 _genesisMerkleRoot = _genesisView.merkleRoot();
        relayGenesisMerkleRoot = _genesisMerkleRoot;
        blockData memory newblockData;
        newblockData.merkleRoot = _genesisView.merkleRoot();
        newblockData.relayer = _msgSender();
        newblockData.gasPrice = 0;
        newblockData.verified = true;
        chain[_height].push(newblockData);
        require(
            _periodStart & bytes32(0x0000000000000000000000000000000000000000000000000000000000ffffff) == bytes32(0),
            "Period start hash does not have work. Hint: wrong byte order?");
        blockHeight[_genesisMerkleRoot] = _height;
        blockHeight[_periodStart] = _height - (_height % BitcoinHelper.RETARGET_PERIOD_BLOCKS);

        // Relay parameters
        _setFinalizationParameter(3); // todo change to 5
        initialHeight = _height;
        lastVerifiedHeight = _height;
        
        _setTeleportDAOToken(_TeleportDAOToken);
        _setRelayerPercentageFee(500);
        _setEpochLength(BitcoinHelper.RETARGET_PERIOD_BLOCKS);
        _setBaseQueries(epochLength);
        lastEpochQueries = baseQueries;
        currentEpochQueries = 0;
        _setSubmissionGasUsed(300000); // in wei // todo compute new value
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
    function getBlockMerkleRoot (uint _height, uint _index) external view override returns(bytes32) {
        return chain[_height][_index].merkleRoot;
    } // todo where do we use this? prvsly it was getBlockHeaderHash... can't have public

    /// @notice             Getter for a specific block header's fee price for a query
    /// @param  _height     The height of the desired block header
    /// @param  _index      The index of the desired block header in that height
    /// @return             Block header's fee price for a query
    function getBlockUsageFee (uint _height, uint _index) external view override returns(uint) {
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
    
    /// @notice                             Internal setter for proofRewardPercentage
    /// @param _proofRewardPercentage     A percentage of the disputer collateral that goes to the relayer
    function setProofRewardPercentage(uint _proofRewardPercentage) external override onlyOwner {
        _setProofRewardPercentage(_proofRewardPercentage);
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

    /// @notice                             Internal setter for proofRewardPercentage
    /// @param _proofRewardPercentage       A percentage of the disputer collateral that goes to the relayer
    function _setProofRewardPercentage(uint _proofRewardPercentage) private {
        emit NewProofRewardPercentage(proofRewardPercentage, _proofRewardPercentage);
        proofRewardPercentage = _proofRewardPercentage;
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
        bytes29 intermediateNodes = _intermediateNodes.ref(0).tryAsMerkleArray(); // Check for errors if any
        return BitcoinHelper.prove(_txid, chain[_blockHeight][0].merkleRoot, intermediateNodes, _index);
    }

    /// @notice                     Adds header to storage
    /// @dev                        
    /// @param  _anchorMerkleRoot   The header hash immediately preceeding the new chain
    /// @param  _blockMerkleRoot    A 80-byte Bitcoin header
    /// @return                     True if successfully written, error otherwise
    function addBlock(
        bytes32 _anchorMerkleRoot, 
        bytes32 _blockMerkleRoot
    ) external payable nonReentrant whenNotPaused override returns (bool) {
        // check relayer has enough available collateral
        require(msg.value >= minCollateralRelayer, "Relay: no enough collateral -- relayer");
        relayers[_msgSender()] += msg.value;
        
        // check input lengths
        require(_blockMerkleRoot != bytes32(0), "Relay: input should be non-zero");
        require(_anchorMerkleRoot != bytes32(0), "Relay: input should be non-zero");

        _addBlock(_anchorMerkleRoot, _blockMerkleRoot);

        return true;
    }

    /// @notice                     Disputes an unverified block header
    /// @param  _blockMerkleRoot    Hash of the Bitcoin header to dispute
    /// @return                     True if successfully passed, error otherwise
    function disputeBlock(bytes32 _blockMerkleRoot) external payable nonReentrant whenNotPaused override returns (bool) {
        /*
            1. check the caller is paying enough collateral
            2. check if the block header exists
            3. check its dispute time has not passed
            4. check it has not been disputed before
        */
        
        require(msg.value >= minCollateralDisputer, "Relay: no enough collateral -- disputer");
        // save collateral amount
        disputers[_msgSender()] += msg.value;
        uint _height = _findHeight(_blockMerkleRoot); // reverts if header does not exist
        uint _idx = _findIndex(_blockMerkleRoot, _height);
        require(chain[_height][_idx].startDisputeTime + disputeTime > block.timestamp, "Relay: dispute time has passed");
        require(chain[_height][_idx].disputer == address(0), "Relay: header disputed before");

        chain[_height][_idx].disputer = _msgSender();
        chain[_height][_idx].startProofTime = block.timestamp;

        emit BlockDisputed(
            _height,
            _blockMerkleRoot,
            _msgSender(),
            chain[_height][_idx].relayer
        );

        return true;
    }

    // todo think which functions should be pausible which not

    function getDisputeReward(bytes32 _blockMerkleRoot) external nonReentrant whenNotPaused override returns (bool) {
        /* 
            1. check if the block header exists
            2. check the header has been disputed
            3. check the proof time is passed
            4. check the header has not been verified
        */
        uint _height = _findHeight(_blockMerkleRoot); // reverts if header does not exist
        uint _idx = _findIndex(_blockMerkleRoot, _height);
        require(_disputed(_height, _idx), "Relay: header not disputed");
        require(_proofTimePassed(_height, _idx), "Relay: proof time not passed");
        require(!chain[_height][_idx].verified, "Relay: header has been verified");

        emit DisputeReward(
            _blockMerkleRoot, 
            chain[_height][_idx].disputer,
            chain[_height][_idx].relayer,
            relayers[chain[_height][_idx].relayer],
            disputers[chain[_height][_idx].disputer]
        );

        // send the disputer reward + its collateral
        Address.sendValue(
            payable(chain[_height][_idx].disputer), 
            relayers[chain[_height][_idx].relayer] * disputeRewardPercentage / ONE_HUNDRED_PERCENT + disputers[chain[_height][_idx].disputer]
        );
        relayers[chain[_height][_idx].relayer] = 0;
        disputers[chain[_height][_idx].disputer] = 0;

        return true;
    }

    function provideProof(
        bytes calldata _anchor, 
        bytes calldata _header
    ) external nonReentrant whenNotPaused override returns (bool) {
        // todo check it wouldn't cause a problem if block wasn't disputed before (same for with retarget)
        bytes29 _headerView = _header.ref(0).tryAsHeader();
        bytes29 _anchorView = _anchor.ref(0).tryAsHeader();

        _checkInputSizeProvideProof(_headerView, _anchorView);
        return _checkHeaderProof(_anchorView, _headerView, false);
    }

    function provideProofWithRetarget(
        bytes calldata _oldPeriodStartHeader,
        bytes calldata _oldPeriodEndHeader,
        bytes calldata _header
    ) external nonReentrant whenNotPaused override returns (bool) {
        bytes29 _oldStart = _oldPeriodStartHeader.ref(0).tryAsHeader();
        bytes29 _oldEnd = _oldPeriodEndHeader.ref(0).tryAsHeader();
        bytes29 _headerView = _header.ref(0).tryAsHeader();

        _checkInputSizeProvideProofWithRetarget(_oldStart, _oldEnd, _headerView);

        _checkRetarget(_oldStart, _oldEnd, _headerView.target());

        return _checkHeaderProof(_oldEnd, _headerView, true);
    }

    /// @notice             Adds headers to storage after validating
    /// @dev                We use this function when relay is paused
    /// then only owner can add the new blocks, like when a fork happens
    /// @param  _anchor     The header immediately preceeding the new chain
    /// @param  _headers    A tightly-packed list of 80-byte Bitcoin headers
    /// @return             True if successfully written, error otherwise
    function ownerAddHeaders(bytes calldata _anchor, bytes calldata _headers) external nonReentrant onlyOwner override returns (bool) {
        bytes29 _anchorView = _anchor.ref(0).tryAsHeader();
        bytes29 _headersView = _headers.ref(0).tryAsHeaderArray();

        _checkInputSizeAddHeaders(_headersView, _anchorView);

        return _ownerAddHeaders(_anchorView, _headersView, false);
    }

    /// @notice                       Adds headers to storage, performs additional validation of retarget
    /// @dev                          Works like the other addHeadersWithRetarget; we use this function when relay is paused
    /// then only owner can add the new blocks, like when a fork happens
    /// @param  _oldPeriodStartHeader The first header in the difficulty period being closed
    /// @param  _oldPeriodEndHeader   The last header in the difficulty period being closed (anchor of new headers)
    /// @param  _headers              A tightly-packed list of 80-byte Bitcoin headers
    /// @return                       True if successfully written, error otherwise
    function ownerAddHeadersWithRetarget(
        bytes calldata _oldPeriodStartHeader,
        bytes calldata _oldPeriodEndHeader,
        bytes calldata _headers
    ) external nonReentrant onlyOwner override returns (bool) {
        bytes29 _oldStart = _oldPeriodStartHeader.ref(0).tryAsHeader();
        bytes29 _oldEnd = _oldPeriodEndHeader.ref(0).tryAsHeader();
        bytes29 _headersView = _headers.ref(0).tryAsHeaderArray();
        bytes29 _newStart = _headersView.indexHeaderArray(0);

        _checkInputSizeAddHeaders(_oldStart, _oldEnd);
        _checkInputSizeAddHeaders(_headersView, _newStart);

        _checkRetarget(_oldStart, _oldEnd, _newStart.target());

        return _ownerAddHeaders(_oldEnd, _headersView, true);
    }

    // todo emit events everywhere
    // todo NatSpec

    function _ownerAddHeaders(bytes29 _anchor, bytes29 _headers, bool _withRetarget) internal returns (bool) {
        bytes29 _newAnchor = _anchor;
        bytes32 _anchorMerkleRoot;
        bytes32 _blockMerkleRoot;
        for (uint256 i = 0; i < _headers.len() / 80; i++) {
            bytes29 _header = _headers.indexHeaderArray(i);
            _blockMerkleRoot = _header.merkleRoot();
            _anchorMerkleRoot = _newAnchor.merkleRoot();
            _addBlock(_anchorMerkleRoot, _blockMerkleRoot);
            // Extract basic info
            uint256 _height = _findHeight(_blockMerkleRoot); // revert if the block is unknown
            uint _idx = _findIndex(_blockMerkleRoot, _height);

            // check the proof validity: no retarget, hash link good, enough PoW
            _checkProofValidity(_newAnchor, _header, ((i == 0) ? _withRetarget : false));

            // mark the header as verified
            chain[_height][_idx].verified = true;
            emit BlockVerified(
                _height,
                _blockMerkleRoot,
                _anchorMerkleRoot,
                _msgSender(),
                address(0)
            );
            _newAnchor = _header;
        }
        return true;
    }

    function _checkRetarget(bytes29 _oldStart, bytes29 _oldEnd, uint256 _actualTarget) internal view {
        // requires that both blocks are known
        uint256 _startHeight = _findHeight(_oldStart.merkleRoot());
        uint256 _endHeight = _findHeight(_oldEnd.merkleRoot());

        // retargets should happen at 2016 block intervals
        require(
            _endHeight % BitcoinHelper.RETARGET_PERIOD_BLOCKS == 2015,
            "Relay: must provide the last header of the closing difficulty period");
        require(
            _endHeight == _startHeight + 2015,
            "Relay: must provide exactly 1 difficulty period");
        require(
            _oldStart.diff() == _oldEnd.diff(),
            "Relay: period header difficulties do not match");

        /* NB: This comparison looks weird because header nBits encoding truncates targets */
        uint256 _expectedTarget = BitcoinHelper.retargetAlgorithm(
            _oldStart.target(),
            _oldStart.time(),
            _oldEnd.time()
        );
        require(
            (_actualTarget & _expectedTarget) == _actualTarget, 
            "Relay: invalid retarget provided"
        );
    }

    function _checkHeaderProof(bytes29 _anchor, bytes29 _header, bool _withRetarget) internal returns (bool) {
        // Extract basic info
        bytes32 _blockMerkleRoot = _header.merkleRoot();
        uint256 _height = _findHeight(_blockMerkleRoot); // revert if the block is unknown
        uint _idx = _findIndex(_blockMerkleRoot, _height);

        // check not verified yet and proof time not passed
        _checkProofCanBeProvided(_height, _idx);

        // match the stored data with provided data: parent merkle root
        _checkStoredDataMatch(_anchor, _height, _idx);

        // check the proof validity: no retarget, hash link good, enough PoW
        _checkProofValidity(_anchor, _header, _withRetarget);

        // mark the header as verified and give back the collateral
        _verifyHeaderAfterDispute(_height, _idx);

        return true;
    }

    function _checkStoredDataMatch(bytes29 _anchor, uint _height, uint _idx) internal view {
        // check parent merkle root matches
        require(_anchor.merkleRoot() == previousBlock[chain[_height][_idx].merkleRoot], "Relay: provided anchor data not match");
    }

    function _checkProofValidity(bytes29 _anchor, bytes29 _header, bool _withRetarget) internal view {
        // extract basic info
        bytes32 _anchorMerkleRoot = _anchor.merkleRoot();
        uint _anchorHeight = _findHeight(_anchorMerkleRoot); // reverts if the header doesn't exist
        uint256 _height = _anchorHeight + 1;
        uint256 _target = _header.target();

        // no retargetting should happen
        require(
            _withRetarget || _anchor.target() == _target,
            "Relay: unexpected retarget on external call"
        );

        // Blocks that are multiplies of 2016 should be submitted using withRetarget
        require(
            _withRetarget || _height % BitcoinHelper.RETARGET_PERIOD_BLOCKS != 0,
            "Relay: proof should be submitted by calling provideProofWithRetarget"
        );

        // check previous block link is correct
        require(_header.checkParent(_anchor.hash256()), "Relay: headers do not form a consistent chain");
        
        // check that the header has sufficient work
        require(
            TypedMemView.reverseUint256(uint256(_header.hash256())) <= _target,
            "Relay: header work is insufficient"
        );
    }

    function _verifyHeaderAfterDispute(uint _height, uint _idx) internal {
        chain[_height][_idx].verified = true;
        // send relayer its collateral + reward (if disputer exists)
        Address.sendValue(
            payable(chain[_height][_idx].relayer), 
            relayers[chain[_height][_idx].relayer] + disputers[chain[_height][_idx].disputer] * proofRewardPercentage / ONE_HUNDRED_PERCENT
        ); 
        relayers[chain[_height][_idx].relayer] = 0;
        disputers[chain[_height][_idx].disputer] = 0;
        emit BlockVerified(
            _height,
            chain[_height][_idx].merkleRoot,
            previousBlock[chain[_height][_idx].merkleRoot],
            chain[_height][_idx].relayer,
            chain[_height][_idx].disputer
        );
    }

    function _checkProofCanBeProvided(uint _height, uint _idx) internal view {
        // not verified before
        require(!chain[_height - 1][_idx].verified, "Relay: header been verified before");
        // proof time is not passed
        require(_disputed(_height, _idx) && !_proofTimePassed(_height, _idx) 
            || !_disputed(_height, _idx) , "Relay: proof time passed");
    }

    /// @notice                 Checks the size of addHeader inputs 
    /// @param  _headerView1    Input to the provideProof functions
    /// @param  _headerView2    Input to the provideProof functions
    function _checkInputSizeProvideProof(bytes29 _headerView1, bytes29 _headerView2) internal pure {
        require(
            _headerView1.notNull() && _headerView2.notNull(),
            "Relay: bad args. Check header and array byte lengths."
        );
    }

    /// @notice                 Checks the size of addHeader inputs 
    /// @param  _headerView1    Input to the provideProof functions
    /// @param  _headerView2    Input to the provideProof functions
    /// @param  _headerView3    Input to the provideProof functions
    function _checkInputSizeProvideProofWithRetarget(
        bytes29 _headerView1, 
        bytes29 _headerView2,
        bytes29 _headerView3
        ) internal pure {
        require(
            _headerView1.notNull() && _headerView2.notNull() && _headerView3.notNull(),
            "Relay: bad args. Check header and array byte lengths."
        );
    }

    /// @notice                 Checks the size of addHeaders inputs 
    /// @param  _headersView    Input to the addHeaders and ownerAddHeaders functions
    /// @param  _anchorView     Input to the addHeaders and ownerAddHeaders functions
    function _checkInputSizeAddHeaders(bytes29 _headersView, bytes29 _anchorView) internal pure {
        require(_headersView.notNull(), "BitcoinRelay: header array length must be divisible by 80");
        require(_anchorView.notNull(), "BitcoinRelay: anchor must be 80 bytes");
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

    function _verifyHeader(uint _height, uint _idx) internal {
        chain[_height][_idx].verified = true;
        // send back the collateral
        Address.sendValue(payable(chain[_height][_idx].relayer), relayers[chain[_height][_idx].relayer]);
        relayers[chain[_height][_idx].relayer] = 0;

        emit BlockVerified(
            _height,
            chain[_height][_idx].merkleRoot,
            previousBlock[chain[_height][_idx].merkleRoot],
            chain[_height][_idx].relayer,
            chain[_height][_idx].disputer
        );
    }

    /// @notice             Adds header to storage
    /// @dev                We do not get a block on top of an unverified block
    /// @return             True if successfully written, error otherwise
    function _addBlock(bytes32 _anchorMerkleRoot, bytes32 _blockMerkleRoot) internal returns (bool) {
        // Extract basic info
        uint256 _anchorHeight = _findHeight(_anchorMerkleRoot); // revert if the block is unknown
        uint256 _height = _anchorHeight + 1;

        /*
            0. check the height on top of the anchor is not finalized
            1. check if a previous height block gets verified
            2. check the previous block is verified
            3. check that the blockData is not a replica
            4. Store the block connection
            5. Store the height
            6. store the block in the chain
        */

        require(
            _height + finalizationParameter > lastVerifiedHeight, 
            "Relay: block header is too old"
        );

        // The below check prevents adding a replicated block header
        require(
            previousBlock[_blockMerkleRoot] == bytes32(0),
            "Relay: the block header exists on the relay"
        );

        // find the previous header
        // todo test: when no prev block exists, and when two exist,also check block.timestamp is correct and
        // does not have a huge error
        uint _idx = _findIndex(_anchorMerkleRoot, _anchorHeight);
        require(_idx < chain[_anchorHeight].length, "Relay: anchor doesn't exist");

        // check if a previous height block gets verified
        if (!_disputed(_anchorHeight, _idx)) {
            require(_disputeTimePassed(_anchorHeight, _idx), "Relay: previous block not verified yet");
            if (!chain[_anchorHeight][_idx].verified) {
                _verifyHeader(_anchorHeight, _idx);
            }
        }
        require(chain[_anchorHeight][_idx].verified, "Relay: previous block not verified");

        // check if any block gets finalized
        if(_anchorHeight > lastVerifiedHeight){
            lastVerifiedHeight += 1;
            _updateFee();
            _pruneChain();
        }

        previousBlock[_blockMerkleRoot] = _anchorMerkleRoot;
        blockHeight[_blockMerkleRoot] = _height;
        emit BlockAdded(_height, _blockMerkleRoot, _anchorMerkleRoot, _msgSender());
        _addToChain(_blockMerkleRoot, _height);
        
        return true;
    }

    function _disputed(uint _height, uint _idx) internal view returns (bool) {
        return (chain[_height][_idx].disputer == address(0)) ? false : true;
    }

    function _disputeTimePassed(uint _height, uint _idx) internal view returns (bool) {
        return (block.timestamp - chain[_height][_idx].startDisputeTime >= disputeTime) ? true : false;
    }
    
    function _proofTimePassed(uint _height, uint _idx) internal view returns (bool) {
        return (block.timestamp - chain[_height][_idx].startProofTime >= proofTime) ? true : false;
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
    /// @param  _blockMerkleRoot    The Merkle root of the new block's txs
    /// @param  _height             The height of the new block 
    function _addToChain(bytes32 _blockMerkleRoot, uint _height) internal {
        // Prevent relayers to submit too old block headers
        blockData memory newblockData;
        newblockData.merkleRoot = _blockMerkleRoot;
        newblockData.relayer = _msgSender();
        newblockData.gasPrice = tx.gasprice;
        newblockData.verified = false;
        newblockData.startDisputeTime = block.timestamp;
        chain[_height].push(newblockData);
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
            uint _idx = finalizationParameter;
            uint currentHeight = lastVerifiedHeight;
            uint stableIdx = 0;
            while (_idx > 0) {
                bytes32 parentMerkleRoot = previousBlock[chain[currentHeight][stableIdx].merkleRoot];
                stableIdx = _findIndex(parentMerkleRoot, currentHeight-1);
                _idx--;
                currentHeight--;
            }
            // Keep the finalized block header and delete rest of headers
            if(chain[currentHeight].length > 1){
                if(stableIdx != 0) {
                    blockHeight[chain[currentHeight][0].merkleRoot] = 0;
                    chain[currentHeight][0] = chain[currentHeight][stableIdx];
                }
                
                _pruneHeight(currentHeight, stableIdx);
            }
            // A new block has been finalized, we send its relayer's reward
            uint rewardAmountTNT;
            uint rewardAmountTDT;
            (rewardAmountTNT, rewardAmountTDT) = _sendReward(chain[currentHeight][0].relayer, currentHeight);

            emit BlockFinalized(
                currentHeight,
                chain[currentHeight][0].merkleRoot,
                previousBlock[chain[currentHeight][0].merkleRoot],
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
    /// @return                     If the header exists: its index, if not: # of headers in that height
    function _findIndex(bytes32 _blockMerkleRoot, uint _height) internal view returns(uint) {
        for (uint256 _index = 0; _index < chain[_height].length; _index++) {
            if(_blockMerkleRoot == chain[_height][_index].merkleRoot) {
                return _index;
            }
        }
        return chain[_height].length;
    }

    /// @notice                     Deletes all the block header in the same height except the first header
    /// @dev                        The first header is the one that has gotten finalized
    /// @param  _height             The height of the new block header
    function _pruneHeight(uint _height, uint _stableIdx) internal {
        uint _idx = chain[_height].length - 1;
        while(_idx > 0){
            if(_idx != _stableIdx) {
                blockHeight[chain[_height][_idx].merkleRoot] = 0;
            }
            chain[_height].pop();
            _idx -= 1;
        }
    }
}
