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
import "hardhat/console.sol";

contract Relay is IRelay, Ownable, ReentrancyGuard, Pausable {

    using TypedMemView for bytes;
    using TypedMemView for bytes29;
    using BitcoinHelper for bytes29;
    using SafeERC20 for IERC20;

    // Public variables
    uint constant ONE_HUNDRED_PERCENT = 10000;
    uint constant MAX_FINALIZATION_PARAMETER = 432; // roughly 3 days
    uint constant MIN_DISPUTE_TIME = 8 minutes;
    uint constant MIN_PROOF_TIME = 5 minutes;

    uint public override initialHeight;
    uint public override lastVerifiedHeight;
    uint public override finalizationParameter;
    uint public override rewardAmountInTDT;
    uint public override relayerPercentageFee; // A number between [0, 10000)
    uint public override submissionGasUsed; // Gas used for submitting a Merkle root
    uint public override epochLength;
    uint public override baseQueries;
    uint public override currentEpochQueries;
    uint public override lastEpochQueries;
    uint public override disputeTime;
    uint public override proofTime;
    address public override TeleportDAOToken;
    bytes32 public override relayGenesisMerkleRoot; // Initial Merkle root of relay
    uint public override minCollateralRelayer;
    uint public override numCollateralRelayer;
    uint public override minCollateralDisputer;
    uint public override numCollateralDisputer;
    uint public override disputeRewardPercentage;
    uint public override proofRewardPercentage;
    uint public override epochStartTimestamp;
    uint[] public override nonFinalizedEpochStartTimestamp;
    uint public override currTarget;
    uint[] public override nonFinalizedCurrTarget;

    // Private and internal variables
    mapping(uint => blockData[]) private chain; // height => list of block data
    mapping(bytes32 => bytes32) internal parentRoot; // block Merkle root => parent Merkle root
    mapping(bytes32 => uint256) internal blockHeight; // block Merkle root => block height
    mapping(address => uint) internal relayersCollateral; // relayer address => locked collateral
    mapping(address => uint) internal disputersCollateral; // disputer address => locked collateral

    // todo delete parentRoot[] of the blocks that has gotten finalized to save gas
    // but also add a bool to save submission of a block to prevent replicas

    /// @notice Gives a starting point for the relay
    /// @param  _genesisMerkleRoot The starting header Merkle root
    /// @param  _height The starting height of relay
    /// @param  _periodStart The Merkle root of the first header in the genesis epoch
    /// @param  _TeleportDAOToken The address of the TeleportDAO ERC20 token contract
    constructor(
        bytes32 _genesisMerkleRoot, 
        uint256 _height,
        bytes32 _periodStart,
        uint _periodStartTimestamp,
        uint _currTarget,
        address _TeleportDAOToken
    ) {
        // Adds the initial block header to the chain
        require(_genesisMerkleRoot != bytes32(0), "Relay: genesis root is zero");
        // genesis header and period start can be same
        relayGenesisMerkleRoot = _genesisMerkleRoot;
        blockData memory newblockData;
        newblockData.merkleRoot = _genesisMerkleRoot;
        newblockData.relayer = _msgSender();
        newblockData.gasPrice = 0;
        newblockData.verified = true;
        chain[_height].push(newblockData);
        blockHeight[_genesisMerkleRoot] = _height;
        blockHeight[_periodStart] = _height - (_height % BitcoinHelper.RETARGET_PERIOD_BLOCKS);
        epochStartTimestamp = _periodStartTimestamp;
        currTarget = _currTarget;

        // Relay parameters
        _setFinalizationParameter(5);
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

    /// @notice Pause the relay
    /// @dev Only functions with whenPaused modifier can be called
    function pauseRelay() external override onlyOwner {
        _pause();
    }

    /// @notice Unpause the relay
    /// @dev Only functions with whenNotPaused modifier can be called
    function unpauseRelay() external override onlyOwner {
        _unpause();
    }

    /// @notice Getter for a specific Merkle root in the stored chain
    /// @param  _height of the desired Merkle root
    /// @param  _index of the desired Merkle root in that height
    /// @return Merkle root
    function getBlockMerkleRoot(uint _height, uint _index) external view override returns (bytes32) {
        return chain[_height][_index].merkleRoot;
    } // todo where do we use this? prvsly it was getBlockHeaderHash... can't have public

    /// @notice Getter for fee of using a specific Merkle root
    /// @param  _height of the desired Merkle root
    /// @param  _index of the desired Merkle root in that height
    /// @return Fee of querying the Merkle root
    function getBlockUsageFee(uint _height, uint _index) external view override returns (uint) {
        return _calculateFee(chain[_height][_index].gasPrice);
    }

    /// @notice  Getter for the number of submitted Merkle roots in the same height
    /// @dev This shows the number of temporary forks in that specific height
    /// @param  _height The desired height of the blockchain
    /// @return Number of Merkle roots stored in the same height
    function getNumberOfSubmittedHeaders(uint _height) external view override returns (uint) {
        return chain[_height].length;
    }

    /// @notice Getter for available TDT in contract
    /// @return Amount of TDT available in Relay
    function availableTDT() external view override returns (uint) {
        return IERC20(TeleportDAOToken).balanceOf(address(this));
    }

    /// @notice Getter for available target native token in contract
    /// @return Amount of target blockchain native token available in Relay
    function availableTNT() external view override returns (uint) {
        return address(this).balance - minCollateralDisputer * numCollateralDisputer - minCollateralRelayer * numCollateralRelayer;
    }

    /// @notice Finds the height of a Merkle root
    /// @dev Will fail if the Merkle root is unknown
    /// @param _hash  Desired Merkle root
    /// @return Height of the Merkle root, or error if unknown
    function findHeight(bytes32 _hash) external view override returns (uint256) {
        return _findHeight(_hash);
    }

    /// @notice Setter for reward amount of Merkle root submission (in TDT)
    /// @dev For each Merkle root that becomes finalized, the Relayer will receive this reward
    /// @param _rewardAmountInTDT The reward amount in TDT
    function setRewardAmountInTDT(uint _rewardAmountInTDT) external override onlyOwner {
        _setRewardAmountInTDT(_rewardAmountInTDT);
    }

    /// @notice Setter for Relay finalization parameter
    /// @dev This might change to increase/decrease the Relay security
    /// @param _finalizationParameter of Relay
    function setFinalizationParameter(uint _finalizationParameter) external override onlyOwner {
        _setFinalizationParameter(_finalizationParameter);
    }

    /// @notice Setter for Relayer percentage fee
    /// @dev If Relayer paid X for submitting a Merkle root, it will receive X*(1 + _relayerPercentageFee) 
    ///      from the contract
    /// @param _relayerPercentageFee Determines percentage of reward to the Relayer
    function setRelayerPercentageFee(uint _relayerPercentageFee) external override onlyOwner {
        _setRelayerPercentageFee(_relayerPercentageFee);
    }

    /// @notice Setter for TeleportDAO token
    /// @param _TeleportDAOToken The TeleportDAO token address
    function setTeleportDAOToken(address _TeleportDAOToken) external override onlyOwner {
        _setTeleportDAOToken(_TeleportDAOToken);
    }

    /// @notice Ssetter for epoch length
    /// @param _epochLength The length of epochs for calculating fee of using Relay
    function setEpochLength(uint _epochLength) external override onlyOwner {
        _setEpochLength(_epochLength);
    }

    /// @notice Setter for baseQueries
    /// @param _baseQueries The base number of queries we assume in each epoch
    ///                     This is for preventing user fees to grow significantly
    function setBaseQueries(uint _baseQueries) external override onlyOwner {
        _setBaseQueries(_baseQueries);
    }

    /// @notice Setter for submissionGasUsed
    /// @param _submissionGasUsed The gas used for submitting one Merkle root
    function setSubmissionGasUsed(uint _submissionGasUsed) external override onlyOwner {
        _setSubmissionGasUsed(_submissionGasUsed);
    }

    /// @notice Setter for disputeTime
    /// @param _disputeTime The duration in which a block can be disputed after getting submitted
    function setDisputeTime(uint _disputeTime) external override onlyOwner {
        _setDisputeTime(_disputeTime);
    }

    /// @notice Setter for proofTime
    /// @param _proofTime The duration in which a proof can be provided (after getiing dispute)
    function setProofTime(uint _proofTime) external override onlyOwner {
        _setProofTime(_proofTime);
    }

    /// @notice Setter for minCollateralRelayer
    /// @param _minCollateralRelayer The min amount of collateral needed for submitting one block
    function setMinCollateralRelayer(uint _minCollateralRelayer) external override onlyOwner {
        _setMinCollateralRelayer(_minCollateralRelayer);
    }

    /// @notice Setter for minCollateralDisputer
    /// @param _minCollateralDisputer The min amount of collateral needed for disputing one block
    function setMinCollateralDisputer(uint _minCollateralDisputer) external override onlyOwner {
        _setMinCollateralDisputer(_minCollateralDisputer);
    }

    /// @notice Ssetter for disputeRewardPercentage
    /// @param _disputeRewardPercentage A percentage of the Relayer collateral that goes to the disputer
    ///                                 (if dispute was successful)
    function setDisputeRewardPercentage(uint _disputeRewardPercentage) external override onlyOwner {
        _setDisputeRewardPercentage(_disputeRewardPercentage);
    }
    
    /// @notice Setter for proofRewardPercentage
    /// @param _proofRewardPercentage A percentage of the disputer collateral that goes to the Relayer
    ///                               (if dispute was unsuccessful)
    function setProofRewardPercentage(uint _proofRewardPercentage) external override onlyOwner {
        _setProofRewardPercentage(_proofRewardPercentage);
    }

    /// @notice Checks if a tx is included and finalized on Bitcoin
    /// @dev Checks if the block is finalized, and Merkle proof is correct
    /// @param  _txid Desired tx Id in LE form
    /// @param  _blockHeight of the desired tx
    /// @param  _intermediateNodes Part of the Merkle tree from the tx to the root (Merkle proof) in LE form
    /// @param  _index of the tx in Merkle tree
    /// @return True if the provided tx is confirmed on Bitcoin
    function checkTxProof (
        bytes32 _txid, // In LE form
        uint _blockHeight,
        bytes calldata _intermediateNodes, // In LE form
        uint _index
    ) external payable nonReentrant whenNotPaused override returns (bool) {
        require(_txid != bytes32(0), "Relay: txid should be non-zero");

        // Update status of Merkle roots of last submitted height (if any of them gets verified)
        if (_blockHeight + finalizationParameter == lastVerifiedHeight + 1) {
            _updateVerifiedAndFinalizedStats();
        }

        // Revert if the block is not finalized
        require(
            _blockHeight + finalizationParameter <= lastVerifiedHeight,
            "Relay: not finalized"
        );

        // Block should exist on the relay
        require(
            _blockHeight >= initialHeight,
            "Relay: old block"
        );
        
        // Count number of queries for fee calculation
        currentEpochQueries += 1;

        // Get the relay fee from the user
        _getFee(chain[_blockHeight][0].gasPrice);

        // Check the inclusion of the transaction
        bytes29 intermediateNodes = _intermediateNodes.ref(0).tryAsMerkleArray(); // Check for errors if any
        return BitcoinHelper.prove(_txid, chain[_blockHeight][0].merkleRoot, intermediateNodes, _index);
    }

    /// @notice Adds Merkle root to storage
    /// @param  _anchorMerkleRoot The merkle root immediately preceeding the new chain
    /// @param  _blockMerkleRoot A merkle root
    /// @return True if successfully stored
    function addBlock(
        bytes32 _anchorMerkleRoot, 
        bytes32 _blockMerkleRoot
    ) external payable nonReentrant whenNotPaused override returns (bool) {
        // check relayer locks enough collateral
        require(msg.value >= minCollateralRelayer, "Relay: low collateral");
        relayersCollateral[_msgSender()] += msg.value;
        numCollateralRelayer ++;
        
        // check inputs
        require(
            _blockMerkleRoot != bytes32(0) && _anchorMerkleRoot != bytes32(0), 
            "Relay: zero input"
        );

        _addBlock(_anchorMerkleRoot, _blockMerkleRoot, false);

        return true;
    }

    function addBlockWithRetarget(
        bytes32 _anchorMerkleRoot, 
        bytes32 _blockMerkleRoot,
        uint256 _blockTimestamp,
        uint256 _newTarget
    ) external payable nonReentrant whenNotPaused override returns (bool) {
        // check relayer locks enough collateral
        require(msg.value >= minCollateralRelayer, "Relay: low collateral");
        relayersCollateral[_msgSender()] += msg.value;
        numCollateralRelayer ++;
        
        // check inputs
        require(
            _blockMerkleRoot != bytes32(0) && _anchorMerkleRoot != bytes32(0), 
            "Relay: zero input"
        );

        nonFinalizedEpochStartTimestamp.push(_blockTimestamp);
        nonFinalizedCurrTarget.push(_newTarget);
        
        _addBlock(_anchorMerkleRoot, _blockMerkleRoot, true);

        return true;
    }

    /// @notice Disputes an unverified Merkle root
    /// @param  _blockMerkleRoot to dispute
    /// @return True if successfully passed
    function disputeBlock(
        bytes32 _blockMerkleRoot
    ) external payable nonReentrant override returns (bool) {
        /*
            Steps:
            1. Check the caller is paying enough collateral
            2. Check if the Merkle root exists
            3. Check its dispute time has not passed
            4. Check it has not been disputed before
        */
        
        require(msg.value >= minCollateralDisputer, "Relay: low collateral");

        // Saves collateral amount
        disputersCollateral[_msgSender()] += msg.value;
        numCollateralDisputer ++;
        uint _height = _findHeight(_blockMerkleRoot); // Reverts if header does not exist
        uint _idx = _findIndex(_blockMerkleRoot, _height);
        require(
            chain[_height][_idx].startDisputeTime + disputeTime > block.timestamp, 
            "Relay: dispute time passed"
        );
        require(
            chain[_height][_idx].disputer == address(0),
            "Relay: disputed before"
        );

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

    function getDisputeReward(
        bytes32 _blockMerkleRoot
    ) external nonReentrant whenNotPaused override returns (bool) {
        /* 
            Steps:
            1. Check if the Merkle root exists
            2. Check the Merkle root has been disputed
            3. Check the proof time is passed
            4. Check the Merkle root has not been verified
        */
        uint _height = _findHeight(_blockMerkleRoot); // Reverts if header does not exist
        uint _idx = _findIndex(_blockMerkleRoot, _height);
        require(_isDisputed(_height, _idx), "Relay: not disputed");
        require(_proofTimePassed(_height, _idx), "Relay: proof time not passed");
        require(!chain[_height][_idx].verified, "Relay: already verified");

        emit DisputeReward(
            _blockMerkleRoot, 
            chain[_height][_idx].disputer,
            chain[_height][_idx].relayer
        );
        relayersCollateral[chain[_height][_idx].relayer] -= minCollateralRelayer;
        disputersCollateral[chain[_height][_idx].disputer] -= minCollateralDisputer; 
        // Sends the disputer reward + its collateral
        Address.sendValue(
            payable(chain[_height][_idx].disputer), // TODO: send the rest to the treasury
            minCollateralRelayer * disputeRewardPercentage / ONE_HUNDRED_PERCENT
                + minCollateralDisputer
        );
        numCollateralRelayer --;
        numCollateralDisputer --;

        return true;
    }

    function provideProof(
        bytes calldata _anchor, 
        bytes calldata _header
    ) external nonReentrant whenNotPaused override returns (bool) {
        // todo check it wouldn't cause a problem if block wasn't disputed before (same for with retarget)
        bytes29 _headerView = _header.ref(0).tryAsHeader();
        bytes29 _anchorView = _anchor.ref(0).tryAsHeader();
        _checkInputSize(_headerView, _anchorView);
        return _checkHeaderProof(_anchorView, _headerView, false);
    }

    function provideProofWithRetarget(
        bytes calldata _oldPeriodEndHeader,
        bytes calldata _header
    ) external nonReentrant whenNotPaused override returns (bool) {
        bytes29 _oldEnd = _oldPeriodEndHeader.ref(0).tryAsHeader();
        bytes29 _headerView = _header.ref(0).tryAsHeader();

        _checkInputSize(_oldEnd, _headerView);
        _checkEpochEndBlock(_oldEnd);
        _checkRetarget(_oldEnd.time(), _oldEnd.target(), _headerView.target());

        return _checkHeaderProof(_oldEnd, _headerView, true);
    }

    /// @notice Adds headers to storage after validating
    /// @dev We use this function when relay is paused
    ///      then only owner can add the new blocks (e.g. when a fork happens)
    /// @param  _anchor The header immediately preceeding the new chain
    /// @param  _headers A tightly-packed list of 80-byte Bitcoin headers
    /// @return True if successfully written, error otherwise
    function ownerAddHeaders(
        bytes calldata _anchor, 
        bytes calldata _headers
    ) external nonReentrant onlyOwner override returns (bool) {
        bytes29 _anchorView = _anchor.ref(0).tryAsHeader();
        bytes29 _headersView = _headers.ref(0).tryAsHeaderArray();

        _checkInputSize(_headersView, _anchorView);

        return _ownerAddHeaders(_anchorView, _headersView, false);
    }

    /// @notice Adds headers to storage, performs additional validation of retarget
    /// @dev Works like the other addHeadersWithRetarget; we use this function when relay is paused
    ///      then only owner can add the new blocks (e.g. when a fork happens)
    /// @param  _oldPeriodEndHeader The last header in the difficulty period being closed (anchor of new headers)
    /// @param  _headers A tightly-packed list of 80-byte Bitcoin headers
    /// @return True if successfully written
    function ownerAddHeadersWithRetarget(
        bytes calldata _oldPeriodEndHeader,
        bytes calldata _headers
    ) external nonReentrant onlyOwner override returns (bool) {
        bytes29 _oldEnd = _oldPeriodEndHeader.ref(0).tryAsHeader();
        bytes29 _headersView = _headers.ref(0).tryAsHeaderArray();
        bytes29 _newStart = _headersView.indexHeaderArray(0);

        _checkInputSize(_headersView, _oldEnd);
        _checkInputSize(_headersView, _newStart); // repeated bcz the func has 2 inputs

        _checkEpochEndBlock(_oldEnd);
        _checkRetarget(_oldEnd.time(), _oldEnd.target(), _newStart.target());
        nonFinalizedEpochStartTimestamp.push(_newStart.time());
        nonFinalizedCurrTarget.push(_newStart.target());

        return _ownerAddHeaders(_oldEnd, _headersView, true);
    }

    // todo NatSpec

    // *************** Internal and private functions ***************

    /// @notice Internal setter for rewardAmountInTDT
    function _setRewardAmountInTDT(uint _rewardAmountInTDT) private {
        emit NewRewardAmountInTDT(rewardAmountInTDT, _rewardAmountInTDT);
        // this reward can be zero as well
        rewardAmountInTDT = _rewardAmountInTDT;
    }

    /// @notice Internal setter for finalizationParameter
    function _setFinalizationParameter(uint _finalizationParameter) private {
        emit NewFinalizationParameter(finalizationParameter, _finalizationParameter);
        require(
            _finalizationParameter > 0 && _finalizationParameter <= MAX_FINALIZATION_PARAMETER,
            "Relay: invalid finalization param"
        );

        finalizationParameter = _finalizationParameter;
    }

    /// @notice Internal setter for relayerPercentageFee
    function _setRelayerPercentageFee(uint _relayerPercentageFee) private {
        emit NewRelayerPercentageFee(relayerPercentageFee, _relayerPercentageFee);
        require(
            _relayerPercentageFee <= ONE_HUNDRED_PERCENT,
            "Relay: relay fee is above max"
        );
        relayerPercentageFee = _relayerPercentageFee;
    }

    /// @notice Internal setter for teleportDAO token
    function _setTeleportDAOToken(address _TeleportDAOToken) private {
        emit NewTeleportDAOToken(TeleportDAOToken, _TeleportDAOToken);
        TeleportDAOToken = _TeleportDAOToken;
    }

    /// @notice Internal setter for epochLength
    function _setEpochLength(uint _epochLength) private {
        emit NewEpochLength(epochLength, _epochLength);
        require(
            _epochLength > 0,
            "Relay: zero epoch length"
        );
        epochLength = _epochLength;
    }

    /// @notice Internal setter for baseQueries
    function _setBaseQueries(uint _baseQueries) private {
        emit NewBaseQueries(baseQueries, _baseQueries);
        require(
            _baseQueries > 0,
            "Relay: zero base query"
        );
        baseQueries = _baseQueries;
    }

    /// @notice Internal setter for submissionGasUsed
    function _setSubmissionGasUsed(uint _submissionGasUsed) private {
        emit NewSubmissionGasUsed(submissionGasUsed, _submissionGasUsed);
        submissionGasUsed = _submissionGasUsed;
    }

    /// @notice Internal setter for disputeTime
    function _setDisputeTime(uint _disputeTime) private {
        require(_disputeTime >= MIN_DISPUTE_TIME);
        emit NewDisputeTime(disputeTime, _disputeTime);
        disputeTime = _disputeTime;
    }

    /// @notice Internal setter for proofTime
    function _setProofTime(uint _proofTime) private {
        require(_proofTime >= MIN_PROOF_TIME);
        emit NewProofTime(proofTime, _proofTime);
        proofTime = _proofTime;
    }

    /// @notice Internal setter for minCollateralRelayer
    function _setMinCollateralRelayer(uint _minCollateralRelayer) private {
        emit NewMinCollateralRelayer(minCollateralRelayer, _minCollateralRelayer);
        minCollateralRelayer = _minCollateralRelayer;
    }

    /// @notice  Internal setter for minCollateralDisputer
    function _setMinCollateralDisputer(uint _minCollateralDisputer) private {
        emit NewMinCollateralDisputer(minCollateralDisputer, _minCollateralDisputer);
        minCollateralDisputer = _minCollateralDisputer;
    }

    /// @notice Internal setter for disputeRewardPercentage
    function _setDisputeRewardPercentage(uint _disputeRewardPercentage) private {
        emit NewDisputeRewardPercentage(disputeRewardPercentage, _disputeRewardPercentage);
        disputeRewardPercentage = _disputeRewardPercentage;
    }

    /// @notice Internal setter for proofRewardPercentage
    function _setProofRewardPercentage(uint _proofRewardPercentage) private {
        emit NewProofRewardPercentage(proofRewardPercentage, _proofRewardPercentage);
        proofRewardPercentage = _proofRewardPercentage;
    }

    function _ownerAddHeaders(bytes29 _anchor, bytes29 _headers, bool _withRetarget) internal returns (bool) {
        bytes29 _newAnchor = _anchor;
        bytes32 _anchorMerkleRoot;
        bytes32 _blockMerkleRoot;
        for (uint256 i = 0; i < _headers.len() / 80; i++) {
            bytes29 _header = _headers.indexHeaderArray(i);
            _blockMerkleRoot = _header.merkleRoot();
            _anchorMerkleRoot = _newAnchor.merkleRoot();
            _addBlock(_anchorMerkleRoot, _blockMerkleRoot, ((i == 0) ? _withRetarget : false));
            // Extract basic info
            uint256 _height = _findHeight(_blockMerkleRoot); // revert if the block is unknown
            uint _idx = _findIndex(_blockMerkleRoot, _height);

            // check the proof validity: no retarget, hash link good, enough PoW
            _checkProofValidity(_newAnchor, _header, ((i == 0) ? _withRetarget : false));

            // Marks Merkle root as verified (owner doesn't put collateral for submitting blocks)
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

    function _updateVerifiedAndFinalizedStats() internal {
        uint lastSubmittedHeight = lastVerifiedHeight + 1;
        if (chain[lastSubmittedHeight].length != 0) { // if there is any unverified Merkle root
            // check for a new verified Mekrle root
            for(uint _idx = 0; _idx < chain[lastSubmittedHeight].length; _idx++) {
                if (
                    !_isDisputed(lastSubmittedHeight, _idx) &&
                    _disputeTimePassed(lastSubmittedHeight, _idx)
                ) {
                    _verifyHeader(lastSubmittedHeight, _idx); // verify the Merkle root
                    // if new block verified, update finalized stats
                    if (lastVerifiedHeight != lastSubmittedHeight) {
                        lastVerifiedHeight = lastSubmittedHeight;
                        _updateFee();
                        _pruneChain();
                    }
                }
            }
        }
    }

    function _checkEpochEndBlock(bytes29 _oldEnd) internal view {
        // Requires that the block is known
        uint256 _endHeight = _findHeight(_oldEnd.merkleRoot());

        // Retargets should happen at 2016 block intervals
        require(
            _endHeight % BitcoinHelper.RETARGET_PERIOD_BLOCKS == 2015,
            "Relay: wrong end height"
        );
    }
    
    function _checkRetarget(uint256 _epochEndTimestamp, uint256 _oldEndTarget, uint256 _actualTarget) internal view {
        /* NB: This comparison looks weird because header nBits encoding truncates targets */
        uint256 _expectedTarget = BitcoinHelper.retargetAlgorithm(
            _oldEndTarget,
            epochStartTimestamp,
            _epochEndTimestamp
        );
        require(
            (_actualTarget & _expectedTarget) == _actualTarget, 
            "Relay: invalid retarget"
        );
    }

    function _checkHeaderProof(
        bytes29 _anchor, 
        bytes29 _header, 
        bool _withRetarget
    ) internal returns (bool) {
        // Extracts basic info
        bytes32 _blockMerkleRoot = _header.merkleRoot();
        uint256 _height = _findHeight(_blockMerkleRoot); // Revert if the block is unknown
        uint _idx = _findIndex(_blockMerkleRoot, _height);

        // Checks not verified yet & proof time not passed
        _checkProofCanBeProvided(_height, _idx);

        // Matchs the stored data with provided data: parent merkle root
        _checkStoredDataMatch(_anchor, _height, _idx);

        // check the provided timestamp and target are correct
        if(_withRetarget) {
            require(
                nonFinalizedEpochStartTimestamp[_idx] == _header.time(),
                "Relay: incorrect timestamp"
            );
            require(
                nonFinalizedCurrTarget[_idx] == _header.target(),
                "Relay: incorrect target"
            );
        }

        // Checks the proof validity: no retarget & hash link good & enough PoW
        _checkProofValidity(_anchor, _header, _withRetarget);

        // Marks the header as verified and give back the collateral
        _verifyHeaderAfterDispute(_height, _idx);

        return true;
    }

    function _checkStoredDataMatch(bytes29 _anchor, uint _height, uint _idx) internal view {
        // Checks parent merkle root matches
        require(
            _anchor.merkleRoot() == parentRoot[chain[_height][_idx].merkleRoot], 
            "Relay: not match"
        );
    }

    // @notice              Finds an ancestor for a block by its merkle root
    /// @dev                Will fail if the header is unknown
    /// @param _merkleRoot  The header merkle root to search for
    /// @param _offset      The depth which is going to be searched
    /// @return             The height of the header, or error if unknown
    function _findAncestor(bytes32 _merkleRoot, uint256 _offset) internal view returns (bytes32) {
        bytes32 _current = _merkleRoot;
        for (uint256 i = 0; i < _offset; i++) {
            _current = parentRoot[_current];
        }
        require(_current != bytes32(0), "BitcoinRelay: unknown ancestor");
        return _current;
    }

    // TODO: add checking the timestamp not be too high
    /// @notice Checks the validity of proof
    /// @dev Checks that _anchor is parent of _header and it has sufficient PoW
    function _checkProofValidity(
        bytes29 _anchor, 
        bytes29 _header, 
        bool _withRetarget
    ) internal view {
        // Extracts basic info
        bytes32 _anchorMerkleRoot = _anchor.merkleRoot();
        uint _anchorHeight = _findHeight(_anchorMerkleRoot); // Reverts if the header doesn't exist
        uint256 _height = _anchorHeight + 1;
        uint256 _target = _header.target();
        uint _idxInEpoch = _height % BitcoinHelper.RETARGET_PERIOD_BLOCKS;

        // Checks targets are same in the case of no-retarget
        require(
            _withRetarget || _anchor.target() == _target,
            "Relay: unexpected retarget"
        );

        // check the target matches the storage
        if(
            !_withRetarget &&
            _idxInEpoch <= finalizationParameter &&
            nonFinalizedCurrTarget.length != 0
        ) {
            // check _target matches with its ancestor's saved target in nonFinalizedCurrTarget
            require(
                nonFinalizedCurrTarget[_findIndex(_findAncestor(_header.merkleRoot(), _idxInEpoch), _height - _idxInEpoch)]
                == _target
            );
        } else {
            require(
                _withRetarget || (currTarget & _target) == _target,
                "Relay: wrong target"
            );
        }

        // Blocks that are multiplies of 2016 should be submitted using provideProofWithRetarget
        require(
            _withRetarget || _idxInEpoch != 0,
            "Relay: wrong func"
        );

        // Checks previous block link is correct
        require(
            _header.checkParent(_anchor.hash256()), 
            "Relay: no link"
        );
        
        // Checks that the header has sufficient work
        require(
            TypedMemView.reverseUint256(uint256(_header.hash256())) <= _target,
            "Relay: insufficient work"
        );
    }

    function _verifyHeaderAfterDispute(uint _height, uint _idx) internal {
        chain[_height][_idx].verified = true;
        if (lastVerifiedHeight < _height) {
            lastVerifiedHeight += 1;
        }
        relayersCollateral[chain[_height][_idx].relayer] -= minCollateralRelayer;
        numCollateralRelayer --;
        // below check is neccessary because the block might not have been disputed
        if(chain[_height][_idx].disputer != address(0)) {
            disputersCollateral[chain[_height][_idx].disputer] -= minCollateralDisputer;
            numCollateralDisputer --;
        }
        // Sends relayer its collateral + reward (if disputer exists)
        Address.sendValue(payable(chain[_height][_idx].relayer), minCollateralRelayer);
        Address.sendValue(
            payable(_msgSender()),
                minCollateralDisputer * proofRewardPercentage / ONE_HUNDRED_PERCENT // TODO: send the rest to the treasury
        ); 
        emit BlockVerified(
            _height,
            chain[_height][_idx].merkleRoot,
            parentRoot[chain[_height][_idx].merkleRoot],
            chain[_height][_idx].relayer,
            chain[_height][_idx].disputer
        );
    }

    function _checkProofCanBeProvided(uint _height, uint _idx) internal view {
        // Should not been verified before
        require(!chain[_height][_idx].verified, "Relay: already verified");
        // Proof time should not passed
        require(
            (_isDisputed(_height, _idx) && !_proofTimePassed(_height, _idx)) 
                || !_isDisputed(_height, _idx),
            "Relay: proof time passed"
        );
    }

    /// @notice                 Checks the size of addHeader inputs 
    /// @param  _headerView1    Input to the provideProof functions
    /// @param  _headerView2    Input to the provideProof functions
    function _checkInputSize(bytes29 _headerView1, bytes29 _headerView2) internal pure {
        require(
            _headerView1.notNull() && _headerView2.notNull(),
            "Relay: bad args. Check header and array byte lengths."
        );
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

    /// @notice Gets fee from user
    /// @dev Fee is paid in target blockchain native token
    /// @param gasPrice of adding the merkle root
    function _getFee(uint gasPrice) internal {
        uint feeAmount;
        feeAmount = _calculateFee(gasPrice);
        require(msg.value >= feeAmount, "Relay: low fee");
        Address.sendValue(payable(_msgSender()), msg.value - feeAmount);
    }

    /// @notice Calculates the fee amount
    /// @dev Fee is paid in target blockchain native token
    /// @param gasPrice used for adding the Merkle root
    /// @return Fee amount 
    function _calculateFee(uint gasPrice) private view returns (uint) {
        return (submissionGasUsed * gasPrice * (ONE_HUNDRED_PERCENT + relayerPercentageFee) * epochLength) 
            / lastEpochQueries / ONE_HUNDRED_PERCENT;
    }

    /// @notice Verifies a Merkle root
    function _verifyHeader(uint _height, uint _idx) internal {
        chain[_height][_idx].verified = true;
        
        relayersCollateral[chain[_height][_idx].relayer] -= minCollateralRelayer;
        // Sends back the Relayer collateral
        Address.sendValue(
            payable(chain[_height][_idx].relayer), 
            minCollateralRelayer
        );
        numCollateralRelayer --;

        emit BlockVerified(
            _height,
            chain[_height][_idx].merkleRoot,
            parentRoot[chain[_height][_idx].merkleRoot],
            chain[_height][_idx].relayer,
            chain[_height][_idx].disputer
        );
    }

    /// @notice Adds merkle root to storage
    /// @dev We do accepet a merkle root on top of an unverified root
    /// @return True if successfully written
    function _addBlock(bytes32 _anchorMerkleRoot, bytes32 _blockMerkleRoot, bool _withRetarget) internal returns (bool) {
        // Extract basic info
        uint256 _anchorHeight = _findHeight(_anchorMerkleRoot); // revert if the block is unknown
        uint256 _height = _anchorHeight + 1;

        // check if introduces a new epoch
        if(_withRetarget) {
            require(_anchorHeight % BitcoinHelper.RETARGET_PERIOD_BLOCKS == 2015,
                "Relay: call addBlock");
        } else {
            require(_anchorHeight % BitcoinHelper.RETARGET_PERIOD_BLOCKS != 2015,
                "Relay: call addBlockWithRetarget");
        }

        /*
            Steps:
            0. Check _anchorHeight + 1 is not finalized
            1. Check if a previous height block gets verified
            2. Check _anchorMerkleRoot is verified
            3. Check that _blockMerkleRoot hasn't been submitted
            4. Store the block connection
            5. Store the height
            6. Store the block in the chain
        */

        require(
            _height + finalizationParameter > lastVerifiedHeight, 
            "Relay: old block"
        );

        // The below check prevents adding a replicated block header
        require(
            parentRoot[_blockMerkleRoot] == bytes32(0),
            "Relay: already submitted"
        );

        // Find the previous header
        // todo test: when no prev block exists, and when two exist, also check block.timestamp is correct and
        //      does not have a huge error
        uint _idx = _findIndex(_anchorMerkleRoot, _anchorHeight); 

        // Checks if a previous height block gets verified
        if (!_isDisputed(_anchorHeight, _idx)) {
            require(_disputeTimePassed(_anchorHeight, _idx) || chain[_anchorHeight][_idx].verified, "Relay: not verified");

            // Verifies _anchorMerkleRoot if it hasn't verified
            if (!chain[_anchorHeight][_idx].verified) {
                _verifyHeader(_anchorHeight, _idx);
            }
        }
        require(chain[_anchorHeight][_idx].verified, "Relay: previous block not verified"); // TODO: this line is unneccessary i guess?

        // Checks if any block gets finalized (handles when owner adds headers)
        if(_anchorHeight > lastVerifiedHeight){
            lastVerifiedHeight += 1;
            _updateFee();
            _pruneChain();
        }

        parentRoot[_blockMerkleRoot] = _anchorMerkleRoot;
        blockHeight[_blockMerkleRoot] = _height;
        _addToChain(_blockMerkleRoot, _height);
        emit BlockAdded(_height, _blockMerkleRoot, _anchorMerkleRoot, _msgSender());
        
        return true;
    }

    /// @notice Returns true if Merkle root got disputed
    function _isDisputed(uint _height, uint _idx) internal view returns (bool) {
        return (chain[_height][_idx].disputer == address(0)) ? false : true;
    }

    /// @notice Returns true if dispute time is passed
    function _disputeTimePassed(uint _height, uint _idx) internal view returns (bool) {
        return (block.timestamp - chain[_height][_idx].startDisputeTime >= disputeTime) ? true : false;
    }
    
    function _proofTimePassed(uint _height, uint _idx) internal view returns (bool) {
        return (block.timestamp - chain[_height][_idx].startProofTime >= proofTime) ? true : false;
    }

    /// @notice Sends reward and compensation to the relayer
    /// @dev We pay the block submission cost in TNT and the extra reward in TDT
    /// @param  _relayer The relayer address
    /// @param  _height The height of the bitcoin block
    /// @return Reward in native token
    /// @return Reward in TDT token
    function _sendReward(address _relayer, uint _height) internal returns (uint, uint) {

        // Reward in TNT
        uint rewardAmountInTNT = submissionGasUsed * chain[_height][0].gasPrice * 
            (ONE_HUNDRED_PERCENT + relayerPercentageFee) / ONE_HUNDRED_PERCENT;

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
        if (
            address(this).balance - minCollateralDisputer * numCollateralDisputer - minCollateralRelayer * numCollateralRelayer 
                > rewardAmountInTNT && rewardAmountInTNT > 0
        ) {
            // note: no need to revert if failed
            (sentTNT,) = payable(_relayer).call{value: rewardAmountInTNT}("");
        }

        if (sentTNT) {
            return sentTDT ? (rewardAmountInTNT, rewardAmountInTDT) : (rewardAmountInTNT, 0);
        } else {
            return sentTDT ? (0, rewardAmountInTDT) : (0, 0);
        }
    }

    /// @notice Adds a Merkle root to the chain
    /// @param  _blockMerkleRoot of the new block
    /// @param  _height of the new block 
    function _addToChain(bytes32 _blockMerkleRoot, uint _height) internal {
        blockData memory newblockData;
        newblockData.merkleRoot = _blockMerkleRoot;
        newblockData.relayer = _msgSender();
        newblockData.gasPrice = tx.gasprice;
        newblockData.verified = false;
        newblockData.startDisputeTime = block.timestamp;
        chain[_height].push(newblockData);
    }

    /// @notice Reset the number of users in an epoch when a new epoch starts
    /// @dev Updates fee if we enter a new epoch after verifying a new block
    function _updateFee() internal {
        if (lastVerifiedHeight % epochLength == 0) {
            lastEpochQueries = (currentEpochQueries < baseQueries) ? baseQueries : currentEpochQueries;
            currentEpochQueries = 0;
        }
    }

    /// @notice Finalizes a Merkle root and removes all the other roots in that height
    /// @dev When a chain gets pruned, it only deletes blocks of that height. 
    ///      Blocks on higher heights will exist until their height gets pruned.
    function _pruneChain() internal {
        // Make sure that we have at least finalizationParameter blocks on relay
        if ((lastVerifiedHeight - initialHeight) >= finalizationParameter){
            uint _idx = finalizationParameter;
            uint currentHeight = lastVerifiedHeight;
            uint stableIdx = 0;

            // find index of finalized Merkle root
            while(_idx > 0) {
                bytes32 parentMerkleRoot = parentRoot[chain[currentHeight][stableIdx].merkleRoot];
                stableIdx = _findIndex(parentMerkleRoot, currentHeight-1);
                _idx--;
                currentHeight--;
            }

            // if the finalized block is the start of the epoch, save its timestamp and target
            if (currentHeight % BitcoinHelper.RETARGET_PERIOD_BLOCKS == 0) {
                epochStartTimestamp = nonFinalizedEpochStartTimestamp[stableIdx];
                delete nonFinalizedEpochStartTimestamp; // TODO: check if this works correctly
                currTarget = nonFinalizedCurrTarget[stableIdx];
                delete nonFinalizedCurrTarget; // TODO: check if this works correctly
            }

            // Keep the finalized Merkle root and delete rest of roots
            if(chain[currentHeight].length > 1){
                if(stableIdx != 0) {
                    if(!chain[currentHeight][0].verified) {_verifyHeader(currentHeight, 0);}
                    blockHeight[chain[currentHeight][0].merkleRoot] = 0; // Since we copy stableIdx in index 0 of chain, we need to remove index 0 Merkle root from blockHeight here
                    // store finalized merkle root at index 0
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
                parentRoot[chain[currentHeight][0].merkleRoot],
                chain[currentHeight][0].relayer,
                rewardAmountTNT,
                rewardAmountTDT
            );
        }
    }

    /// @notice Finds index of Merkle root in a specific height
    /// @param  _blockMerkleRoot Desired Merkle root
    /// @param  _height of Merkle root
    /// @return _index If the header exists: its index, if not revert
    function _findIndex(bytes32 _blockMerkleRoot, uint _height) internal view returns (uint _index) {
        for (_index = 0; _index < chain[_height].length; _index++) {
            if(_blockMerkleRoot == chain[_height][_index].merkleRoot) {
                return _index;
            }
        }
        require(false, "Relay: unknown block");
    }

    /// @notice Deletes all the block header in the same height except the _stableIdx
    /// @dev The first header is the one that has gotten finalized
    /// @param  _height of pruning
    function _pruneHeight(uint _height, uint _stableIdx) internal {
        uint _idx = chain[_height].length - 1;
        while(_idx > 0){
            if(_idx != _stableIdx) {
                if(!chain[_height][_idx].verified) {_verifyHeader(_height, _idx);}
                blockHeight[chain[_height][_idx].merkleRoot] = 0;
            }
            chain[_height].pop();
            _idx -= 1;
        }
    }
}
